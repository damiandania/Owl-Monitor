#include "ipc.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ucred.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>

// Mark a socket close-on-exec so no process we spawn can inherit it (which would otherwise keep a
// CLI connection open forever). dm_spawn_session also sets POSIX_SPAWN_CLOEXEC_DEFAULT; this is
// belt-and-suspenders for any other spawn path.
static void dm_cloexec(int fd) {
    if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static int dm_set_path(struct sockaddr_un *addr, const char *path) {
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr->sun_path)) {
        return -1;
    }
    strncpy(addr->sun_path, path, sizeof(addr->sun_path) - 1);
    return 0;
}

int dm_ipc_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    dm_cloexec(fd);
    struct sockaddr_un addr;
    if (dm_set_path(&addr, path) != 0) {
        close(fd);
        return -1;
    }
    // Before removing the socket file, probe whether a LIVE hub already owns it. A blind unlink
    // (the previous behavior) let a second instance steal the socket from a running one — leaving
    // two half-wired hubs and the races that made instances appear to "die" on launch. If a connect
    // succeeds, another instance is listening: don't clobber it — return -2 so the caller can stand
    // down (single-instance). Only when the socket is stale (nobody answers) do we unlink and bind.
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe >= 0) {
        int live = (connect(probe, (struct sockaddr *)&addr, sizeof(addr)) == 0);
        close(probe);
        if (live) {
            close(fd);
            return -2;
        }
    }
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    // Owner-only (0600): on macOS the filesystem permissions of an AF_UNIX socket are enforced on
    // connect, so this alone keeps another local user from driving the hub (run/stop/build/remove).
    // The per-connection LOCAL_PEERCRED check in dm_ipc_peer_uid is the belt to this suspenders.
    chmod(path, S_IRUSR | S_IWUSR);
    if (listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int dm_ipc_accept(int listen_fd) {
    int fd = accept(listen_fd, NULL, NULL);
    dm_cloexec(fd);
    if (fd >= 0) {
        // The hub reads each request on its single accept thread, so a peer that connects and then
        // stalls (never sends its newline) would otherwise wedge EVERY later CLI call. Bound the read
        // so a stuck client times out as a bad request. The write bound covers the mirror case: a
        // client that stops reading would block the reply write, which runs on the main actor —
        // freezing the UI. Both are far above any real request/reply (a few hundred bytes, instant),
        // and neither affects a long `build`: the hub reads once up front, then only writes.
        struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    }
    return fd;
}

int dm_ipc_peer_uid(int fd) {
    struct xucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) != 0) {
        return -1;
    }
    if (cred.cr_version != XUCRED_VERSION) {
        return -1;
    }
    return (int)cred.cr_uid;
}

int dm_ipc_connect(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    if (dm_set_path(&addr, path) != 0) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}
