// Baud → modem bandwidth. Strict on purpose: a wrong value here would
// put the wrong signal width on the air.
import Testing

@testable import WinlinkKit

@Suite struct GatewayBandwidthTests {
    @Test(arguments: [200, 500, 1000, 2000])
    func ardopBandwidthsAreTakenAtFaceValue(_ width: Int) {
        #expect(
            GatewayBandwidth.hertz(
                baud: String(width), mode: .ardop, frequencyHz: 7_051_500) == width)
    }

    @Test(arguments: ["500", "2300", "2750"])
    func varaBandwidthsAreTakenAtFaceValue(_ width: String) {
        #expect(
            GatewayBandwidth.hertz(baud: width, mode: .vara, frequencyHz: 7_051_500)
                == Int(width))
    }

    @Test func trailingUnitsAreTolerated() {
        #expect(
            GatewayBandwidth.hertz(baud: "2000 Hz", mode: .ardop, frequencyHz: 7_051_500)
                == 2000)
    }

    /// Anything we cannot map is nil, and nil means the client keeps the
    /// user's setting instead of inventing one.
    @Test(arguments: ["", " ", "wide", "N/A", "2400", "300", "9600", "-500"])
    func unknownValuesYieldNil(_ baud: String) {
        #expect(
            GatewayBandwidth.hertz(baud: baud, mode: .ardop, frequencyHz: 7_051_500)
                == nil)
    }

    /// Packet reports baud rates, Pactor negotiates its own — neither
    /// says anything about bandwidth.
    @Test(arguments: [GatewayOperatingMode.packet, .pactor, .robustPacket, .anyAll])
    func modesWithoutABandwidthYieldNil(_ mode: GatewayOperatingMode) {
        #expect(GatewayBandwidth.hertz(baud: "1200", mode: mode) == nil)
    }

    /// 30 m is 50 kHz wide and secondary; the starter list has carried
    /// the same 500 Hz rule since the first release.
    @Test func thirtyMetresIsCappedAtFiveHundredHertz() {
        #expect(
            GatewayBandwidth.hertz(baud: "2000", mode: .ardop, frequencyHz: 10_145_900)
                == 500)
        #expect(
            GatewayBandwidth.hertz(baud: "2750", mode: .vara, frequencyHz: 10_145_000)
                == 500)
    }

    @Test func neighbouringBandsAreNotCapped() {
        #expect(
            GatewayBandwidth.hertz(baud: "2000", mode: .ardop, frequencyHz: 7_051_500)
                == 2000)
        #expect(
            GatewayBandwidth.hertz(baud: "2000", mode: .ardop, frequencyHz: 14_110_400)
                == 2000)
    }

    /// Without a frequency there is no band-plan check, so no cap.
    @Test func missingFrequencyStillMapsTheBandwidth() {
        #expect(GatewayBandwidth.hertz(baud: "2000", mode: .ardop) == 2000)
    }
}
