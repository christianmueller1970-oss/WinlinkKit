#if os(macOS)
import Foundation

/// Errors from managing a bundled rigctld process.
public enum RigctldProcessError: Error, Sendable, Equatable {
    /// The executable could not be launched.
    case launchFailed(String)
    /// The process exited before its TCP port became reachable — most
    /// often rigctld could not open the rig (wrong port, wrong model,
    /// port held by another program). Includes the exit code and the
    /// last captured log lines.
    case terminatedEarly(exitCode: Int32, log: [String])
    /// The TCP port did not become reachable within the timeout.
    case readyTimeout(log: [String])
}

/// Runs a bundled Hamlib `rigctld` as a managed child process.
///
/// Same contract as `ArdopProcess`: the app resolves the binary and
/// injects its URL; `start()` returns once the TCP port accepts a
/// connection, after which `RigctldClient.connect` takes over;
/// `stop()` ends the process with escalating signals.
///
/// rigctld never outlives the process that started it: it runs under a
/// supervisor that ends it when the parent exits, crashes included.
/// `processIdentifier` is the supervisor's PID; signalling it reaches
/// rigctld.
public actor RigctldProcess {
    private let executable: URL
    private let config: RigctldLaunchConfig
    private var process: Process?
    private var collector: LineCollector?
    /// Write end of the supervision pipe; see `supervisorScript`.
    private var lifeline: FileHandle?

    /// Merged stdout/stderr of the process, line by line. A single
    /// consumer may iterate this; the stream ends when the process
    /// exits.
    public nonisolated let logLines: AsyncStream<String>
    private nonisolated let logContinuation: AsyncStream<String>.Continuation

    public init(executable: URL, config: RigctldLaunchConfig) {
        self.executable = executable
        self.config = config
        (logLines, logContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// The last captured output lines, for error reporting.
    public var recentLogLines: [String] {
        collector?.recentLines ?? []
    }

    /// PID of the running child, e.g. for a synchronous SIGTERM from an
    /// app-termination hook; nil before start and after stop.
    public private(set) var processIdentifier: Int32?

    /// True while the child is alive. Turns false when rigctld dies on
    /// its own (cable pulled, rig switched off).
    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Launches rigctld and returns once its TCP port accepts a
    /// connection (probe connection, closed immediately).
    public func start(readyTimeout: Duration = .seconds(10)) async throws {
        precondition(process == nil, "RigctldProcess.start() called twice")

        // rigctld runs under a small shell supervisor that ends it as
        // soon as this process goes away — see `supervisorScript`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.supervisorScript, executable.path] + config.arguments()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let lifelinePipe = Pipe()
        process.standardInput = lifelinePipe.fileHandleForReading

        let continuation = logContinuation
        let collector = LineCollector { continuation.yield($0) }
        self.collector = collector

        // Hamlib reports errors on stdout or stderr depending on the
        // version — capture both.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                collector.ingest(handle.availableData, from: handle)
            }
        }

        process.terminationHandler = { [logContinuation] _ in
            for pipe in [stdout, stderr] {
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = nil
                if let rest = try? handle.readToEnd() {
                    collector.ingest(rest + Data("\n".utf8), from: handle)
                }
            }
            logContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            logContinuation.finish()
            throw RigctldProcessError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.processIdentifier = process.processIdentifier
        // Only we may hold the write end: the child's copy of the read
        // end is closed here, ours is what keeps rigctld alive.
        try? lifelinePipe.fileHandleForReading.close()
        self.lifeline = lifelinePipe.fileHandleForWriting

        let deadline = ContinuousClock.now + readyTimeout
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                self.process = nil
                self.processIdentifier = nil
                try? lifeline?.close()
                lifeline = nil
                throw RigctldProcessError.terminatedEarly(
                    exitCode: process.terminationStatus,
                    log: collector.recentLines)
            }
            if await probePort() {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await stop(gracePeriod: .seconds(1))
        throw RigctldProcessError.readyTimeout(log: collector.recentLines)
    }

    /// Stops the process: SIGTERM, after `gracePeriod` SIGKILL. Returns
    /// when it has exited, so the serial port is free again.
    public func stop(gracePeriod: Duration = .seconds(3)) async {
        guard let process else { return }
        self.process = nil
        self.processIdentifier = nil
        defer {
            try? lifeline?.close()
            lifeline = nil
        }

        if process.isRunning {
            process.terminate()
            if await waitForExit(of: process, upTo: gracePeriod) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(of: process, upTo: .seconds(2))
            }
        }
    }

    /// Runs rigctld (`$0` with its arguments) and ends it when stdin
    /// reaches end-of-file — that is, when the parent holding the other
    /// end of the pipe exits, however it exits.
    ///
    /// Without this a crashed or force-quit app leaves rigctld running
    /// under launchd, still holding the serial port. Cleaning up
    /// afterwards is not possible from a sandboxed app: it may not
    /// signal a process started by an earlier instance of itself. A
    /// termination hook alone does not cover crashes.
    ///
    /// fd 3 carries the pipe into the watcher, because a background job
    /// in a non-interactive shell gets /dev/null as stdin. SIGTERM/SIGINT
    /// to the shell (from `stop()` or the app's termination hook) are
    /// passed on to rigctld; the shell exits with rigctld's status.
    static let supervisorScript = """
        exec 3<&0
        "$0" "$@" 3<&- </dev/null &
        child=$!
        ( cat <&3 >/dev/null; kill "$child" 2>/dev/null ) &
        watcher=$!
        exec 3<&-
        trap 'kill "$child" "$watcher" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
        wait "$child"
        status=$?
        kill "$watcher" 2>/dev/null
        exit "$status"
        """

    /// Closes our end of the supervision pipe without stopping the
    /// process — what happens when the app dies. Test seam.
    func dropLifelineForTesting() {
        try? lifeline?.close()
        lifeline = nil
    }

    private func waitForExit(of process: Process, upTo timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    private func probePort() async -> Bool {
        do {
            let probe = try await TCPTransport.connect(
                host: "127.0.0.1", port: config.listenPort)
            await probe.close()
            return true
        } catch {
            return false
        }
    }
}
#endif
