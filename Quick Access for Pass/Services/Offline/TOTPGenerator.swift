import CryptoKit
import Foundation

nonisolated enum TOTPGenerator {
    enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedURI
    }

    static func code(from uri: String, at date: Date = .now) throws -> String {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp",
              let label = components.percentEncodedPath.dropFirst().removingPercentEncoding,
              components.percentEncodedPath.first == "/",
              !label.isEmpty,
              let queryItems = components.queryItems else {
            throw Error.unsupportedURI
        }
        let supportedParameterNames: Set = ["secret", "algorithm", "digits", "period", "issuer"]
        var values: [String: String] = [:]
        var parameterNames = Set<String>()
        for item in queryItems {
            let name = item.name.lowercased()
            guard supportedParameterNames.contains(name),
                  parameterNames.insert(name).inserted,
                  let value = item.value else {
                throw Error.unsupportedURI
            }
            values[name] = value
        }
        guard let secret = values["secret"], !secret.isEmpty,
              let key = base32Decode(secret), !key.isEmpty,
              let digitsValue = values["digits"] ?? "6" as String?,
              isASCIIDecimal(digitsValue),
              let digits = Int(digitsValue), (6...8).contains(digits),
              let periodValue = values["period"] ?? "30" as String?,
              isASCIIDecimal(periodValue),
              let period = Int64(periodValue), period > 0 else {
            throw Error.unsupportedURI
        }

        let counter = UInt64(max(0, Int64(date.timeIntervalSince1970)) / period)
        let message = withUnsafeBytes(of: counter.bigEndian, Array.init)
        let algorithm = (values["algorithm"] ?? "SHA1").uppercased()
        let digest: [UInt8]
        switch algorithm {
        case "SHA1": digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "SHA256": digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "SHA512": digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        default: throw Error.unsupportedURI
        }
        let offset = Int(digest.last! & 0x0f)
        guard offset + 3 < digest.count else { throw Error.unsupportedURI }
        let value = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        return String(format: "%0*llu", digits, value % UInt32(pow(10.0, Double(digits))))
    }

    private static func isASCIIDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func base32Decode(_ value: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var symbols: [Int] = []
        var paddingCount = 0
        var hasPadding = false

        for character in value.uppercased() {
            guard !character.isWhitespace else { return nil }
            if character == "=" {
                hasPadding = true
                paddingCount += 1
            } else {
                guard !hasPadding, let index = alphabet.firstIndex(of: character) else { return nil }
                symbols.append(index)
            }
        }

        guard !symbols.isEmpty else { return nil }
        let remainder = symbols.count % 8
        let expectedPadding = [0: 0, 2: 6, 4: 4, 5: 3, 7: 1]
        guard let requiredPadding = expectedPadding[remainder],
              (!hasPadding || (paddingCount == requiredPadding && remainder != 0)) else {
            return nil
        }

        var buffer: UInt64 = 0
        var bits = 0
        var output = Data()
        for symbol in symbols {
            buffer = (buffer << 5) | UInt64(symbol)
            bits += 5
            while bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        guard bits == 0 || (buffer & ((UInt64(1) << UInt64(bits)) - 1)) == 0 else { return nil }
        return output
    }
}
