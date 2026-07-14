// ArdopLaunchConfig argument building and ArdopProcess lifecycle
// against fake executables (shell scripts) — no real ardopcf needed.
import Foundation
import Testing

@testable import WinlinkKit

@Suite struct ArdopLaunchConfigTests {
    @Test func defaultArguments() {
        let config = ArdopLaunchConfig()
        #expect(config.arguments() == ["--nologfile", "8515", "DEFAULT", "DEFAULT"])
    }

    @Test func catCIVBuildsIcomKeyCommands() {
        let config = ArdopLaunchConfig(
            controlPort: 8520,
            captureDevice: "USB Audio CODEC",
            playbackDevice: "USB Audio CODEC",
            ptt: .catCIV(port: "/dev/cu.usbmodem14201", baud: 115200, civAddress: 0x98))
        #expect(config.arguments() == [
            "--nologfile",
            "-c", "/dev/cu.usbmodem14201:115200",
            "-k", "FEFE98E01C0001FD",
            "-u", "FEFE98E01C0000FD",
            "8520", "USB Audio CODEC", "USB Audio CODEC",
        ])
    }

    @Test func civAddressIsFormattedAsHex() {
        #expect(ArdopLaunchConfig.civKeyCommand(address: 0xA4, transmit: true)
            == "FEFEA4E01C0001FD")
        #expect(ArdopLaunchConfig.civKeyCommand(address: 0x0E, transmit: false)
            == "FEFE0EE01C0000FD")
    }

    @Test func rtsAndRigctldAndLogsAndHostCommands() {
        var config = ArdopLaunchConfig(ptt: .rts(port: "/dev/cu.usbserial-A1"))
        #expect(config.arguments().contains("-p"))
        #expect(config.arguments().contains("/dev/cu.usbserial-A1"))

        config.ptt = .rigctld(host: "127.0.0.1", port: 4532)
        #expect(config.arguments().joined(separator: " ").contains("-p 127.0.0.1:4532"))

        config.logDirectory = URL(fileURLWithPath: "/tmp/ardop-logs")
        config.hostCommands = ["CONSOLELOG 2", "DRIVELEVEL 80"]
        let args = config.arguments()
        #expect(args.contains("--logdir"))
        #expect(!args.contains("--nologfile"))
        #expect(args.joined(separator: " ").contains("-H CONSOLELOG 2;DRIVELEVEL 80"))
    }

    @Test func modemConfigMatchesPorts() {
        let config = ArdopLaunchConfig(controlPort: 8600)
        #expect(config.modemConfig.controlPort == 8600)
        #expect(config.modemConfig.dataPort == 8601)
    }
}

#if os(macOS)
/// Writes a fake ardopcf (a shell script) into a temp directory.
private func makeFakeExecutable(_ script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ardop-fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("ardopcf")
    try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite struct ArdopProcessTests {
    /// A fake TNC: prints a line, then listens on the control port so
    /// the readiness probe succeeds; exits on SIGINT/SIGTERM.
    @Test func startBecomesReadyAndStopCleansUp() async throws {
        let port = UInt16.random(in: 20000..<40000)
        let exe = try makeFakeExecutable("""
            echo "fake tnc starting"
            exec python3 -c '
            import socket, signal, sys
            signal.signal(signal.SIGINT, lambda *a: sys.exit(0))
            signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen(1)
            while True:
                c, _ = s.accept()
                c.close()
            '
            """)
        let process = ArdopProcess(
            executable: exe,
            config: ArdopLaunchConfig(controlPort: port))

        try await process.start(readyTimeout: .seconds(15))
        let lines = await process.recentLogLines
        #expect(lines.contains("fake tnc starting"))
        await process.stop(gracePeriod: .seconds(3))
    }

    @Test func earlyExitThrowsWithCapturedLog() async throws {
        let exe = try makeFakeExecutable("""
            echo "boom: no audio device" >&2
            exit 7
            """)
        let process = ArdopProcess(
            executable: exe,
            config: ArdopLaunchConfig(controlPort: UInt16.random(in: 20000..<40000)))

        do {
            try await process.start(readyTimeout: .seconds(10))
            Issue.record("start() should have thrown")
        } catch let error as ArdopProcessError {
            guard case .terminatedEarly(let code, let log) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(code == 7)
            #expect(log.contains { $0.contains("boom: no audio device") })
        }
    }

    @Test func readyTimeoutThrowsAndKillsProcess() async throws {
        // Sleeps without ever opening the port; SIGINT-able.
        let exe = try makeFakeExecutable("exec sleep 60")
        let process = ArdopProcess(
            executable: exe,
            config: ArdopLaunchConfig(controlPort: UInt16.random(in: 20000..<40000)))

        do {
            try await process.start(readyTimeout: .seconds(1))
            Issue.record("start() should have thrown")
        } catch let error as ArdopProcessError {
            guard case .readyTimeout = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func logLinesStreamDeliversOutput() async throws {
        let exe = try makeFakeExecutable("""
            echo "line one"
            echo "line two"
            exit 0
            """)
        let process = ArdopProcess(
            executable: exe,
            config: ArdopLaunchConfig(controlPort: UInt16.random(in: 20000..<40000)))

        // The process exits immediately, so start() throws — the log
        // stream must still carry the output and then end.
        _ = try? await process.start(readyTimeout: .seconds(5))

        var seen = [String]()
        for await line in process.logLines {
            seen.append(line)
        }
        #expect(seen.contains("line one"))
        #expect(seen.contains("line two"))
    }
}
#endif
