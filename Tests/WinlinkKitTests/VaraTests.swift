// Tests for the VARA modem client (reference: Pat-Vara, MIT)
import Foundation
import Testing

@testable import WinlinkKit

/// Records PTT keying for assertions.
private actor PTTRecorder {
    private(set) var events = [Bool]()
    func record(_ on: Bool) { events.append(on) }
}

/// A test harness holding both ends of the command and data channels.
private struct ModemHarness {
    let modem: VaraModem
    let commandServer: ScriptedServer // the "VARA program" side of the command channel
    let dataEnd: PipeTransport        // the "VARA program" side of the data channel

    static func start(mode: VaraModem.Mode = .hf, mycall: String = "HB9HJI") async throws -> ModemHarness {
        let (cmdClient, cmdServer) = await PipeTransport.pair()
        let (dataClient, dataServer) = await PipeTransport.pair()
        let modem = VaraModem(mode: mode, mycall: mycall, command: cmdClient, data: dataClient)
        try await modem.setup()
        return ModemHarness(
            modem: modem, commandServer: ScriptedServer(cmdServer), dataEnd: dataServer)
    }

    /// Consumes and verifies the setup command sequence.
    func expectSetup(cwid: Bool = true, mycall: String = "HB9HJI") async throws {
        try await commandServer.expect("PUBLIC ON")
        if cwid {
            try await commandServer.expect("CWID ON")
        }
        try await commandServer.expect("COMPRESSION TEXT", "MYCALL \(mycall)", "LISTEN OFF")
    }

    /// Closes the modem, playing the modem's side of the link teardown
    /// if a connection is still up.
    func shutdown() async throws {
        let state = await modem.state
        if state == .disconnected {
            await modem.close()
            return
        }
        let closer = Task { await modem.close() }
        try await commandServer.expect("DISCONNECT")
        await commandServer.send("DISCONNECTED\r")
        await closer.value
    }
}

@Suite struct VaraCommandTests {

    @Test(arguments: [
        ("OK", VaraCommand.ok),
        ("WRONG", .wrong),
        ("IAMALIVE", .iAmAlive),
        ("PENDING", .pending),
        ("CANCELPENDING", .cancelPending),
        ("PTT ON", .pttOn),
        ("PTT OFF", .pttOff),
        ("BUSY ON", .busyOn),
        ("BUSY OFF", .busyOff),
        ("DISCONNECTED", .disconnected),
        ("LINK REGISTERED", .linkRegistered),
        ("LINK UNREGISTERED", .linkUnregistered),
        ("ENCRYPTION DISABLED", .encryptionDisabled),
        ("ENCRYPTION READY", .encryptionReady),
        ("UNENCRYPTED LINK", .unencryptedLink),
        ("ENCRYPTED LINK", .encryptedLink),
        ("BUFFER 1234", .buffer(1234)),
        ("BUFFER 0", .buffer(0)),
        ("CONNECTED HB9HJI HB9AK 2300", .connected(source: "HB9HJI", destination: "HB9AK")),
        ("CONNECTED HB9HJI HB9AK", .connected(source: "HB9HJI", destination: "HB9AK")),
        ("REGISTERED HB9HJI", .registered("HB9HJI")),
        ("VERSION VARA HF 4.8.7", .version("VARA HF 4.8.7")),
        ("FOO BAR", .unknown("FOO BAR")),
        ("CONNECTED ONLYONE", .unknown("CONNECTED ONLYONE")),
    ])
    func parse(line: String, expected: VaraCommand) {
        #expect(VaraCommand(parsing: line) == expected)
    }
}

@Suite struct VaraModemTests {

    /// Setup sends the configuration sequence (HF includes CWID).
    @Test func setupSequenceHF() async throws {
        let harness = try await ModemHarness.start(mode: .hf)
        try await harness.expectSetup(cwid: true)
        await harness.modem.close()
    }

    /// VARA FM setup skips the CWID command.
    @Test func setupSequenceFM() async throws {
        let harness = try await ModemHarness.start(mode: .fm)
        try await harness.expectSetup(cwid: false)
        await harness.modem.close()
    }

    /// Happy-path dial: BW + session type + CONNECT, answered with CONNECTED.
    @Test func dialConnects() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        async let connection = harness.modem.dial("hb9ak", bandwidth: "2300")

        try await harness.commandServer.expect(
            "BW2300", "WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("CONNECTED HB9HJI HB9AK 2300\r")

        _ = try await connection
        let state = await harness.modem.state
        #expect(state == .connected)
        try await harness.shutdown()
    }

    /// A dial answered with DISCONNECTED (VARA's own timeout) throws.
    @Test func dialFails() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        let dial = Task { try await harness.modem.dial("HB9AK") }
        try await harness.commandServer.expect("WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("DISCONNECTED\r")

        await #expect(throws: WinlinkError.self) {
            _ = try await dial.value
        }
        let state = await harness.modem.state
        #expect(state == .disconnected)
        await harness.modem.close()
    }

    /// An invalid bandwidth is rejected before touching the modem.
    @Test func dialRejectsInvalidBandwidth() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        await #expect(throws: WinlinkError.self) {
            _ = try await harness.modem.dial("HB9AK", bandwidth: "1200")
        }
        await harness.modem.close()
    }

    /// Data written to the connection reaches the data channel; inbound
    /// data is readable. BUFFER updates from the modem are tracked.
    @Test func dataPassthrough() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        async let dialed = harness.modem.dial("HB9AK")
        try await harness.commandServer.expect("WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("CONNECTED HB9HJI HB9AK 2300\r")
        let connection = try await dialed

        // Outbound
        try await connection.write(Data("hello remote".utf8))
        let sent = try await harness.dataEnd.read()
        #expect(String(decoding: sent, as: UTF8.self) == "hello remote")

        // Inbound
        await harness.dataEnd.write(Data("hello local".utf8))
        let received = try await connection.read()
        #expect(String(decoding: received, as: UTF8.self) == "hello local")

        try await harness.shutdown()
    }

    /// PTT ON/OFF from the modem is forwarded to the PTT handler.
    @Test func pttForwarding() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        let recorder = PTTRecorder()
        await harness.modem.setPTTHandler { on in await recorder.record(on) }

        await harness.commandServer.send("PTT ON\r")
        await harness.commandServer.send("PTT OFF\r")

        // The handler runs on a detached task; poll briefly.
        for _ in 0..<50 {
            if await recorder.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await recorder.events
        #expect(events == [true, false])
        await harness.modem.close()
    }

    /// BUSY ON/OFF updates the busy flag.
    @Test func busyTracking() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        await harness.commandServer.send("BUSY ON\r")
        for _ in 0..<50 {
            if await harness.modem.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await harness.modem.isBusy)

        await harness.commandServer.send("BUSY OFF\r")
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
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        async let dialed = harness.modem.dial("HB9AK")
        try await harness.commandServer.expect("WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("CONNECTED HB9HJI HB9AK 2300\r")
        let connection = try await dialed

        let closer = Task { await connection.close() }
        try await harness.commandServer.expect("DISCONNECT")
        await harness.commandServer.send("DISCONNECTED\r")
        await closer.value

        let state = await harness.modem.state
        #expect(state == .disconnected)
        let eof = try await connection.read()
        #expect(eof.isEmpty)
        await harness.modem.close()
    }

    /// A remote disconnect unblocks a pending read with EOF.
    @Test func remoteDisconnectEndsRead() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        async let dialed = harness.modem.dial("HB9AK")
        try await harness.commandServer.expect("WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("CONNECTED HB9HJI HB9AK 2300\r")
        let connection = try await dialed

        let reader = Task { try await connection.read() }
        try await Task.sleep(for: .milliseconds(50)) // let the read block
        await harness.commandServer.send("DISCONNECTED\r")

        let chunk = try await reader.value
        #expect(chunk.isEmpty)
        await harness.modem.close()
    }

    /// The full B2F exchange runs over a VARA connection unchanged:
    /// scripted CMS dialog on the far end of the data channel.
    @Test func b2fSessionOverVara() async throws {
        let harness = try await ModemHarness.start()
        try await harness.expectSetup()

        async let dialed = harness.modem.dial("HB9AK")
        try await harness.commandServer.expect("WINLINK SESSION", "CONNECT HB9HJI HB9AK")
        await harness.commandServer.send("CONNECTED HB9HJI HB9AK 2300\r")
        let connection = try await dialed

        let session = Task {
            let s = B2FSession(mycall: "HB9HJI", targetcall: "HB9AK", locator: "JN47PN")
            return try await s.exchange(over: connection)
        }

        // The far end of the data channel plays a scripted RMS.
        let rms = ScriptedServer(harness.dataEnd)
        await rms.send("[WL2K-5.0-B2FWIHJM$]\r")
        await rms.send("Test RMS >\r")
        try await rms.expect(
            ";FW: HB9HJI",
            "[WinlinkKit-\(WinlinkKit.version)-B2FHM$]",
            "; HB9AK DE HB9HJI (JN47PN)"
        )
        // The real modem reports its draining TX buffer continuously;
        // without an update the session's next write would block on
        // flow control.
        await harness.commandServer.send("BUFFER 0\r")
        try await rms.expect("FF")
        await rms.send("FQ\r")

        // The session closes its transport, which disconnects the link.
        try await harness.commandServer.expect("DISCONNECT")
        await harness.commandServer.send("DISCONNECTED\r")

        let stats = try await session.value
        #expect(stats == TrafficStats())
        await harness.modem.close()
    }
}
