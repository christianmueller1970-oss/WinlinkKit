// Ported from Pat-Vara/vara/vara.go (handleCmd) — MIT, © 2021 Jeremy Bush
import Foundation

/// A command received from the VARA modem on the command channel.
///
/// See "VARA Protocol Native TNC Commands" (PDF in the Pat-Vara repo).
/// Commands are CR-terminated ASCII lines.
enum VaraCommand: Equatable, Sendable {
    case ok
    case wrong
    case iAmAlive
    case pending
    case cancelPending
    case pttOn
    case pttOff
    case busyOn
    case busyOff
    /// `CONNECTED <source> <destination> [<bandwidth>]`
    case connected(source: String, destination: String)
    case disconnected
    /// `BUFFER <bytes>` — bytes queued in the modem's TX buffer.
    case buffer(Int)
    /// `REGISTERED <call>` — full speed available.
    case registered(String)
    case linkRegistered
    case linkUnregistered
    case encryptionDisabled
    case encryptionReady
    case unencryptedLink
    case encryptedLink
    /// `VERSION <version string>`
    case version(String)
    /// Anything we don't (need to) understand.
    case unknown(String)

    /// Parses one command line (without the trailing CR).
    init(parsing line: String) {
        switch line {
        case "OK": self = .ok
        case "WRONG": self = .wrong
        case "IAMALIVE": self = .iAmAlive
        case "PENDING": self = .pending
        case "CANCELPENDING": self = .cancelPending
        case "PTT ON": self = .pttOn
        case "PTT OFF": self = .pttOff
        case "BUSY ON": self = .busyOn
        case "BUSY OFF": self = .busyOff
        case "DISCONNECTED": self = .disconnected
        case "LINK REGISTERED": self = .linkRegistered
        case "LINK UNREGISTERED": self = .linkUnregistered
        case "ENCRYPTION DISABLED": self = .encryptionDisabled
        case "ENCRYPTION READY": self = .encryptionReady
        case "UNENCRYPTED LINK": self = .unencryptedLink
        case "ENCRYPTED LINK": self = .encryptedLink
        default:
            if line.hasPrefix("BUFFER ") {
                self = .buffer(Int(line.dropFirst(7)) ?? 0)
            } else if line.hasPrefix("CONNECTED ") {
                // CONNECTED HB9HJI HB9AK 2300
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    self = .connected(source: String(parts[1]), destination: String(parts[2]))
                } else {
                    self = .unknown(line)
                }
            } else if line.hasPrefix("REGISTERED") {
                let parts = line.split(separator: " ")
                self = .registered(parts.count > 1 ? String(parts[1]) : "")
            } else if line.hasPrefix("VERSION") {
                self = .version(String(line.dropFirst("VERSION".count)).trimmingCharacters(in: .whitespaces))
            } else {
                self = .unknown(line)
            }
        }
    }

    /// True for the answers that terminate a connect attempt.
    var endsDial: Bool {
        switch self {
        case .connected, .disconnected: return true
        default: return false
        }
    }
}
