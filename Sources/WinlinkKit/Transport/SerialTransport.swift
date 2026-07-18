import Foundation

/// A serial line (`/dev/cu.*`) as a `WinlinkTransport` byte stream —
/// raw mode, 8N1, no flow control. Used by `CIVClient` for CAT control
/// of the transceiver over its (USB) CI-V port.
///
/// Reads poll a non-blocking descriptor instead of parking a thread:
/// CAT traffic is a handful of tiny frames around a session, so a
/// 10 ms poll interval is irrelevant next to the serial line itself.
public actor SerialTransport: WinlinkTransport {
    private let fd: Int32
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Opens and configures the device. Deliberately leaves the modem
    /// control lines (RTS/DTR) alone — on rigs wired for RTS keying a
    /// line change would press the PTT.
    public static func open(path: String, baud: Int = 115200) throws -> SerialTransport {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw WinlinkError.remoteError(
                "Cannot open serial port \(path): \(String(cString: strerror(errno)))")
        }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw WinlinkError.remoteError("Not a serial port (\(path)): \(message)")
        }
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        cfsetspeed(&tty, speed_t(baud))
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw WinlinkError.remoteError(
                "Cannot configure serial port \(path) (\(baud) Bd): \(message)")
        }

        return SerialTransport(fd: fd)
    }

    public func read() async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 512)
        while !closed {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                return Data(buffer[..<count])
            }
            if count == 0 {
                break  // Device disappeared (USB unplugged).
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return Data()
    }

    public func write(_ data: Data) async throws {
        guard !closed else { throw WinlinkError.connectionClosed }
        var remaining = [UInt8](data)
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                remaining.removeFirst(count)
                continue
            }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw WinlinkError.remoteError(
                    "Serial write failed: \(String(cString: strerror(errno)))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
