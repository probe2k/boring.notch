// pdwatch.c — parent-death watchdog for the mediaremote-adapter Perl helper
//
// Usage: pdwatch HOST_PID PERL_PID
//
// Blocks event-driven inside kqueue(EVFILT_PROC | NOTE_EXIT) until either
// HOST_PID (the boringNotch host app) or PERL_PID (the Perl interpreter
// running mediaremote-adapter.pl) exits. When HOST_PID exits first, we
// signal PERL_PID (SIGTERM, then SIGKILL after 1s if needed) so the
// orphaned Perl helper terminates instead of being reparented to launchd
// and streaming MediaRemote events forever. When PERL_PID exits first
// (clean shutdown via the host's teardown), we do nothing and exit.
//
// Why a separate process: once Perl enters the C `adapter_stream_*`
// function in MediaRemoteAdapter.framework, it is blocked inside the
// framework's CFRunLoop for the entire stream lifetime. Perl cannot poll,
// `select`, or run signal handlers from there. Having an external watcher
// is the only reliable mechanism.
//
// Why C (not a Perl polling loop): kqueue NOTE_EXIT is event-driven — the
// kernel wakes us exactly once, when the target PID exits. Zero idle
// wakes while waiting. A 2-second Perl `sleep` loop would cost ~0.5
// wakes/sec, which is negligible but non-zero; this is the strictly
// correct primitive for the job.
//
// Build:
//   clang -arch arm64 -arch x86_64 -O2 -mmacosx-version-min=14.0 \
//         -o pdwatch pdwatch.c
//
// Or just run the sibling build-pdwatch.sh script.

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

// SIGTERM with a 1-second grace period, then SIGKILL if still alive.
// `kill(pid, 0)` is the POSIX liveness probe — sends no signal, returns 0
// iff the target exists and we can signal it.
static void term_then_kill(pid_t pid) {
    if (kill(pid, SIGTERM) != 0 && errno == ESRCH) return;
    const struct timespec wait = { .tv_sec = 1, .tv_nsec = 0 };
    nanosleep(&wait, NULL);
    if (kill(pid, 0) == 0) {
        kill(pid, SIGKILL);
    }
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s HOST_PID PERL_PID\n", argv[0]);
        return 2;
    }

    const pid_t host_pid = (pid_t)atoi(argv[1]);
    const pid_t perl_pid = (pid_t)atoi(argv[2]);
    if (host_pid <= 1 || perl_pid <= 1) {
        fprintf(stderr, "%s: invalid pid(s) host=%d perl=%d\n",
                argv[0], host_pid, perl_pid);
        return 2;
    }

    // If either PID is already gone by the time we get here, react now —
    // don't bother setting up kqueue.
    if (kill(host_pid, 0) != 0 && errno == ESRCH) {
        term_then_kill(perl_pid);
        return 0;
    }
    if (kill(perl_pid, 0) != 0 && errno == ESRCH) {
        return 0;
    }

    const int kq = kqueue();
    if (kq < 0) {
        perror("pdwatch: kqueue");
        return 1;
    }

    struct kevent changes[2];
    EV_SET(&changes[0], host_pid, EVFILT_PROC,
           EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], perl_pid, EVFILT_PROC,
           EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);

    if (kevent(kq, changes, 2, NULL, 0, NULL) < 0) {
        // ESRCH means a PID vanished between our probe above and registration.
        // Recheck and react accordingly instead of failing.
        if (errno == ESRCH) {
            if (kill(host_pid, 0) != 0 && errno == ESRCH) {
                term_then_kill(perl_pid);
            }
            return 0;
        }
        perror("pdwatch: kevent register");
        return 1;
    }

    // Block forever — kernel wakes us exactly once, when either PID exits.
    // Zero CPU, zero wakes while waiting.
    struct kevent event;
    const int n = kevent(kq, NULL, 0, &event, 1, NULL);
    if (n < 0) {
        perror("pdwatch: kevent wait");
        return 1;
    }
    if (n == 0) {
        // Shouldn't happen with a NULL timeout, but bail out cleanly.
        return 0;
    }

    if ((pid_t)event.ident == host_pid) {
        // Host died first — orphan-prevent the Perl helper.
        term_then_kill(perl_pid);
    }
    // Else: Perl exited first (host's teardown path ran cleanly).
    // Nothing for us to do but exit.

    return 0;
}
