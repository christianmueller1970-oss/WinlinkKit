import Foundation
import Testing

@testable import WinlinkKit

/// A fresh mailbox rooted in a unique temp directory.
private func makeMailbox() -> (DirectoryMailbox, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirectoryMailboxTests-\(UUID().uuidString)", isDirectory: true)
    return (DirectoryMailbox(root: root), root)
}

private func makeMessage(subject: String = "Test") -> B2Message {
    var message = B2Message(mycall: "HB9ABC")
    message.addTo("HB9HJI")
    message.setSubject(subject)
    message.setBody("Hallo\n")
    return message
}

@Suite struct DirectoryMailboxTests {

    /// A received message is rejected when proposed again — even after
    /// a client filed it into a subdirectory of `in/` or into `trash/`.
    @Test func inboundAnswerRejectsMovedDuplicates() async throws {
        let (mailbox, root) = makeMailbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let message = makeMessage()
        try await mailbox.prepare()
        try await mailbox.processInbound(message)

        let proposal = Proposal(
            mid: message.mid, title: message.subject, data: try message.bytes())
        #expect(await mailbox.inboundAnswer(for: proposal) == .reject)

        // Moved into a nested subfolder below in/: still a duplicate.
        let subfolder = root.appendingPathComponent("in/QSL/2026", isDirectory: true)
        try FileManager.default.createDirectory(
            at: subfolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("in/\(message.mid).b2f"),
            to: subfolder.appendingPathComponent("\(message.mid).b2f"))
        #expect(await mailbox.inboundAnswer(for: proposal) == .reject)

        // Moved to trash/: still a duplicate.
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: subfolder.appendingPathComponent("\(message.mid).b2f"),
            to: trash.appendingPathComponent("\(message.mid).b2f"))
        #expect(await mailbox.inboundAnswer(for: proposal) == .reject)

        // Gone entirely: accepted again.
        try FileManager.default.removeItem(
            at: trash.appendingPathComponent("\(message.mid).b2f"))
        #expect(await mailbox.inboundAnswer(for: proposal) == .accept)
    }

    /// A copy in out/ or sent/ must NOT count as received — a message
    /// sent to oneself is still delivered inbound.
    @Test func inboundAnswerIgnoresOutboundCopies() async throws {
        let (mailbox, root) = makeMailbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let message = makeMessage()
        try await mailbox.addOutbound(message)

        let proposal = Proposal(
            mid: message.mid, title: message.subject, data: try message.bytes())
        #expect(await mailbox.inboundAnswer(for: proposal) == .accept)

        await mailbox.markSent(message.mid, rejected: false)
        #expect(await mailbox.inboundAnswer(for: proposal) == .accept)
    }
}
