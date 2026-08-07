import Foundation

/// A Maidenhead locator resolved to the centre of its cell, with
/// great-circle distance and bearing.
///
/// The web service reports a distance itself, but we still need this:
/// the cached gateway list outlives a locator change (portable, holiday,
/// club event), the built-in fallback list carries only grid squares and
/// no distance at all, and the API rounds to whole statute miles while
/// the UI shows kilometres.
public struct Maidenhead: Sendable, Equatable, CustomStringConvertible {
    /// Mean Earth radius (IUGG), the value Pat's `go-maidenhead` uses too.
    public static let earthRadiusKm = 6371.0

    public let latitude: Double
    public let longitude: Double
    /// The locator as given, upper/lower-cased to the conventional form.
    public let locator: String

    /// Parses a 4-, 6- or 8-character locator (`JN47`, `JN47PN`,
    /// `JN47PN12`). Case does not matter; the conventional spelling is
    /// `JN47pn12`, but rigs and web services send every variant.
    ///
    /// A two-character field alone is not accepted: it spans 20° × 10°,
    /// which is useless for «nearest gateway» and far more likely a typo.
    public init(locator raw: String) throws {
        let characters = Array(
            raw.trimmingCharacters(in: .whitespaces).uppercased().utf8)
        guard let normalized = Self.normalize(characters) else {
            throw WinlinkServiceError.invalidGridSquare(raw)
        }
        self.locator = normalized

        let digits = characters.count
        // Field: 20° of longitude, 10° of latitude, starting at the
        // antimeridian and the south pole.
        var longitude = -180.0 + Double(characters[0] - UInt8(ascii: "A")) * 20
        var latitude = -90.0 + Double(characters[1] - UInt8(ascii: "A")) * 10

        // Square: a tenth of a field. Always present — `normalize`
        // rejects anything shorter than four characters.
        longitude += Double(characters[2] - UInt8(ascii: "0")) * 2
        latitude += Double(characters[3] - UInt8(ascii: "0"))
        var longitudeCell = 2.0
        var latitudeCell = 1.0

        if digits >= 6 {
            // Sub-square: a 24th of a square (5' × 2.5').
            longitude += Double(characters[4] - UInt8(ascii: "A")) * (2.0 / 24)
            latitude += Double(characters[5] - UInt8(ascii: "A")) * (1.0 / 24)
            longitudeCell = 2.0 / 24
            latitudeCell = 1.0 / 24
        }
        if digits >= 8 {
            // Extended square: a tenth of a sub-square.
            longitude += Double(characters[6] - UInt8(ascii: "0")) * (2.0 / 240)
            latitude += Double(characters[7] - UInt8(ascii: "0")) * (1.0 / 240)
            longitudeCell = 2.0 / 240
            latitudeCell = 1.0 / 240
        }

        // Report the centre of the cell, not its south-west corner —
        // otherwise every distance is biased towards the south-west.
        self.longitude = longitude + longitudeCell / 2
        self.latitude = latitude + latitudeCell / 2
    }

    /// Great-circle distance in kilometres (haversine).
    public func distanceKm(to other: Maidenhead) -> Double {
        let φ1 = latitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let Δφ = (other.latitude - latitude) * .pi / 180
        let Δλ = (other.longitude - longitude) * .pi / 180

        let a =
            sin(Δφ / 2) * sin(Δφ / 2)
            + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * Self.earthRadiusKm * asin(min(1, sqrt(a)))
    }

    /// Initial bearing in degrees true, 0…<360.
    public func bearingDegrees(to other: Maidenhead) -> Double {
        let φ1 = latitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let Δλ = (other.longitude - longitude) * .pi / 180

        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Shape check for a text field, without throwing — the settings
    /// locator is typed character by character, so the UI only warns.
    public static func isValid(_ locator: String) -> Bool {
        normalize(Array(locator.trimmingCharacters(in: .whitespaces).uppercased().utf8))
            != nil
    }

    public var description: String { locator }

    /// Validates the character classes and returns the conventional
    /// spelling (`JN47pn12`), or nil if this is not a locator.
    private static func normalize(_ characters: [UInt8]) -> String? {
        guard characters.count == 4 || characters.count == 6 || characters.count == 8
        else { return nil }

        func inRange(_ index: Int, _ lower: UnicodeScalar, _ upper: UnicodeScalar) -> Bool {
            characters[index] >= UInt8(ascii: lower) && characters[index] <= UInt8(ascii: upper)
        }
        // Field A–R (18 × 20° = 360°), square and extended square 0–9,
        // sub-square A–X (24 divisions).
        guard inRange(0, "A", "R"), inRange(1, "A", "R"),
            inRange(2, "0", "9"), inRange(3, "0", "9")
        else { return nil }
        if characters.count >= 6 {
            guard inRange(4, "A", "X"), inRange(5, "A", "X") else { return nil }
        }
        if characters.count >= 8 {
            guard inRange(6, "0", "9"), inRange(7, "0", "9") else { return nil }
        }

        var text = String(decoding: characters, as: UTF8.self)
        if text.count >= 6 {
            let start = text.index(text.startIndex, offsetBy: 4)
            let end = text.index(start, offsetBy: 2)
            text.replaceSubrange(start..<end, with: text[start..<end].lowercased())
        }
        return text
    }
}
