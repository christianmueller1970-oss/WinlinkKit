import Foundation
import Testing
@testable import WinlinkKit

struct MessageDraftTests {
    /// A message from LA5NTA to HB9HJI (To) and N0CALL, SMTP (Cc).
    private func incoming(subject: String = "Hello") throws -> B2Message {
        var m = B2Message(mycall: "LA5NTA", date: Date(timeIntervalSince1970: 1_469_030_400))
        m.addTo("HB9HJI")
        m.addCc("N0CALL", "foo@bar.baz")
        m.setSubject(subject)
        m.setBody("Line one\nLine two")
        return m
    }

    // MARK: Reply

    @Test func replyAddressesTheSender() throws {
        let draft = try incoming().replyDraft(mycall: "HB9HJI")
        #expect(draft.to == ["LA5NTA"])
        #expect(draft.cc.isEmpty)
        #expect(draft.attachments.isEmpty)
    }

    @Test func replyAllKeepsOtherReceiversAsCcExcludingSelf() throws {
        let draft = try incoming().replyDraft(mycall: "HB9HJI", all: true)
        #expect(draft.to == ["LA5NTA"])
        #expect(draft.cc == ["N0CALL", "SMTP:foo@bar.baz"])
    }

    @Test func replyToOwnMessageAddressesOriginalReceivers() throws {
        let draft = try incoming().replyDraft(mycall: "LA5NTA")
        #expect(draft.to == ["HB9HJI"])
    }

    @Test func replyPrefixesSubjectOnce() throws {
        #expect(try incoming(subject: "Hello").replyDraft(mycall: "HB9HJI").subject == "Re: Hello")
        #expect(try incoming(subject: "Re: Hello").replyDraft(mycall: "HB9HJI").subject == "Re: Hello")
        #expect(try incoming(subject: "RE: Hello").replyDraft(mycall: "HB9HJI").subject == "RE: Hello")
    }

    @Test func replyQuotesBodyBelowAttribution() throws {
        let draft = try incoming().replyDraft(mycall: "HB9HJI")
        #expect(draft.body == """


        On 2016/07/20 16:00 UTC, LA5NTA wrote:
        > Line one
        > Line two
        """)
    }

    @Test func replyToMessageWithoutDateOmitsDateInAttribution() throws {
        var m = try incoming()
        m.header.set(B2Header.date, "")
        let draft = m.replyDraft(mycall: "HB9HJI")
        #expect(draft.body.contains("LA5NTA wrote:"))
        #expect(!draft.body.contains("On "))
    }

    // MARK: Forward

    @Test func forwardLeavesReceiversEmptyAndCarriesAttachments() throws {
        var m = try incoming()
        m.addFile(B2File(name: "pic.jpg", data: Data([1, 2, 3])))
        let draft = m.forwardDraft()
        #expect(draft.to.isEmpty)
        #expect(draft.cc.isEmpty)
        #expect(draft.attachments == [B2File(name: "pic.jpg", data: Data([1, 2, 3]))])
    }

    @Test func forwardPrefixesSubjectOnce() throws {
        #expect(try incoming(subject: "Hello").forwardDraft().subject == "Fw: Hello")
        #expect(try incoming(subject: "Fw: Hello").forwardDraft().subject == "Fw: Hello")
        #expect(try incoming(subject: "Fwd: Hello").forwardDraft().subject == "Fwd: Hello")
    }

    @Test func forwardBodyContainsHeaderBlockAndOriginalBody() throws {
        let draft = try incoming().forwardDraft()
        #expect(draft.body == """


        ----- Forwarded message -----
        From: LA5NTA
        Date: 2016/07/20 16:00 UTC
        To: HB9HJI
        Subject: Hello

        Line one
        Line two
        """)
    }

    // MARK: Round trip

    @Test func replyDraftComposesToValidMessage() throws {
        let draft = try incoming().replyDraft(mycall: "HB9HJI", all: true)
        var m = B2Message(mycall: "HB9HJI")
        for addr in draft.to { m.addTo(addr) }
        for addr in draft.cc { m.addCc(addr) }
        m.setSubject(draft.subject)
        m.setBody("Fine here!" + draft.body)
        try m.validate()
        #expect(m.to == [Address(addr: "LA5NTA")])
        #expect(m.cc == [Address(addr: "N0CALL"), Address(proto: "SMTP", addr: "foo@bar.baz")])
    }
}
