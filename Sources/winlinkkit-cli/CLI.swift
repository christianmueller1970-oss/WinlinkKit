// Manual end-to-end test tool against the real Winlink CMS (not part of CI).
import Foundation
import WinlinkKit

@main
struct CLI {
    static let usage = """
        winlinkkit-cli — manual E2E test tool for WinlinkKit

        Usage:
          winlinkkit-cli send --to <addr> --subject <text> --body <text>
              Queue a message in the mailbox, then exchange with the CMS.
          winlinkkit-cli fetch
              Exchange with the CMS (sends queued, fetches pending messages).

        Environment:
          WL_CALLSIGN   your callsign (required)
          WL_PASSWORD   your Winlink account password (required)
          WL_LOCATOR    your Maidenhead locator (optional)
          WL_MAILBOX    mailbox directory (default: ./mailbox)
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

        switch command {
        case "send":
            let options = parseOptions(args)
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
            try await exchange(
                callsign: callsign, password: password, locator: locator, mailbox: mailbox)

        case "fetch":
            try await exchange(
                callsign: callsign, password: password, locator: locator, mailbox: mailbox)

        default:
            fail("Unknown command '\(command)'\n\n\(usage)")
        }
    }

    static func exchange(
        callsign: String, password: String, locator: String, mailbox: DirectoryMailbox
    ) async throws {
        print("Connecting to \(TelnetTransport.cmsHost):\(TelnetTransport.cmsPort) ...")
        let transport = try await TelnetTransport.dialCMS(mycall: callsign)
        print("Connected, starting B2F exchange")

        let session = B2FSession(
            mycall: callsign,
            targetcall: TelnetTransport.cmsTargetCall,
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
