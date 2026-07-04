// Ported from wl2k-go/fbb/wl2k_test.go, handshake_test.go and proposal_test.go
import Foundation
import Testing

@testable import WinlinkKit

// MARK: - Test doubles

/// An in-memory duplex pipe; the Swift equivalent of Go's net.Pipe(),
/// except that writes are buffered (which conveniently rules out
/// test deadlocks).
actor PipeTransport: WinlinkTransport {
    private var inbox = [Data]()
    private var waiter: CheckedContinuation<Data, Never>?
    private var closed = false
    private var peer: PipeTransport?

    /// Two connected transport ends.
    static func pair() async -> (PipeTransport, PipeTransport) {
        let a = PipeTransport()
        let b = PipeTransport()
        await a.connect(to: b)
        await b.connect(to: a)
        return (a, b)
    }

    private func connect(to peer: PipeTransport) {
        self.peer = peer
    }

    private func deliver(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    private func finishReads() {
        closed = true
        waiter?.resume(returning: Data())
        waiter = nil
    }

    func read() async throws -> Data {
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        if closed {
            return Data() // Remote hung up.
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func write(_ data: Data) async {
        await peer?.deliver(data)
    }

    func close() async {
        await peer?.finishReads()
    }
}

/// Drives the server side of a scripted session (the role the Go tests
/// play inline against net.Pipe).
struct ScriptedServer {
    let transport: PipeTransport
    private let reader: TransportReader

    init(_ transport: PipeTransport) {
        self.transport = transport
        self.reader = TransportReader(transport)
    }

    func send(_ line: String) async {
        await transport.write(Data(line.utf8))
    }

    func readLine() async throws -> String {
        try await reader.readLine()
    }

    func expect(_ lines: String..., sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for expected in lines {
            let got = try await reader.readLine()
            #expect(got == expected, sourceLocation: sourceLocation)
        }
    }
}

/// Simple in-memory mailbox for session tests.
actor MemoryMailbox: MailboxHandler {
    private(set) var outbox: [B2Message] = []
    private(set) var inbox: [B2Message] = []
    private(set) var deferred: [String] = []

    func addOutbound(_ message: B2Message) {
        outbox.append(message)
    }

    func prepare() {}

    func outboundMessages(for forwarders: [Address]) -> [B2Message] {
        guard !forwarders.isEmpty else { return outbox }
        return outbox.filter { m in forwarders.contains(where: m.isOnlyReceiver) }
    }

    func markSent(_ mid: String, rejected: Bool) {
        outbox.removeAll { $0.mid == mid }
    }

    func markDeferred(_ mid: String) {
        deferred.append(mid)
    }

    func processInbound(_ message: B2Message) {
        inbox.append(message)
    }

    func inboundAnswer(for proposal: Proposal) -> ProposalAnswer {
        inbox.contains { $0.mid == proposal.messageID } ? .reject : .accept
    }
}

private let localSIDLine = "[WinlinkKit-\(WinlinkKit.version)-B2FHM$]"

// MARK: - Scripted CMS sessions (Go: wl2k_test.go)

@Suite struct SessionTests {

    /// Go: TestSessionCMS
    @Test func sessionCMS() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        async let result: TrafficStats = {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }()

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send("Foobar should be ignored\r")
        await server.send("Test CMS >\r")

        try await server.expect(
            ";FW: LA5NTA",
            localSIDLine,
            "; LA1B-10 DE LA5NTA (JO39EQ)",
            "FF"
        )

        await server.send("FQ\r")
        await serverEnd.close()

        let stats = try await result
        #expect(stats == TrafficStats())
    }

    /// Go: TestSessionCMSWithMessage — one inbound proposal is deferred
    /// (no mailbox handler), CMS quits right after.
    @Test func sessionCMSWithMessage() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        async let result: TrafficStats = {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }()

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send("Test CMS >\r")

        try await server.expect(
            ";FW: LA5NTA",
            localSIDLine,
            "; LA1B-10 DE LA5NTA (JO39EQ)",
            "FF"
        )

        // One proposal block, then no more proposals + checksum.
        await server.send("FC EM TJKYEIMMHSRB 527 123 0\r")
        await server.send("F> 3b\r")

        try await server.expect("FS =") // Deferred: no mailbox handler.

        // Session turnover: we have nothing to send.
        try await server.expect("FF")

        await server.send("FQ\r")
        await serverEnd.close()

        _ = try await result
    }

    /// Go: TestSessionCMSv4 — CMS v4 sends ;PM and other ;-lines.
    @Test func sessionCMSv4() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        async let result: TrafficStats = {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }()

        await server.send("[WL2K-4.0-B2FWIHJM$]\r")
        await server.send("Test CMS >\r")

        try await server.expect(
            ";FW: LA5NTA",
            localSIDLine,
            "; LA1B-10 DE LA5NTA (JO39EQ)",
            "FF"
        )

        // Some CMS v4 ;-lines, then one proposal.
        await server.send(";PM: LA5NTA TJKYEIMMHSRB 123 martin.h.pedersen@gmail.com\r")
        await server.send(";WARNING: Foo bar baz\r")
        await server.send("FC EM TJKYEIMMHSRB 527 123 0\r")
        await server.send("F> 3b\r")

        try await server.expect("FS =", "FF")

        await server.send(";WARNING: Foo bar baz\r") // One more CMS v4 ;-line
        await server.send("FQ\r")
        await serverEnd.close()

        _ = try await result
    }

    /// A secure login challenge (;PQ) must be answered with a ;PR line.
    @Test func sessionSecureLogin() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        async let result: TrafficStats = {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            session.secureLoginPassword = "foobar"
            return try await session.exchange(over: clientEnd)
        }()

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send(";PQ: 23753528\r")
        await server.send("Test CMS >\r")

        let expectedResponse = SecureLogin.response(challenge: "23753528", password: "foobar")
        try await server.expect(
            ";FW: LA5NTA",
            localSIDLine,
            ";PR: \(expectedResponse)",
            "; LA1B-10 DE LA5NTA (JO39EQ)",
            "FF"
        )

        await server.send("FQ\r")
        await serverEnd.close()

        _ = try await result
    }

    /// A challenge without a configured password must abort the session.
    @Test func sessionSecureLoginWithoutPassword() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        let result = Task {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send(";PQ: 23753528\r")
        await server.send("Test CMS >\r")

        await #expect(throws: WinlinkError.self) {
            _ = try await result.value
        }
    }

    /// The remote must announce B2F support, otherwise we abort.
    @Test func sessionRequiresB2F() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        let result = Task {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }

        await server.send("[WL2K-2.8.4.8-B1FWIHJM$]\r") // B1, not B2
        await server.send("Test CMS >\r")

        await #expect(throws: WinlinkError.unsupportedRemoteSID("B1FWIHJM$")) {
            _ = try await result.value
        }
    }

    /// A checksum mismatch on the proposal block must abort the session.
    @Test func sessionBadProposalChecksum() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        let result = Task {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send("Test CMS >\r")
        try await server.expect(";FW: LA5NTA", localSIDLine, "; LA1B-10 DE LA5NTA (JO39EQ)", "FF")

        await server.send("FC EM TJKYEIMMHSRB 527 123 0\r")
        await server.send("F> FF\r") // Wrong checksum (correct would be 3B)

        await #expect(throws: WinlinkError.invalidChecksum) {
            _ = try await result.value
        }
    }

    /// A connection dropped mid-session must surface as connectionClosed.
    @Test func sessionConnectionLost() async throws {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        let server = ScriptedServer(serverEnd)

        let result = Task {
            let session = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ")
            return try await session.exchange(over: clientEnd)
        }

        await server.send("[WL2K-2.8.4.8-B2FWIHJM$]\r")
        await server.send("Test CMS >\r")
        try await server.expect(";FW: LA5NTA", localSIDLine, "; LA1B-10 DE LA5NTA (JO39EQ)", "FF")

        // Hang up in the middle of the exchange.
        await serverEnd.close()

        await #expect(throws: WinlinkError.connectionClosed) {
            _ = try await result.value
        }
    }

    // MARK: P2P sessions (Go: TestSessionP2P)

    /// Go: TestSessionP2P — two empty stations exchange FF/FQ.
    @Test func sessionP2P() async throws {
        let (clientEnd, masterEnd) = await PipeTransport.pair()

        async let clientStats: TrafficStats = {
            let s = B2FSession(mycall: "LA5NTA", targetcall: "N0CALL", locator: "JO39EQ")
            return try await s.exchange(over: clientEnd)
        }()
        async let masterStats: TrafficStats = {
            let s = B2FSession(mycall: "N0CALL", targetcall: "LA5NTA", locator: "JO39EQ")
            s.isMaster = true
            return try await s.exchange(over: masterEnd)
        }()

        _ = try await (clientStats, masterStats)
    }

    /// Full happy path: the client sends one message to the master,
    /// including binary transfer, and both mailboxes agree afterwards.
    @Test func sessionP2PMessageTransfer() async throws {
        let (clientEnd, masterEnd) = await PipeTransport.pair()

        let clientBox = MemoryMailbox()
        let masterBox = MemoryMailbox()

        var message = B2Message(mycall: "LA5NTA")
        message.addTo("N0CALL")
        message.setSubject("Grüezi from JO39EQ") // Umlaut exercises Q-encoding
        message.setBody("Hello, world!\nMit Umlauten: äöü.\n")
        let mid = message.mid
        await clientBox.addOutbound(message)

        async let clientStats: TrafficStats = {
            let s = B2FSession(
                mycall: "LA5NTA", targetcall: "N0CALL", locator: "JO39EQ", mailbox: clientBox)
            return try await s.exchange(over: clientEnd)
        }()
        async let masterStats: TrafficStats = {
            let s = B2FSession(
                mycall: "N0CALL", targetcall: "LA5NTA", locator: "JO39EQ", mailbox: masterBox)
            s.isMaster = true
            return try await s.exchange(over: masterEnd)
        }()

        let (client, master) = try await (clientStats, masterStats)

        #expect(client.sent == [mid])
        #expect(client.received.isEmpty)
        #expect(master.received == [mid])
        #expect(master.sent.isEmpty)

        let received = await masterBox.inbox
        try #require(received.count == 1)
        #expect(received[0].mid == mid)
        #expect(received[0].subject == "Grüezi from JO39EQ")
        #expect(received[0].bodyText == "Hello, world!\r\nMit Umlauten: äöü.\r\n")

        // The client's outbox is drained.
        let remaining = await clientBox.outbox
        #expect(remaining.isEmpty)
    }

    /// A message the master already has is rejected and *not* transferred,
    /// but still counts as sent (the remote confirmed having it).
    @Test func sessionP2PRejectedMessage() async throws {
        let (clientEnd, masterEnd) = await PipeTransport.pair()

        let clientBox = MemoryMailbox()
        let masterBox = MemoryMailbox()

        var message = B2Message(mycall: "LA5NTA")
        message.addTo("N0CALL")
        message.setSubject("Twice")
        message.setBody("Same message again\n")
        await clientBox.addOutbound(message)
        await masterBox.processInbound(message) // Master already has it.

        async let clientStats: TrafficStats = {
            let s = B2FSession(
                mycall: "LA5NTA", targetcall: "N0CALL", locator: "JO39EQ", mailbox: clientBox)
            return try await s.exchange(over: clientEnd)
        }()
        async let masterStats: TrafficStats = {
            let s = B2FSession(
                mycall: "N0CALL", targetcall: "LA5NTA", locator: "JO39EQ", mailbox: masterBox)
            s.isMaster = true
            return try await s.exchange(over: masterEnd)
        }()

        let (client, master) = try await (clientStats, masterStats)

        // Rejected messages are marked sent but not counted in the stats.
        #expect(client.sent.isEmpty)
        #expect(master.received.isEmpty)
        let remaining = await clientBox.outbox
        #expect(remaining.isEmpty)
        let inbox = await masterBox.inbox
        #expect(inbox.count == 1)
    }
}

// MARK: - Parser units (Go: handshake_test.go, proposal_test.go)

@Suite struct HandshakeParserTests {

    /// Go: TestParseFW
    @Test(arguments: [
        (";FW: LA5NTA", ["LA5NTA"]),
        (";FW: LE1OF", ["LE1OF"]),
        (";FW: LE1OF LA5NTA", ["LE1OF", "LA5NTA"]),
        (";FW: la4tta", ["LA4TTA"]),
        (";FW: LA5NTA LE1OF|2384c1ea6103a02b8a5eee5d0e3fbbe3", ["LA5NTA", "LE1OF"]),
    ])
    func parseFW(line: String, expected: [String]) throws {
        let got = try B2FSession.parseFW(line)
        #expect(got.map(\.addr) == expected)
    }

    @Test func parseFWRejectsMalformedLine() {
        #expect(throws: WinlinkError.self) {
            _ = try B2FSession.parseFW("FW: LA5NTA")
        }
    }

    /// Go: TestParsePM
    @Test func parsePM() throws {
        let pm = try PendingMessage(
            parsing: ";PM: LA5NTA FOOBARBAZ 869 SERVICE@winlink.org Your new Winlink Account")
        #expect(pm.mid == "FOOBARBAZ")
        #expect(pm.to == Address(string: "LA5NTA"))
        #expect(pm.from == Address(string: "SERVICE@winlink.org"))
        #expect(pm.subject == "Your new Winlink Account")
        #expect(pm.size == 869)
    }

    /// Go: TestIsLoginFailure
    @Test func isLoginFailure() {
        let line = "*** [1] Secure login failed - account password does not match. - Disconnecting (88.90.2.192)"
        let error = B2FSession.remoteErrorLine(line)
        #expect(error != nil)
        #expect(error?.isLoginFailure == true)

        #expect(B2FSession.remoteErrorLine("FF") == nil)
        #expect(WinlinkError.connectionClosed.isLoginFailure == false)
    }
}

@Suite struct ProposalTests {

    /// Go: TestParseProposal
    @Test func parseProposal() throws {
        let prop = try Proposal(parsing: "FC EM TJKYEIMMHSRB 527 123 0")
        #expect(prop.code == .wl2k)
        #expect(prop.msgType == "EM")
        #expect(prop.messageID == "TJKYEIMMHSRB")
        #expect(prop.offset == 0)
        #expect(prop.uncompressedSize == 527)
        #expect(prop.compressedSize == 123)
    }

    @Test(arguments: [
        "FC XX TJKYEIMMHSRB 527 123 0", // bad message type
        "FC EM TJKYEIMMHSRB 527 123",   // too few parts
        "FC EM TJKYEIMMHSRB 527 123 0 1", // too many parts
        "FX EM TJKYEIMMHSRB 527 123 0", // unknown code
    ])
    func parseProposalRejectsMalformed(line: String) {
        #expect(throws: WinlinkError.self) {
            _ = try Proposal(parsing: line)
        }
    }

    /// The Go test's proposal line sums to checksum 0x3B ("F> 3b").
    @Test func blockChecksum() {
        let checksum = Proposal.blockChecksum(overLines: ["FC EM TJKYEIMMHSRB 527 123 0"])
        #expect(checksum == 0x3B)
    }

    /// Go: parseProposalAnswer (accept/reject/defer and offset requests)
    @Test func applyAnswers() throws {
        var props = [
            try Proposal(parsing: "FC EM AAAAAAAAAAAA 100 50 0"),
            try Proposal(parsing: "FC EM BBBBBBBBBBBB 100 50 0"),
            try Proposal(parsing: "FC EM CCCCCCCCCCCC 100 50 0"),
            try Proposal(parsing: "FC EM DDDDDDDDDDDD 100 50 0"),
        ]
        try Proposal.applyAnswers("FS +-=A10", to: &props)
        #expect(props[0].answer == .accept)
        #expect(props[1].answer == .reject)
        #expect(props[2].answer == .defer_)
        #expect(props[3].answer == .accept)
        #expect(props[3].offset == 10)
    }

    @Test func applyAnswersRejectsExcessAnswers() throws {
        var props = [try Proposal(parsing: "FC EM AAAAAAAAAAAA 100 50 0")]
        #expect(throws: WinlinkError.self) {
            try Proposal.applyAnswers("FS ++", to: &props)
        }
    }

    /// Go: TestSortProposals — precedence first, then size.
    @Test func sortProposals() {
        func prop(_ title: String) -> Proposal {
            Proposal(mid: generateMID(callsign: "N0CALL"), title: title, data: Data(title.utf8))
        }
        var props = [
            prop("Just a test"),
            prop("Re://WL2K O/Very important"),
            prop("//WL2K R/Read this sometime, or don't"),
            prop("//WL2K P/ Pretty important"),
            prop("//WL2K Z/The world is on fire!"),
        ]
        Proposal.sort(&props)

        #expect(props[0].title == "//WL2K Z/The world is on fire!") // Flash
        #expect(props[1].title == "Re://WL2K O/Very important") // Immediate
        #expect(props[2].title == "//WL2K P/ Pretty important") // Priority
        // Everything else is Routine and goes by increasing size.
        #expect(props[3].title == "Just a test")
        #expect(props[4].title == "//WL2K R/Read this sometime, or don't")
    }

    /// Proposal roundtrip: message → proposal → compressed → message.
    @Test func proposalRoundtrip() throws {
        var message = B2Message(mycall: "HB9HJI")
        message.addTo("HB9HJI")
        message.setSubject("Roundtrip")
        message.setBody("Test body\n")

        let prop = try message.proposal()
        #expect(prop.messageID == message.mid)
        #expect(prop.dataIsComplete)
        #expect(prop.proposalLine == "FC EM \(message.mid) \(prop.uncompressedSize) \(prop.compressedSize) 0")

        let parsed = try prop.message()
        #expect(parsed.mid == message.mid)
        #expect(parsed.bodyText == "Test body\r\n")
    }
}
