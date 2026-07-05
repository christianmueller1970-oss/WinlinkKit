// Tests for the ARDOP TNC client (reference: wl2k-go/transport/ardop, MIT)
import Foundation
import Testing

@testable import WinlinkKit

/// Records PTT keying for assertions.
private actor PTTRecorder {
    private(set) var events = [Bool]()
    func record(_ on: Bool) { events.append(on) }
}

/// The "remote RMS" as seen through the framed ARDOP data channel:
/// unwraps host → TNC frames (acknowledging each with a BUFFER update,
/// like the real TNC), and wraps its own lines as TNC → host ARQ
/// frames.
private actor ArdopRMS {
    private let dataEnd: PipeTransport
    private let commandEnd: PipeTransport
    private var pending = [UInt8]() // framed bytes not yet parsed
    private var text = [UInt8]()    // payload bytes not yet consumed as lines

    init(dataEnd: PipeTransport, commandEnd: PipeTransport) {
        self.dataEnd = dataEnd
        self.commandEnd = commandEnd
    }

    /// Sends an ARQ data frame to the host.
    func sendData(_ payload: Data) async {
        var frame = Data()
        let length = payload.count + 3
        frame.append(UInt8(length >> 8))
        frame.append(UInt8(length & 0xff))
        frame.append(Data("ARQ".utf8))
        frame.append(payload)
        await dataEnd.write(frame)
    }

    func send(_ line: String) async {
        await sendData(Data(line.utf8))
    }

    /// Reads one host → TNC frame and acknowledges it with a BUFFER
    /// update (which also unblocks the host's flow-controlled write).
    func readFrame() async throws -> Data {
        while true {
            if pending.count >= 2 {
                let length = Int(pending[0]) << 8 | Int(pending[1])
                if pending.count >= 2 + length {
                    let payload = Data(pending[2..<(2 + length)])
                    pending.removeFirst(2 + length)
                    await commandEnd.write(Data("BUFFER 0\r".utf8))
                    return payload
                }
            }
            let chunk = try await dataEnd.read()
            if chunk.isEmpty {
                throw WinlinkError.connectionClosed
            }
            pending.append(contentsOf: chunk)
        }
    }

    func readLine() async throws -> String {
        while true {
            if let idx = text.firstIndex(of: FBBControl.cr) {
                let line = String(decoding: text[..<idx], as: UTF8.self)
                text.removeSubrange(...idx)
                return line
            }
            text.append(contentsOf: try await readFrame())
        }
    }

    func expect(_ lines: String..., sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for expected in lines {
            let got = try await readLine()
            #expect(got == expected, sourceLocation: sourceLocation)
        }
    }
}

/// A test harness holding both ends of the control and data channels.
private struct TNCHarness {
    let modem: ArdopModem
    let commandServer: ScriptedServer // the "TNC" side of the control channel
    let dataEnd: PipeTransport        // the "TNC" side of the data channel
    let commandEnd: PipeTransport

    static func start(
        mycall: String = "HB9HJI", gridSquare: String = "JN47PN"
    ) async -> TNCHarness {
        let (ctrlClient, ctrlServer) = await PipeTransport.pair()
        let (dataClient, dataServer) = await PipeTransport.pair()
        let modem = ArdopModem(
            mycall: mycall, gridSquare: gridSquare,
            control: ctrlClient, data: dataClient)
        return TNCHarness(
            modem: modem, commandServer: ScriptedServer(ctrlServer),
            dataEnd: dataServer, commandEnd: ctrlServer)
    }

    /// Runs `setup()` while playing the TNC's side of the init dialog.
    func performSetup(initialState: String = "DISC") async throws {
        async let done: Void = modem.setup()

        try await commandServer.expect("INITIALIZE")
        await commandServer.send("INITIALIZE\r")
        try await commandServer.expect("STATE")
        await commandServer.send("STATE \(initialState)\r")
        if initialState == "OFFLINE" {
            try await commandServer.expect("CODEC true")
            await commandServer.send("CODEC now True\r")
        }
        try await commandServer.expect("PROTOCOLMODE ARQ")
        await commandServer.send("PROTOCOLMODE now ARQ\r")
        try await commandServer.expect("ARQTIMEOUT 90")
        await commandServer.send("ARQTIMEOUT now 90\r")
        try await commandServer.expect("LISTEN false")
        await commandServer.send("LISTEN now False\r")
        try await commandServer.expect("MYCALL HB9HJI")
        await commandServer.send("MYCALL now HB9HJI\r")
        try await commandServer.expect("GRIDSQUARE JN47PN")
        await commandServer.send("GRIDSQUARE now JN47PN\r")

        try await done
    }

    /// Plays the TNC side of a successful dial and returns the link.
    func dial(
        _ target: String = "HB9AK", bandwidth: ArdopBandwidth? = nil
    ) async throws -> ArdopConnection {
        async let dialed = modem.dial(target, bandwidth: bandwidth)
        if let bandwidth {
            try await commandServer.expect("ARQBW \(bandwidth)")
            await commandServer.send("ARQBW now \(bandwidth)\r")
        }
        try await commandServer.expect("ARQCALL \(target) 10")
        await commandServer.send("NEWSTATE ISS\r") // must not end the dial
        await commandServer.send("CONNECTED \(target) 500\r")
        return try await dialed
    }

    /// Closes the modem, playing the TNC's side of the link teardown
    /// if a connection is still up.
    func shutdown() async throws {
        let linkState = await modem.linkState
        if linkState == .disconnected {
            await modem.close()
            return
        }
        let closer = Task { await modem.close() }
        try await commandServer.expect("DISCONNECT")
        await commandServer.send("DISCONNECTED\r")
        await closer.value
    }
}

@Suite struct ArdopCommandTests {

    // Port of wl2k-go/transport/ardop TestParse, plus echo-back cases.
    @Test(arguments: [
        ("NEWSTATE DISC", ArdopCommand(name: "NEWSTATE", value: .state(.disconnected))),
        ("NEWSTATE ISS", ArdopCommand(name: "NEWSTATE", value: .state(.iss))),
        ("PTT True", ArdopCommand(name: "PTT", value: .bool(true))),
        ("PTT False", ArdopCommand(name: "PTT", value: .bool(false))),
        ("PTT trUE", ArdopCommand(name: "PTT", value: .bool(true))),
        ("CODEC True", ArdopCommand(name: "CODEC", value: .bool(true))),
        ("LISTEN now False", ArdopCommand(name: "LISTEN", value: .bool(false))),
        ("foobar baz", ArdopCommand(name: "FOOBAR", value: .none)),
        ("DISCONNECTED", ArdopCommand(name: "DISCONNECTED", value: .none)),
        (
            "FAULT 5/Error in the application.",
            ArdopCommand(name: "FAULT", value: .string("5/Error in the application."))
        ),
        ("BUFFER 300", ArdopCommand(name: "BUFFER", value: .int(300))),
        ("MYCALL LA5NTA", ArdopCommand(name: "MYCALL", value: .string("LA5NTA"))),
        ("MYCALL now HB9HJI", ArdopCommand(name: "MYCALL", value: .string("HB9HJI"))),
        ("GRIDSQUARE JP20QH", ArdopCommand(name: "GRIDSQUARE", value: .string("JP20QH"))),
        ("MYAUX LA5NTA,LE3OF", ArdopCommand(name: "MYAUX", value: .list(["LA5NTA", "LE3OF"]))),
        ("MYAUX LA5NTA, LE3OF", ArdopCommand(name: "MYAUX", value: .list(["LA5NTA", "LE3OF"]))),
        ("VERSION 1.4.7.0", ArdopCommand(name: "VERSION", value: .string("1.4.7.0"))),
        ("FREQUENCY 14096400", ArdopCommand(name: "FREQUENCY", value: .int(14096400))),
        ("ARQBW 200MAX", ArdopCommand(name: "ARQBW", value: .string("200MAX"))),
        ("CONNECTED LA5NTA 500", ArdopCommand(name: "CONNECTED", value: .list(["LA5NTA", "500"]))),
        ("NEWSTATE DISC ", ArdopCommand(name: "NEWSTATE", value: .state(.disconnected))),
    ])
    func parse(line: String, expected: ArdopCommand) {
        #expect(ArdopCommand(parsing: line) == expected)
    }

    @Test func bandwidthStrings() {
        #expect(ArdopBandwidth(parsing: "500")?.description == "500MAX")
        #expect(ArdopBandwidth(parsing: "2000MAX")?.description == "2000MAX")
        #expect(ArdopBandwidth(parsing: "2000forced")?.description == "2000FORCED")
        #expect(ArdopBandwidth(parsing: "1200") == nil)
        #expect(ArdopBandwidth(max: 1200) == nil)
        #expect(ArdopBandwidth(max: 500, forced: true)?.description == "500FORCED")
    }
}

@Suite struct ArdopFramingTests {

    @Test func encodeFrame() {
        let frame = ArdopFraming.encode(Data("hello".utf8))
        #expect(frame == Data([0x00, 0x05] + Array("hello".utf8)))
    }

    /// Frames survive arbitrary TCP chunk boundaries and back-to-back
    /// delivery.
    @Test func decodeAcrossChunks() {
        var decoder = ArdopFraming.Decoder()

        // First frame split mid-payload.
        decoder.append(Data([0x00, 0x08] + Array("ARQhe".utf8)))
        #expect(decoder.next() == nil)
        // Rest of frame one plus a complete second frame.
        decoder.append(
            Data(Array("llo".utf8) + [0x00, 0x07] + Array("IDF id".utf8) + [0x20]))

        let first = decoder.next()
        #expect(first?.type == "ARQ")
        #expect(first.map { String(decoding: $0.payload, as: UTF8.self) } == "hello")

        let second = decoder.next()
        #expect(second?.type == "IDF")
        #expect(decoder.next() == nil)
    }
}

@Suite struct ArdopModemTests {

    /// Setup sends the init sequence; a DISC TNC needs no CODEC start.
    @Test func setupSequence() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        #expect(await harness.modem.tncState == .disconnected)
        await harness.modem.close()
    }

    /// An OFFLINE TNC gets its codec enabled during setup.
    @Test func setupStartsCodecWhenOffline() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup(initialState: "OFFLINE")
        await harness.modem.close()
    }

    /// A FAULT reply to a setup command fails the setup.
    @Test func setupFaultThrows() async throws {
        let harness = await TNCHarness.start()
        let setup = Task { try await harness.modem.setup() }
        try await harness.commandServer.expect("INITIALIZE")
        await harness.commandServer.send("FAULT not from state OFFLINE\r")
        await #expect(throws: WinlinkError.remoteError("not from state OFFLINE")) {
            try await setup.value
        }
        await harness.modem.close()
    }

    /// Happy-path dial: optional ARQBW, then ARQCALL answered with
    /// CONNECTED. Intermediate NEWSTATE changes don't end the dial.
    @Test func dialConnects() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()

        _ = try await harness.dial("HB9AK", bandwidth: ArdopBandwidth(max: 500))
        #expect(await harness.modem.linkState == .connected)
        #expect(await harness.modem.tncState == .iss)
        try await harness.shutdown()
    }

    /// A dial answered with NEWSTATE DISC (connect timeout) throws.
    @Test func dialFails() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()

        let dial = Task { try await harness.modem.dial("HB9AK") }
        try await harness.commandServer.expect("ARQCALL HB9AK 10")
        await harness.commandServer.send("NEWSTATE DISC\r")

        await #expect(throws: WinlinkError.self) {
            _ = try await dial.value
        }
        #expect(await harness.modem.linkState == .disconnected)
        await harness.modem.close()
    }

    /// A FAULT reply to ARQCALL surfaces as a remote error.
    @Test func dialFault() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()

        let dial = Task { try await harness.modem.dial("HB9AK") }
        try await harness.commandServer.expect("ARQCALL HB9AK 10")
        await harness.commandServer.send("FAULT callsign not valid\r")

        await #expect(throws: WinlinkError.remoteError("callsign not valid")) {
            _ = try await dial.value
        }
        #expect(await harness.modem.linkState == .disconnected)
        await harness.modem.close()
    }

    /// Outbound data is framed and waits for the TNC's BUFFER ack;
    /// inbound ARQ frames are unwrapped.
    @Test func dataPassthrough() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        let connection = try await harness.dial()
        let rms = ArdopRMS(dataEnd: harness.dataEnd, commandEnd: harness.commandEnd)

        // Outbound: one frame, released by the BUFFER update the RMS
        // side sends when it consumes the frame.
        let writer = Task { try await connection.write(Data("hello remote".utf8)) }
        let sent = try await rms.readFrame()
        try await writer.value
        #expect(String(decoding: sent, as: UTF8.self) == "hello remote")

        // Inbound
        await rms.sendData(Data("hello local".utf8))
        let received = try await connection.read()
        #expect(String(decoding: received, as: UTF8.self) == "hello local")

        try await harness.shutdown()
    }

    /// PTT True/False from the TNC is forwarded to the PTT handler.
    @Test func pttForwarding() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()

        let recorder = PTTRecorder()
        await harness.modem.setPTTHandler { on in await recorder.record(on) }

        await harness.commandServer.send("PTT True\r")
        await harness.commandServer.send("PTT False\r")

        // The handler runs on a detached task; poll briefly.
        for _ in 0..<50 {
            if await recorder.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await recorder.events
        #expect(events == [true, false])
        await harness.modem.close()
    }

    /// BUSY True/False updates the busy flag.
    @Test func busyTracking() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()

        await harness.commandServer.send("BUSY True\r")
        for _ in 0..<50 {
            if await harness.modem.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await harness.modem.isBusy)

        await harness.commandServer.send("BUSY False\r")
        for _ in 0..<50 {
            if await !harness.modem.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await !harness.modem.isBusy)
        await harness.modem.close()
    }

    /// Closing the connection sends DISCONNECT and awaits DISCONNECTED;
    /// subsequent reads return EOF.
    @Test func gracefulDisconnect() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        let connection = try await harness.dial()

        let closer = Task { await connection.close() }
        try await harness.commandServer.expect("DISCONNECT")
        await harness.commandServer.send("DISCONNECTED\r")
        await closer.value

        #expect(await harness.modem.linkState == .disconnected)
        let eof = try await connection.read()
        #expect(eof.isEmpty)
        await harness.modem.close()
    }

    /// Disconnect waits for the TNC's TX buffer to drain before
    /// sending DISCONNECT (ARDOP drops queued data otherwise).
    @Test func disconnectFlushesBuffer() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        let connection = try await harness.dial()
        let rms = ArdopRMS(dataEnd: harness.dataEnd, commandEnd: harness.commandEnd)

        // Leave 42 queued bytes behind: overwrite the automatic
        // "BUFFER 0" ack with a non-zero update.
        let writer = Task { try await connection.write(Data("last line\r".utf8)) }
        _ = try await rms.readFrame()
        try await writer.value
        await harness.commandServer.send("BUFFER 42\r")
        try await Task.sleep(for: .milliseconds(50)) // let the update land

        let closer = Task { await connection.close() }
        try await Task.sleep(for: .milliseconds(50)) // close must now be flushing
        await harness.commandServer.send("BUFFER 0\r")
        try await harness.commandServer.expect("DISCONNECT")
        await harness.commandServer.send("DISCONNECTED\r")
        await closer.value

        #expect(await harness.modem.linkState == .disconnected)
        await harness.modem.close()
    }

    /// A remote disconnect unblocks a pending read with EOF.
    @Test func remoteDisconnectEndsRead() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        let connection = try await harness.dial()

        let reader = Task { try await connection.read() }
        try await Task.sleep(for: .milliseconds(50)) // let the read block
        await harness.commandServer.send("DISCONNECTED\r")

        let chunk = try await reader.value
        #expect(chunk.isEmpty)
        await harness.modem.close()
    }

    /// The full B2F exchange runs over an ARDOP connection unchanged:
    /// scripted CMS dialog on the far end of the framed data channel.
    @Test func b2fSessionOverArdop() async throws {
        let harness = await TNCHarness.start()
        try await harness.performSetup()
        let connection = try await harness.dial()
        let rms = ArdopRMS(dataEnd: harness.dataEnd, commandEnd: harness.commandEnd)

        let session = Task {
            let s = B2FSession(mycall: "HB9HJI", targetcall: "HB9AK", locator: "JN47PN")
            return try await s.exchange(over: connection)
        }

        await rms.send("[WL2K-5.0-B2FWIHJM$]\r")
        await rms.send("Test RMS >\r")
        try await rms.expect(
            ";FW: HB9HJI",
            "[WinlinkKit-\(WinlinkKit.version)-B2FHM$]",
            "; HB9AK DE HB9HJI (JN47PN)",
            "FF"
        )
        await rms.send("FQ\r")

        // The session closes its transport, which disconnects the link.
        try await harness.commandServer.expect("DISCONNECT")
        await harness.commandServer.send("DISCONNECTED\r")

        let stats = try await session.value
        #expect(stats == TrafficStats())
        await harness.modem.close()
    }
}
