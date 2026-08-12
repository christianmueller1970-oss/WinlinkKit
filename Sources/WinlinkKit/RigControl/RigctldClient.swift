// Ported from wl2k-go/rigcontrol/hamlib/rigctld.go
import Foundation

/// Client for Hamlib's `rigctld` network daemon (default TCP port 4532).
///
/// Deliberately minimal: PTT, dial frequency and operating mode of the
/// current VFO — exactly what a radio transport needs to QSY onto a
/// gateway channel and key the rig. Hook `setPTT` into
/// `VaraModem.setPTTHandler` to key the transceiver from the modem's
/// PTT events. Anything beyond that (split, levels, memories) belongs
/// to the host application, not this protocol library.
///
/// Mode is here for symmetry with `CIVClient.setOperatingMode`: a QSY
/// that sets the frequency but leaves the rig in SSB is worse than no
/// QSY at all, and via a shared rigctld this is the only way to reach
/// the radio while another program holds the serial port.
///
/// The rigctld protocol is line-based ASCII: one command per line,
/// one reply line per command; errors are reported as `RPRT <code>`
/// (0 = success).
public actor RigctldClient {
    /// An operating mode as Hamlib names it: `USB`, `PKTUSB`, `CW` …
    ///
    /// A plain string on purpose — Hamlib's list is long, rig-specific
    /// and grows; an enum here would be a moving target. The host app
    /// knows which names its rig accepts.
    public struct Mode: Sendable, Equatable, CustomStringConvertible {
        public let name: String
        /// Filter width in Hz; 0 = leave it to the rig.
        public let passbandHz: Int

        public init(name: String, passbandHz: Int = 0) {
            self.name = name
            self.passbandHz = passbandHz
        }

        /// Upper sideband data mode — what an RMS gateway channel needs.
        public static let dataUSB = Mode(name: "PKTUSB")
        public static let usb = Mode(name: "USB")
        public static let lsb = Mode(name: "LSB")

        public var description: String {
            passbandHz > 0 ? "\(name)/\(passbandHz)" : name
        }
    }

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

    /// Reads the operating mode of the current VFO.
    ///
    /// `\get_mode` answers with **two** lines — mode and passband —
    /// where every other command answers with one. Both are consumed
    /// here; leaving the second in the queue would desynchronise the
    /// next command's reply.
    public func mode() async throws -> Mode {
        let name = try await command("\\get_mode")
        // A failed command reports RPRT and sends no passband line.
        if name.hasPrefix("RPRT ") {
            throw WinlinkError.remoteError("rigctld: get_mode failed (\(name))")
        }
        let passband = try await readLine()
        return Mode(name: name, passbandHz: Int(passband) ?? 0)
    }

    /// Sets the operating mode of the current VFO.
    ///
    /// `passbandHz` 0 leaves the filter to the rig's default, which is
    /// what a data-mode QSY wants.
    public func setMode(_ mode: Mode) async throws {
        _ = try await command("\\set_mode \(mode.name) \(mode.passbandHz)")
    }

    // MARK: - Messwerte

    /// Reads a Hamlib level by name, e.g. `ALC`, `SWR`,
    /// `RFPOWER_METER_WATTS`.
    ///
    /// Not every backend implements every level, and a rig that does not
    /// know one answers with `RPRT -11` — the caller should treat a throw
    /// as "this rig does not report it" rather than as a failure.
    public func level(_ name: String) async throws -> Double {
        let reply = try await command("\\get_level \(name)")
        guard let value = Double(reply) else {
            throw WinlinkError.malformedInput("Unexpected \(name) reply: \(reply)")
        }
        return value
    }

    /// ALC reading, normalised 0…1 — only meaningful while transmitting.
    ///
    /// This is the value a drive level is set against: it should just
    /// barely leave zero. Anything more means the control loop is
    /// limiting, and what it limits, it also distorts.
    public func alc() async throws -> Double {
        min(1, max(0, try await level("ALC")))
    }

    /// Measured output power in watts — only meaningful while
    /// transmitting. Unlike a catalogue value this is what the rig
    /// actually reports, which shows whether more drive still buys
    /// any power.
    public func powerWatts() async throws -> Double {
        max(0, try await level("RFPOWER_METER_WATTS"))
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
