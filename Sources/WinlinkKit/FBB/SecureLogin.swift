// Ported from wl2k-go/fbb/secure.go
import CryptoKit
import Foundation

/// Winlink secure login: computes the response token for the CMS
/// `;PQ:` challenge (answered with `;PR:`).
enum SecureLogin {
    /// This salt was found in paclink-unix's source code.
    private static let winlinkSecureSalt: [UInt8] = [
        77, 197, 101, 206, 190, 249,
        93, 200, 51, 243, 93, 237,
        71, 94, 239, 138, 68, 108,
        70, 185, 225, 137, 217, 16,
        51, 122, 193, 48, 194, 195,
        198, 175, 172, 169, 70, 84,
        61, 62, 104, 186, 114, 52,
        61, 168, 66, 129, 192, 208,
        187, 249, 232, 193, 41, 113,
        41, 45, 240, 16, 29, 228,
        208, 228, 61, 20,
    ]

    /// Computes the 8-digit response for a given challenge and password.
    /// The protocol mandates MD5 (hence `Insecure.MD5`).
    static func response(challenge: String, password: String) -> String {
        var payload = Array(challenge.utf8)
        payload.append(contentsOf: Array(password.utf8))
        payload.append(contentsOf: winlinkSecureSalt)

        let sum = Array(Insecure.MD5.hash(data: Data(payload)))

        // Little-endian assembly of the first 4 digest bytes, top 2 bits masked
        // (max 0x3fffffff, so the Int32 shifts below cannot overflow).
        var pr = Int32(sum[3] & 0x3f)
        for i in stride(from: 2, through: 0, by: -1) {
            pr = (pr << 8) | Int32(sum[i])
        }

        let str = String(format: "%08d", pr)
        return String(str.suffix(8))
    }
}
