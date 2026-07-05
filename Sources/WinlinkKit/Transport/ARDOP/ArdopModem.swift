// Ported from wl2k-go/transport/ardop (tnc.go, conn.go, dial.go) — MIT, © 2015 Martin Hebnes Pedersen (LA5NTA)
import Foundation

/// Client for an ARDOP TNC (ardopcf/ARDOPC) reached over TCP.
///
/// ARDOP exposes a control port (default 8515) with CR-terminated ASCII
/// commands and a data port (default 8516) carrying length-prefixed
/// data frames. `ArdopModem` drives the control channel and hands out
/// an `ArdopConnection` (a `WinlinkTransport`) for the ARQ data stream,
/// so a `B2FSession` runs over ARDOP exactly like over telnet or VARA.
///
/// Unlike VARA, ARDOP does not key the radio itself — hook rigctld into
/// `setPTTHandler` or configure CAT PTT in the TNC.
public actor ArdopModem {
    /// Configuration for reaching the TNC (Go: DefaultAddr
    /// "localhost:8515"; the data port is control + 1).
    public struct Config: Sendable {
        public var host = "localhost"
        public var controlPort: UInt16 = 8515
        public var dataPort: UInt16 = 8516

        public init() {}
    }

    /// The default ARQ session idle timeout in seconds
    /// (Go: DefaultARQTimeout).
    public static let defaultARQTimeout = 90

    /// The default number of connect frames sent when dialing
    /// (Go: DefaultConnectRequests).
    public static let defaultConnectRequests = 10

    /// Our view of the ARQ link. Transitions:
    ///
    ///     disconnected ──dial()──▶ connecting
    ///     connecting ──CONNECTED──▶ connected
    ///     connecting ──NEWSTATE DISC / DISCONNECTED / FAULT──▶ disconnected
    ///     connected ──NEWSTATE DISC / DISCONNECTED──▶ disconnected
    enum LinkState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private let mycall: String
    private let gridSquare: String
    private let control: any WinlinkTransport
    private let data: any WinlinkTransport

    private(set) var linkState: LinkState = .disconnected
    private var closed = false

    /// The last state reported by the TNC (NEWSTATE/STATE).
    public private(set) var tncState: ArdopState = .unknown

    /// True while the TNC reports the channel as busy (BUSY True/False).
    public private(set) var isBusy = false

    /// Bytes outstanding in the TNC's data-to-send queue, tracked via
    /// BUFFER updates (Go: tncConn.buffer).
    private var txBufferCount = 0

    /// Called when the TNC asserts/releases PTT. Hook the rig control
    /// (rigctld) here; if nil, PTT requests are ignored (the TNC may
    /// do CAT PTT itself).
    private var pttHandler: (@Sendable (Bool) async -> Void)?

    /// Optional sink for control-channel log lines (`>` marks sent).
    public var logLine: (@Sendable (String) -> Void)?

    /// A one-shot subscription for the next command matching a
    /// predicate. Registered *before* sending the request (same
    /// subscribe-then-write pattern as `VaraModem`), so a fast answer
    /// can't be missed.
    private final class CommandExpectation {
        let predicate: (ArdopCommand) -> Bool
        var result: Result<ArdopCommand, WinlinkError>?
        var continuation: CheckedContinuation<ArdopCommand, any Error>?

        init(_ predicate: @escaping (ArdopCommand) -> Bool) {
            self.predicate = predicate
        }
    }

    private var expectations = [CommandExpectation]()

    // Inbound ARQ payloads and blocked readers (only ever one reader —
    // the session).
    private var dataInbox = [Data]()
    private var dataWaiter: CheckedContinuation<Data, Never>?

    private var listenTask: Task<Void, Never>?
    private var dataTask: Task<Void, Never>?

    /// Creates a TNC client over the given control/data byte streams.
    /// Use `connect(mycall:gridSquare:config:)` for the TCP case; tests
    /// inject pipe transports here.
    init(
        mycall: String, gridSquare: String,
        control: any WinlinkTransport, data: any WinlinkTransport
    ) {
        self.mycall = mycall.uppercased()
        self.gridSquare = gridSquare
        self.control = control
        self.data = data
    }

    /// Connects to the ARDOP TNC via TCP and performs the initial
    /// setup (Go: OpenTCP).
    public static func connect(
        mycall: String, gridSquare: String = "", config: Config = Config()
    ) async throws -> ArdopModem {
        let control = try await TCPTransport.connect(
            host: config.host, port: config.controlPort)
        let data: TCPTransport
        do {
            data = try await TCPTransport.connect(host: config.host, port: config.dataPort)
        } catch {
            await control.close()
            throw error
        }

        let modem = ArdopModem(
            mycall: mycall, gridSquare: gridSquare, control: control, data: data)
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

    // MARK: - Setup (Go: open + TNC.init)

    /// Sends the initial configuration and starts the listeners.
    /// Internal so tests can drive it over pipe transports.
    func setup() async throws {
        startListening()

        try await set("INITIALIZE")
        tncState = try await get("STATE").stateValue ?? .unknown
        if tncState == .offline {
            try await set("CODEC", "true")
        }
        try await set("PROTOCOLMODE", "ARQ")
        try await set("ARQTIMEOUT", "\(Self.defaultARQTimeout)")
        // Only answer inbound ARQ connect requests when requested by
        // the user (listen mode is stage-2 backlog).
        try await set("LISTEN", "false")
        try await set("MYCALL", mycall)
        // Go sends GRIDSQUARE unconditionally, but an empty value
        // FAULTs — skip it when we have no locator.
        if !gridSquare.isEmpty {
            try await set("GRIDSQUARE", gridSquare)
        }
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            await self?.listenLoop()
        }
        dataTask = Task { [weak self] in
            await self?.dataLoop()
        }
    }

    // MARK: - Dialing (Go: DialBandwidth + arqCall)

    /// Connects to a remote station via ARQ and returns the data
    /// stream as a `WinlinkTransport` for the B2F session.
    ///
    /// `connectRequests` is the number of connect frames the TNC sends
    /// before giving up; `timeout` is our own upper bound on top of
    /// that.
    public func dial(
        _ target: String, bandwidth: ArdopBandwidth? = nil,
        connectRequests: Int = ArdopModem.defaultConnectRequests,
        timeout: TimeInterval = 300
    ) async throws -> ArdopConnection {
        guard !closed else { throw WinlinkError.connectionClosed }
        guard linkState == .disconnected else {
            throw WinlinkError.malformedInput("TNC busy (already connecting or connected)")
        }

        // Go sets ARQBW temporarily and reverts it on close; we keep
        // the setting — one modem instance serves one connection.
        if let bandwidth {
            try await set("ARQBW", bandwidth.description)
        }

        linkState = .connecting
        let answer = expect { $0.endsDial }
        do {
            try await writeCommand("ARQCALL \(target.uppercased()) \(connectRequests)")
            let result = try await value(of: answer, timeout: timeout)
            switch result.name {
            case "CONNECTED":
                // linkState is set to .connected by the listener.
                return ArdopConnection(modem: self)
            case "FAULT":
                linkState = .disconnected
                throw WinlinkError.remoteError(result.stringValue ?? "FAULT")
            default:
                linkState = .disconnected
                throw WinlinkError.timeout("Connect to \(target) failed (ARDOP reported disconnect)")
            }
        } catch {
            if linkState == .connecting {
                linkState = .disconnected
            }
            cancel(answer)
            throw error
        }
    }

    /// The TNC's version string (Go: TNC.Version).
    public func version() async throws -> String {
        let reply = try await get("VERSION", timeout: 5)
        guard let version = reply.stringValue else {
            throw WinlinkError.malformedInput("VERSION reply without value")
        }
        return version
    }

    /// Closes the ARQ link (if any) and the channels to the TNC
    /// (Go: TNC.Close).
    public func close() async {
        guard !closed else { return }

        if linkState != .disconnected {
            await disconnectLink()
        }

        closed = true
        // Make sure to stop TX (should have already happened; backup).
        await pttHandler?(false)

        listenTask?.cancel()
        dataTask?.cancel()
        failAllWaiters(with: WinlinkError.connectionClosed)
        resumeDataReader(with: Data())
        await control.close()
        await data.close()
    }

    // MARK: - Data channel (used by ArdopConnection; Go: conn.go)

    /// Reads the next ARQ payload. Returns empty Data (EOF) once the
    /// link is down and all received data was consumed.
    func readData() async throws -> Data {
        if !dataInbox.isEmpty {
            return dataInbox.removeFirst()
        }
        if linkState != .connected || closed {
            return Data() // EOF
        }
        return await withCheckedContinuation { dataWaiter = $0 }
    }

    /// Writes one data frame per chunk and waits for the TNC's BUFFER
    /// update before returning, pacing the host against the TNC queue
    /// (Go: conn.Write). CRCFAULT retries are a serial-transport
    /// concern — we are TCP-only.
    func writeData(_ chunk: Data) async throws {
        guard linkState == .connected, !closed else {
            throw WinlinkError.connectionClosed
        }

        // The frame length field is a uint16 — split larger writes
        // (Go truncates and relies on io.Copy retrying).
        var rest = chunk[...]
        while !rest.isEmpty {
            let payload = Data(rest.prefix(ArdopFraming.maxPayload))
            rest = rest.dropFirst(payload.count)

            let update = expect { $0.name == "BUFFER" || $0.endsLink }
            do {
                try await data.write(ArdopFraming.encode(payload))
                let answer = try await value(of: update, timeout: 60)
                guard answer.name == "BUFFER" else {
                    throw WinlinkError.connectionClosed
                }
            } catch {
                cancel(update)
                throw error
            }
        }
    }

    /// Gracefully closes the ARQ link: drain the TNC's TX buffer,
    /// DISCONNECT, await DISCONNECTED; ABORT after 30 s (Go: conn.Close
    /// with flushAndCloseTimeout).
    func disconnectLink() async {
        guard linkState != .disconnected, !closed else { return }

        // ARDOP disconnects without sending queued data, so wait for
        // the buffer to drain first.
        let flushDeadline = Date().addingTimeInterval(30)
        while linkState == .connected, txBufferCount > 0 {
            let remaining = flushDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let update = expect { $0.name == "BUFFER" || $0.endsLink }
            guard let answer = try? await value(of: update, timeout: remaining) else {
                cancel(update)
                break
            }
            if answer.endsLink {
                return // Link already down.
            }
        }
        guard linkState != .disconnected else { return }

        let done = expect { $0.endsLink }
        do {
            try await writeCommand("DISCONNECT")
            _ = try await value(of: done, timeout: 30)
        } catch {
            // Disconnect failed or timed out: abort hard.
            try? await writeCommand("ABORT")
            cancel(done)
            linkDown()
        }
    }

    // MARK: - Control channel

    /// Sends a command and awaits the TNC's echo-back or FAULT
    /// (Go: TNC.set/get). ARDOP acknowledges every host command by
    /// repeating its name, e.g. "LISTEN now False".
    @discardableResult
    private func get(
        _ name: String, _ param: String? = nil, timeout: TimeInterval = 10
    ) async throws -> ArdopCommand {
        let reply = expect { $0.name == name || $0.name == "FAULT" }
        do {
            try await writeCommand(param.map { "\(name) \($0)" } ?? name)
            let answer = try await value(of: reply, timeout: timeout)
            guard answer.name != "FAULT" else {
                throw WinlinkError.remoteError(answer.stringValue ?? "FAULT")
            }
            return answer
        } catch {
            cancel(reply)
            throw error
        }
    }

    private func set(
        _ name: String, _ param: String? = nil, timeout: TimeInterval = 10
    ) async throws {
        try await get(name, param, timeout: timeout)
    }

    private func writeCommand(_ cmd: String) async throws {
        guard !closed else { throw WinlinkError.connectionClosed }
        logLine?(">\(cmd)")
        try await control.write(Data((cmd + protocolCR).utf8))
    }

    /// Reads CR-separated commands from the control channel and
    /// dispatches them (Go: runControlLoop).
    private func listenLoop() async {
        var buffer = [UInt8]()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await control.read()
            } catch {
                break
            }
            if chunk.isEmpty {
                break // TNC closed the control channel.
            }
            buffer.append(contentsOf: chunk)

            while let idx = buffer.firstIndex(of: FBBControl.cr) {
                let line = String(decoding: buffer[..<idx], as: UTF8.self)
                buffer.removeSubrange(...idx)
                if line.isEmpty {
                    continue
                }
                logLine?(line)
                handle(ArdopCommand(parsing: line))
            }
        }
        if !closed {
            // Lost the TNC: bring everything down.
            linkDown()
            failAllWaiters(with: WinlinkError.connectionClosed)
            resumeDataReader(with: Data())
        }
    }

    /// State effects of one control message (Go: the control loop's
    /// switch), then waiter dispatch.
    private func handle(_ cmd: ArdopCommand) {
        switch cmd.name {
        case "PTT":
            if let on = cmd.boolValue {
                let handler = pttHandler
                Task { await handler?(on) }
            }
        case "BUSY":
            isBusy = cmd.boolValue ?? false
        case "BUFFER":
            txBufferCount = cmd.intValue ?? 0
        case "NEWSTATE", "STATE":
            if let state = cmd.stateValue {
                tncState = state
                if state == .disconnected {
                    linkDown()
                }
            }
        case "CONNECTED":
            linkState = .connected
        case "DISCONNECTED":
            tncState = .disconnected
            linkDown()
        default:
            break
        }

        for expectation in expectations where expectation.result == nil && expectation.predicate(cmd) {
            fulfill(expectation, with: .success(cmd))
        }
        expectations.removeAll { $0.result != nil && $0.continuation == nil }
    }

    private func linkDown() {
        linkState = .disconnected
        txBufferCount = 0
        resumeDataReader(with: Data()) // EOF for a blocked reader
    }

    /// Registers a one-shot subscription. Synchronous — call *before*
    /// sending the command whose answer is awaited.
    private func expect(_ predicate: @escaping (ArdopCommand) -> Bool) -> CommandExpectation {
        let expectation = CommandExpectation(predicate)
        expectations.append(expectation)
        return expectation
    }

    /// Awaits the expectation's command, failing after the timeout.
    private func value(
        of expectation: CommandExpectation, timeout: TimeInterval
    ) async throws -> ArdopCommand {
        if let result = expectation.result {
            expectations.removeAll { $0 === expectation }
            return try result.get()
        }

        Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.fulfill(expectation, with: .failure(.timeout("No answer from ARDOP TNC")))
            self.expectations.removeAll { $0 === expectation }
        }

        return try await withCheckedThrowingContinuation { cont in
            if let result = expectation.result {
                // Fulfilled between the check above and now (same
                // actor, so in practice impossible, but cheap to be
                // safe).
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
        _ expectation: CommandExpectation, with result: Result<ArdopCommand, WinlinkError>
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
        var decoder = ArdopFraming.Decoder()
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
            decoder.append(chunk)
            while let frame = decoder.next() {
                handleDataFrame(frame)
            }
        }
    }

    private func handleDataFrame(_ frame: (type: String, payload: Data)) {
        switch frame.type {
        case "ARQ":
            // ARDOPc sends non-ARQ data as ARQ frames when not
            // connected — drop those (Go: control loop quirk note).
            guard linkState == .connected, !frame.payload.isEmpty else { return }
            if let dataWaiter {
                self.dataWaiter = nil
                dataWaiter.resume(returning: frame.payload)
            } else {
                dataInbox.append(frame.payload)
            }
        case "IDF", "FEC", "ERR":
            // Heard-station tracking (ID frames) is not ported —
            // listen/P2P mode is stage-2 backlog.
            logLine?("[\(frame.type)] \(String(decoding: frame.payload, as: UTF8.self))")
        default:
            break
        }
    }

    private func resumeDataReader(with chunk: Data) {
        if let dataWaiter {
            self.dataWaiter = nil
            dataWaiter.resume(returning: chunk)
        }
    }
}

extension ArdopCommand {
    /// True for the messages that terminate a connect attempt.
    var endsDial: Bool {
        name == "CONNECTED" || name == "FAULT" || endsLink
    }

    /// True for the messages that report the ARQ link as down.
    var endsLink: Bool {
        name == "DISCONNECTED" || (name == "NEWSTATE" && stateValue == .disconnected)
    }
}

/// The ARQ data stream of a connected ARDOP link, as seen by a
/// `B2FSession`.
///
/// Closing the connection closes the ARQ link (DISCONNECT), not the
/// channels to the TNC — the modem can dial again.
public struct ArdopConnection: WinlinkTransport {
    let modem: ArdopModem

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
