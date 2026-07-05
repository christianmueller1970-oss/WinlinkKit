// Ported from wl2k-go/rigcontrol/hamlib/rigctld.go
import Foundation

/// Client for Hamlib's `rigctld` network daemon (default TCP port 4532).
///
/// Deliberately minimal: PTT and dial frequency of the current VFO —
/// exactly what a radio transport needs. Hook `setPTT` into
/// `VaraModem.setPTTHandler` to key the transceiver from the modem's
/// PTT events. Anything beyond that (mode, split, levels) belongs to
/// the host application, not this protocol library.
///
/// The rigctld protocol is line-based ASCII: one command per line,
/// one reply line per command; errors are reported as `RPRT <code>`
/// (0 = success).
public actor RigctldClient {
    public static let defaultPort: UInt16 = 4532

    /// Timeout for one command/response round trip
    /// (Go: hamlib.TCPTimeout — rigctld answers locally, 1 s is plenty).
    private static let commandTimeout: TimeInterval = 1

    private let transport: any WinlinkTransport
    private var closed = false

    // Reply plumbing (same pattern as VaraModem): a long-lived read
    // loop feeds complete lines; `readLine` awaits the next one. The
    // loop may block in `transport.read()` forever — that's fine, it
    // is never awaited by a command, so a silent daemon only trips
    // the timeout, not a deadlock.
    private var readTask: Task<Void, Never>?
    private var pendingLines = [String]()
    private var lineWaiter: CheckedContinuation<String, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var eof = false

    /// Creates a client over an existing byte stream (tests inject a
    /// pipe transport here).
    init(transport: any WinlinkTransport) {
        self.transport = transport
    }

    /// Connects to rigctld via TCP.
    public static func connect(
        host: String = "localhost", port: UInt16 = defaultPort
    ) async throws -> RigctldClient {
        let transport = try await TCPTransport.connect(host: host, port: port)
        return RigctldClient(transport: transport)
    }

    /// Keys or unkeys the transmitter (Go: tcpVFO.SetPTT).
    public func setPTT(_ on: Bool) async throws {
        _ = try await command("\\set_ptt \(on ? 1 : 0)")
    }

    /// Reads the PTT state (Go: tcpVFO.GetPTT). Hamlib reports
    /// 0 = RX and 1/2/3 for the PTT variants — all of them are "on".
    public func ptt() async throws -> Bool {
        let reply = try await command("t")
        switch reply {
        case "0": return false
        case "1", "2", "3": return true
        default:
            throw WinlinkError.malformedInput("Unexpected PTT reply: \(reply)")
        }
    }

    /// Reads the dial frequency in Hz (Go: tcpVFO.GetFreq).
    public func frequency() async throws -> Int {
        let reply = try await command("\\get_freq")
        guard let hz = Int(reply) else {
            throw WinlinkError.malformedInput("Unexpected frequency reply: \(reply)")
        }
        return hz
    }

    /// Sets the dial frequency in Hz (Go: tcpVFO.SetFreq).
    public func setFrequency(_ hz: Int) async throws {
        _ = try await command("\\set_freq \(hz)")
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        failWaiter(with: .connectionClosed)
        await transport.close()
    }

    // MARK: - Protocol plumbing

    /// Sends one command and returns the first reply line.
    /// `RPRT <code>` replies are mapped to success (0) or an error.
    private func command(_ cmd: String) async throws -> String {
        guard !closed else { throw WinlinkError.connectionClosed }
        startReadingIfNeeded()
        try await transport.write(Data((cmd + "\n").utf8))
        let reply = try await readLine()
        if reply.hasPrefix("RPRT ") {
            guard reply == "RPRT 0" else {
                throw WinlinkError.remoteError("rigctld: \(cmd) failed (\(reply))")
            }
        }
        return reply
    }

    private func startReadingIfNeeded() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Reads newline-separated reply lines and hands them to `deliver`.
    private func readLoop() async {
        var buffer = [UInt8]()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await transport.read()
            } catch {
                break
            }
            if chunk.isEmpty {
                break // Daemon closed the connection.
            }
            buffer.append(contentsOf: chunk)
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = Array(buffer[..<idx])
                buffer.removeSubrange(...idx)
                if line.last == UInt8(ascii: "\r") {
                    line.removeLast()
                }
                deliver(String(decoding: line, as: UTF8.self))
            }
        }
        eof = true
        failWaiter(with: .connectionClosed)
    }

    /// Awaits the next reply line, failing after `commandTimeout`
    /// (rigctld is local; a silent daemon should fail the command,
    /// not hang the session).
    private func readLine() async throws -> String {
        if !pendingLines.isEmpty {
            return pendingLines.removeFirst()
        }
        guard !eof, !closed else { throw WinlinkError.connectionClosed }
        return try await withCheckedThrowingContinuation { cont in
            lineWaiter = cont
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.commandTimeout))
                guard !Task.isCancelled else { return }
                await self?.failWaiter(with: .timeout("No reply from rigctld"))
            }
        }
    }

    private func deliver(_ line: String) {
        if let waiter = lineWaiter {
            timeoutTask?.cancel()
            timeoutTask = nil
            lineWaiter = nil
            waiter.resume(returning: line)
        } else {
            pendingLines.append(line)
        }
    }

    private func failWaiter(with error: WinlinkError) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(throwing: error)
        }
    }
}
