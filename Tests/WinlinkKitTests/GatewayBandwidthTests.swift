// Channel mode → modem bandwidth. The values come from ARSFI's
// ModeMappings enum, which is explicitly numbered.
import Testing

@testable import WinlinkKit

@Suite struct GatewayBandwidthTests {
    /// The numbers the live service actually sends. Verified against
    /// api.winlink.org on 2026-08-07: 41 and 43 for ARDOP channels.
    @Test(arguments: [
        (40, 200), (41, 500), (42, 1000), (43, 2000), (44, 2000),
        (53, 500), (54, 2750),
    ])
    func modeIntegersCarryTheBandwidth(_ raw: Int, _ hertz: Int) throws {
        let mode = try #require(GatewayChannelMode(rawValue: raw))
        #expect(mode.bandwidthHz == hertz)
        #expect(GatewayBandwidth.hertz(mode: mode, frequencyHz: 7_051_500) == hertz)
    }

    /// Modes that do not pin a bandwidth down yield nil, and nil means
    /// the client keeps the user's setting instead of inventing one.
    @Test(arguments: [0, 3, 13, 20, 21, 30, 50, 51, 52])
    func modesWithoutABandwidthYieldNil(_ raw: Int) throws {
        let mode = try #require(GatewayChannelMode(rawValue: raw))
        #expect(GatewayBandwidth.hertz(mode: mode, frequencyHz: 7_051_500) == nil)
    }

    /// A value the enum does not know must not become a guess.
    @Test func unknownModeYieldsNil() {
        #expect(GatewayChannelMode(rawValue: 99) == nil)
        #expect(GatewayBandwidth.hertz(mode: nil, frequencyHz: 7_051_500) == nil)
    }

    /// HB9AK really does announce ARDOP 2000 on 30 m (mode 43 on
    /// 10'145.9 kHz, live data). IARU Region 1 makes 30 m narrow-band
    /// only, so a Swiss station answers with 500.
    @Test func thirtyMetresIsCappedEvenWhenTheGatewayAnnouncesMore() {
        #expect(
            GatewayBandwidth.hertz(mode: .ardop2000, frequencyHz: 10_145_900) == 500)
        #expect(
            GatewayBandwidth.hertz(mode: .vara2750, frequencyHz: 10_145_000) == 500)
        // Already narrow: unchanged.
        #expect(GatewayBandwidth.hertz(mode: .ardop500, frequencyHz: 10_145_300) == 500)
        #expect(GatewayBandwidth.hertz(mode: .ardop200, frequencyHz: 10_145_300) == 200)
    }

    @Test(arguments: [3_614_500, 7_051_500, 14_110_400, 18_115_900, 21_115_000])
    func otherBandsAreNotCapped(_ frequencyHz: Int) {
        #expect(GatewayBandwidth.hertz(mode: .ardop2000, frequencyHz: frequencyHz) == 2000)
    }

    /// The families the app has a transport for must map cleanly.
    @Test func familiesMatchTheRequestedMode() {
        #expect(GatewayChannelMode.ardop2000.family == .ardop)
        #expect(GatewayChannelMode.ardop500.family == .ardop)
        #expect(GatewayChannelMode.vara2750.family == .vara)
        #expect(GatewayChannelMode.varaFMWide.family == .varaFM)
        #expect(GatewayChannelMode.packet9600.family == .packet)
    }
}
