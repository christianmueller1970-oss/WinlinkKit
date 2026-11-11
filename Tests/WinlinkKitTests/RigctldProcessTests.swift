// RigctldLaunchConfig argument building and RigctldProcess lifecycle
// against fake executables (shell scripts) — no real rigctld needed.
import Foundation
import Testing

@testable import WinlinkKit

@Suite struct RigctldLaunchConfigTests {
    @Test func dummyRigNeedsNoDevice() {
        let config = RigctldLaunchConfig(model: 1)
        #expect(config.arguments() == ["-m", "1", "-T", "127.0.0.1", "-t", "4532"])
    }

    @Test func serialIcomCarriesLineParametersAndCIVAddress() {
        let config = RigctldLaunchConfig(
            model: 3085,
            connection: .serial(.init(port: "/dev/cu.usbserial-113110", baud: 115200)),
            civAddress: " 0xA4 ",
            listenPort: 4540)
        #expect(config.arguments() == [
            "-m", "3085",
            "-r", "/dev/cu.usbserial-113110", "-s", "115200",
            "-C", "data_bits=8,stop_bits=1,serial_parity=None,serial_handshake=None,civaddr=0xA4",
            "-T", "127.0.0.1", "-t", "4540",
        ])
    }

    @Test func serialWithoutCIVAddressOmitsIt() {
        let config = RigctldLaunchConfig(
            model: 1042,
            connection: .serial(.init(
                port: "/dev/cu.SLAB", baud: 38400, stopBits: 2, handshake: .hardware)),
            civAddress: "")
        let conf = config.arguments()[config.arguments().firstIndex(of: "-C")! + 1]
        #expect(conf == "data_bits=8,stop_bits=2,serial_parity=None,serial_handshake=Hardware")
    }

    @Test func networkRigPassesHost() {
        let config = RigctldLaunchConfig(model: 2036, connection: .network(host: "192.168.1.20"))
        #expect(config.arguments() == [
            "-m", "2036", "-r", "192.168.1.20", "-T", "127.0.0.1", "-t", "4532",
        ])
    }
}

#if os(macOS)
/// Writes a fake rigctld (a shell script) into a temp directory.
private func makeFakeExecutable(_ script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rigctld-fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("rigctld")
    try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite struct RigctldProcessTests {
    /// A fake daemon that answers `\get_freq`: start() becomes ready,
    /// RigctldClient can talk to it, stop() ends it.
    @Test func startBecomesReadyServesClientAndStops() async throws {
        let port = UInt16.random(in: 40000..<60000)
        let exe = try makeFakeExecutable("""
            echo "fake rigctld starting"
            exec python3 -c '
            import socket, signal, sys
            signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen(4)
            while True:
                c, _ = s.accept()
                data = c.recv(100)
                if data:
                    c.sendall(b"7052000\\n")
                c.close()
            '
            """)
        let process = RigctldProcess(
            executable: exe, config: RigctldLaunchConfig(model: 1, listenPort: port))

        try await process.start(readyTimeout: .seconds(15))
        #expect(await process.isRunning)
        #expect(await process.recentLogLines.contains("fake rigctld starting"))

        let client = try await RigctldClient.connect(host: "127.0.0.1", port: port)
        #expect(try await client.frequency() == 7_052_000)
        await client.close()

        await process.stop(gracePeriod: .seconds(3))
        #expect(await process.isRunning == false)
        #expect(await process.processIdentifier == nil)
    }

    /// When the app dies — crash or force quit, no termination hook —
    /// the supervision pipe closes and rigctld must go with it.
    @Test func childEndsWhenTheParentGoesAway() async throws {
        let port = UInt16.random(in: 40000..<60000)
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rigctld-fake-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let exe = try makeFakeExecutable("""
            exec python3 -c '
            import os, socket, signal, sys
            open("\(pidFile.path)", "w").write(str(os.getpid()))
            signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen(4)
            while True:
                c, _ = s.accept()
                c.close()
            '
            """)
        let process = RigctldProcess(
            executable: exe, config: RigctldLaunchConfig(model: 1, listenPort: port))
        try await process.start(readyTimeout: .seconds(15))
        let daemon = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(daemon, 0) == 0)

        await process.dropLifelineForTesting()

        let deadline = ContinuousClock.now + .seconds(5)
        while kill(daemon, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(daemon, 0) != 0)
        #expect(await process.isRunning == false)
    }

    /// stop() reaches the real daemon behind the supervisor.
    @Test func stopEndsTheDaemonBehindTheSupervisor() async throws {
        let port = UInt16.random(in: 40000..<60000)
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rigctld-fake-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let exe = try makeFakeExecutable("""
            exec python3 -c '
            import os, socket, signal, sys
            open("\(pidFile.path)", "w").write(str(os.getpid()))
            signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", \(port)))
            s.listen(4)
            while True:
                c, _ = s.accept()
                c.close()
            '
            """)
        let process = RigctldProcess(
            executable: exe, config: RigctldLaunchConfig(model: 1, listenPort: port))
        try await process.start(readyTimeout: .seconds(15))
        let daemon = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(daemon != (await process.processIdentifier))

        await process.stop(gracePeriod: .seconds(3))
        #expect(kill(daemon, 0) != 0)
    }

    /// rigctld that cannot open the rig exits at once — the error
    /// carries what it printed.
    @Test func earlyExitThrowsWithCapturedLog() async throws {
        let exe = try makeFakeExecutable("""
            echo "rig_open: error = IO error" >&2
            exit 2
            """)
        let process = RigctldProcess(
            executable: exe,
            config: RigctldLaunchConfig(model: 3085, listenPort: UInt16.random(in: 40000..<60000)))

        do {
            try await process.start(readyTimeout: .seconds(10))
            Issue.record("start() should have thrown")
        } catch let error as RigctldProcessError {
            guard case .terminatedEarly(let code, let log) = error else {
                Issue.record("unexpected error \\(error)")
                return
            }
            #expect(code == 2)
            #expect(log.contains { $0.contains("rig_open: error = IO error") })
        }
        #expect(await process.isRunning == false)
    }

    @Test func readyTimeoutThrowsAndKillsProcess() async throws {
        let exe = try makeFakeExecutable("exec sleep 60")
        let process = RigctldProcess(
            executable: exe,
            config: RigctldLaunchConfig(model: 1, listenPort: UInt16.random(in: 40000..<60000)))

        do {
            try await process.start(readyTimeout: .seconds(1))
            Issue.record("start() should have thrown")
        } catch let error as RigctldProcessError {
            guard case .readyTimeout = error else {
                Issue.record("unexpected error \\(error)")
                return
            }
        }
        #expect(await process.isRunning == false)
    }
}
#endif
