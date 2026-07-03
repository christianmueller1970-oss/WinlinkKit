// Ported from wl2k-go/fbb/message.go and message_body.go
import Foundation

/// The message type (Go: MsgType).
public struct MessageType: RawRepresentable, Equatable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let `private` = MessageType(rawValue: "Private")
    public static let service = MessageType(rawValue: "Service")
    public static let inquiry = MessageType(rawValue: "Inquiry")
    public static let positionReport = MessageType(rawValue: "Position Report")
    public static let option = MessageType(rawValue: "Option")
    public static let system = MessageType(rawValue: "System")
}

/// An attachment (Go: File).
public struct B2File: Equatable, Sendable {
    public let name: String
    public let data: Data

    /// A B2F file must have an associated name.
    public init(name: String, data: Data) {
        precondition(!name.isEmpty, "Empty filename is not allowed")
        self.name = name
        self.data = data
    }

    public var size: Int { data.count }

    fileprivate init(unchecked name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// The Winlink 2000 Message Structure as defined in https://winlink.org/B2F.
public struct B2Message: Sendable {
    /// The header names are case-insensitive. Users should normally access
    /// common header fields using the appropriate B2Message properties.
    public var header = B2Header()

    /// Raw body bytes (encoded in `charset`). Use `bodyText` for a String.
    public private(set) var body = [UInt8]()

    /// The message attachments.
    public private(set) var files = [B2File]()

    /// Initializes a new message with Mid, Type, Mbo, From and Date set.
    public init(type: MessageType = .private, mycall: String, date: Date = Date()) {
        header.set(B2Header.mid, generateMID(callsign: mycall, date: date))
        setDate(date)
        setFrom(mycall)
        header.set(B2Header.mbo, mycall)
        header.set(B2Header.type, type.rawValue)
    }

    // MARK: Header accessors

    /// The unique identifier of this message across the winlink system.
    public var mid: String { header.get(B2Header.mid) }

    /// The message type.
    public var type: MessageType { MessageType(rawValue: header.get(B2Header.type)) }

    /// The mailbox operator origin of this message.
    public var mbo: String { header.get(B2Header.mbo) }

    /// The subject, decoded from RFC 2047 encoded-words if necessary.
    public var subject: String { RFC2047.decodeHeader(header.get(B2Header.subject)) }

    /// Sets the subject. The Winlink Message Format only allows ASCII;
    /// words containing non-ASCII characters are Q-encoded (RFC 2047).
    public mutating func setSubject(_ subject: String) {
        header.set(B2Header.subject, RFC2047.encode(subject))
    }

    /// The From header field as an Address.
    public var from: Address { Address(string: header.get(B2Header.from)) }

    /// Sets the From header field (SMTP: prefix added if needed).
    public mutating func setFrom(_ addr: String) {
        header.set(B2Header.from, Address(string: addr).description)
    }

    /// The parsed Date header field (nil if absent or unparsable).
    public var date: Date? { try? B2Date.parse(header.get(B2Header.date)) }

    /// Sets the Date header field in the Winlink format (UTC).
    public mutating func setDate(_ date: Date) {
        header.set(B2Header.date, B2Date.format(date))
    }

    /// Adds primary receivers (one To header field per address).
    public mutating func addTo(_ addresses: String...) {
        for addr in addresses {
            header.add(B2Header.to, Address(string: addr).description)
        }
    }

    /// Adds carbon copy receivers (one Cc header field per address).
    public mutating func addCc(_ addresses: String...) {
        for addr in addresses {
            header.add(B2Header.cc, Address(string: addr).description)
        }
    }

    /// Primary receivers of this message.
    public var to: [Address] { header.all(B2Header.to).map(Address.init(string:)) }

    /// Carbon copy receivers of this message.
    public var cc: [Address] { header.all(B2Header.cc).map(Address.init(string:)) }

    /// All receivers (To and Cc) of this message.
    public var receivers: [Address] { to + cc }

    /// True if the given Address is the only receiver of this message.
    public func isOnlyReceiver(_ addr: Address) -> Bool {
        receivers.count == 1
            && receivers[0].description.caseInsensitiveCompare(addr.description) == .orderedSame
    }

    /// The expected body size (in bytes) as defined in the header.
    public var bodySize: Int { Int(header.get(B2Header.body)) ?? 0 }

    /// The body character encoding from the Content-Type header field
    /// (DefaultCharset if unset).
    public var charset: String {
        B2Charset.charsetParameter(inContentType: header.get(B2Header.contentType))
            ?? B2Charset.defaultCharset
    }

    // MARK: Body

    /// The body decoded to a String using `charset`.
    public var bodyText: String { B2Charset.decode(body, charset: charset) }

    /// Sets the body: lines are CRLF-terminated, wrapped at 1000 characters
    /// and encoded as ISO-8859-1. Content-Type/-Transfer-Encoding are set.
    public mutating func setBody(_ text: String) {
        header.set(B2Header.contentTransferEncoding, B2Charset.defaultTransferEncoding)
        header.set(
            B2Header.contentType,
            "text/plain; charset=\(B2Charset.defaultCharset)"
        )
        body = Self.bodyBytes(from: text)
        header.set(B2Header.body, "\(body.count)")
    }

    /// Converts a body string into wire bytes (Go: StringToBody):
    /// CRLF line breaks are enforced and lines longer than 1000 characters
    /// (including CRLF) are split.
    static func bodyBytes(from text: String, charset: String = B2Charset.defaultCharset) -> [UInt8] {
        var out = [UInt8]()

        // Like Go's bufio.Scanner: split on \n, strip a trailing \r per line,
        // and no empty token after a trailing newline.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }

        for line in lines {
            var bytes = Array((line.hasSuffix("\r") ? line.dropLast() : line).utf8)[...]
            while true {
                // Lines can not be longer than 1000 characters including CRLF.
                let n = min(bytes.count, 1000 - 2)
                out.append(contentsOf: bytes.prefix(n))
                out.append(contentsOf: [0x0D, 0x0A])
                bytes = bytes.dropFirst(n)
                if bytes.isEmpty {
                    break
                }
            }
        }

        return B2Charset.encode(String(decoding: out, as: UTF8.self), charset: charset)
    }

    // MARK: Attachments

    /// Adds the given file as an attachment (adds a File header field;
    /// non-ASCII names are Q-encoded, as only ASCII is allowed per spec).
    public mutating func addFile(_ file: B2File) {
        files.append(file)
        header.add(B2Header.file, "\(file.size) \(RFC2047.encode(file.name))")
    }

    // MARK: Validation

    /// Throws if this message violates any Winlink Message Structure constraints.
    public func validate() throws {
        if mid.isEmpty {
            throw WinlinkError.validation(field: "MID", reason: "Empty MID")
        }
        if mid.count > MaxMIDLength {
            throw WinlinkError.validation(field: "MID", reason: "MID too long")
        }
        if receivers.isEmpty {
            // Not documented, but the CMS refuses such messages (with good reason).
            throw WinlinkError.validation(field: "To/Cc", reason: "No recipient")
        }
        if header.get(B2Header.from).isEmpty {
            throw WinlinkError.validation(field: "From", reason: "Empty From field")
        }
        if bodySize == 0 {
            throw WinlinkError.validation(field: "Body", reason: "Empty body")
        }
        if header.get(B2Header.subject).isEmpty {
            // Not documented, but the CMS writes the proposal title if empty.
            throw WinlinkError.validation(field: "Subject", reason: "Empty subject")
        }
        if header.get(B2Header.subject).count > 128 {
            throw WinlinkError.validation(field: "Subject", reason: "Subject too long")
        }
        for file in files where file.name.count > 255 {
            // B2F amendment of 2020-05-27: file name limit is 255 characters.
            throw WinlinkError.validation(
                field: "Files", reason: "Attachment file name too long: \(file.name)")
        }
    }

    // MARK: Wire format

    /// Parses a message in the Winlink Message format (Go: ReadFrom).
    public init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        var pos = 0

        // Trim leading whitespace before reading the header: received
        // messages have been observed with leading CRLFs.
        let asciiSpace: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]
        while pos < bytes.count, asciiSpace.contains(bytes[pos]) {
            pos += 1
        }

        try Self.parseHeader(bytes, at: &pos, into: &header)

        // Read body
        body = try Self.readSection(bytes, at: &pos, count: bodySize)

        // Read files
        for value in header.all(B2Header.file) {
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                throw WinlinkError.malformedInput("Failed to parse file header. Got: \(value)")
            }
            let size = Int(parts[0]) ?? 0
            // The name may be UTF-8 encoded by Winlink Express — decode defensively.
            let name = RFC2047.decodeHeader(String(parts[1]))
            let data = try Self.readSection(bytes, at: &pos, count: size)
            files.append(B2File(unchecked: name, data: Data(data)))
        }

        // The date field must be parseable.
        _ = try B2Date.parse(header.get(B2Header.date))
    }

    /// Serializes the message in the Winlink Message format (Go: Write/Bytes).
    public func bytes() throws -> Data {
        // Ensure the Date field is in the correct format.
        _ = try B2Date.parse(header.get(B2Header.date))

        var out = try header.bytes()
        out.append(contentsOf: [0x0D, 0x0A]) // end of headers

        out.append(contentsOf: body)
        if !files.isEmpty {
            out.append(contentsOf: [0x0D, 0x0A]) // end of body
        }

        // Files (same order as they appear in the header)
        for file in files {
            out.append(contentsOf: file.data)
            out.append(contentsOf: [0x0D, 0x0A]) // end of file
        }

        return Data(out)
    }

    /// Parses MIME-style header lines until the empty line (Go: textproto).
    private static func parseHeader(_ bytes: [UInt8], at pos: inout Int, into header: inout B2Header) throws {
        var sawTerminator = false
        var lastKey: String?

        while pos < bytes.count {
            // Read one line (up to \n, strip trailing \r).
            var end = pos
            while end < bytes.count, bytes[end] != 0x0A {
                end += 1
            }
            var lineBytes = Array(bytes[pos..<end])
            pos = min(end + 1, bytes.count)
            if lineBytes.last == 0x0D {
                lineBytes.removeLast()
            }

            if lineBytes.isEmpty {
                sawTerminator = true
                break
            }

            let line = B2Charset.decode(lineBytes)

            // Continuation line: append to the previous value.
            if line.first == " " || line.first == "\t" {
                guard let key = lastKey else {
                    throw WinlinkError.malformedInput("Malformed header line: \(line)")
                }
                var values = header.all(key)
                values[values.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                header.remove(key)
                for v in values {
                    header.add(key, v)
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                throw WinlinkError.malformedInput("Malformed header line: \(line)")
            }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            header.add(key, value)
            lastKey = key
        }

        guard sawTerminator else {
            throw WinlinkError.malformedInput("Unexpected end of header")
        }
    }

    /// Reads a section of `count` bytes followed by CRLF or EOF (Go: readSection).
    private static func readSection(_ bytes: [UInt8], at pos: inout Int, count: Int) throws -> [UInt8] {
        guard pos + count <= bytes.count else {
            pos = bytes.count
            throw WinlinkError.malformedInput("Unexpected end of section data")
        }
        let section = Array(bytes[pos..<(pos + count)])
        pos += count

        // Expect CRLF terminator; a bare EOF is also accepted (like Go,
        // which tolerates io.EOF here).
        var end = [UInt8]()
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            end.append(b)
            if b == 0x0A {
                break
            }
        }
        if end.last == 0x0A, end != [0x0D, 0x0A] {
            throw WinlinkError.malformedInput("Unexpected end of section")
        }
        return section
    }
}

// MARK: - Date handling

/// Winlink date parsing/formatting (Go: ParseDate, DateLayout).
enum B2Date {
    /// The date (UTC) format as described in the Winlink Message
    /// Structure docs (YYYY/MM/DD HH:MM).
    static let dateLayout = "yyyy/MM/dd HH:mm"

    /// Layouts tried when parsing the Date header.
    static let parseLayouts: [String] = {
        var layouts = [
            dateLayout,          // The correct layout according to Winlink.
            "yyyy.MM.dd HH:mm",  // RMS Relay-3.0.27.1 store-and-forward mode.
            "yyyy-MM-dd HH:mm",  // Radio Only via RMS Relay-3.0.30.0.
            "yyyyMMddHHmmss",    // Older BPQ format.
        ]
        // RFC 5322 layouts, generated like Go's net/mail.
        for dow in ["", "EEE, "] {
            for day in ["d", "dd"] {
                for year in ["yyyy", "yy"] {
                    for second in [":ss", ""] {
                        for zone in ["ZZZ", "zzz", "ZZZ (zzz)"] {
                            layouts.append("\(dow)\(day) MMM \(year) HH:mm\(second) \(zone)")
                        }
                    }
                }
            }
        }
        return layouts
    }()

    /// Parses a Date header value. Empty strings yield nil (Go: zero time).
    static func parse(_ string: String) throws -> Date? {
        if string.isEmpty {
            return nil
        }
        for layout in parseLayouts {
            if let date = formatter(layout).date(from: string) {
                return date
            }
        }
        throw WinlinkError.malformedInput("Unparsable date: \(string)")
    }

    /// Formats a date in the Winlink format (UTC).
    static func format(_ date: Date) -> String {
        formatter(dateLayout).string(from: date)
    }

    private static func formatter(_ layout: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = layout
        return formatter
    }
}
