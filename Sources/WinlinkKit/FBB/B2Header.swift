// Ported from wl2k-go/fbb/header.go
import Foundation

/// The key-value pairs in a Winlink 2000 Message header.
///
/// Keys are case-insensitive (stored in canonical MIME form, like Go's
/// textproto). Values keep their insertion order per key; serialization
/// writes Mid first, then the remaining keys in sorted order — the stable
/// order wl2k-go uses to ensure reproducibility.
public struct B2Header: Equatable, Sendable {
    // Common Winlink 2000 Message headers (Go: HEADER_*)
    static let mid = "Mid"
    static let to = "To"
    static let date = "Date"
    static let type = "Type"
    static let from = "From"
    static let cc = "Cc"
    static let subject = "Subject"
    static let mbo = "Mbo"
    static let body = "Body"
    static let file = "File"

    // These headers are stripped by the winlink system, but let's
    // include them anyway... just in case the winlink team one day
    // starts taking encoding seriously.
    static let contentType = "Content-Type"
    static let contentTransferEncoding = "Content-Transfer-Encoding"

    private var storage: [String: [String]] = [:]

    public init() {}

    /// Adds the key, value pair, appending to any existing values.
    public mutating func add(_ key: String, _ value: String) {
        storage[Self.canonicalKey(key), default: []].append(value)
    }

    /// Sets the entries for key to the single value, replacing existing ones.
    public mutating func set(_ key: String, _ value: String) {
        storage[Self.canonicalKey(key)] = [value]
    }

    /// Gets the first value associated with the given key ("" if none).
    public func get(_ key: String) -> String {
        storage[Self.canonicalKey(key)]?.first ?? ""
    }

    /// Gets all values associated with the given key.
    public func all(_ key: String) -> [String] {
        storage[Self.canonicalKey(key)] ?? []
    }

    /// Deletes the values associated with key.
    public mutating func remove(_ key: String) {
        storage[Self.canonicalKey(key)] = nil
    }

    /// Serializes the header in wire format (ISO-8859-1, CR-LF terminated).
    func bytes() throws -> [UInt8] {
        // Mid is required and defined to be the first value.
        let mid = get(Self.mid)
        guard !mid.isEmpty else {
            throw WinlinkError.malformedInput("Missing MID in header")
        }

        var out = B2Charset.encode("Mid: \(mid)\r\n")

        // The rest is printed in a stable order to ensure reproducibility.
        let keys = storage.keys
            .filter { $0.caseInsensitiveCompare(Self.mid) != .orderedSame }
            .sorted()
        for key in keys {
            for value in storage[key] ?? [] {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                out += B2Charset.encode("\(key): \(trimmed)\r\n")
            }
        }
        return out
    }

    /// Canonical MIME header key form (Go: textproto.CanonicalMIMEHeaderKey):
    /// first letter and letters following a hyphen are uppercased, the rest
    /// lowercased. Keys containing invalid characters are left unchanged.
    static func canonicalKey(_ key: String) -> String {
        let tokenExtras = Set("!#$%&'*+-.^_`|~")
        var result = ""
        var upperNext = true
        for char in key {
            guard char.isASCII, char.isLetter || char.isNumber || tokenExtras.contains(char) else {
                return key // not a valid token — leave as-is
            }
            result.append(upperNext ? Character(char.uppercased()) : Character(char.lowercased()))
            upperNext = char == "-"
        }
        return result
    }
}
