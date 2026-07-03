import Testing
@testable import WinlinkKit

/// Test vectors ported from wl2k-go/fbb/secure_test.go
struct SecureLoginTests {
    @Test(arguments: [
        (challenge: "23753528", password: "FOOBAR", expect: "72768415"),
        (challenge: "23753528", password: "FooBar", expect: "95074758"),
    ])
    func loginResponse(challenge: String, password: String, expect: String) {
        #expect(SecureLogin.response(challenge: challenge, password: password) == expect)
    }
}
