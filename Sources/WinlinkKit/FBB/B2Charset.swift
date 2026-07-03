// Ported from wl2k-go/fbb/header.go and message_body.go (charset handling).
//
// Deviation from Go: instead of the go-charset library we map the few
// charsets seen in the Winlink system onto Foundation's String.Encoding.
import Foundation

enum B2Charset {
    /// The default body charset seems to be ISO-8859-1.
    ///
    /// The Winlink Message Structure docs says that the body should
    /// be ASCII-only, but RMS Express seems to encode the body as
    /// ISO-8859-1. This is also the charset set (Content-Type header)
    /// when a message reaches an SMTP server.
    static let defaultCharset = "ISO-8859-1"

    /// Mails going out over SMTP from the Winlink system are sent with
    /// 'Content-Transfer-Encoding: 7bit', but let's be reasonable...
    /// we don't send ASCII-only bodies.
    static let defaultTransferEncoding = "8bit"

    static func encoding(for name: String) -> String.Encoding {
        switch name.uppercased() {
        case "UTF-8", "UTF8":
            return .utf8
        case "US-ASCII", "ASCII":
            return .ascii
        case "WINDOWS-1252", "CP1252":
            return .windowsCP1252
        default:
            // ISO-8859-1 and anything unknown: Latin-1 decodes any
            // byte sequence, so it is the safe fallback.
            return .isoLatin1
        }
    }

    /// Encodes a string in the given charset, replacing unmappable
    /// characters (lossy, like go-charset's translator).
    static func encode(_ string: String, charset: String = defaultCharset) -> [UInt8] {
        let encoding = encoding(for: charset)
        let data = string.data(using: encoding)
            ?? string.data(using: encoding, allowLossyConversion: true)
            ?? Data()
        return [UInt8](data)
    }

    /// Decodes bytes in the given charset into a String.
    static func decode(_ bytes: [UInt8], charset: String = defaultCharset) -> String {
        String(data: Data(bytes), encoding: encoding(for: charset))
            // Invalid byte sequences (e.g. broken UTF-8): Latin-1 never fails.
            ?? String(data: Data(bytes), encoding: .isoLatin1)
            ?? ""
    }

    /// Extracts the `charset` parameter from a Content-Type header value
    /// (Go: mime.ParseMediaType). Returns nil if absent or unparsable.
    static func charsetParameter(inContentType value: String) -> String? {
        let parts = value.split(separator: ";").dropFirst()
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "charset" else { continue }
            var val = pair[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            return val.isEmpty ? nil : val
        }
        return nil
    }
}
