// Scripted CI-V dialogs over a pipe transport (no real rig).
import Foundation
import Testing

@testable import WinlinkKit

/// A scripted Icom rig at address 0x98: reads one raw frame, replies
/// with canned bytes.
private actor FakeIcomRig {
    let transport: PipeTransport
    private var buffer = [UInt8]()

    init(_ transport: PipeTransport) {
        self.transport = transport
    }

    /// Awaits one complete frame (incl. preamble and trailing FD).
    func readFrame() async throws -> [UInt8] {
        while true {
            if let end = buffer.firstIndex(of: 0xFD) {
                let frame = Array(buffer[...end])
                buffer.removeSubrange(...end)
                return frame
            }
            let chunk = try await transport.read()
            if chunk.isEmpty { throw WinlinkError.connectionClosed }
            buffer.append(contentsOf: chunk)
        }
    }

    func send(_ bytes: [UInt8]) async {
        await transport.write(Data(bytes))
    }

    /// `FE FE E0 98 <payload> FD` — a reply addressed to the controller.
    func reply(_ payload: [UInt8]) async {
        await send([0xFE, 0xFE, 0xE0, 0x98] + payload + [0xFD])
    }
}

@Suite struct CIVClientTests {
    private func makePair() async -> (CIVClient, FakeIcomRig) {
        let (clientEnd, rigEnd) = await PipeTransport.pair()
        return (CIVClient(transport: clientEnd, radioAddress: 0x98), FakeIcomRig(rigEnd))
    }

    @Test func bcdFrequencyRoundTrip() throws {
        #expect(CIVClient.bcd(frequency: 7_051_500) == [0x00, 0x15, 0x05, 0x07, 0x00])
        #expect(CIVClient.bcd(frequency: 14_109_200) == [0x00, 0x92, 0x10, 0x14, 0x00])
        #expect(try CIVClient.frequency(fromBCD: [0x00, 0x15, 0x05, 0x07, 0x00]) == 7_051_500)
        #expect(try CIVClient.frequency(fromBCD: [0x00, 0x40, 0x60, 0x03, 0x00]) == 3_604_000)
    }

    @Test func invalidBCDThrows() {
        #expect(throws: WinlinkError.self) {
            _ = try CIVClient.frequency(fromBCD: [0x00, 0x0A, 0x00, 0x07, 0x00])
        }
        #expect(throws: WinlinkError.self) {
            _ = try CIVClient.frequency(fromBCD: [0x00, 0x15])
        }
    }

    @Test func readFrequency() async throws {
        let (client, rig) = await makePair()

        async let get = client.frequency()
        #expect(try await rig.readFrame() == [0xFE, 0xFE, 0x98, 0xE0, 0x03, 0xFD])
        await rig.reply([0x03, 0x00, 0x15, 0x05, 0x07, 0x00])
        #expect(try await get == 7_051_500)
    }

    @Test func setFrequencySendsBCDAndAcceptsOK() async throws {
        let (client, rig) = await makePair()

        async let set: Void = client.setFrequency(7_051_500)
        #expect(
            try await rig.readFrame()
                == [0xFE, 0xFE, 0x98, 0xE0, 0x05, 0x00, 0x15, 0x05, 0x07, 0x00, 0xFD])
        await rig.reply([0xFB])
        try await set
    }

    @Test func rejectedCommandThrows() async throws {
        let (client, rig) = await makePair()

        let set = Task { try await client.setFrequency(7_051_500) }
        _ = try await rig.readFrame()
        await rig.reply([0xFA])
        await #expect(throws: WinlinkError.self) { try await set.value }
    }

    @Test func echoAndBroadcastFramesAreSkipped() async throws {
        let (client, rig) = await makePair()

        async let get = client.frequency()
        _ = try await rig.readFrame()
        // CI-V echo back of our own command — from the controller address.
        await rig.send([0xFE, 0xFE, 0x98, 0xE0, 0x03, 0xFD])
        // A transceive broadcast (cmd 00) — addressed to everyone.
        await rig.send([0xFE, 0xFE, 0x00, 0x98, 0x00, 0x00, 0x40, 0x60, 0x03, 0x00, 0xFD])
        // The actual reply.
        await rig.reply([0x03, 0x00, 0x15, 0x05, 0x07, 0x00])
        #expect(try await get == 7_051_500)
    }

    @Test func readOperatingMode() async throws {
        let (client, rig) = await makePair()

        async let get = client.operatingMode()
        #expect(try await rig.readFrame() == [0xFE, 0xFE, 0x98, 0xE0, 0x26, 0x00, 0xFD])
        await rig.reply([0x26, 0x00, 0x00, 0x00, 0x01])  // LSB, data off, FIL1
        let mode = try await get
        #expect(mode == CIVClient.OperatingMode(mode: 0x00, dataMode: 0, filter: 1))
        #expect(mode.description == "LSB")
    }

    @Test func setOperatingModeUSBData() async throws {
        let (client, rig) = await makePair()

        async let set: Void = client.setOperatingMode(.usbData)
        #expect(
            try await rig.readFrame()
                == [0xFE, 0xFE, 0x98, 0xE0, 0x26, 0x00, 0x01, 0x01, 0x01, 0xFD])
        await rig.reply([0xFB])
        try await set
        #expect(CIVClient.OperatingMode.usbData.description == "USB-D")
    }

    @Test func silentRigTimesOutInsteadOfHanging() async throws {
        let (client, rig) = await makePair()

        let get = Task { try await client.frequency() }
        _ = try await rig.readFrame()
        // No reply at all — the client must give up on its own.
        await #expect(throws: WinlinkError.timeout("No reply from the rig (CI-V)")) {
            try await get.value
        }
    }
}
