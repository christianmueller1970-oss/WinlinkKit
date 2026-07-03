import Foundation
import Testing
@testable import WinlinkKit

/// M0 sanity checks: package builds, fixtures are bundled and readable.
struct PackageScaffoldTests {
    @Test func versionIsSet() {
        #expect(!WinlinkKit.version.isEmpty)
    }

    @Test(arguments: [
        "e.txt", "e.txt.lzh",
        "pi.txt", "pi.txt.lzh",
        "gettysburg.txt", "gettysburg.txt.lzh",
        "Mark.Twain-Tom.Sawyer.txt", "Mark.Twain-Tom.Sawyer.txt.lzh",
        "LPE5NXDVLVSQ.b2f", "LPE5NXDVLVSQ.b2f.lzh",
    ])
    func fixtureIsBundled(name: String) throws {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: nil))
        let data = try Data(contentsOf: url)
        #expect(!data.isEmpty)
    }
}
