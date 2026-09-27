#ifndef DM_METRICS_H
#define DM_METRICS_H

#include <sys/types.h>
#include <stdint.h>

/// Cumulative CPU time + memory footprint for one process.
typedef struct {
    int64_t cpu_time_ns;     // user + system CPU time consumed so far (nanoseconds)
    int64_t phys_footprint;  // physical memory footprint (bytes, ~Activity Monitor "Memory")
    int32_t valid;           // 1 if the pid was readable, 0 otherwise
} dm_proc_stat;

/// Per-process cumulative CPU time and memory footprint.
dm_proc_stat dm_proc_stat_for(pid_t pid);

/// System-wide CPU ticks summed across all cores.
typedef struct {
    uint64_t user;
    uint64_t system;
    uint64_t idle;
    uint64_t nice;
    uint64_t total;
} dm_cpu_ticks;

/// Fills `out` with summed CPU ticks. Returns 0 on success, -1 on failure.
int dm_system_cpu_ticks(dm_cpu_ticks *out);

/// System memory usage (bytes).
typedef struct {
    uint64_t used;
    uint64_t total;
} dm_mem_info;

/// Fills `out` with used/total memory. Returns 0 on success, -1 on failure.
int dm_system_mem(dm_mem_info *out);

/// Fills `out` with swap used/total (bytes), from `vm.swapusage`. Returns 0 on success, -1 on failure.
int dm_system_swap(dm_mem_info *out);

/// Fills `out` (capacity `cap`) with the direct child pids of `ppid`.
/// Returns the number of children written (>= 0), or -1 on error.
int dm_child_pids(pid_t ppid, pid_t *out, int cap);

/// Fills `out` (capacity `cap`) with all pids in process group `pgid`
/// (includes the group leader). Returns the count written.
int dm_pgrp_pids(pid_t pgid, pid_t *out, int cap);

/// Fills `out` (capacity `cap`) with every pid whose session id == `sid`.
/// Robust to re-parenting/process-group changes within the session.
/// Returns the count written.
int dm_session_pids(pid_t sid, pid_t *out, int cap);

/// 1-minute load average, or -1 on error.
double dm_load_avg(void);

/// Fills `out` (capacity `cap`) with every pid on the system. Returns count written.
int dm_all_pids(pid_t *out, int cap);

/// Best-effort human-readable process name (executable basename). Returns length, or 0.
int dm_proc_name(pid_t pid, char *buf, int size);

/// 1 if the process's executable lives under a macOS system location (Apple daemon, system app,
/// privileged helper), else 0.
int dm_proc_is_system(pid_t pid);

/// The "responsible" process for `pid` — the app macOS attributes an XPC helper to (e.g. the Safari
/// that owns a `com.apple.WebKit.WebContent` renderer). Returns that pid, or -1 if there's no distinct
/// owner. Lets generic WebKit service processes — whose own argv names no `.app` — be labelled and
/// iconned by their owning app.
int dm_responsible_pid(pid_t pid);

/// Best-effort process arguments (argv joined by spaces). Returns length, or 0.
/// Used to tell apart generic helpers (e.g. which VS Code language server a "Code Helper" is).
int dm_proc_args(pid_t pid, char *buf, int size);

// Value of environment variable `key` in process `pid`, copied into `buf` (NUL-terminated). Returns
// its length, or -1 when the variable is absent or the process is unreadable (KERN_PROCARGS2 only
// exposes the environment of processes owned by the same user — which every tree we spawn is), or
// -2 when the process shows no environment at all: macOS hides it for Apple platform binaries.
int dm_proc_env_value(pid_t pid, const char *key, char *buf, int size);

/// How many TCP connections the process tree `tree` (`ntree` pids) has ACCEPTED from OUTSIDE and still
/// holds open: established sockets on a port the tree listens on (a browser tab's page load or HMR
/// websocket) whose other end isn't another process of the same tree (a bundler talking to its own
/// worker) nor `exclude_peer` (pass Owl Monitor's pid: its health probe keeps a keep-alive
/// connection open to every server; 0 excludes nothing). The tree's own outbound connections never
/// count. Drives idle auto-stop — a server nobody is connected to is one nobody is using.
int dm_tree_inbound_count(const pid_t *tree, int ntree, pid_t exclude_peer);

/// The TCP port a process is LISTENing on (e.g. a dev server's port), or 0 if none.
/// Used to identify a dev server started outside the app (e.g. "MiddleSpace :3001").
int dm_proc_listen_port(pid_t pid);

/// Best-effort average CPU / SoC temperature in °C, read from the Apple Silicon thermal sensors via
/// the IOKit HID event system. Returns -1 when no sensor is readable (e.g. unsupported hardware).
/// No root or entitlement required.
double dm_cpu_temperature(void);

#endif /* DM_METRICS_H */
