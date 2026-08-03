import Foundation

/// Grobe Übertragungszeit-Schätzung fürs Funkbudget. Die Durchsätze
/// sind konservative Praxiswerte (Netto, inkl. ARQ-Overhead) — die
/// echte Rate hängt von Band, QRN und Distanz ab, darum immer als
/// «~»-Wert anzeigen. Verbindungsaufbau ist nicht eingerechnet.
public enum TransferTimeEstimator {

    public enum Mode: String, CaseIterable, Sendable {
        case ardop500
        case ardop2000
        case varaHF
        case telnet

        public var label: String {
            switch self {
            case .ardop500: return "ARDOP 500"
            case .ardop2000: return "ARDOP 2000"
            case .varaHF: return "VARA HF"
            case .telnet: return "Telnet"
            }
        }

        /// Effektiver Netto-Durchsatz in Bytes pro Sekunde.
        public var bytesPerSecond: Double {
            switch self {
            case .ardop500: return 60
            case .ardop2000: return 220
            case .varaHF: return 400
            case .telnet: return 20_000
            }
        }
    }

    public static func seconds(forBytes bytes: Int, mode: Mode) -> TimeInterval {
        guard bytes > 0 else { return 0 }
        return Double(bytes) / mode.bytesPerSecond
    }

    /// Kompakte Anzeige: «~40 s», «~4 min», «~1.5 h».
    public static func formatted(bytes: Int, mode: Mode) -> String {
        let seconds = seconds(forBytes: bytes, mode: mode)
        switch seconds {
        case ..<60:
            return "~\(max(1, Int(seconds.rounded()))) s"
        case ..<3600:
            return "~\(Int((seconds / 60).rounded())) min"
        default:
            let hours = seconds / 3600
            let rounded = (hours * 10).rounded() / 10
            let text = rounded == rounded.rounded()
                ? String(Int(rounded))
                : String(format: "%.1f", rounded)
            return "~\(text) h"
        }
    }
}
