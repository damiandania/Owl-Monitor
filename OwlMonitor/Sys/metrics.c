#include "metrics.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/tcp_fsm.h>
#include <arpa/inet.h>
#include <CoreFoundation/CoreFoundation.h>

// --- CPU temperature via the private IOKit HID event-system API (Apple Silicon thermal sensors).
// These symbols live in IOKit.framework but are absent from the public SDK headers, so we
// forward-declare them here. IOKit is pulled in by `import IOKit` on the Swift side (autolink).
// Reading temperature sensors needs no root and no entitlement.
typedef struct __DMIOHIDEvent *DMIOHIDEventRef;
typedef struct __DMIOHIDServiceClient *DMIOHIDServiceClientRef;
typedef struct __DMIOHIDEventSystemClient *DMIOHIDEventSystemClientRef;

extern DMIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int       IOHIDEventSystemClientSetMatching(DMIOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(DMIOHIDEventSystemClientRef client);
extern CFTypeRef  IOHIDServiceClientCopyProperty(DMIOHIDServiceClientRef service, CFStringRef key);
extern DMIOHIDEventRef IOHIDServiceClientCopyEvent(DMIOHIDServiceClientRef service, int64_t type,
                                                   int32_t options, int64_t timestamp);
extern double     IOHIDEventGetFloatValue(DMIOHIDEventRef event, int32_t field);

#define DM_HID_TEMPERATURE_TYPE  15                          // kIOHIDEventTypeTemperature
#define DM_HID_TEMPERATURE_FIELD (DM_HID_TEMPERATURE_TYPE << 16)  // IOHIDEventFieldBase(type)

// Heuristic: does this sensor's product name look like a CPU/SoC sensor (vs battery, NAND, …)?
static int dm_name_is_cpu(const char *n) {
    return strstr(n, "CPU")  || strstr(n, "SOC")  || strstr(n, "PMGR") ||
           strstr(n, "eACC") || strstr(n, "pACC");
}

static double dm_timebase_scale(void);

double dm_cpu_temperature(void) {
    // Sensors move on a seconds scale, but every read walks the whole HID service list — the most
    // expensive single call in the sampling tick — so cache the answer for ~10 s. Only the
    // sampler's (serialized) background pass calls this, so the statics need no locking. A -1
    // (no readable sensor) is cached too: retrying a missing sensor every tick buys nothing.
    static double cachedTemp = 0;
    static uint64_t cachedAt = 0;
    uint64_t now = mach_absolute_time();
    if (cachedAt != 0 && (double)(now - cachedAt) * dm_timebase_scale() < 10e9) {
        return cachedTemp;
    }

    static DMIOHIDEventSystemClientRef client = NULL;
    if (client == NULL) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (client == NULL) return -1;
        int page = 0xff00;   // kHIDPage_AppleVendor
        int usage = 5;       // kHIDUsage_AppleVendor_TemperatureSensor
        CFNumberRef pageNum  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
        CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[] = { pageNum, usageNum };
        CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match); CFRelease(pageNum); CFRelease(usageNum);
    }

    // The matching sensor-service list doesn't change between reads, so copy it once and reuse it
    // (this is called every sampling tick; re-copying the array each time was the dominant cost).
    // If a read ever yields no valid sensor, the list is dropped and re-copied on the next call —
    // covering the rare case where the services went stale (e.g. across a sleep/wake).
    static CFArrayRef services = NULL;
    if (services == NULL) {
        services = IOHIDEventSystemClientCopyServices(client);
        if (services == NULL) return -1;
    }

    CFIndex n = CFArrayGetCount(services);
    double cpuSum = 0, allSum = 0;
    int cpuCount = 0, allCount = 0;

    for (CFIndex i = 0; i < n; i++) {
        DMIOHIDServiceClientRef svc = (DMIOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (svc == NULL) continue;

        DMIOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, DM_HID_TEMPERATURE_TYPE, 0, 0);
        if (ev == NULL) continue;
        double t = IOHIDEventGetFloatValue(ev, DM_HID_TEMPERATURE_FIELD);
        CFRelease(ev);
        if (!(t > 0 && t < 150)) continue;   // ignore implausible readings

        allSum += t; allCount++;

        CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (name) {
            char buf[128];
            if (CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8) && dm_name_is_cpu(buf)) {
                cpuSum += t; cpuCount++;
            }
            CFRelease(name);
        }
    }
    if (allCount == 0) {
        // No sensor answered — the cached list may be stale; refresh it on the next call.
        CFRelease(services);
        services = NULL;
    }

    if (cpuCount > 0) cachedTemp = cpuSum / cpuCount;        // average of the CPU/SoC sensors
    else if (allCount > 0) cachedTemp = allSum / allCount;   // fallback: average of every sensor
    else cachedTemp = -1;
    cachedAt = now;
    return cachedTemp;
}

// rusage CPU times are in mach absolute-time units; this scales them to ns.
// On Intel the timebase is 1:1 (no-op); on Apple Silicon it is ~125/3.
static double dm_timebase_scale(void) {
    static double scale = 0.0;
    if (scale == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        scale = (double)tb.numer / (double)tb.denom;
    }
    return scale;
}

dm_proc_stat dm_proc_stat_for(pid_t pid) {
    dm_proc_stat s = { 0, 0, 0 };
    struct rusage_info_v6 ri;
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
        double scale = dm_timebase_scale();
        s.cpu_time_ns = (int64_t)((double)(ri.ri_user_time + ri.ri_system_time) * scale);
        s.phys_footprint = (int64_t)ri.ri_phys_footprint;
        s.valid = 1;
    }
    return s;
}

int dm_system_cpu_ticks(dm_cpu_ticks *out) {
    natural_t ncpu = 0;
    processor_cpu_load_info_t info = NULL;
    mach_msg_type_number_t count = 0;

    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &ncpu, (processor_info_array_t *)&info, &count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    uint64_t user = 0, system = 0, idle = 0, nice = 0;
    for (natural_t i = 0; i < ncpu; i++) {
        user   += info[i].cpu_ticks[CPU_STATE_USER];
        system += info[i].cpu_ticks[CPU_STATE_SYSTEM];
        idle   += info[i].cpu_ticks[CPU_STATE_IDLE];
        nice   += info[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));

    out->user = user;
    out->system = system;
    out->idle = idle;
    out->nice = nice;
    out->total = user + system + idle + nice;
    return 0;
}

int dm_system_mem(dm_mem_info *out) {
    int64_t total = 0;
    size_t len = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) != 0) {
        return -1;
    }

    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);

    vm_statistics64_data_t vm;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &c) != KERN_SUCCESS) {
        return -1;
    }

    uint64_t used = ((uint64_t)vm.active_count + (uint64_t)vm.wire_count
                     + (uint64_t)vm.compressor_page_count) * (uint64_t)page;
    out->used = used;
    out->total = (uint64_t)total;
    return 0;
}

int dm_system_swap(dm_mem_info *out) {
    struct xsw_usage swap;
    size_t len = sizeof(swap);
    int mib[2] = { CTL_VM, VM_SWAPUSAGE };
    if (sysctl(mib, 2, &swap, &len, NULL, 0) != 0) {
        return -1;
    }
    out->used = (uint64_t)swap.xsu_used;
    out->total = (uint64_t)swap.xsu_total;
    return 0;
}

int dm_child_pids(pid_t ppid, pid_t *out, int cap) {
    for (int i = 0; i < cap; i++) {
        out[i] = 0;
    }
    int r = proc_listchildpids(ppid, out, cap * (int)sizeof(pid_t));
    if (r <= 0) {
        return 0;
    }
    // The return value's units (bytes vs count) vary across SDKs; derive the
    // count directly from the populated buffer (pids are always > 0).
    int count = 0;
    for (int i = 0; i < cap; i++) {
        if (out[i] > 0) {
            count++;
        } else {
            break;
        }
    }
    return count;
}

int dm_pgrp_pids(pid_t pgid, pid_t *out, int cap) {
    for (int i = 0; i < cap; i++) {
        out[i] = 0;
    }
    int r = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, out, cap * (int)sizeof(pid_t));
    if (r <= 0) {
        return 0;
    }
    int n = r / (int)sizeof(pid_t);
    if (n > cap) {
        n = cap;
    }
    // proc_listpids can leave zero gaps; compact the valid pids.
    int w = 0;
    for (int i = 0; i < n; i++) {
        if (out[i] > 0) {
            out[w++] = out[i];
        }
    }
    return w;
}

int dm_session_pids(pid_t sid, pid_t *out, int cap) {
    static pid_t all[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, all, (int)sizeof(all));
    if (bytes <= 0) {
        return 0;
    }
    int n = bytes / (int)sizeof(pid_t);
    int w = 0;
    for (int i = 0; i < n && w < cap; i++) {
        pid_t p = all[i];
        if (p <= 0) {
            continue;
        }
        if (getsid(p) == sid) {
            out[w++] = p;
        }
    }
    return w;
}

double dm_load_avg(void) {
    double avg[3];
    if (getloadavg(avg, 3) < 0) {
        return -1.0;
    }
    return avg[0];
}

int dm_all_pids(pid_t *out, int cap) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, out, cap * (int)sizeof(pid_t));
    if (bytes <= 0) {
        return 0;
    }
    int n = bytes / (int)sizeof(pid_t);
    if (n > cap) {
        n = cap;
    }
    return n;
}

int dm_proc_name(pid_t pid, char *buf, int size) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int r = proc_pidpath(pid, path, sizeof(path));
    if (r > 0) {
        char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        strncpy(buf, base, size - 1);
        buf[size - 1] = '\0';
        return (int)strlen(buf);
    }
    return proc_name(pid, buf, size);
}

// The app macOS holds "responsible" for `pid` — e.g. the Safari that owns a
// com.apple.WebKit.WebContent renderer. WebKit's XPC services carry no owning-app path in their own
// argv (unlike an Electron helper), so this is the only way to attribute them. Private but stable
// libSystem symbol (Activity Monitor / TCC use the same attribution).
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

int dm_responsible_pid(pid_t pid) {
    pid_t r = responsibility_get_pid_responsible_for_pid(pid);
    return r > 0 ? (int)r : -1;
}

// 1 if the process's executable lives under a macOS system location (Apple daemons, system
// frameworks, bundled system apps, privileged helpers), else 0. Used to badge system/background
// processes distinctly from user apps in the process table.
int dm_proc_is_system(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int r = proc_pidpath(pid, path, sizeof(path));
    if (r <= 0) return 0;
    static const char *prefixes[] = {
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/",
        "/sbin/", "/bin/", "/Library/Apple/", "/Library/PrivilegedHelperTools/"
    };
    for (unsigned i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        size_t len = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], len) == 0) return 1;
    }
    return 0;
}

int dm_proc_env_value(pid_t pid, const char *key, char *buf, int size) {
    if (size <= 0 || key == NULL) {
        return -1;
    }
    buf[0] = '\0';

    int argmax = 0;
    size_t sz = sizeof(argmax);
    int mib_max[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(mib_max, 2, &argmax, &sz, NULL, 0) != 0 || argmax <= 0) {
        return -1;
    }
    char *procargs = (char *)malloc((size_t)argmax);
    if (procargs == NULL) {
        return -1;
    }
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t len = (size_t)argmax;
    if (sysctl(mib, 3, procargs, &len, NULL, 0) != 0 || len < sizeof(int)) {
        free(procargs);
        return -1;
    }

    // Layout: argc | exec_path \0 | padding \0… | argv[0] \0 … argv[argc-1] \0 | envp[0] \0 …
    int argc = 0;
    memcpy(&argc, procargs, sizeof(argc));
    char *cp = procargs + sizeof(argc);
    char *end = procargs + len;
    while (cp < end && *cp != '\0') cp++;          // exec_path
    while (cp < end && *cp == '\0') cp++;          // padding
    for (int i = 0; i < argc && cp < end; i++) {   // argv — skip past each string
        while (cp < end && *cp != '\0') cp++;
        cp++;
    }

    // envp, one "KEY=value" per string. NULs are SKIPPED, not treated as the end: a process that
    // rewrites its own title (Node's process.title — `npm run dev`, `next-server`) overwrites argv[0]
    // and zero-fills the rest of its original argv block, leaving a run of NULs longer than argc
    // strings. Stopping at the first empty string made those processes' environment look empty —
    // hiding the ownership tag on exactly the `npm run dev` leaders that are the root of an orphaned
    // tree. (argv is still skipped by argc above, so an argument can never be read as a variable.)
    size_t klen = strlen(key);
    int result = -1;
    int envc = 0;
    while (cp < end) {
        if (*cp == '\0') { cp++; continue; }
        char *s = cp;
        while (cp < end && *cp != '\0') cp++;
        envc++;
        if ((size_t)(cp - s) > klen && strncmp(s, key, klen) == 0 && s[klen] == '=') {
            const char *v = s + klen + 1;
            int n = (int)(cp - v);
            if (n > size - 1) n = size - 1;
            memcpy(buf, v, (size_t)n);
            buf[n] = '\0';
            result = n;
            break;
        }
        cp++;
    }
    free(procargs);
    // No variables at all: macOS strips the environment of Apple platform binaries (sh, make, sleep…)
    // from KERN_PROCARGS2 even for the same user, so "absent" can't be told from "hidden" here —
    // report it apart, so a caller can look for the tag elsewhere (see OrphanReaper).
    if (result < 0 && envc == 0) return -2;
    return result;
}

int dm_proc_args(pid_t pid, char *buf, int size) {
    if (size <= 0) {
        return 0;
    }
    buf[0] = '\0';

    int argmax = 0;
    size_t sz = sizeof(argmax);
    int mib_max[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(mib_max, 2, &argmax, &sz, NULL, 0) != 0 || argmax <= 0) {
        return 0;
    }

    char *procargs = (char *)malloc((size_t)argmax);
    if (procargs == NULL) {
        return 0;
    }

    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t len = (size_t)argmax;
    if (sysctl(mib, 3, procargs, &len, NULL, 0) != 0 || len < sizeof(int)) {
        free(procargs);
        return 0;
    }

    int argc = 0;
    memcpy(&argc, procargs, sizeof(argc));
    char *cp = procargs + sizeof(argc);
    char *end = procargs + len;
    while (cp < end && *cp != '\0') cp++;     // skip exec_path
    while (cp < end && *cp == '\0') cp++;     // skip null padding

    int written = 0, done = 0;
    while (cp < end && written < size - 1 && done < argc) {
        char c = *cp++;
        if (c == '\0') { buf[written++] = ' '; done++; }
        else { buf[written++] = c; }
    }
    buf[written] = '\0';
    free(procargs);
    return written;
}

int dm_proc_listen_port(pid_t pid) {
    int bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufSize <= 0) {
        return 0;
    }
    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)bufSize);
    if (fds == NULL) {
        return 0;
    }
    int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufSize);
    int count = (n > 0) ? n / (int)sizeof(struct proc_fdinfo) : 0;
    int port = 0;
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        struct socket_fdinfo si;
        int r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, PROC_PIDFDSOCKETINFO_SIZE);
        if (r < (int)PROC_PIDFDSOCKETINFO_SIZE || si.psi.soi_kind != SOCKINFO_TCP) {
            continue;
        }
        struct tcp_sockinfo *t = &si.psi.soi_proto.pri_tcp;
        int lport = ntohs((uint16_t)t->tcpsi_ini.insi_lport);
        int fport = ntohs((uint16_t)t->tcpsi_ini.insi_fport);
        if (t->tcpsi_state == TCPS_LISTEN && lport > 0) {
            port = lport;     // a real listener — prefer it and stop
            break;
        }
        if (fport == 0 && lport > 0 && port == 0) {
            port = lport;     // fallback (bound, no peer); keep scanning for a true LISTEN
        }
    }
    free(fds);
    return port;
}
