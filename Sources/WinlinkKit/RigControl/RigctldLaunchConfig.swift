import Foundation

/// Launch configuration for a managed Hamlib `rigctld` process.
///
/// Builds the command line for a rigctld that owns the connection to
/// the transceiver and serves it on a local TCP port, where
/// `RigctldClient` picks it up.
public struct RigctldLaunchConfig: Sendable, Equatable {
    public enum Parity: String, Sendable, Equatable, CaseIterable {
        case none = "None"
        case odd = "Odd"
        case even = "Even"
    }

    public enum Handshake: String, Sendable, Equatable, CaseIterable {
        case none = "None"
        case hardware = "Hardware"
        case xonxoff = "XONXOFF"
    }

    /// Serial line parameters of a rig on a serial (or USB serial) port.
    public struct Serial: Sendable, Equatable {
        /// Device path, e.g. `/dev/cu.usbserial-113110`.
        public var port: String
        public var baud: Int
        public var dataBits: Int
        public var stopBits: Int
        public var parity: Parity
        public var handshake: Handshake

        public init(
            port: String, baud: Int, dataBits: Int = 8, stopBits: Int = 1,
            parity: Parity = .none, handshake: Handshake = .none
        ) {
            self.port = port
            self.baud = baud
            self.dataBits = dataBits
            self.stopBits = stopBits
            self.parity = parity
            self.handshake = handshake
        }
    }

    /// How rigctld reaches the transceiver.
    public enum Connection: Sendable, Equatable {
        /// No device argument — Hamlib's dummy rig (model 1) and other
        /// backends that need none.
        case none
        case serial(Serial)
        /// A rig that Hamlib addresses over the network (`-r host[:port]`).
        case network(host: String)
    }

    /// Hamlib rig model number (`-m`), e.g. 3085 for the IC-705.
    public var model: Int
    public var connection: Connection
    /// Icom CI-V address as Hamlib takes it (`0xA4` or `A4`); nil keeps
    /// the backend default. Only meaningful for CI-V backends.
    public var civAddress: String?
    /// TCP port rigctld listens on. Always bound to loopback — the rig
    /// must not become reachable from the LAN by accident.
    public var listenPort: UInt16

    public init(
        model: Int, connection: Connection = .none, civAddress: String? = nil,
        listenPort: UInt16 = RigctldClient.defaultPort
    ) {
        self.model = model
        self.connection = connection
        self.civAddress = civAddress
        self.listenPort = listenPort
    }

    /// The rigctld command line (without the executable).
    public func arguments() -> [String] {
        var args = ["-m", String(model)]
        switch connection {
        case .none:
            break
        case .serial(let serial):
            args += ["-r", serial.port, "-s", String(serial.baud)]
            var conf = [
                "data_bits=\(serial.dataBits)",
                "stop_bits=\(serial.stopBits)",
                "serial_parity=\(serial.parity.rawValue)",
                "serial_handshake=\(serial.handshake.rawValue)",
            ]
            if let civ = civAddress?.trimmingCharacters(in: .whitespaces), !civ.isEmpty {
                conf.append("civaddr=\(civ)")
            }
            args += ["-C", conf.joined(separator: ",")]
        case .network(let host):
            args += ["-r", host]
        }
        // Without -T the bind address depends on the Hamlib version.
        args += ["-T", "127.0.0.1", "-t", String(listenPort)]
        return args
    }
}
