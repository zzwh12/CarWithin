import Foundation
import Security

/// Imports a local test identity once, then keeps it in this device's Keychain.
/// It makes a best-effort attempt to remove the raw private-key staging file.
enum AccessoryIdentityStore {
    private static let service = "local.tds.carkit.mfi-identity"
    private static let chainAccount = "certificate-chain"
    private static let leafAccount = "leaf-certificate"
    private static let keyTag = Data("local.tds.carkit.mfi-identity.private-key".utf8)
    private static let maximumIdentityFileSize = 65_536

    static func load() throws -> AccessoryIdentity {
        let chain = try readData(account: chainAccount)
        let leaf = try readData(account: leafAccount)
        let key = try readPrivateKey()
        return try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKey: key)
    }

    /// Loads an MFi identity bundled inside the app (certificate.p7b, leaf.cer, private.x963).
    /// Used so a sideloaded build works without a per-device import step.
    static func loadFromBundle() throws -> AccessoryIdentity {
        guard let chainURL = Bundle.main.url(forResource: "certificate", withExtension: "p7b"),
              let leafURL = Bundle.main.url(forResource: "leaf", withExtension: "cer"),
              let keyURL = Bundle.main.url(forResource: "private", withExtension: "x963") else {
            throw StoreError.identityMissing
        }
        let chain = try readBounded(chainURL)
        let leaf = try readBounded(leafURL)
        var keyData = try readBounded(keyURL)
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        return try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
    }

    static func importFromDocuments() throws -> AccessoryIdentity {
        let directory = try stagingDirectory()
        let chainURL = directory.appendingPathComponent("certificate.p7b")
        let leafURL = directory.appendingPathComponent("leaf.cer")
        let keyURL = directory.appendingPathComponent("private.x963")
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let chain = try readBounded(chainURL)
        let leaf = try readBounded(leafURL)
        var keyData = try readBounded(keyURL)
        defer { keyData.resetBytes(in: 0..<keyData.count) }

        _ = try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
        do {
            try replacePrivateKey(keyData)
            try replaceData(chain, account: chainAccount)
            try replaceData(leaf, account: leafAccount)
            let identity = try load()
            try? FileManager.default.removeItem(at: chainURL)
            try? FileManager.default.removeItem(at: leafURL)
            try? FileManager.default.removeItem(at: directory)
            return identity
        } catch {
            deleteStoredIdentity()
            throw error
        }
    }

    static func deleteStoredIdentity() {
        SecItemDelete(privateKeyQuery() as CFDictionary)
        for account in [chainAccount, leafAccount] {
            SecItemDelete(dataQuery(account: account) as CFDictionary)
        }
    }

    private static func stagingDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsUnavailable
        }
        return documents.appendingPathComponent("IdentityImport", isDirectory: true)
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumIdentityFileSize else {
            throw StoreError.invalidStagingFile(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url, options: [.uncached])
        guard !data.isEmpty, data.count <= maximumIdentityFileSize else {
            throw StoreError.invalidStagingFile(url.lastPathComponent)
        }
        return data
    }

    private static func replacePrivateKey(_ representation: Data) throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw StoreError.invalidPrivateKey
        }
        SecItemDelete(privateKeyQuery() as CFDictionary)
        var query = privateKeyQuery()
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueRef] = key
        try requireSuccess(SecItemAdd(query as CFDictionary, nil))
    }

    private static func readPrivateKey() throws -> SecKey {
        var query = privateKeyQuery()
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { throw StoreError.identityMissing }
        try requireSuccess(status)
        guard let key = value as! SecKey? else { throw StoreError.invalidPrivateKey }
        return key
    }

    private static func replaceData(_ data: Data, account: String) throws {
        let base = dataQuery(account: account)
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData] = data
        try requireSuccess(SecItemAdd(query as CFDictionary, nil))
    }

    private static func readData(account: String) throws -> Data {
        var query = dataQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { throw StoreError.identityMissing }
        try requireSuccess(status)
        guard let data = value as? Data else { throw StoreError.invalidStoredIdentity }
        return data
    }

    private static func privateKeyQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
    }

    private static func dataQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private enum StoreError: LocalizedError {
        case documentsUnavailable
        case identityMissing
        case invalidStagingFile(String)
        case invalidPrivateKey
        case invalidStoredIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .documentsUnavailable: return CWL("App 的 Documents 目录不可用")
            case .identityMissing: return CWL("Keychain 中未存储 MFi 身份")
            case .invalidStagingFile(let name): return CWL("身份导入文件缺失或无效：{1}", [String(describing: name)])
            case .invalidPrivateKey: return CWL("导入的 P-256 私钥无效")
            case .invalidStoredIdentity: return CWL("已存储的 MFi 身份无效")
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?) ?? CWL("Keychain 错误 {1}", [String(describing: status)])
            }
        }
    }
}
