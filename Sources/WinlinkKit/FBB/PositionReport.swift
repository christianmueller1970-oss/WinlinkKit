// Ported from wl2k-go/catalog/position_report.go
import Foundation

/// A Winlink position report — a message of type «Position Report» to
/// the CMS address `QTH`, shown on winlink.org/userPositions
/// (Go: catalog.PosReport).
///
/// The body is a handful of `KEY: value` lines. Coordinates go out in
/// degrees and decimal minutes with a hemisphere letter (`47-30.0000N`),
/// the way Winlink Express and Pat send them.
public struct PositionReport: Equatable, Sendable {
    /// Time of the fix (UTC in the message).
    public var date: Date
    /// Decimal degrees; both or neither are written.
    public var latitude: Double?
    public var longitude: Double?
    /// Unit not specified in the Winlink docs (Go: same remark).
    public var speed: Double?
    public var course: Course?
    /// Up to 80 characters; longer comments are cut.
    public var comment: String

    public static let commentLimit = 80

    public init(
        date: Date = Date(), latitude: Double? = nil, longitude: Double? = nil,
        speed: Double? = nil, course: Course? = nil, comment: String = ""
    ) {
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.course = course
        self.comment = comment
    }

    /// A heading in whole degrees, true or magnetic (Go: Course).
    public struct Course: Equatable, Sendable {
        public let degrees: Int
        public let magnetic: Bool

        /// 0…360; 360 wraps to 0. Anything else is nil (Go: NewCourse error).
        public init?(degrees: Int, magnetic: Bool = false) {
            guard (0...360).contains(degrees) else { return nil }
            self.degrees = degrees == 360 ? 0 : degrees
            self.magnetic = magnetic
        }

        /// `045T` / `045M`. Go pads with spaces (`%3d`); Pat, which is
        /// what the CMS actually sees in the field, zero-pads — we do
        /// the same.
        public var formatted: String {
            String(format: "%03d", degrees) + (magnetic ? "M" : "T")
        }
    }

    /// The message body, lines CRLF-terminated (Go: Message's buffer).
    public var body: String {
        var text = "DATE: \(B2Date.format(date))\r\n"
        if let latitude, let longitude {
            text += "LATITUDE: \(Self.degreesMinutes(latitude, latitude: true))\r\n"
            text += "LONGITUDE: \(Self.degreesMinutes(longitude, latitude: false))\r\n"
        }
        if let speed {
            text += "SPEED: \(String(format: "%f", speed))\r\n"
        }
        if let course {
            text += "COURSE: \(course.formatted)\r\n"
        }
        let trimmedComment = String(comment.prefix(Self.commentLimit))
        if !trimmedComment.isEmpty {
            text += "COMMENT: \(trimmedComment)\r\n"
        }
        return text
    }

    /// The ready-to-queue message: type Position Report, subject
    /// `POSITION REPORT`, to `QTH` (Go: PosReport.Message).
    public func message(mycall: String) -> B2Message {
        var message = B2Message(type: .positionReport, mycall: mycall, date: date)
        // setBody splits on "\n" Characters; in a Swift String "\r\n" is
        // one grapheme and would not split, leaving the CRLFs inside a
        // single line plus one more at the end. Hand over LF text and
        // let setBody write the wire CRLFs.
        message.setBody(body.replacingOccurrences(of: "\r\n", with: "\n"))
        message.setSubject("POSITION REPORT")
        message.addTo("QTH")
        return message
    }

    /// `23-42.3000N`: whole degrees, decimal minutes, hemisphere; a
    /// space instead of a letter for exactly zero (Go: decToMinDec).
    static func degreesMinutes(_ decimal: Double, latitude: Bool) -> String {
        let hemisphere: Character
        switch (latitude, decimal.sign, decimal == 0) {
        case (_, _, true): hemisphere = " "
        case (true, .plus, _): hemisphere = "N"
        case (true, .minus, _): hemisphere = "S"
        case (false, .plus, _): hemisphere = "E"
        case (false, .minus, _): hemisphere = "W"
        }
        let degrees = decimal.rounded(.towardZero)
        let minutes = (decimal - degrees) * 60
        let format = latitude ? "%02.0f-%07.4f" : "%03.0f-%07.4f"
        return String(format: format, abs(degrees), abs(minutes)) + String(hemisphere)
    }
}
