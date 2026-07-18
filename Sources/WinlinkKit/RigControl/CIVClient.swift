import Foundation

/// Client for Icom's CI-V CAT protocol on the rig's (USB) serial port.
///
/// Deliberately minimal, like `RigctldClient`: read and set the dial
/// frequency and the operating mode (incl. data mode) of the selected
/// VFO — exactly what a gateway QSY needs. PTT stays with ardopcf
/// (`ArdopLaunchConfig.PTT.catCIV`), which owns the serial port
/// *during* a session; use this client only before and after.
///
/// Frames are `FE FE <to> <from> <cmd> [data…] FD`. The mode commands
/// use `26 00` (selected VFO with data-mode byte), which the current
/// Icom generation speaks (IC-7300, IC-7610, IC-705, IC-9700, …).
public actor CIVClient {
    /// The bus address a controller talks from.
    public static let controllerAddress: UInt8 = 0xE0

    /// A rig answers within a few ms even at classic CI-V baud rates;
    /// a silent line should fail the QSY, not hang the session.
    private static let commandTimeout: TimeInterval = 2

    /// Mode, data mode and IF filter of a VFO — everything command
    /// `26 00` reads and sets, so a QSY can restore the rig exactly.
    public struct OperatingMode: Sendable, Equatable, CustomStringConvertible {
        /// CI-V mode code (0x00 = LSB, 0x01 = USB, 0x03 = CW, …).
        public var mode: UInt8
        /// 0 = data mode off, 1–3 = DATA1–DATA3.
        public var dataMode: UInt8
        /// IF filter 1–3.
        public var filter: UInt8

        public init(mode: UInt8, dataMode: UInt8 = 0, filter: UInt8 = 1) {
            self.mode = mode
            self.dataMode = dataMode
            self.filter = filter
        }

        /// USB + DATA1 — the setting for ARDOP/VARA on HF.
        public static let usbData = OperatingMode(mode: 0x01, dataMode: 1, filter: 1)

        public var description: String {
            let names: [UInt8: String] = [
                0x00: "LSB", 0x01: "USB", 0x02: "AM", 0x03: "CW",
                0x04: "RTTY", 0x05: "FM", 0x07: "CW-R", 0x08: "RTTY-R",
            ]
            let base = names[mode] ?? String(format: "Mode %02X", mode)
            return dataMode > 0 ? "\(base)-D" : base
        }
    }

    private let transport: any WinlinkTransport
    private let radioAddress: UInt8
    private var closed = false

    // Reply plumbing (same pattern as RigctldClient): a long-lived read
    // loop feeds decoded frame payloads; `nextFrame` awaits the next one.
    private var readTask: Task<Void, Never>?
    private var pendingFrames = [[UInt8]]()
    private var frameWaiter: CheckedContinuation<[UInt8], any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var eof = false

    /// Creates a client over an existing byte stream (tests inject a
    /// pipe transport here).
    init(transport: any WinlinkTransport, radioAddress: UInt8) {
        self.transport = transport
        self.radioAddress = radioAddress
    }

    /// Opens the serial port and talks CI-V to the rig at `radioAddress`
    /// (IC-7610 default: 0x98; IC-705: 0xA4).
    public static func connect(
        serialPort: String, baud: Int = 115200, radioAddress: UInt8 = 0x98
    ) async throws -> CIVClient {
        let transport = try SerialTransport.open(path: serialPort, baud: baud)
        return CIVClient(transport: transport, radioAddress: radioAddress)
    }

    /// Reads the dial frequency of the selected VFO in Hz (cmd 03).
    public func frequency() async throws -> Int {
        let reply = try await command([0x03], expecting: 0x03)
        return try Self.frequency(fromBCD: Array(reply.dropFirst()))
    }

    /// Sets the dial frequency of the selected VFO in Hz (cmd 05).
    public func setFrequency(_ hz: Int) async throws {
        _ = try await command([0x05] + Self.bcd(frequency: hz), expecting: nil)
    }

    /// Reads mode, data mode and filter of the selected VFO (cmd 26 00).
    public func operatingMode() async throws -> OperatingMode {
        let reply = try await command([0x26, 0x00], expecting: 0x26)
        guard reply.count >= 5 else {
            throw WinlinkError.malformedInput("Short CI-V mode reply (\(reply.count) bytes)")
        }
        return OperatingMode(mode: reply[2], dataMode: reply[3], filter: reply[4])
    }

    /// Sets mode, data mode and filter of the selected VFO (cmd 26 00).
    public func setOperatingMode(_ mode: OperatingMode) async throws {
        _ = try await command(
            [0x26, 0x00, mode.mode, mode.dataMode, mode.filter], expecting: nil)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        failWaiter(with: .connectionClosed)
        await transport.close()
    }

    // MARK: - Protocol plumbing

    /// Sends one command payload and awaits the matching reply payload:
    /// `FB` (OK), `FA` (NG → error) or the echoed `expecting` command
    /// for reads. Unrelated frames (transceive broadcasts) are skipped.
    private func command(_ payload: [UInt8], expecting reply: UInt8?) async throws -> [UInt8] {
        guard !closed else { throw WinlinkError.connectionClosed }
        startReadingIfNeeded()
        let frame = [0xFE, 0xFE, radioAddress, Self.controllerAddress] + payload + [0xFD]
        try await transport.write(Data(frame))

        let deadline = ContinuousClock.now + .seconds(Self.commandTimeout)
        while true {
            let response = try await nextFrame(deadline: deadline)
            if response.first == 0xFB {
                return response
            }
            if response.first == 0xFA {
                let sent = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                throw WinlinkError.remoteError("CI-V: rig rejected command \(sent) (NG)")
            }
            if let reply, response.first == reply {
                return response
            }
        }
    }

    private func startReadingIfNeeded() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

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
                break  // Port closed or device gone.
            }
            buffer.append(contentsOf: chunk)
            while let end = buffer.firstIndex(of: 0xFD) {
                let raw = Array(buffer[..<end])
                buffer.removeSubrange(...end)
                deliver(frame: raw)
            }
        }
        eof = true
        failWaiter(with: .connectionClosed)
    }

    /// Decodes one raw frame (without the trailing FD) and hands the
    /// payload on when it is a reply from our rig to us. Our own echoed
    /// commands (CI-V echo back) and third-party traffic are dropped.
    private func deliver(frame raw: [UInt8]) {
        var index = 0
        while index < raw.count, raw[index] == 0xFE { index += 1 }
        guard index >= 2, raw.count - index >= 3 else { return }  // Not a CI-V frame.
        let to = raw[index]
        let from = raw[index + 1]
        guard from == radioAddress, to == Self.controllerAddress || to == 0x00 else {
            return
        }
        let payload = Array(raw[(index + 2)...])
        if let waiter = frameWaiter {
            timeoutTask?.cancel()
            timeoutTask = nil
            frameWaiter = nil
            waiter.resume(returning: payload)
        } else {
            pendingFrames.append(payload)
        }
    }

    /// Awaits the next reply frame, failing at `deadline` — the whole
    /// command shares one deadline even when broadcasts arrive between
    /// request and reply.
    private func nextFrame(deadline: ContinuousClock.Instant) async throws -> [UInt8] {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        guard !eof, !closed else { throw WinlinkError.connectionClosed }
        return try await withCheckedThrowingContinuation { cont in
            frameWaiter = cont
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                await self?.failWaiter(with: .timeout("No reply from the rig (CI-V)"))
            }
        }
    }

    private func failWaiter(with error: WinlinkError) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    // MARK: - BCD frequency coding

    /// 5 bytes little-endian packed BCD, 1 Hz digit first (10 digits).
    static func bcd(frequency hz: Int) -> [UInt8] {
        var digits = [UInt8]()
        var value = hz
        for _ in 0..<10 {
            digits.append(UInt8(value % 10))
            value /= 10
        }
        return stride(from: 0, to: 10, by: 2).map { digits[$0] | (digits[$0 + 1] << 4) }
    }

    static func frequency(fromBCD bytes: [UInt8]) throws -> Int {
        guard bytes.count == 5 else {
            throw WinlinkError.malformedInput("CI-V frequency needs 5 BCD bytes, got \(bytes.count)")
        }
        var hz = 0
        for byte in bytes.reversed() {
            let high = Int(byte >> 4)
            let low = Int(byte & 0x0F)
            guard high < 10, low < 10 else {
                throw WinlinkError.malformedInput(
                    String(format: "Invalid BCD byte %02X in CI-V frequency", byte))
            }
            hz = hz * 100 + high * 10 + low
        }
        return hz
    }
}
