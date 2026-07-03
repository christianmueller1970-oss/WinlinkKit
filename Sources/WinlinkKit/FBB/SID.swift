// Ported from wl2k-go/fbb/handshake.go (SID handling)
import Foundation

/// A station identification line: `[Name-Version-Features$]`,
/// e.g. `[WL2K-2.8.4.8-B2FWIHJM$]`.
struct SID: Equatable, Sendable {
    /// The feature codes (everything after the last `-`), uppercased.
    let features: String

    // The SID codes (subset we care about; see Go source for the full list).
    static let fbbBasic = "F"   // FBB basic ascii protocol supported
    static let fbbComp2 = "B2"  // FBB compressed protocol v2 (aka B2F) supported
    static let hierarchicalLocation = "H"
    static let messageID = "M"
    static let bid = "$"        // BID supported (must be last character in SID)

    /// Our own feature set, mirrors wl2k-go's localSID: B2 + F + H + M + $.
    static let localFeatures = fbbComp2 + fbbBasic + hierarchicalLocation + messageID + bid

    /// The SID line we announce, without the trailing CR.
    static func localLine(name: String = "WinlinkKit", version: String = WinlinkKit.version) -> String {
        "[\(name)-\(version)-\(localFeatures)]"
    }

    /// True if the line looks like a SID (used to dispatch handshake lines).
    static func isSIDLine(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]")
    }

    /// Parses a SID line. The greedy `.*` before the `-` means the features
    /// are whatever follows the *last* hyphen — same as Go's `\[.*-(.*)\]`.
    init(parsing line: String) throws {
        guard let match = line.firstMatch(of: /\[.*-(.*)\]/) else {
            throw WinlinkError.malformedInput("Bad SID line: \(line)")
        }
        self.features = String(match.1).uppercased()
    }

    /// True if the remote announced the given feature code.
    func has(_ code: String) -> Bool {
        features.contains(code.uppercased())
    }

    /// We require the FBB compressed protocol v2 (B2F). Aborts the session
    /// with a clear error if the remote does not support it.
    func requireB2F() throws {
        guard has(Self.fbbComp2) else {
            throw WinlinkError.unsupportedRemoteSID(features)
        }
    }
}
