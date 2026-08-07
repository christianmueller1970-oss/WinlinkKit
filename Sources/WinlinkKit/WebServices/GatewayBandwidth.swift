import Foundation

/// Translates the web service's free-text `Baud` field into a modem
/// bandwidth in Hz.
///
/// The field is documented as a string and nothing more, so this is
/// deliberately strict: a value that does not land on a bandwidth the
/// modem actually supports yields nil, and nil means the client leaves
/// the user's bandwidth setting alone. Guessing here would put the
/// wrong signal width on the air.
public enum GatewayBandwidth {
    /// The modem bandwidth for `baud`, or nil when it cannot be trusted.
    ///
    /// `frequencyHz` is not optional cosmetics: the 30 m band is only
    /// 50 kHz wide and carries narrow modes by band plan, so a wider
    /// value reported there is capped rather than believed.
    public static func hertz(
        baud: String, mode: GatewayOperatingMode, frequencyHz: Int = 0
    ) -> Int? {
        guard let value = leadingInteger(in: baud) else { return nil }

        let bandwidth: Int?
        switch mode {
        case .ardop:
            bandwidth = ArdopBandwidth.supportedMax.contains(value) ? value : nil
        case .vara, .varaFM:
            bandwidth = VaraModem.bandwidths.contains(String(value)) ? value : nil
        default:
            // Packet reports baud rates (1200/9600), not bandwidths, and
            // Pactor negotiates its own. Nothing to derive.
            bandwidth = nil
        }

        guard let bandwidth else { return nil }
        if let cap = narrowBandCapHz(frequencyHz) {
            return min(bandwidth, cap)
        }
        return bandwidth
    }

    /// The widest signal a band plan allows for data on `frequencyHz`,
    /// or nil where no special limit applies.
    ///
    /// 30 m is the case that matters in practice: the whole band is
    /// 50 kHz, it is secondary allocation, and the Winlink channels
    /// there are 500 Hz. The starter list encodes the same rule.
    static func narrowBandCapHz(_ frequencyHz: Int) -> Int? {
        switch frequencyHz {
        case 10_100_000...10_150_000: 500
        default: nil
        }
    }

    /// The leading run of digits, e.g. "2000" from "2000 Hz".
    private static func leadingInteger(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}
