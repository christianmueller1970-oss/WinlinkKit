// Scripted rigctld dialogs over a pipe transport (no real daemon).
import Foundation
import Testing

@testable import WinlinkKit

/// A scripted rigctld: reads one command line, replies with the next
/// canned response.
private actor FakeRigctld {
    let transport: PipeTransport
    private var buffer = [UInt8]()

    init(_ transport: PipeTransport) {
        self.transport = transport
    }

    /// Awaits one command line from the client.
    func readCommand() async throws -> String {
        while true {
            if let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<idx], as: UTF8.self)
                buffer.removeSubrange(...idx)
                return line
            }
            let chunk = try await transport.read()
            if chunk.isEmpty { throw WinlinkError.connectionClosed }
            buffer.append(contentsOf: chunk)
        }
    }

    func reply(_ line: String) async {
        await transport.write(Data((line + "\n").utf8))
    }
}

@Suite struct RigctldClientTests {
    private func makePair() async -> (RigctldClient, FakeRigctld) {
        let (clientEnd, serverEnd) = await PipeTransport.pair()
        return (RigctldClient(transport: clientEnd), FakeRigctld(serverEnd))
    }

    @Test func setPTTSendsSetPttAndAcceptsRPRT0() async throws {
        let (client, rigctld) = await makePair()

        async let call: Void = client.setPTT(true)
        #expect(try await rigctld.readCommand() == "\\set_ptt 1")
        await rigctld.reply("RPRT 0")
        try await call

        async let off: Void = client.setPTT(false)
        #expect(try await rigctld.readCommand() == "\\set_ptt 0")
        await rigctld.reply("RPRT 0")
        try await off
    }

    @Test func setPTTThrowsOnNonZeroRPRT() async throws {
        let (client, rigctld) = await makePair()

        let call = Task { try await client.setPTT(true) }
        _ = try await rigctld.readCommand()
        await rigctld.reply("RPRT -1")
        await #expect(throws: WinlinkError.self) { try await call.value }
    }

    @Test(arguments: [("0", false), ("1", true), ("2", true), ("3", true)])
    func pttParsesAllHamlibVariants(reply: String, expected: Bool) async throws {
        let (client, rigctld) = await makePair()

        async let call = client.ptt()
        #expect(try await rigctld.readCommand() == "t")
        await rigctld.reply(reply)
        #expect(try await call == expected)
    }

    @Test func frequencyRoundTrip() async throws {
        let (client, rigctld) = await makePair()

        async let get = client.frequency()
        #expect(try await rigctld.readCommand() == "\\get_freq")
        await rigctld.reply("7050000")
        #expect(try await get == 7_050_000)

        async let set: Void = client.setFrequency(10_144_400)
        #expect(try await rigctld.readCommand() == "\\set_freq 10144400")
        await rigctld.reply("RPRT 0")
        try await set
    }

    @Test func malformedFrequencyReplyThrows() async throws {
        let (client, rigctld) = await makePair()

        let get = Task { try await client.frequency() }
        _ = try await rigctld.readCommand()
        await rigctld.reply("Frequency: 7050000")  // extended format we don't speak
        await #expect(throws: WinlinkError.self) { try await get.value }
    }

    @Test func silentDaemonTimesOutInsteadOfHanging() async throws {
        let (client, rigctld) = await makePair()

        let call = Task { try await client.setPTT(true) }
        _ = try await rigctld.readCommand()
        // No reply at all — the client must give up on its own.
        await #expect(throws: WinlinkError.timeout("No reply from rigctld")) {
            try await call.value
        }
    }

    @Test func crlfLineEndingsAreAccepted() async throws {
        let (client, rigctld) = await makePair()

        async let get = client.frequency()
        _ = try await rigctld.readCommand()
        await rigctld.transport.write(Data("7050000\r\n".utf8))
        #expect(try await get == 7_050_000)
    }
}
