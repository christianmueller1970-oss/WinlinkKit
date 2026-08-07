import Foundation

/// Derives the modem bandwidth a gateway channel should be dialled with.
///
/// The source is the channel's `Mode` (`GatewayChannelMode`), which
/// states it exactly. The `Baud` field does not: live data from
/// api.winlink.org shows "600" for ARDOP 500 and ARDOP 2000 channels
/// alike, and "0" for others.
public enum GatewayBandwidth {
    /// The bandwidth for a channel, or nil when it cannot be trusted —
    /// and nil means the client leaves the user's setting alone rather
    /// than guess a signal width.
    public static func hertz(mode: GatewayChannelMode?, frequencyHz: Int = 0) -> Int? {
        guard let bandwidth = mode?.bandwidthHz else { return nil }
        if let cap = narrowBandCapHz(frequencyHz) {
            return min(bandwidth, cap)
        }
        return bandwidth
    }

    /// The widest data signal the band plan allows on `frequencyHz`, or
    /// nil where no special limit applies.
    ///
    /// 30 m is the case that matters: the IARU Region 1 band plan makes
    /// it narrow-band only, and the whole band is 50 kHz. Gateways do
    /// announce ARDOP 2000 there — HB9AK on 10'145.9 kHz does — but a
    /// Swiss station should not answer with 2000 Hz. ARDOP negotiates
    /// down, so capping costs throughput, not the connection.
    static func narrowBandCapHz(_ frequencyHz: Int) -> Int? {
        switch frequencyHz {
        case 10_100_000...10_150_000: 500
        default: nil
        }
    }
}
