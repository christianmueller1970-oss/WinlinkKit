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
    /// Something already listens on the port rigctld was to use. The
    /// readiness probe would answer for that other service, and the
    /// client would then talk to it — possibly another rig.
    case portInUse(port: UInt16)
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
    /// Write end of the supervision pipe; see `ProcessSupervisor`.
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
        guard await probePort() == false else {
            logContinuation.finish()
            throw RigctldProcessError.portInUse(port: config.listenPort)
        }

        // rigctld runs under a small shell supervisor that ends it as
        // soon as this process goes away — see `ProcessSupervisor`.
        let process = Process()
        process.executableURL = ProcessSupervisor.shell
        process.arguments = ProcessSupervisor.arguments(
            executable: executable, arguments: config.arguments())
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
                // SIGKILL to this PID would only end the supervisor shell
                // and leave the helper holding its port — have the
                // supervisor kill the helper instead.
                ProcessSupervisor.forceKill(supervisor: process.processIdentifier)
                if await waitForExit(of: process, upTo: .seconds(2)) == false {
                    kill(process.processIdentifier, SIGKILL)
                    _ = await waitForExit(of: process, upTo: .seconds(2))
                }
            }
        }
    }

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
