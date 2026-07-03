// Ported from wl2k-go/fbb/header.go (WordDecoder) and Go's mime package
// (QEncoding), reduced to what the Winlink system actually uses.
import Foundation

enum RFC2047 {
    private static let maxEncodedWordLen = 75

    /// Q-encodes a word if needed (Go: mime.QEncoding.Encode).
    ///
    /// The string is first converted to the given charset (Winlink allows
    /// only ASCII in headers, so non-ASCII words are Q-encoded with
    /// ISO-8859-1 as per wl2k-go).
    static func encode(_ string: String, charset: String = B2Charset.defaultCharset) -> String {
        let needsEncoding = string.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7e }
        guard needsEncoding else { return string }

        let bytes = B2Charset.encode(string, charset: charset)
        let prefix = "=?\(charset)?q?"
        let maxContentLen = maxEncodedWordLen - prefix.count - "?=".count

        var words = [String]()
        var content = ""
        for byte in bytes {
            let encoded: String
            switch byte {
            case 0x20: // space
                encoded = "_"
            case 0x21...0x7e where byte != UInt8(ascii: "=")
                && byte != UInt8(ascii: "?")
                && byte != UInt8(ascii: "_"):
                encoded = String(UnicodeScalar(byte))
            default:
                encoded = String(format: "=%02X", byte)
            }
            if content.count + encoded.count > maxContentLen {
                words.append(prefix + content + "?=")
                content = ""
            }
            content += encoded
        }
        words.append(prefix + content + "?=")

        return words.joined(separator: " ")
    }

    /// Decodes MIME headers containing RFC 2047 encoded-words
    /// (Go: fbb.WordDecoder.DecodeHeader).
    ///
    /// If the header contains no encoded-word, the data may be ISO-8859-1
    /// or UTF-8 depending on how CMS decoded it — valid UTF-8 is passed
    /// through, everything else is treated as raw ISO-8859-1 (a work-around
    /// for RMS Express' non-conforming encoding of the Subject header).
    static func decodeHeader(_ header: String) -> String {
        guard header.contains("=?") else {
            // Header values are parsed as Latin-1, so this recovers the raw bytes.
            let bytes = B2Charset.encode(header, charset: "ISO-8859-1")
            if let utf8 = String(bytes: bytes, encoding: .utf8) {
                return utf8
            }
            return header
        }

        // General RFC 2047 decoding: replace each encoded-word, dropping
        // whitespace between adjacent encoded words.
        let pattern = /=\?([^?]+)\?([qQbB])\?([^?]*)\?=/
        var result = ""
        var lastEnd = header.startIndex
        var lastWasEncodedWord = false

        for match in header.matches(of: pattern) {
            let between = String(header[lastEnd..<match.range.lowerBound])
            let betweenIsSpace = !between.isEmpty
                && between.allSatisfy { $0 == " " || $0 == "\t" }
            if !(lastWasEncodedWord && betweenIsSpace) {
                result += between
            }

            result += decodeWord(
                charset: String(match.1),
                encoding: Character(String(match.2).uppercased()),
                content: String(match.3)
            )
            lastEnd = match.range.upperBound
            lastWasEncodedWord = true
        }
        result += String(header[lastEnd...])
        return result
    }

    private static func decodeWord(charset: String, encoding: Character, content: String) -> String {
        var bytes = [UInt8]()
        switch encoding {
        case "B":
            guard let data = Data(base64Encoded: content) else { return content }
            bytes = [UInt8](data)
        default: // "Q"
            var iterator = content.unicodeScalars.makeIterator()
            while let scalar = iterator.next() {
                switch scalar {
                case "_":
                    bytes.append(0x20)
                case "=":
                    guard let hi = iterator.next(), let lo = iterator.next(),
                          let value = UInt8("\(hi)\(lo)", radix: 16) else { return content }
                    bytes.append(value)
                default:
                    bytes.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        return B2Charset.decode(bytes, charset: charset)
    }
}
