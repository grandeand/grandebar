import CommonCrypto
import Foundation
import Security

// Claude Desktop keeps its OAuth tokens in config.json (`oauth:tokenCacheV2`), encrypted with
// Chromium's OSCrypt: a secret in the login Keychain ("Claude Safe Storage") -> PBKDF2-SHA1
// ("saltysalt", 1003 rounds) -> AES-128-CBC with an IV of 16 spaces, values prefixed "v10".
// GrandeBar reads the live account's inference token to ask the usage API for that account,
// the same request Desktop makes for its own usage screen. The token is only used in memory:
// it is never written, logged or refreshed, so Desktop's login is left exactly as it is.

enum ClaudeDesktopTokenError: Error, Equatable {
    case noTokenCache
    /// The Keychain item is missing, or the user denied GrandeBar access to it.
    case keychain(OSStatus)
    case undecryptable
    case noInferenceToken
    /// Desktop refreshes it the next time it runs; GrandeBar never does.
    case expired
}

enum ClaudeDesktopToken {
    static let safeStorageService = "Claude Safe Storage"
    static let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    private static let inferenceScope = "user:inference"

    /// The bearer token of the account Desktop is signed into. `secret` is injectable for tests.
    static func read(dataDir: URL, now: Date = Date(), secret: () throws -> Data) throws -> String {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeDesktopTokenError.noTokenCache
        }
        let blobs = cacheKeys.compactMap { config[$0] as? String }.filter { !$0.isEmpty }
        guard !blobs.isEmpty else { throw ClaudeDesktopTokenError.noTokenCache }
        let key = try secret()
        var sawExpired = false
        var decrypted = false
        for blob in blobs {
            // A wrong key passes the padding check about once in 256 tries; only JSON counts.
            guard let plain = decrypt(blob, secret: key),
                  (try? JSONSerialization.jsonObject(with: plain)) is [String: Any] else { continue }
            decrypted = true
            switch inferenceToken(in: plain, now: now) {
            case .success(let token): return token
            case .failure(.expired): sawExpired = true
            case .failure: continue
            }
        }
        if sawExpired { throw ClaudeDesktopTokenError.expired }
        throw decrypted ? ClaudeDesktopTokenError.noInferenceToken : ClaudeDesktopTokenError.undecryptable
    }

    /// Prompts once per code signature unless the user picks "Always Allow". Blocking: call it
    /// off the main thread.
    static func keychainSecret() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            throw ClaudeDesktopTokenError.keychain(status)
        }
        return data
    }

    /// Plaintext of one "v10" value, or nil; a wrong key fails the PKCS7 padding check.
    static func decrypt(_ valueBase64: String, secret: Data) -> Data? {
        guard let raw = Data(base64Encoded: valueBase64), raw.count > 3,
              raw.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = raw.dropFirst(3)
        guard let key = deriveKey(secret) else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            cipher.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                inBytes.baseAddress, cipher.count, outBytes.baseAddress, outCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    static func deriveKey(_ secret: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                secret.withUnsafeBytes { secretBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secretBytes.baseAddress?.assumingMemoryBound(to: Int8.self), secret.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// The cache maps "client:org:audience:scopes" to {token, expiresAt (ms)}; the app also
    /// keeps a profile-only token, which the usage API refuses.
    static func inferenceToken(in plaintext: Data, now: Date) -> Result<String, ClaudeDesktopTokenError> {
        guard let entries = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else {
            return .failure(.noInferenceToken)
        }
        var sawExpired = false
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) where key.contains(inferenceScope) {
            guard let entry = value as? [String: Any], let token = entry["token"] as? String, !token.isEmpty else { continue }
            if let expires = (entry["expiresAt"] as? NSNumber)?.doubleValue, expires > 0,
               expires / 1000 <= now.timeIntervalSince1970 + 60 {
                sawExpired = true
                continue
            }
            return .success(token)
        }
        return .failure(sawExpired ? .expired : .noInferenceToken)
    }
}
