// Ported from wl2k-go/transport/ardop/command.go and ardop.go — MIT, © 2015 Martin Hebnes Pedersen (LA5NTA)
import Foundation

/// The state of an ARDOP TNC (Go: ardop.State).
public enum ArdopState: Sendable, Equatable {
    case unknown
    /// Sound card disabled and all sound card resources are released.
    case offline
    /// The session is disconnected, the sound card remains active.
    case disconnected
    /// Information Sending Station (sending data).
    case iss
    /// Information Receiving Station (receiving data).
    case irs
    case idle
    case fecSend
    /// Receiving FEC (unproto) data.
    case fecReceive

    /// Parses a TNC state name, case-insensitive.
    ///
    /// Note: Go's strToState upper-cases the input but keeps the
    /// mixed-case map keys "FECRcv"/"FECSend", so those two never match
    /// there — an upstream bug we don't reproduce.
    init(parsing str: String) {
        switch str.uppercased() {
        case "OFFLINE": self = .offline
        case "DISC": self = .disconnected
        case "ISS": self = .iss
        case "IRS": self = .irs
        case "IDLE": self = .idle
        case "FECSEND": self = .fecSend
        case "FECRCV": self = .fecReceive
        default: self = .unknown
        }
    }
}

/// An ARDOP ARQ bandwidth (Go: ardop.Bandwidth).
public struct ArdopBandwidth: Sendable, Equatable, CustomStringConvertible {
    /// Valid maximum bandwidths in Hz (Go: Bandwidths()).
    public static let supportedMax = [200, 500, 1000, 2000]

    /// Maximum bandwidth to use, in Hz.
    public var max: Int
    /// Force use of the maximum bandwidth instead of negotiating down.
    public var forced: Bool

    /// Creates a bandwidth; returns nil for unsupported values.
    public init?(max: Int, forced: Bool = false) {
        guard Self.supportedMax.contains(max) else { return nil }
        self.max = max
        self.forced = forced
    }

    /// Parses an ARQ bandwidth string such as "500", "500MAX" or
    /// "2000FORCED" (Go: BandwidthFromString). The MAX/FORCED suffix
    /// may be omitted and defaults to MAX.
    public init?(parsing str: String) {
        var digits = str.uppercased()
        var forced = false
        if digits.hasSuffix("FORCED") {
            forced = true
            digits.removeLast("FORCED".count)
        } else if digits.hasSuffix("MAX") {
            digits.removeLast("MAX".count)
        }
        guard let max = Int(digits) else { return nil }
        self.init(max: max, forced: forced)
    }

    /// A valid bandwidth parameter for the ARQBW command, e.g. "500MAX".
    public var description: String { "\(max)\(forced ? "FORCED" : "MAX")" }
}

/// A command received from the ARDOP TNC on the control channel
/// (Go: ctrlMsg). Commands are CR-terminated ASCII lines of the form
/// `NAME [value]`; replies to host commands echo the name back,
/// optionally with a "now" marker (e.g. "LISTEN now False").
struct ArdopCommand: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case none
        case bool(Bool)
        case string(String)
        case int(Int)
        case state(ArdopState)
        case list([String])
    }

    /// The command name (first token), upper-cased.
    let name: String
    let value: Value

    init(name: String, value: Value = .none) {
        self.name = name
        self.value = value
    }

    /// Parses one control line (without the trailing CR)
    /// (Go: parseCtrlMsg).
    init(parsing line: String) {
        // Workaround for ARDOPc trailing space in NEWSTATE.
        let line = line.trimmingCharacters(in: .whitespaces)

        let parts = line.split(separator: " ", maxSplits: 1)
        name = parts.first.map { $0.uppercased() } ?? ""
        var rest = parts.count > 1 ? String(parts[1]) : ""

        // Echo-back marker: "MYCALL now HB9HJI" → "HB9HJI".
        if rest.lowercased().hasPrefix("now ") {
            rest.removeFirst("now ".count)
        }

        switch name {
        // bool
        case "CODEC", "PTT", "BUSY", "TWOTONETEST", "CWID", "LISTEN", "AUTOBREAK", "FSKONLY":
            value = .bool(rest.lowercased() == "true")

        // no params (or params we ignore, like INPUTPEAKS)
        case "ABORT", "DISCONNECT", "CLOSE", "DISCONNECTED", "CRCFAULT", "PENDING",
            "CANCELPENDING", "SENDID", "INPUTPEAKS",
            // echo-back only
            "INITIALIZE", "ARQCALL", "PROTOCOLMODE":
            value = .none

        // State
        case "NEWSTATE", "STATE":
            value = .state(ArdopState(parsing: rest))

        // string
        case "FAULT", "MYCALL", "GRIDSQUARE", "CAPTURE", "PLAYBACK", "VERSION",
            "TARGET", "STATUS", "ARQBW":
            value = .string(rest)

        // list (space separated), e.g. "CONNECTED W1ABC 500"
        case "CONNECTED":
            value = .list(rest.split(separator: " ").map(String.init))

        // list (comma separated)
        case "CAPTUREDEVICES", "PLAYBACKDEVICES", "MYAUX":
            value = .list(
                rest.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) })

        // int
        case "DRIVELEVEL", "BUFFER", "ARQTIMEOUT", "FREQUENCY":
            value = .int(Int(rest) ?? 0)

        default:
            value = .none
        }
    }

    var boolValue: Bool? {
        guard case .bool(let b) = value else { return nil }
        return b
    }

    var stringValue: String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    var intValue: Int? {
        guard case .int(let i) = value else { return nil }
        return i
    }

    var stateValue: ArdopState? {
        guard case .state(let s) = value else { return nil }
        return s
    }

    var listValue: [String]? {
        guard case .list(let l) = value else { return nil }
        return l
    }
}
