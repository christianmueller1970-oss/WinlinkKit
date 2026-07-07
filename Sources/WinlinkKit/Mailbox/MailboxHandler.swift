// Ported from wl2k-go/fbb/wl2k.go (MBoxHandler, InboundHandler, OutboundHandler)
import Foundation

/// Handles inbound and outbound messages for a `B2FSession`
/// (Go: MBoxHandler).
///
/// All methods are async so implementations are free to do I/O; the
/// session awaits them at well-defined points of the exchange.
public protocol MailboxHandler: Sendable {
    /// Called before any other operation in a session. Throw to indicate
    /// that the mailbox is not ready; the error is forwarded to the remote.
    func prepare() async throws

    /// Returns all pending outbound messages addressed to (and only to)
    /// one of the given forwarder addresses (Go: GetOutbound).
    ///
    /// An empty forwarder list implies the remote is a Winlink CMS and
    /// all outbound messages can be delivered through it.
    func outboundMessages(for forwarders: [Address]) async -> [B2Message]

    /// Marks the message identified by MID as successfully sent
    /// (Go: SetSent). `rejected` means the remote already had the message.
    func markSent(_ mid: String, rejected: Bool) async

    /// Marks the outbound message identified by MID as deferred — the
    /// remote wants to receive it later (Go: SetDeferred).
    func markDeferred(_ mid: String) async

    /// Persists a received message. Throw if the operation fails; the
    /// error is (if possible) forwarded to the remote (Go: ProcessInbound).
    func processInbound(_ message: B2Message) async throws

    /// Returns the answer (accept/reject/defer) for an inbound proposal.
    /// An already received message (see MID) should be rejected
    /// (Go: GetInboundAnswer).
    func inboundAnswer(for proposal: Proposal) async -> ProposalAnswer
}

/// A simple directory-backed mailbox, mainly for tests and the CLI.
///
/// Layout inside the root directory:
/// - `out/`  — outbound messages as `<MID>.b2f` (Winlink Message format)
/// - `in/`   — received messages, written as `<MID>.b2f`; clients may
///   file them into subdirectories or an optional `trash/` next to it —
///   duplicate detection covers both
/// - `sent/` — outbound messages are moved here once sent
public actor DirectoryMailbox: MailboxHandler {
    private let root: URL
    private let outbox: URL
    private let inbox: URL
    private let sentbox: URL

    public init(root: URL) {
        self.root = root
        self.outbox = root.appendingPathComponent("out", isDirectory: true)
        self.inbox = root.appendingPathComponent("in", isDirectory: true)
        self.sentbox = root.appendingPathComponent("sent", isDirectory: true)
    }

    public func prepare() throws {
        for dir in [outbox, inbox, sentbox] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func outboundMessages(for forwarders: [Address]) -> [B2Message] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outbox, includingPropertiesForKeys: nil)
        else { return [] }

        var messages = [B2Message]()
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "b2f" {
            guard let data = try? Data(contentsOf: url),
                  let message = try? B2Message(parsing: data)
            else { continue }

            // With forwarders given, only offer messages addressed
            // exclusively to one of them (Go: mailbox.GetOutbound).
            if forwarders.isEmpty || forwarders.contains(where: message.isOnlyReceiver) {
                messages.append(message)
            }
        }
        return messages
    }

    public func markSent(_ mid: String, rejected: Bool) {
        let source = outbox.appendingPathComponent("\(mid).b2f")
        let target = sentbox.appendingPathComponent("\(mid).b2f")
        try? FileManager.default.moveItem(at: source, to: target)
    }

    public func markDeferred(_ mid: String) {
        // Deferred messages stay in the outbox for the next session.
    }

    public func processInbound(_ message: B2Message) throws {
        let target = inbox.appendingPathComponent("\(message.mid).b2f")
        try message.bytes().write(to: target)
    }

    public func inboundAnswer(for proposal: Proposal) -> ProposalAnswer {
        // A message counts as "already received" anywhere below `in/`
        // (clients may file messages into subdirectories) and in an
        // optional `trash/` directory next to it. Deliberately NOT
        // `out/`/`sent/`: a message sent to oneself must still be
        // accepted inbound.
        let filename = "\(proposal.messageID).b2f"
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        for dir in [inbox, trash] {
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                return .reject
            }
        }
        return .accept
    }

    /// Adds a message to the outbox (convenience for tests and the CLI).
    public func addOutbound(_ message: B2Message) throws {
        try prepare()
        try message.bytes().write(to: outbox.appendingPathComponent("\(message.mid).b2f"))
    }

    /// All received messages currently in the inbox.
    public func inboundMessages() -> [B2Message] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "b2f" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? B2Message(parsing: data)
            }
    }
}
