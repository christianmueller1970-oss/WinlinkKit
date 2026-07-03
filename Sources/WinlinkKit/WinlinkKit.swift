/// WinlinkKit – a native Swift implementation of the Winlink B2F protocol.
///
/// Core logic is ported from wl2k-go (https://github.com/la5nta/wl2k-go, MIT).
public enum WinlinkKit {
    /// Package version, also used in the SID: `[WinlinkKit-<version>-B2FHM$]`.
    public static let version = "0.1.0"
}

/// Protocol line ending: FBB/B2F uses a bare CR, not CRLF.
let protocolLineEnding: UInt8 = 0x0D // '\r'
