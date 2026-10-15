import Foundation
import CommonCrypto
import CryptoKit

public enum CryptoError: Error, Equatable {
    case cipherFailure(Int32)
    case invalidLength
}

enum Crypto {
    static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count)
        let ab = a.bytes, bb = b.bytes
        return Data(zip(ab, bb).map { $0 ^ $1 })
    }

    private static func aes(_ operation: Int, options: Int, key: Data, iv: Data?, input: Data) throws -> Data {
        var outLength = 0
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let ivData = iv ?? Data()
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(operation),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(options),
                                keyPtr.baseAddress, key.count,
                                iv == nil ? nil : ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outCapacity,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cipherFailure(status) }
        out.count = outLength
        return out
    }

    /// AES (key length selects 128/192/256) in ECB mode with PKCS7 padding.
    static func aesECBEncrypt(key: Data, data: Data) throws -> Data {
        try aes(kCCEncrypt, options: kCCOptionECBMode | kCCOptionPKCS7Padding, key: key, iv: nil, input: data)
    }

    static func aesECBDecrypt(key: Data, data: Data) throws -> Data {
        guard data.count % 16 == 0, !data.isEmpty else { throw CryptoError.invalidLength }
        return try aes(kCCDecrypt, options: kCCOptionECBMode | kCCOptionPKCS7Padding, key: key, iv: nil, input: data)
    }

    /// AES CBC with an all-zero IV and no padding (data must be block aligned).
    static func aesCBCEncryptZeroIV(key: Data, data: Data) throws -> Data {
        guard data.count % 16 == 0 else { throw CryptoError.invalidLength }
        return try aes(kCCEncrypt, options: 0, key: key, iv: Data(count: 16), input: data)
    }

    static func aesCBCDecryptZeroIV(key: Data, data: Data) throws -> Data {
        guard data.count % 16 == 0 else { throw CryptoError.invalidLength }
        return try aes(kCCDecrypt, options: 0, key: key, iv: Data(count: 16), input: data)
    }
}
