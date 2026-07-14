#if os(macOS)
import Foundation

/// Errors from managing a bundled ardopcf process.
public enum ArdopProcessError: Error, Sendable, Equatable {
    /// The executable could not be launched.
    case launchFailed(String)
    /// The process exited before the control port became reachable.
    /// Includes the exit code and the last captured log lines.
    case terminatedEarly(exitCode: Int32, log: [String])
    /// The control port did not become reachable within the timeout.
    case readyTimeout(log: [String])
}

/// Collects process output lines; safe to touch from the pipe-reader
/// queues and the actor.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = [FileHandle: String]()
    private var lastLines = [String]()
    private let onLine: @Sendable (String) -> Void
    private let keep = 30

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func ingest(_ data: Data, from handle: FileHandle) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        var buffer = (partial[handle] ?? "") + text
        var lines = [String]()
        while let idx = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<idx]))
            buffer = String(buffer[buffer.index(after: idx)...])
        }
        partial[handle] = buffer
        lastLines.append(contentsOf: lines)
        if lastLines.count > keep {
            lastLines.removeFirst(lastLines.count - keep)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            onLine(line)
        }
    }

    var recentLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lastLines
    }
}

/// Runs a bundled ardopcf binary as a managed child process.
///
/// The library does not locate the binary itself — the app resolves it
/// (e.g. `Bundle.main.url(forAuxiliaryExecutable: "ardopcf")`) and
/// injects the URL, which keeps this testable with a fake executable.
///
/// Lifecycle: `start()` launches the process and waits until the TCP
/// control port accepts a connection; `ArdopModem.connect` takes over
/// from there. `stop()` shuts down with escalating signals
/// (SIGINT → SIGTERM → SIGKILL); ardopcf handles INT and TERM
/// gracefully.
public actor ArdopProcess {
    private let executable: URL
    private let config: ArdopLaunchConfig
    private var process: Process?
    private var collector: LineCollector?

    /// Merged stdout/stderr of the process, line by line. A single
    /// consumer may iterate this; the stream ends when the process
    /// exits.
    public nonisolated let logLines: AsyncStream<String>
    private nonisolated let logContinuation: AsyncStream<String>.Continuation

    public init(executable: URL, config: ArdopLaunchConfig) {
        self.executable = executable
        self.config = config
        (logLines, logContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// The last captured output lines, for error reporting.
    public var recentLogLines: [String] {
        collector?.recentLines ?? []
    }

    /// PID of the running child, e.g. for a synchronous SIGINT from an
    /// app-termination hook; nil before start and after stop.
    public private(set) var processIdentifier: Int32?

    /// Launches ardopcf and returns once its control port accepts a TCP
    /// connection (probe connection, closed immediately).
    public func start(readyTimeout: Duration = .seconds(10)) async throws {
        precondition(process == nil, "ArdopProcess.start() called twice")

        let process = Process()
        process.executableURL = executable
        process.arguments = config.arguments()
        // ardopcf writes debug WAV files to its working directory when
        // no log directory is set; keep that out of the app's cwd.
        process.currentDirectoryURL = config.logDirectory
            ?? FileManager.default.temporaryDirectory

        let continuation = logContinuation
        let collector = LineCollector { continuation.yield($0) }
        self.collector = collector

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                collector.ingest(handle.availableData, from: handle)
            }
        }

        process.terminationHandler = { [logContinuation] finished in
            // Flush whatever is still buffered, then end the log stream.
            for pipe in [stdout, stderr] {
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = nil
                if let rest = try? handle.readToEnd() {
                    collector.ingest(rest + Data("\n".utf8), from: handle)
                }
            }
            _ = finished
            logContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            logContinuation.finish()
            throw ArdopProcessError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.processIdentifier = process.processIdentifier

        // Wait for the control port to accept a connection.
        let deadline = ContinuousClock.now + readyTimeout
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw ArdopProcessError.terminatedEarly(
                    exitCode: process.terminationStatus,
                    log: collector.recentLines)
            }
            if await probeControlPort() {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await stop(gracePeriod: .seconds(1))
        throw ArdopProcessError.readyTimeout(log: collector.recentLines)
    }

    /// Stops the process: SIGINT, after `gracePeriod` SIGTERM, after
    /// another grace period SIGKILL. Returns when it has exited.
    public func stop(gracePeriod: Duration = .seconds(3)) async {
        guard let process else { return }
        self.process = nil
        self.processIdentifier = nil

        if process.isRunning {
            process.interrupt()  // SIGINT: ardopcf shuts down cleanly
            if await waitForExit(of: process, upTo: gracePeriod) == false {
                process.terminate()  // SIGTERM: also handled by ardopcf
                if await waitForExit(of: process, upTo: gracePeriod) == false {
                    kill(process.processIdentifier, SIGKILL)
                    _ = await waitForExit(of: process, upTo: .seconds(2))
                }
            }
        }
    }

    private func waitForExit(of process: Process, upTo timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    private func probeControlPort() async -> Bool {
        do {
            let probe = try await TCPTransport.connect(
                host: "localhost", port: config.controlPort)
            await probe.close()
            return true
        } catch {
            return false
        }
    }
}
#endif
