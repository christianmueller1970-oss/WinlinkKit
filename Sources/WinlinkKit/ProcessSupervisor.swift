#if os(macOS)
import Foundation

/// Keeps a helper process (rigctld, ardopcf) from outliving the app
/// that started it.
///
/// Without this a crashed or force-quit app leaves the helper running
/// under launchd, still holding the serial port or the audio device.
/// Cleaning up afterwards is not possible from a sandboxed app: it may
/// not signal a process started by an earlier instance of itself. A
/// termination hook alone does not cover crashes.
///
/// The helper runs under a small shell supervisor whose stdin is a pipe
/// ("lifeline"). The app holds the write end; when the app exits,
/// however it exits, the supervisor sees end-of-file and sends the
/// helper SIGTERM — and SIGKILL if it is still there a few seconds
/// later.
///
/// The PID the caller holds is the supervisor's. SIGKILL to that PID
/// would only end the shell and leave the helper running, so the last
/// escalation step goes through `forceKill(supervisor:)` instead.
enum ProcessSupervisor {
    static let shell = URL(fileURLWithPath: "/bin/sh")

    /// `$0` is the helper, `$@` its arguments, stdin the lifeline.
    ///
    /// - fd 3 carries the lifeline into the watcher, because a
    ///   background job in a non-interactive shell gets /dev/null as
    ///   stdin.
    /// - The watcher waits with the shell builtin `read`: no extra
    ///   process that could be left behind holding the helper's output
    ///   pipes open, and it writes nothing into them. A helper that
    ///   ignores SIGTERM or hangs in its cleanup gets SIGKILL after
    ///   `lifelineGraceSeconds`; if it went away in time, the supervisor
    ///   has ended the watcher before that.
    /// - SIGINT and SIGTERM sent to the supervisor are passed on to the
    ///   helper unchanged, so a caller can still escalate
    ///   (SIGINT → SIGTERM). A trapped signal interrupts `wait`, hence
    ///   the loop; the supervisor exits with the helper's status.
    /// - SIGUSR1 to the supervisor ends the helper with SIGKILL.
    static let script = """
        exec 3<&0
        "$0" "$@" 3<&- </dev/null &
        child=$!
        ( while read -r _; do :; done <&3
          kill "$child"
          sleep \(lifelineGraceSeconds)
          kill -KILL "$child" ) >/dev/null 2>&1 &
        watcher=$!
        exec 3<&-
        trap 'kill -INT "$child" 2>/dev/null' INT
        trap 'kill "$child" 2>/dev/null' TERM
        trap 'kill -KILL "$child" 2>/dev/null' USR1
        while :; do
            wait "$child"
            status=$?
            [ "$status" -le 128 ] && break
            kill -0 "$child" 2>/dev/null || break
        done
        kill "$watcher" 2>/dev/null
        exit "$status"
        """

    /// How long a helper gets to react to SIGTERM after the parent went
    /// away before the watcher sends SIGKILL.
    static let lifelineGraceSeconds = 3

    /// Last escalation step of a `stop()`: has the supervisor SIGKILL
    /// the helper. The supervisor then exits with the helper's status.
    static func forceKill(supervisor pid: Int32) {
        kill(pid, SIGUSR1)
    }

    /// Arguments for `shell` that run `executable` under the supervisor.
    static func arguments(executable: URL, arguments: [String]) -> [String] {
        ["-c", script, executable.path] + arguments
    }
}
#endif
