// Ported from Pat-Vara (vara.go, transport.go, conn.go) — MIT, © 2021 Jeremy Bush
import Foundation

/// Client for the VARA HF/FM modem program.
///
/// VARA exposes two TCP channels: a command channel (default port 8300)
/// for CR-terminated ASCII commands and a data channel (default 8301)
/// carrying the raw over-the-air payload. `VaraModem` drives the command
/// channel and hands out a `VaraConnection` (a `WinlinkTransport`) for
/// the data channel, so a `B2FSession` runs over VARA exactly like over
/// telnet.
public actor VaraModem {
    /// VARA flavor: HF (`VARA.exe`) or FM (`VaraFM.exe`).
    public enum Mode: Sendable {
        case hf
        case fm
    }

    /// Configuration for reaching the modem program.
    public struct Config: Sendable {
        public var host = "localhost"
        public var commandPort: UInt16 = 8300
        public var dataPort: UInt16 = 8301

        public init() {}
    }

    /// Valid VARA HF bandwidths in Hz (Go: bandwidths).
    public static let bandwidths = ["500", "2300", "2750"]

    /// The link state machine. Transitions:
    ///
    ///     disconnected ──dial()──▶ connecting
    ///     connecting ──CONNECTED──▶ connected
    ///     connecting ──DISCONNECTED (timeout/busy)──▶ disconnected
    ///     connected ──DISCONNECTED (either side)──▶ disconnected
    enum LinkState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private let mode: Mode
    private let mycall: String
    private let command: any WinlinkTransport
    private let data: any WinlinkTransport

    private(set) var state: LinkState = .disconnected
    private var closed = false

    /// True while the modem reports the channel as busy (BUSY ON/OFF).
    public private(set) var isBusy = false

    /// Bytes queued in the modem's TX buffer (tracked via BUFFER updates
    /// and our own writes; Go: bufferCount).
    private var txBufferCount = 0

    /// Called when the modem asserts/releases PTT. Hook the rig control
    /// (rigctld) here; if nil, PTT requests are ignored (VOX may work).
    private var pttHandler: (@Sendable (Bool) async -> Void)?

    /// Optional sink for command-channel log lines (`>` marks sent).
    public var logLine: (@Sendable (String) -> Void)?

    /// A one-shot subscription for the next command matching a predicate.
    /// Registered *before* sending the request (like Pat-Vara's pubsub
    /// Subscribe-then-write pattern), so a fast answer can't be missed.
    private final class CommandExpectation {
        let predicate: (VaraCommand) -> Bool
        var result: Result<VaraCommand, WinlinkError>?
        var continuation: CheckedContinuation<VaraCommand, any Error>?

        init(_ predicate: @escaping (VaraCommand) -> Bool) {
            self.predicate = predicate
        }
    }

    private var expectations = [CommandExpectation]()

    // Inbound data chunks and blocked readers (only ever one reader — the session).
    private var dataInbox = [Data]()
    private var dataWaiter: CheckedContinuation<Data, Never>?

    private var listenTask: Task<Void, Never>?
    private var dataTask: Task<Void, Never>?

    /// Creates a modem client over the given command/data byte streams.
    /// Use `connect(mode:mycall:config:)` for the TCP case; tests inject
    /// pipe transports here.
    init(
        mode: Mode, mycall: String,
        command: any WinlinkTransport, data: any WinlinkTransport
    ) {
        self.mode = mode
        self.mycall = mycall.uppercased()
        self.command = command
        self.data = data
    }

    /// Connects to the VARA modem program via TCP and performs the
    /// initial setup (Go: NewModem + start).
    public static func connect(
        mode: Mode, mycall: String, config: Config = Config()
    ) async throws -> VaraModem {
        let command = try await TCPTransport.connect(
            host: config.host, port: config.commandPort)
        let data: TCPTransport
        do {
            data = try await TCPTransport.connect(host: config.host, port: config.dataPort)
        } catch {
            await command.close()
            throw error
        }

        let modem = VaraModem(mode: mode, mycall: mycall, command: command, data: data)
        do {
            try await modem.setup()
        } catch {
            await modem.close()
            throw error
        }
        return modem
    }

    /// Sets the PTT handler (e.g. rigctld). Must be set before dialing.
    public func setPTTHandler(_ handler: (@Sendable (Bool) async -> Void)?) {
        pttHandler = handler
    }

    public func setLogLine(_ handler: (@Sendable (String) -> Void)?) {
        logLine = handler
    }

    // MARK: - Setup (Go: Modem.start)

    /// Sends the initial configuration and starts the command listener.
    /// Internal so tests can drive it over pipe transports.
    func setup() async throws {
        startListening()

        try await writeCommand("PUBLIC ON")
        if mode == .hf {
            try await writeCommand("CWID ON")
        }
        try await writeCommand("COMPRESSION TEXT")
        try await writeCommand("MYCALL \(mycall)")
        try await writeCommand("LISTEN OFF")
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            await self?.listenLoop()
        }
        dataTask = Task { [weak self] in
            await self?.dataLoop()
        }
    }

    // MARK: - Dialing (Go: DialURLContext)

    /// Connects to a remote station and returns the data channel as a
    /// `WinlinkTransport` for the B2F session.
    ///
    /// The connect timeout is handled by VARA itself (it reports
    /// DISCONNECTED when the attempt fails); `timeout` is our own upper
    /// bound on top of that.
    public func dial(
        _ target: String, bandwidth: String? = nil, p2p: Bool = false,
        timeout: TimeInterval = 300
    ) async throws -> VaraConnection {
        guard !closed else { throw WinlinkError.connectionClosed }
        guard state == .disconnected else {
            throw WinlinkError.malformedInput("Modem busy (already connecting or connected)")
        }

        if let bandwidth {
            guard Self.bandwidths.contains(bandwidth) else {
                throw WinlinkError.malformedInput("Bandwidth \(bandwidth) not supported")
            }
            try await writeCommand("BW\(bandwidth)")
        }

        if mode == .hf {
            // VARA HF distinguishes Winlink and P2P sessions.
            try await writeCommand(p2p ? "P2P SESSION" : "WINLINK SESSION")
        }

        state = .connecting
        let answer = expect { $0.endsDial }
        do {
            try await writeCommand("CONNECT \(mycall) \(target.uppercased())")
            guard case .connected = try await value(of: answer, timeout: timeout) else {
                state = .disconnected
                throw WinlinkError.timeout("Connect to \(target) failed (VARA reported disconnect)")
            }
            // state is set to .connected by the listener.
            return VaraConnection(modem: self)
        } catch {
            state = .disconnected
            cancel(answer)
            throw error
        }
    }

    /// The modem program's version string (Go: Version).
    public func version() async throws -> String {
        let reply = expect {
            if case .version = $0 { return true }
            return $0 == .wrong
        }
        try await writeCommand("VERSION")
        guard case .version(let v) = try await value(of: reply, timeout: 5) else {
            throw WinlinkError.malformedInput("VERSION not implemented")
        }
        return v
    }

    /// Closes the RF link (if any) and the channels to the modem
    /// (Go: Modem.Close).
    public func close() async {
        guard !closed else { return }

        if state != .disconnected {
            await disconnectLink()
        }

        closed = true
        // Make sure to stop TX (should have already happened; backup).
        await pttHandler?(false)

        listenTask?.cancel()
        dataTask?.cancel()
        failAllWaiters(with: WinlinkError.connectionClosed)
        resumeDataReader(with: Data())
        await command.close()
        await data.close()
    }

    // MARK: - Data channel (used by VaraConnection; Go: conn.go)

    /// Reads the next chunk from the data channel. Returns empty Data
    /// (EOF) once the link is down and all received data was consumed.
    func readData() async throws -> Data {
        if !dataInbox.isEmpty {
            return dataInbox.removeFirst()
        }
        if state != .connected || closed {
            return Data() // EOF
        }
        // Note: unlike Pat-Vara we don't grace-wait for late data after a
        // DISCONNECT — data and command are separate TCP streams, but on
        // localhost the reorder window is negligible. Revisit if needed.
        return await withCheckedContinuation { dataWaiter = $0 }
    }

    /// Writes to the data channel, throttled so the modem's TX buffer
    /// stays in the same order of magnitude as the payload size
    /// (Go: conn.Write and its magic number).
    func writeData(_ chunk: Data) async throws {
        guard state == .connected, !closed else {
            throw WinlinkError.connectionClosed
        }

        let magicNumber = 7
        while txBufferCount >= magicNumber * chunk.count {
            let update = expect {
                if case .buffer = $0 { return true }
                return $0 == .disconnected
            }
            if try await value(of: update, timeout: 60) == .disconnected {
                throw WinlinkError.connectionClosed
            }
        }

        txBufferCount += chunk.count
        try await data.write(chunk)
    }

    /// Gracefully closes the RF link: DISCONNECT, await DISCONNECTED,
    /// ABORT after 60 s (Go: conn.Close).
    func disconnectLink() async {
        guard state != .disconnected, !closed else { return }

        // VARA flushes the TX buffer before disconnecting, but the last
        // written data must have reached the modem first (cmd and data
        // are separate TCP streams). Pat waits 2 s since the last write;
        // we simply give the data channel a moment.
        try? await Task.sleep(for: .milliseconds(200))

        let done = expect { $0 == .disconnected }
        do {
            try await writeCommand("DISCONNECT")
            _ = try await value(of: done, timeout: 60)
        } catch {
            // Disconnect failed or timed out: abort hard.
            try? await writeCommand("ABORT")
            handle(.disconnected)
        }
    }

    // MARK: - Command channel

    private func writeCommand(_ cmd: String) async throws {
        guard !closed else { throw WinlinkError.connectionClosed }
        logLine?(">\(cmd)")
        try await command.write(Data((cmd + protocolCR).utf8))
    }

    /// Reads CR-separated commands from the command channel and
    /// dispatches them (Go: cmdListen).
    private func listenLoop() async {
        var buffer = [UInt8]()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await command.read()
            } catch {
                break
            }
            if chunk.isEmpty {
                break // Modem closed the command channel.
            }
            buffer.append(contentsOf: chunk)

            while let idx = buffer.firstIndex(of: FBBControl.cr) {
                let line = String(decoding: buffer[..<idx], as: UTF8.self)
                buffer.removeSubrange(...idx)
                if line.isEmpty {
                    continue
                }
                logLine?(line)
                handle(VaraCommand(parsing: line))
            }
        }
        if !closed {
            // Lost the modem: bring everything down.
            handle(.disconnected)
            failAllWaiters(with: WinlinkError.connectionClosed)
            resumeDataReader(with: Data())
        }
    }

    /// State effects of one modem command (Go: handleCmd), then waiter
    /// dispatch.
    private func handle(_ cmd: VaraCommand) {
        switch cmd {
        case .pttOn:
            let handler = pttHandler
            Task { await handler?(true) }
        case .pttOff:
            let handler = pttHandler
            Task { await handler?(false) }
        case .busyOn:
            isBusy = true
        case .busyOff:
            isBusy = false
        case .buffer(let count):
            txBufferCount = count
        case .connected:
            state = .connected
        case .disconnected:
            state = .disconnected
            txBufferCount = 0
            resumeDataReader(with: Data()) // EOF for a blocked reader
        default:
            break
        }

        for expectation in expectations where expectation.result == nil && expectation.predicate(cmd) {
            fulfill(expectation, with: .success(cmd))
        }
        expectations.removeAll { $0.result != nil && $0.continuation == nil }
    }

    /// Registers a one-shot subscription. Synchronous — call *before*
    /// sending the command whose answer is awaited.
    private func expect(_ predicate: @escaping (VaraCommand) -> Bool) -> CommandExpectation {
        let expectation = CommandExpectation(predicate)
        expectations.append(expectation)
        return expectation
    }

    /// Awaits the expectation's command, failing after the timeout.
    private func value(
        of expectation: CommandExpectation, timeout: TimeInterval
    ) async throws -> VaraCommand {
        if let result = expectation.result {
            expectations.removeAll { $0 === expectation }
            return try result.get()
        }

        Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.fulfill(expectation, with: .failure(.timeout("No answer from VARA modem")))
            self.expectations.removeAll { $0 === expectation }
        }

        return try await withCheckedThrowingContinuation { cont in
            if let result = expectation.result {
                // Fulfilled between the check above and now (same actor,
                // so in practice impossible, but cheap to be safe).
                cont.resume(with: result.mapError { $0 as any Error })
            } else {
                expectation.continuation = cont
            }
        }
    }

    private func cancel(_ expectation: CommandExpectation) {
        expectations.removeAll { $0 === expectation }
    }

    /// Resolves an expectation exactly once.
    private func fulfill(
        _ expectation: CommandExpectation, with result: Result<VaraCommand, WinlinkError>
    ) {
        guard expectation.result == nil else { return }
        expectation.result = result
        if let cont = expectation.continuation {
            expectation.continuation = nil
            cont.resume(with: result.mapError { $0 as any Error })
        }
    }

    private func failAllWaiters(with error: WinlinkError) {
        let pending = expectations
        expectations.removeAll()
        for expectation in pending {
            fulfill(expectation, with: .failure(error))
        }
    }

    // MARK: - Data channel plumbing

    private func dataLoop() async {
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await data.read()
            } catch {
                break
            }
            if chunk.isEmpty {
                break
            }
            if let dataWaiter {
                self.dataWaiter = nil
                dataWaiter.resume(returning: chunk)
            } else {
                dataInbox.append(chunk)
            }
        }
    }

    private func resumeDataReader(with chunk: Data) {
        if let dataWaiter {
            self.dataWaiter = nil
            dataWaiter.resume(returning: chunk)
        }
    }
}

/// The data channel of a connected VARA link, as seen by a `B2FSession`.
///
/// Closing the connection closes the RF link (DISCONNECT), not the
/// channels to the modem program — the modem can dial again.
public struct VaraConnection: WinlinkTransport {
    let modem: VaraModem

    public func read() async throws -> Data {
        try await modem.readData()
    }

    public func write(_ data: Data) async throws {
        try await modem.writeData(data)
    }

    public func close() async {
        await modem.disconnectLink()
    }
}
