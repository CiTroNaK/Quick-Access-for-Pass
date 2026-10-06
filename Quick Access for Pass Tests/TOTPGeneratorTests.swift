import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("TOTP generator")
struct TOTPGeneratorTests {
    private let sha1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private let sha256Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"
    private let sha512Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"

    @Test func generatesRFC6238SHA1EightDigitCode() throws {
        #expect(try code(secret: sha1Secret, algorithm: "SHA1", digits: 8, period: 30, at: 59) == "94287082")
    }

    @Test func generatesRFC6238SHA256EightDigitCode() throws {
        #expect(try code(secret: sha256Secret, algorithm: "SHA256", digits: 8, period: 30, at: 59) == "46119246")
    }

    @Test func generatesRFC6238SHA512EightDigitCode() throws {
        #expect(try code(secret: sha512Secret, algorithm: "SHA512", digits: 8, period: 30, at: 59) == "90693936")
    }

    @Test func honorsNonDefaultPeriodAndDigits() throws {
        #expect(try code(secret: sha1Secret, algorithm: "SHA1", digits: 6, period: 60, at: 59) == "755224")
    }

    @Test(arguments: [
        "MZXW6*==", // invalid Base32 character
        "MZXW6==", // invalid padding length
        "MZXW6=AA", // padding must be terminal
        "MZXW6===A", // data after padding
        "MZ" // non-zero trailing Base32 bits
    ])
    func rejectsMalformedBase32(_ secret: String) {
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try code(secret: secret)
        }
    }

    @Test func rejectsPercentEncodedWhitespaceInBase32Secret() {
        let uri = "otpauth://totp/Test?secret=\(sha1Secret)%20"
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    @Test(arguments: [
        "otpauth://totp?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
        "otpauth://totp/?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    ])
    func rejectsMissingOrEmptyLabel(_ uri: String) {
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    @Test func acceptsPercentEncodedLabel() throws {
        let uri = "otpauth://totp/Example%20Account?secret=\(sha1Secret)"
        #expect(try TOTPGenerator.code(from: uri, at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test(arguments: [
        "digits=5",
        "digits=9",
        "digits=abc",
        "digits=",
        "digits=+6",
        "digits=%2B6",
        "period=0",
        "period=-30",
        "period=+30",
        "period=%2B30",
        "period=abc",
        "period="
    ])
    func rejectsInvalidDigitsAndPeriod(_ parameter: String) {
        let uri = "otpauth://totp/Test?secret=\(sha1Secret)&\(parameter)"
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    @Test func rejectsDuplicateQueryParameters() {
        let uri = "otpauth://totp/Test?secret=\(sha1Secret)&secret=\(sha1Secret)"
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    @Test(arguments: ["digits", "period", "algorithm"])
    func rejectsValuelessSupportedQueryParameters(_ parameter: String) {
        let uri = "otpauth://totp/Test?secret=\(sha1Secret)&\(parameter)"
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    @Test(arguments: ["issuer=Example", "counter=1", "image=https%3A%2F%2Fexample.com%2Ficon.png"])
    func rejectsUnsupportedQueryParameters(_ parameter: String) {
        let uri = "otpauth://totp/Test?secret=\(sha1Secret)&\(parameter)"
        #expect(throws: TOTPGenerator.Error.unsupportedURI) {
            _ = try TOTPGenerator.code(from: uri)
        }
    }

    private func code(secret: String, algorithm: String = "SHA1", digits: Int = 6, period: Int = 30, at timestamp: TimeInterval = 59) throws -> String {
        let uri = "otpauth://totp/Test?secret=\(secret)&algorithm=\(algorithm)&digits=\(digits)&period=\(period)"
        return try TOTPGenerator.code(from: uri, at: Date(timeIntervalSince1970: timestamp))
    }
}
