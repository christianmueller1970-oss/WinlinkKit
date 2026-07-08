// Reply/forward compose helpers. Client behavior (not part of the wl2k-go
// port); conventions follow Pat and other mail clients.
import Foundation

/// Prefilled compose fields for a reply or forward, ready for a UI or CLI
/// to let the user edit and turn into a B2Message on send.
public struct MessageDraft: Equatable, Sendable {
    /// Primary receivers, as address strings (e.g. `HB9HJI`, `SMTP:foo@bar.baz`).
    public var to: [String]
    /// Carbon copy receivers, as address strings.
    public var cc: [String]
    public var subject: String
    public var body: String
    /// Attachments carried over from the original (forward only).
    public var attachments: [B2File]

    public init(
        to: [String] = [],
        cc: [String] = [],
        subject: String = "",
        body: String = "",
        attachments: [B2File] = []
    ) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
}

extension B2Message {
    /// A draft replying to this message.
    ///
    /// The sender becomes the receiver; with `all`, the remaining receivers
    /// are kept as Cc, excluding `mycall` itself. Replying to a message sent
    /// by `mycall` addresses the original receivers instead. The original
    /// body is quoted with `> ` below an attribution line.
    public func replyDraft(mycall: String, all: Bool = false) -> MessageDraft {
        let me = Address(string: mycall)
        let sender = from

        var to: [Address]
        if sender == me, !receivers.isEmpty {
            to = self.to.isEmpty ? cc : self.to
        } else if sender.isZero {
            to = []
        } else {
            to = [sender]
        }
        to = Self.dedup(to)

        var cc = [Address]()
        if all {
            cc = Self.dedup(receivers.filter { $0 != me && !to.contains($0) })
        }

        return MessageDraft(
            to: to.map(\.description),
            cc: cc.map(\.description),
            subject: Self.prefixSubject(subject, with: "Re: ", recognized: ["re:"]),
            body: "\n\n\(attributionLine)\n\(quotedBody)"
        )
    }

    /// A draft forwarding this message: receivers are left for the user to
    /// fill in, the original body follows a forwarded-message header block,
    /// and the original attachments are carried over.
    public func forwardDraft() -> MessageDraft {
        var block = "\n\n----- Forwarded message -----\n"
        block += "From: \(from.description)\n"
        if let date {
            block += "Date: \(B2Date.format(date)) UTC\n"
        }
        if !to.isEmpty {
            block += "To: \(to.map(\.description).joined(separator: ", "))\n"
        }
        block += "Subject: \(subject)\n\n"
        block += normalizedBodyText

        return MessageDraft(
            subject: Self.prefixSubject(subject, with: "Fw: ", recognized: ["fw:", "fwd:"]),
            body: block,
            attachments: files
        )
    }

    /// `On 2016/07/20 18:00 UTC, LA5NTA wrote:` (date omitted if unset).
    private var attributionLine: String {
        if let date {
            return "On \(B2Date.format(date)) UTC, \(from.addr) wrote:"
        }
        return "\(from.addr) wrote:"
    }

    /// The body with every line prefixed by `> `.
    private var quotedBody: String {
        normalizedBodyText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    /// The body text with wire CRLFs normalized to LF and no trailing newline.
    private var normalizedBodyText: String {
        var text = bodyText.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }

    /// Prepends `prefix` unless the subject already starts with one of the
    /// `recognized` prefixes (case-insensitive), so replies to replies don't
    /// stack up as `Re: Re: …`.
    private static func prefixSubject(
        _ subject: String, with prefix: String, recognized: [String]
    ) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if recognized.contains(where: lowered.hasPrefix) {
            return trimmed
        }
        return prefix + trimmed
    }

    /// Removes duplicate addresses, keeping the first occurrence.
    private static func dedup(_ addresses: [Address]) -> [Address] {
        var seen = Set<Address>()
        return addresses.filter { seen.insert($0).inserted }
    }
}
