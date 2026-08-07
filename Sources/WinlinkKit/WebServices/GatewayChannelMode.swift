import Foundation

/// The `Mode` value of a gateway channel record.
///
/// This is ARSFI's `ModeMappings` enum (`WinlinkWebServices.dtos.cs`),
/// and unlike the `GatewayOperatingMode` we send in a request it
/// carries **explicit numeric values** — so reading it is safe, and it
/// is the only place the channel's bandwidth is stated. The `Baud`
/// field is not: live data shows "600" for both ARDOP 500 and ARDOP
/// 2000 channels.
public enum GatewayChannelMode: Int, Sendable, CaseIterable {
    case packet1200 = 0
    case packet2400 = 1
    case packet4800 = 2
    case packet9600 = 3
    case packet19200 = 4
    case packet38400 = 5
    case pactor1 = 11
    case pactor12 = 12
    case pactor123 = 13
    case pactor2 = 14
    case pactor23 = 15
    case pactor3 = 16
    case pactor1234 = 17
    case pactor234 = 18
    case pactor34 = 19
    case pactor4 = 20
    case winmor500 = 21
    case winmor1600 = 22
    case robustPacket = 30
    case ardop200 = 40
    case ardop500 = 41
    case ardop1000 = 42
    case ardop2000 = 43
    case ardop2000FM = 44
    case vara = 50
    case varaFM = 51
    case varaFMWide = 52
    case vara500 = 53
    case vara2750 = 54

    /// The modem bandwidth in Hz, or nil where the mode does not pin
    /// one down (packet, Pactor, and plain `VARA`, which the service
    /// uses when it does not distinguish 500 from 2750).
    public var bandwidthHz: Int? {
        switch self {
        case .ardop200: 200
        case .ardop500: 500
        case .ardop1000: 1000
        case .ardop2000, .ardop2000FM: 2000
        case .vara500: 500
        case .vara2750: 2750
        default: nil
        }
    }

    /// Which transport family this channel belongs to, for matching
    /// against the mode that was requested.
    public var family: GatewayOperatingMode? {
        switch self {
        case .ardop200, .ardop500, .ardop1000, .ardop2000: .ardop
        case .ardop2000FM: .ardop
        case .vara, .vara500, .vara2750: .vara
        case .varaFM, .varaFMWide: .varaFM
        case .robustPacket: .robustPacket
        case .winmor500, .winmor1600: .winmor
        case .packet1200, .packet2400, .packet4800, .packet9600,
            .packet19200, .packet38400:
            .packet
        default: .pactor
        }
    }
}
