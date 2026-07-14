// Manual end-to-end test tool against the real Winlink CMS (not part of CI).
import Foundation
import WinlinkKit

@main
struct CLI {
    static let usage = """
        winlinkkit-cli — manual E2E test tool for WinlinkKit

        Usage:
          winlinkkit-cli send --to <addr> --subject <text> --body <text> [connection]
              Queue a message in the mailbox, then exchange with the CMS.
          winlinkkit-cli fetch [connection]
              Exchange with the CMS (sends queued, fetches pending messages).
          winlinkkit-cli vara-check [--transport vara|varafm]
              Connect to the VARA modem program, print its version and
              disconnect. No RF transmission — safe wiring test.
          winlinkkit-cli ardop-check
              Connect to the ARDOP TNC, print its version and
              disconnect. No RF transmission — safe wiring test.

        Connection options:
          --transport <name>    telnet (default), vara (HF), varafm or ardop
          --gateway <callsign>  RMS gateway to dial (required for VARA/ARDOP)
          --bandwidth <value>   VARA HF: 500, 2300 or 2750 Hz
                                ARDOP: 200, 500, 1000 or 2000, with optional
                                MAX (default) or FORCED suffix

        Environment:
          WL_CALLSIGN        your callsign (required)
          WL_PASSWORD        your Winlink account password (required)
          WL_LOCATOR         your Maidenhead locator (optional)
          WL_MAILBOX         mailbox directory (default: ./mailbox)
          WL_CMS_HOST        CMS host (default: server.winlink.org; production
                             only accepts registered client types — use
                             cms-z.winlink.org for testing)
          WL_CMS_PORT        CMS port (default: 8772)
          WL_VARA_HOST       VARA modem host (default: localhost)
          WL_VARA_CMD_PORT   VARA command port (default: 8300)
          WL_VARA_DATA_PORT  VARA data port (default: 8301)
          WL_ARDOP_HOST      ARDOP TNC host (default: localhost)
          WL_ARDOP_CTRL_PORT ARDOP control port (default: 8515)
          WL_ARDOP_DATA_PORT ARDOP data port (default: 8516)
          WL_ARDOP_EXEC      spawn this ardopcf binary as a managed child
          WL_ARDOP_CAPTURE   audio capture device for spawned ardopcf
          WL_ARDOP_PLAYBACK  audio playback device for spawned ardopcf
          WL_RIGCTLD_HOST    if set, key PTT via rigctld at this host
                             (ARDOP only; VARA keys the radio itself)
          WL_RIGCTLD_PORT    rigctld port (default: 4532)
        """

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            print(usage)
            exit(64)
        }
        let command = args.removeFirst()

        let env = ProcessInfo.processInfo.environment
        guard let callsign = env["WL_CALLSIGN"], !callsign.isEmpty else {
            fail("WL_CALLSIGN is not set")
        }
        let options = parseOptions(args)

        if command == "vara-check" {
            try await varaCheck(
                mode: options["transport"] == "varafm" ? .fm : .hf, callsign: callsign)
            return
        }
        if command == "ardop-check" {
            try await ardopCheck(callsign: callsign, locator: env["WL_LOCATOR"] ?? "")
            return
        }

        guard let password = env["WL_PASSWORD"], !password.isEmpty else {
            fail("WL_PASSWORD is not set")
        }
        let locator = env["WL_LOCATOR"] ?? ""
        let mailboxRoot = URL(
            fileURLWithPath: env["WL_MAILBOX"] ?? "mailbox", isDirectory: true)
        let mailbox = DirectoryMailbox(root: mailboxRoot)
        switch command {
        case "send":
            guard let to = options["to"], let subject = options["subject"],
                let body = options["body"]
            else {
                fail("send requires --to, --subject and --body\n\n\(usage)")
            }
            var message = B2Message(mycall: callsign)
            message.addTo(to)
            message.setSubject(subject)
            message.setBody(body.hasSuffix("\n") ? body : body + "\n")
            try await mailbox.addOutbound(message)
            print("Queued \(message.mid) to \(to)")

        case "fetch":
            break

        default:
            fail("Unknown command '\(command)'\n\n\(usage)")
        }

        switch options["transport"] ?? "telnet" {
        case "telnet":
            try await telnetExchange(
                callsign: callsign, password: password, locator: locator,
                mailbox: mailbox)
        case "vara", "varahf":
            try await varaExchange(
                mode: .hf, callsign: callsign, password: password,
                locator: locator, mailbox: mailbox, options: options)
        case "varafm":
            try await varaExchange(
                mode: .fm, callsign: callsign, password: password,
                locator: locator, mailbox: mailbox, options: options)
        case "ardop":
            try await ardopExchange(
                callsign: callsign, password: password, locator: locator,
                mailbox: mailbox, options: options)
        case let transport:
            fail("Unknown transport '\(transport)'\n\n\(usage)")
        }
    }

    static func telnetExchange(
        callsign: String, password: String, locator: String, mailbox: DirectoryMailbox
    ) async throws {
        let env = ProcessInfo.processInfo.environment
        let host = env["WL_CMS_HOST"] ?? TelnetTransport.cmsHost
        let port = env["WL_CMS_PORT"].flatMap(UInt16.init) ?? TelnetTransport.cmsPort

        print("Connecting to \(host):\(port) ...")
        let transport = try await TelnetTransport.dialCMS(
            mycall: callsign, host: host, port: port)
        print("Connected, starting B2F exchange")

        try await runSession(
            over: transport, targetcall: TelnetTransport.cmsTargetCall,
            callsign: callsign, password: password, locator: locator,
            mailbox: mailbox)
    }

    static func varaExchange(
        mode: VaraModem.Mode, callsign: String, password: String,
        locator: String, mailbox: DirectoryMailbox, options: [String: String]
    ) async throws {
        guard let gateway = options["gateway"]?.uppercased() else {
            fail("--gateway <callsign> is required for VARA\n\n\(usage)")
        }

        let config = varaConfig()
        print("Connecting to VARA modem at \(config.host):\(config.commandPort) ...")
        let modem = try await VaraModem.connect(mode: mode, mycall: callsign, config: config)
        await modem.setLogLine { print("  vara: \($0)") }

        do {
            if let version = try? await modem.version() {
                print("Modem: VARA \(version)")
            }
            print("Dialing \(gateway) — this can take a while over RF ...")
            let link = try await modem.dial(gateway, bandwidth: options["bandwidth"])
            print("Link established, starting B2F exchange")

            try await runSession(
                over: link, targetcall: gateway,
                callsign: callsign, password: password, locator: locator,
                mailbox: mailbox)
        } catch {
            await modem.close()
            throw error
        }
        await modem.close()
    }

    /// Connects to the modem program, prints its version and disconnects.
    /// No CONNECT is issued, so nothing is transmitted over RF.
    static func varaCheck(mode: VaraModem.Mode, callsign: String) async throws {
        let config = varaConfig()
        print("Connecting to VARA modem at \(config.host):\(config.commandPort) ...")
        let modem = try await VaraModem.connect(mode: mode, mycall: callsign, config: config)
        await modem.setLogLine { print("  vara: \($0)") }
        do {
            let version = try await modem.version()
            print("OK — VARA \(version), command and data channels connected.")
        } catch {
            await modem.close()
            throw error
        }
        await modem.close()
    }

    static func ardopExchange(
        callsign: String, password: String, locator: String,
        mailbox: DirectoryMailbox, options: [String: String]
    ) async throws {
        guard let gateway = options["gateway"]?.uppercased() else {
            fail("--gateway <callsign> is required for ARDOP\n\n\(usage)")
        }
        var bandwidth: ArdopBandwidth?
        if let value = options["bandwidth"] {
            guard let parsed = ArdopBandwidth(parsing: value) else {
                fail("Invalid ARDOP bandwidth '\(value)' (200|500|1000|2000, optional MAX/FORCED suffix)")
            }
            bandwidth = parsed
        }

        let process = try await spawnArdopIfRequested()

        let config = ardopConfig()
        print("Connecting to ARDOP TNC at \(config.host):\(config.controlPort) ...")
        let modem = try await ArdopModem.connect(
            mycall: callsign, gridSquare: locator, config: config)
        await modem.setLogLine { print("  ardop: \($0)") }

        do {
            try await attachRigctldPTT(to: modem)
            if let version = try? await modem.version() {
                print("TNC: \(version)")
            }
            print("Dialing \(gateway) — this can take a while over RF ...")
            let link = try await modem.dial(gateway, bandwidth: bandwidth)
            print("Link established, starting B2F exchange")

            try await runSession(
                over: link, targetcall: gateway,
                callsign: callsign, password: password, locator: locator,
                mailbox: mailbox)
        } catch {
            await modem.close()
            await process?.stop()
            throw error
        }
        await modem.close()
        await process?.stop()
    }

    /// Connects to the TNC, prints its version and disconnects.
    /// No ARQCALL is issued, so nothing is transmitted over RF.
    static func ardopCheck(callsign: String, locator: String) async throws {
        let process = try await spawnArdopIfRequested()

        let config = ardopConfig()
        print("Connecting to ARDOP TNC at \(config.host):\(config.controlPort) ...")
        let modem = try await ArdopModem.connect(
            mycall: callsign, gridSquare: locator, config: config)
        await modem.setLogLine { print("  ardop: \($0)") }
        do {
            let version = try await modem.version()
            print("OK — \(version), control and data channels connected.")
        } catch {
            await modem.close()
            await process?.stop()
            throw error
        }
        await modem.close()
        await process?.stop()
    }

    /// Spawns a bundled/managed ardopcf when WL_ARDOP_EXEC is set,
    /// mirroring what Skywave does with the binary in its app bundle.
    /// WL_ARDOP_CAPTURE / WL_ARDOP_PLAYBACK select the audio devices.
    static func spawnArdopIfRequested() async throws -> ArdopProcess? {
        let env = ProcessInfo.processInfo.environment
        guard let exec = env["WL_ARDOP_EXEC"], !exec.isEmpty else { return nil }

        var launch = ArdopLaunchConfig()
        launch.controlPort = env["WL_ARDOP_CTRL_PORT"].flatMap(UInt16.init) ?? launch.controlPort
        launch.captureDevice = env["WL_ARDOP_CAPTURE"] ?? launch.captureDevice
        launch.playbackDevice = env["WL_ARDOP_PLAYBACK"] ?? launch.playbackDevice

        print("Spawning ardopcf: \(exec) \(launch.arguments().joined(separator: " "))")
        let process = ArdopProcess(
            executable: URL(fileURLWithPath: exec), config: launch)
        Task {
            for await line in process.logLines { print("  ardopcf: \(line)") }
        }
        try await process.start()
        print("ardopcf is up, control port \(launch.controlPort) reachable.")
        return process
    }

    /// Keys PTT via rigctld when WL_RIGCTLD_HOST is set. ARDOP does
    /// not key the radio itself (unlike VARA, which has its own CAT
    /// configuration).
    static func attachRigctldPTT(to modem: ArdopModem) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["WL_RIGCTLD_HOST"], !host.isEmpty else { return }
        let port = env["WL_RIGCTLD_PORT"].flatMap(UInt16.init) ?? RigctldClient.defaultPort

        print("Keying PTT via rigctld at \(host):\(port)")
        let rig = try await RigctldClient.connect(host: host, port: port)
        await modem.setPTTHandler { on in
            do {
                try await rig.setPTT(on)
            } catch {
                fputs("rigctld PTT \(on ? "on" : "off") failed: \(error)\n", stderr)
            }
        }
    }

    static func ardopConfig() -> ArdopModem.Config {
        let env = ProcessInfo.processInfo.environment
        var config = ArdopModem.Config()
        config.host = env["WL_ARDOP_HOST"] ?? config.host
        config.controlPort = env["WL_ARDOP_CTRL_PORT"].flatMap(UInt16.init) ?? config.controlPort
        config.dataPort = env["WL_ARDOP_DATA_PORT"].flatMap(UInt16.init) ?? config.dataPort
        return config
    }

    static func varaConfig() -> VaraModem.Config {
        let env = ProcessInfo.processInfo.environment
        var config = VaraModem.Config()
        config.host = env["WL_VARA_HOST"] ?? config.host
        config.commandPort = env["WL_VARA_CMD_PORT"].flatMap(UInt16.init) ?? config.commandPort
        config.dataPort = env["WL_VARA_DATA_PORT"].flatMap(UInt16.init) ?? config.dataPort
        return config
    }

    static func runSession(
        over transport: some WinlinkTransport, targetcall: String,
        callsign: String, password: String, locator: String,
        mailbox: DirectoryMailbox
    ) async throws {
        let session = B2FSession(
            mycall: callsign,
            targetcall: targetcall,
            locator: locator,
            mailbox: mailbox
        )
        session.secureLoginPassword = password
        session.logLine = { print("  \($0)") }

        let stats = try await session.exchange(over: transport)
        print("Exchange done. Sent: \(stats.sent.count), received: \(stats.received.count)")
        for mid in stats.sent {
            print("  sent \(mid)")
        }
        for mid in stats.received {
            print("  received \(mid)")
        }

        let inbox = await mailbox.inboundMessages()
        if !inbox.isEmpty {
            print("Inbox (\(inbox.count)):")
            for message in inbox {
                print("  \(message.mid)  \(message.from.description)  \(message.subject)")
            }
        }
    }

    /// Parses `--key value` pairs.
    static func parseOptions(_ args: [String]) -> [String: String] {
        var options = [String: String]()
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--"), i + 1 < args.count {
                options[String(args[i].dropFirst(2))] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return options
    }

    static func fail(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(64)
    }
}
