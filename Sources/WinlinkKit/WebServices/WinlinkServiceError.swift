import Foundation

/// Typed errors for the Winlink web services (HTTP), kept apart from
/// `WinlinkError`, which covers the B2F protocol path. Nothing here ever
/// carries the access key — the values are meant for the UI.
public enum WinlinkServiceError: Error, Sendable, Equatable {
    /// No web-service access key was compiled in or configured.
    case missingAPIKey
    /// The grid square is not a well-formed Maidenhead locator.
    case invalidGridSquare(String)
    /// The service answered with a non-2xx status.
    case httpStatus(Int)
    /// The service answered 200 but set `ResponseStatus.ErrorCode`.
    case serviceError(code: String, message: String)
    /// The payload did not decode into the expected shape.
    case malformedResponse(String)
    /// The request never reached the service (offline, DNS, TLS, timeout).
    case transport(String)
    /// Our own rate limit refused the call. Winlink asks that these
    /// endpoints be queried sparingly, so the brake sits in the client.
    case throttled(retryAfter: Duration)
}

extension WinlinkServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey:
            "No Winlink web-service access key configured"
        case .invalidGridSquare(let locator):
            "Not a Maidenhead locator: \(locator)"
        case .httpStatus(let status):
            "Winlink web service answered HTTP \(status)"
        case .serviceError(let code, let message):
            "Winlink web service reported \(code): \(message)"
        case .malformedResponse(let reason):
            "Unexpected answer from the Winlink web service: \(reason)"
        case .transport(let reason):
            "Could not reach the Winlink web service: \(reason)"
        case .throttled(let retryAfter):
            "Rate limited, retry in \(retryAfter)"
        }
    }

    /// True when the service rejected our credentials or told us to slow
    /// down. The client must then stop refreshing automatically instead
    /// of hammering on — a revoked token affects every Skywave user.
    public var isAccessDenied: Bool {
        switch self {
        case .httpStatus(let status):
            return status == 401 || status == 403 || status == 429
        case .missingAPIKey:
            return true
        case .serviceError(let code, _):
            // The service rejects a bad key as HTTP 400 with
            // ErrorCode "InvalidAccessKey" — observed, not documented.
            let code = code.lowercased()
            return code.contains("accesskey") || code.contains("unauthorized")
                || code.contains("forbidden")
        default:
            return false
        }
    }
}
