// Ported from wl2k-go/transport/telnet/dial.go
import Foundation

/// Telnet/TCP transport to a Winlink CMS (or any telnet RMS).
///
/// Handles the `Callsign :` / `Password :` login prompts during dialing;
/// once `dial` returns, the connection is ready for the B2F session.
public actor TelnetTransport: WinlinkTransport {
    /// The common CMS telnet gateway host (Go: CMSAddress).
    public static let cmsHost = "server.winlink.org"
    /// The CMS telnet port.
    public static let cmsPort: UInt16 = 8772

    /// Target call for CMS connections (Go: CMSTargetCall).
    public static let cmsTargetCall = "wl2k"

    /// The fixed password of the CMS telnet login — this is not the
    /// user's Winlink account password (Go: CMSPassword).
    public static let cmsPassword = "CMSTelnet"

    private let tcp: TCPTransport

    /// Bytes received during login that belong to the session already.
    private var leftover = Data()

    private init(tcp: TCPTransport) {
        self.tcp = tcp
    }

    // MARK: - Dialing

    /// Dials a random CMS through server.winlink.org, retrying up to
    /// 4 times in case an unavailable CMS is hit (Go: DialCMS).
    ///
    /// Production CMS only accepts registered client types (SID names);
    /// pass `host: "cms-z.winlink.org"` to use the test server.
    public static func dialCMS(
        mycall: String, host: String = cmsHost, port: UInt16 = cmsPort,
        timeout: TimeInterval = 30
    ) async throws -> TelnetTransport {
        var lastError: any Error = WinlinkError.connectionClosed
        for _ in 0..<4 {
            do {
                return try await dial(
                    host: host, port: port,
                    mycall: mycall, password: cmsPassword, timeout: timeout)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Dials a telnet RMS and performs the prompt login (Go: DialContext).
    public static func dial(
        host: String, port: UInt16, mycall: String, password: String,
        timeout: TimeInterval = 30
    ) async throws -> TelnetTransport {
        let tcp = try await TCPTransport.connect(host: host, port: port, timeout: timeout)

        let transport = TelnetTransport(tcp: tcp)
        do {
            try await transport.login(mycall: mycall, password: password)
        } catch {
            await transport.close()
            throw error
        }
        return transport
    }

    /// Answers the CR-terminated `Callsign :` / `Password :` prompts.
    /// Bytes following the password prompt already belong to the session
    /// and are kept for the first `read()`.
    private func login(mycall: String, password: String) async throws {
        var buffer = [UInt8]()

        while true {
            while let idx = buffer.firstIndex(of: FBBControl.cr) {
                let line = TransportReader.cleanString(
                    B2Charset.decode(Array(buffer[..<idx]))
                ).lowercased()
                buffer.removeSubrange(...idx)

                if line.hasPrefix("callsign") {
                    try await tcp.write(Data("\(mycall)\r".utf8))
                } else if line.hasPrefix("password") {
                    try await tcp.write(Data("\(password)\r".utf8))
                    leftover = Data(buffer)
                    return
                }
                // Anything else (banners etc.) is ignored.
            }

            let chunk = try await tcp.read()
            guard !chunk.isEmpty else {
                throw WinlinkError.connectionClosed
            }
            buffer.append(contentsOf: chunk)
        }
    }

    // MARK: - WinlinkTransport

    public func read() async throws -> Data {
        if !leftover.isEmpty {
            defer { leftover = Data() }
            return leftover
        }
        return try await tcp.read()
    }

    public func write(_ data: Data) async throws {
        try await tcp.write(data)
    }

    public func close() async {
        await tcp.close()
    }
}
