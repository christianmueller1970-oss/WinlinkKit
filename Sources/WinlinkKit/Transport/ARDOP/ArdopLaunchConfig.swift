import Foundation

/// Launch configuration for a managed ardopcf process.
///
/// Builds the command line for the macOS build of ardopcf (see the
/// Skywave ardopcf fork, branch `macos-port`). The data port is always
/// `controlPort + 1`, fixed by ardopcf itself.
public struct ArdopLaunchConfig: Sendable, Equatable {
    /// How ardopcf keys the transmitter.
    public enum PTT: Sendable, Equatable {
        /// ardopcf does not key the radio. PTT state is reported to the
        /// host (`PTT TRUE/FALSE`), which may key via `setPTTHandler`,
        /// or the radio uses VOX.
        case none
        /// RTS on a serial device (`-p /dev/cu...`).
        case rts(port: String)
        /// CAT key/unkey hex commands on a serial CI-V port
        /// (`-c port:baud -k ... -u ...`). The commands are built for
        /// Icom CI-V from the transceiver address (IC-7610: 0x98).
        case catCIV(port: String, baud: Int = 115200, civAddress: UInt8 = 0x98)
        /// PTT via a Hamlib rigctld network connection (`-p host:port`),
        /// keyed by ardopcf itself.
        case rigctld(host: String, port: UInt16 = 4532)
    }

    /// TCP command port; the data port is `controlPort + 1`.
    public var controlPort: UInt16
    /// Capture device: "DEFAULT", a PortAudio index, an exact CoreAudio
    /// device name, or a unique case-insensitive substring of one.
    public var captureDevice: String
    /// Playback device, same forms as `captureDevice`.
    public var playbackDevice: String
    public var ptt: PTT
    /// Directory for ardopcf log and WAV files; nil disables log files
    /// (`--nologfile`), console output is captured either way.
    public var logDirectory: URL?
    /// Host commands applied during startup (`-H`, joined with ";"),
    /// e.g. `["CONSOLELOG 2"]`.
    public var hostCommands: [String]

    public init(
        controlPort: UInt16 = 8515,
        captureDevice: String = "DEFAULT",
        playbackDevice: String = "DEFAULT",
        ptt: PTT = .none,
        logDirectory: URL? = nil,
        hostCommands: [String] = []
    ) {
        self.controlPort = controlPort
        self.captureDevice = captureDevice
        self.playbackDevice = playbackDevice
        self.ptt = ptt
        self.logDirectory = logDirectory
        self.hostCommands = hostCommands
    }

    /// The Icom CI-V PTT-on command for a transceiver address:
    /// `FE FE <addr> E0 1C 00 01 FD` (1C 00 = PTT, 01 = TX).
    static func civKeyCommand(address: UInt8, transmit: Bool) -> String {
        String(format: "FEFE%02XE01C00%02XFD", address, transmit ? 1 : 0)
    }

    /// The ardopcf command line (without the executable itself).
    public func arguments() -> [String] {
        var args: [String] = []

        if let logDirectory {
            args += ["--logdir", logDirectory.path]
        } else {
            args += ["--nologfile"]
        }

        switch ptt {
        case .none:
            break
        case .rts(let port):
            args += ["-p", port]
        case .catCIV(let port, let baud, let address):
            args += [
                "-c", "\(port):\(baud)",
                "-k", Self.civKeyCommand(address: address, transmit: true),
                "-u", Self.civKeyCommand(address: address, transmit: false),
            ]
        case .rigctld(let host, let port):
            args += ["-p", "\(host):\(port)"]
        }

        if !hostCommands.isEmpty {
            args += ["-H", hostCommands.joined(separator: ";")]
        }

        args += [String(controlPort), captureDevice, playbackDevice]
        return args
    }

    /// The matching client configuration for `ArdopModem.connect`.
    public var modemConfig: ArdopModem.Config {
        var config = ArdopModem.Config()
        config.host = "localhost"
        config.controlPort = controlPort
        config.dataPort = controlPort + 1
        return config
    }
}
