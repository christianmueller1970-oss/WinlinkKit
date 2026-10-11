import Foundation

/// Fertige Entwürfe für Winlink-Katalogabfragen und Saildocs-Anfragen.
/// Beides sind gewöhnliche B2F-Nachrichten an Spezialadressen — die
/// Antwort kommt als normale Mail mit dem angeforderten Inhalt zurück.
public enum CatalogRequest {

    /// CMS-interne Adresse für Katalogabfragen.
    public static let inquiryAddress = "INQUIRY"

    /// Saildocs-Dienst: liefert Webseiten als Text und GRIB-Wetterdaten
    /// auf Anfrage per Mail (seit 1995, von Jim Corenman).
    public static let saildocsAddress = "query@saildocs.com"

    /// Katalog-Item mit der Hilfedatei zum Winlink-Katalog.
    public static let helpItem = "WL2K_HELP"

    /// Abfrage von Katalog-Items beim CMS: Message an INQUIRY, Subject
    /// `REQUEST`, ein Item-Name pro Zeile im Body.
    public static func winlinkInquiry(items: [String]) -> MessageDraft {
        MessageDraft(
            to: [inquiryAddress],
            subject: "REQUEST",
            body: items.joined(separator: "\n"))
    }

    /// Saildocs-Abruf beliebiger Web-Dokumente als Text: eine
    /// `send <URL>`-Zeile pro Dokument. Saildocs ignoriert das Subject;
    /// B2F verlangt aber eines.
    public static func saildocsFetch(urls: [String]) -> MessageDraft {
        MessageDraft(
            to: [saildocsAddress],
            subject: "Saildocs request",
            body: urls.map { "send \($0)" }.joined(separator: "\n"))
    }

    /// Saildocs-GRIB-Anfrage mit roher Spezifikation, z. B.
    /// `GFS:50N,42N,5W,20E|0.5,0.5|0,24,48,72|PRMSL,WIND`.
    public static func saildocsGRIB(_ spec: String) -> MessageDraft {
        MessageDraft(
            to: [saildocsAddress],
            subject: "Saildocs request",
            body: "send \(spec)")
    }
}

extension CatalogRequest {

    /// Eine Saildocs-GRIB-Anfrage aus Einzelteilen, damit eine Oberfläche
    /// Gebiet, Auflösung, Zeitpunkte und Parameter abfragen kann, ohne
    /// die Spezifikation `GFS:50N,42N,5W,20E|0.5,0.5|0,24,48|PRMSL,WIND`
    /// von Hand zu tippen. Gebiet in Dezimalgrad, Nord/Ost positiv.
    public struct GRIBSpec: Equatable, Sendable {
        /// Wettermodelle, die Saildocs als GRIB liefert.
        public enum Model: String, CaseIterable, Sendable {
            case gfs = "GFS"
            case ecmwf = "ECMWF"
            case icon = "ICON"
            case coamps = "COAMPS"
            case nam = "NAM"
            case ww3 = "WW3"
        }

        public var model: Model
        public var north: Double
        public var south: Double
        public var west: Double
        public var east: Double
        /// Gitterabstand in Grad, für Breite und Länge gleich.
        public var resolution: Double
        /// Vorhersage-Stunden ab Modelllauf, z. B. `[0, 24, 48, 72]`.
        public var hours: [Int]
        /// Saildocs-Parameternamen, z. B. `PRMSL`, `WIND`, `GUST`, `RAIN`.
        public var parameters: [String]

        public static let commonParameters = ["PRMSL", "WIND", "GUST", "RAIN", "TMP", "WAVES"]
        public static let resolutions: [Double] = [0.25, 0.5, 1, 2]

        public init(
            model: Model = .gfs, north: Double, south: Double, west: Double, east: Double,
            resolution: Double = 0.5, hours: [Int] = [0, 24, 48, 72],
            parameters: [String] = ["PRMSL", "WIND"]
        ) {
            self.model = model
            self.north = north
            self.south = south
            self.west = west
            self.east = east
            self.resolution = resolution
            self.hours = hours
            self.parameters = parameters
        }

        /// Ein Rechteck um einen Punkt: `spanDegrees` nach jeder Seite,
        /// an den Polen und der Datumsgrenze beschnitten.
        public static func around(
            latitude: Double, longitude: Double, spanDegrees: Double = 4, model: Model = .gfs
        ) -> GRIBSpec {
            GRIBSpec(
                model: model,
                north: min(90, latitude + spanDegrees), south: max(-90, latitude - spanDegrees),
                west: max(-180, longitude - spanDegrees), east: min(180, longitude + spanDegrees))
        }

        /// Prüft die Teile; Fehler nennen das Feld (`WinlinkError.validation`).
        public func validate() throws {
            guard north > south, (-90...90).contains(north), (-90...90).contains(south) else {
                throw WinlinkError.validation(field: "area", reason: "north must be above south")
            }
            guard east > west, (-180...180).contains(west), (-180...180).contains(east) else {
                throw WinlinkError.validation(field: "area", reason: "east must be right of west")
            }
            guard resolution.isFinite, resolution > 0, resolution <= 10 else {
                throw WinlinkError.validation(
                    field: "resolution", reason: "must be between 0 and 10 degrees")
            }
            for (field, value) in [("north", north), ("south", south), ("west", west), ("east", east)]
            where !value.isFinite {
                throw WinlinkError.validation(field: field, reason: "must be a finite number")
            }
            guard !hours.isEmpty, hours.allSatisfy({ $0 >= 0 }) else {
                throw WinlinkError.validation(field: "hours", reason: "at least one forecast hour")
            }
            guard !parameters.isEmpty, parameters.allSatisfy({ !$0.isEmpty }) else {
                throw WinlinkError.validation(field: "parameters", reason: "at least one parameter")
            }
        }

        /// Die Saildocs-Spezifikation, z. B.
        /// `GFS:51.5N,43.5N,5.3E,13.3E|0.5,0.5|0,24,48,72|PRMSL,WIND`.
        public var spec: String {
            let area = [
                Self.degrees(north, positive: "N", negative: "S"),
                Self.degrees(south, positive: "N", negative: "S"),
                Self.degrees(west, positive: "E", negative: "W"),
                Self.degrees(east, positive: "E", negative: "W"),
            ].joined(separator: ",")
            let grid = "\(Self.number(resolution)),\(Self.number(resolution))"
            let times = hours.sorted().map(String.init).joined(separator: ",")
            let params = parameters.map { $0.uppercased() }.joined(separator: ",")
            return "\(model.rawValue):\(area)|\(grid)|\(times)|\(params)"
        }

        /// `50N`, `47.5N`, `5W`; genau null wird Nord bzw. Ost.
        static func degrees(_ value: Double, positive: String, negative: String) -> String {
            number(abs(value)) + (value < 0 ? negative : positive)
        }

        /// Ganze Zahlen ohne Nachkommastellen, sonst bis zu zwei. Nie
        /// ein Trap: was nicht in ein Int passt, bleibt Gleitkomma-Text.
        static func number(_ value: Double) -> String {
            if let whole = Int(exactly: value) {
                return String(whole)
            }
            var text = String(format: "%.2f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
    }

    /// Saildocs-GRIB-Anfrage aus einer `GRIBSpec`.
    public static func saildocsGRIB(_ spec: GRIBSpec) -> MessageDraft {
        saildocsGRIB(spec.spec)
    }
}
