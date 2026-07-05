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

        Connection options:
          --transport <name>    telnet (default), vara (HF) or varafm
          --gateway <callsign>  RMS gateway to dial (required for VARA)
          --bandwidth <hz>      VARA HF bandwidth: 500, 2300 or 2750 (optional)

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
        guard let password = env["WL_PASSWORD"], !password.isEmpty else {
            fail("WL_PASSWORD is not set")
        }
        let locator = env["WL_LOCATOR"] ?? ""
        let mailboxRoot = URL(
            fileURLWithPath: env["WL_MAILBOX"] ?? "mailbox", isDirectory: true)
        let mailbox = DirectoryMailbox(root: mailboxRoot)

        let options = parseOptions(args)
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

        let env = ProcessInfo.processInfo.environment
        var config = VaraModem.Config()
        config.host = env["WL_VARA_HOST"] ?? config.host
        config.commandPort = env["WL_VARA_CMD_PORT"].flatMap(UInt16.init) ?? config.commandPort
        config.dataPort = env["WL_VARA_DATA_PORT"].flatMap(UInt16.init) ?? config.dataPort

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
