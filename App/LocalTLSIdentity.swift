import Foundation
import Security
import CryptoKit

/// HTTPS identity with a device-local CA, retained when the phone's IP changes.
enum LocalTLSIdentity {
    private static let keyTag = Data("com.carplays.browser-https.key".utf8)
    /// Internal Keychain label from before the rename; kept so the trusted certificate survives updates.
    private static let certificateLabel = CWL("CarPlays 浏览器 HTTPS")
    private static let rootTag = Data("com.carwithin.browser-https.root".utf8)
    private static let rootLabel = "CarWithin HTTPS Root"
    private static let addressesKey = "browserHTTPSAddresses.v2"
    private static let expiryKey = "browserHTTPSExpiry.v2"
    private static let validityDays = 397

    struct Result { let identity: SecIdentity; let rootDER: Data; let created: Bool; var chain: [SecCertificate] = [] }

    /// Returns a usable identity covering `addresses`, creating or renewing it when needed.
    static func load(addresses: [String]) throws -> Result {
        if HTTPSConfiguration.mode == .duckDNS {
            let material = try HTTPSConfiguration.certificateIdentity()
            return Result(identity: material.identity, rootDER: Data(), created: false, chain: material.chain)
        }
        let addresses = HTTPSConfiguration.mode == .sslip
            ? addresses + addresses.map { $0.replacingOccurrences(of: ".", with: "-") + ".sslip.io" } : addresses
        let defaults = UserDefaults.standard
        let (rootKey, rootDER) = try loadRoot()
        let covered = Set(defaults.stringArray(forKey: addressesKey) ?? [])
        let expiry = defaults.object(forKey: expiryKey) as? Date ?? .distantPast
        if Set(addresses).isSubset(of: covered), expiry.timeIntervalSinceNow > 30 * 86_400,
           let existing = try? findIdentity() {
            return Result(identity: existing.identity, rootDER: rootDER, created: false)
        }
        let wanted = Array(Set(addresses)).sorted()
        let created = try create(addresses: wanted, rootKey: rootKey)
        defaults.set(wanted, forKey: addressesKey)
        defaults.set(created.expiry, forKey: expiryKey)
        return Result(identity: created.identity, rootDER: rootDER, created: true)
    }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Keychain

    /// iOS only has the data-protection keychain; on macOS this keeps test runs out of the login keychain.
    private static let keychain: [CFString: Any] = [kSecUseDataProtectionKeychain: true]

    private static func findCertificate(label: String) throws -> SecCertificate {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keychain.merging([kSecClass: kSecClassCertificate, kSecAttrLabel: label,
                                          kSecReturnRef: true]) { $1 } as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecCertificateGetTypeID() else {
            throw TLSIdentityError.keychain(CWL("查找证书"), status)
        }
        return item as! SecCertificate
    }

    private static func findIdentity() throws -> (identity: SecIdentity, certificate: SecCertificate) {
        let certificate = try findCertificate(label: certificateLabel)
        return (try identity(for: certificate), certificate)
    }

    /// Identities pair a stored certificate with the private key of the same public key hash.
    private static func identity(for certificate: SecCertificate) throws -> SecIdentity {
        let der = SecCertificateCopyData(certificate) as Data
        var identities: CFTypeRef?
        let found = SecItemCopyMatching(keychain.merging([kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll,
                                         kSecReturnRef: true]) { $1 } as CFDictionary, &identities)
        guard found == errSecSuccess, let list = identities as? [SecIdentity] else { throw TLSIdentityError.keychain(CWL("查找身份"), found) }
        for identity in list {
            var candidate: SecCertificate?
            if SecIdentityCopyCertificate(identity, &candidate) == errSecSuccess, let candidate,
               SecCertificateCopyData(candidate) as Data == der { return identity }
        }
        throw TLSIdentityError.keychain(CWL("匹配私钥"), errSecItemNotFound)
    }

    private static func loadRoot() throws -> (SecKey, Data) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keychain.merging([
            kSecClass: kSecClassKey, kSecAttrApplicationTag: rootTag, kSecReturnRef: true
        ]) { $1 } as CFDictionary, &item)
        let key: SecKey
        if status == errSecItemNotFound {
            key = try createKey(tag: rootTag)
            SecItemDelete(keychain.merging([kSecClass: kSecClassCertificate, kSecAttrLabel: rootLabel]) { $1 } as CFDictionary)
            UserDefaults.standard.removeObject(forKey: expiryKey)
        } else {
            guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
                throw TLSIdentityError.keychain(CWL("读取 HTTPS 根证书私钥"), status)
            }
            key = item as! SecKey
        }
        if let cert = try? findCertificate(label: rootLabel) { return (key, SecCertificateCopyData(cert) as Data) }
        let (der, _) = try encodeCertificate(key: key, issuerKey: key, addresses: [], isRoot: true)
        _ = try storeCertificate(der, label: rootLabel)
        return (key, der)
    }

    private static func create(addresses: [String], rootKey: SecKey) throws -> (identity: SecIdentity, expiry: Date) {
        SecItemDelete(keychain.merging([kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel]) { $1 } as CFDictionary)
        SecItemDelete(keychain.merging([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag]) { $1 } as CFDictionary)
        let key = try createKey(tag: keyTag)
        let (der, notAfter) = try encodeCertificate(key: key, issuerKey: rootKey, addresses: addresses, isRoot: false)
        return (try identity(for: storeCertificate(der, label: certificateLabel)), notAfter)
    }

    private static func createKey(tag: Data) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(keychain.merging([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag,
                                  kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        ]) { $1 } as CFDictionary, &error) else { throw error!.takeRetainedValue() as Error }
        return key
    }

    private static func storeCertificate(_ der: Data, label: String) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TLSIdentityError.certificate(CWL("证书编码无效"))
        }
        let added = SecItemAdd(keychain.merging([kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label,
                                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw TLSIdentityError.keychain(CWL("保存证书"), added) }
        return certificate
    }

    private static func publicKeyPoint(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw TLSIdentityError.certificate(CWL("无法读取公钥"))
        }
        return point
    }

    private static func encodeCertificate(key: SecKey, issuerKey: SecKey, addresses: [String], isRoot: Bool)
        throws -> (der: Data, notAfter: Date) {
        let point = try publicKeyPoint(key)
        let issuerPoint = isRoot ? point : try publicKeyPoint(issuerKey)
        let suffix = SHA256.hash(data: issuerPoint).prefix(4).map { String(format: "%02X", $0) }.joined()
        let issuer = name("CarWithin HTTPS " + suffix)
        let notBefore = Date().addingTimeInterval(-3600)
        let notAfter = Date().addingTimeInterval((isRoot ? 3650 : 397) * 86_400)
        let tbs = tbsCertificate(publicKey: point, issuer: issuer, subject: isRoot ? issuer : name("CarWithin"),
                                 addresses: addresses, notBefore: notBefore, notAfter: notAfter, isRoot: isRoot)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(issuerKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return (DER.sequence(tbs + signatureAlgorithm + DER.bitString(signature)), notAfter)
    }

    private static func name(_ commonName: String) -> Data {
        DER.sequence(DER.set(DER.sequence(DER.oid([0x55, 0x04, 0x03]) + DER.utf8(commonName))))
    }

    private static let signatureAlgorithm = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))

    private static func tbsCertificate(publicKey: Data, issuer: Data, subject: Data, addresses: [String],
                                       notBefore: Date, notAfter: Date, isRoot: Bool) -> Data {
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] = (serial[0] & 0x7f) | 0x01
        let validity = DER.sequence(DER.utcTime(notBefore) + DER.utcTime(notAfter))
        let spki = DER.sequence(
            DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]) + DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])) +
            DER.bitString(publicKey))
        var names = DER.tagged(0x82, Data("localhost".utf8))
        for address in addresses {
            var raw = in_addr()
            if inet_pton(AF_INET, address, &raw) == 1 {
                names += DER.tagged(0x87, withUnsafeBytes(of: raw.s_addr) { Data($0) })
            } else if address.hasSuffix(".sslip.io") {
                names += DER.tagged(0x82, Data(address.utf8))
            }
        }
        let extensions = isRoot ? DER.sequence(
            DER.sequence(DER.oid([0x55, 0x1d, 0x13]) + DER.boolean(true) +
                         DER.octetString(DER.sequence(DER.boolean(true) + DER.integer(Data([0]))))) +
            DER.sequence(DER.oid([0x55, 0x1d, 0x0f]) + DER.boolean(true) + DER.octetString(Data([0x03, 0x02, 0x02, 0x04])))
        ) : DER.sequence(
            DER.sequence(DER.oid([0x55, 0x1d, 0x13]) + DER.boolean(true) + DER.octetString(DER.sequence(Data()))) +
            DER.sequence(DER.oid([0x55, 0x1d, 0x0f]) + DER.boolean(true) + DER.octetString(Data([0x03, 0x02, 0x07, 0x80]))) +
            DER.sequence(DER.oid([0x55, 0x1d, 0x25]) + DER.octetString(DER.sequence(DER.oid([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])))) +
            DER.sequence(DER.oid([0x55, 0x1d, 0x11]) + DER.octetString(DER.sequence(names))))
        return DER.sequence(
            DER.tagged(0xa0, DER.integer(Data([2]))) + DER.integer(Data(serial)) + signatureAlgorithm +
            issuer + validity + subject + spki + DER.tagged(0xa3, extensions))
    }

    private enum DER {
        static func tagged(_ tag: UInt8, _ content: Data) -> Data {
            var out = Data([tag])
            if content.count < 0x80 { out.append(UInt8(content.count)) }
            else {
                var length = content.count, bytes: [UInt8] = []
                while length > 0 { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
                out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
            }
            return out + content
        }
        static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
        static func set(_ content: Data) -> Data { tagged(0x31, content) }
        static func oid(_ bytes: [UInt8]) -> Data { tagged(0x06, Data(bytes)) }
        static func integer(_ bytes: Data) -> Data { tagged(0x02, bytes) }
        static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xff : 0x00])) }
        static func octetString(_ content: Data) -> Data { tagged(0x04, content) }
        static func bitString(_ content: Data) -> Data { tagged(0x03, Data([0]) + content) }
        static func utf8(_ text: String) -> Data { tagged(0x0c, Data(text.utf8)) }
        static func utcTime(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tagged(0x17, Data(formatter.string(from: date).utf8))
        }
    }

    enum TLSIdentityError: LocalizedError {
        case keychain(String, OSStatus), certificate(String)
        var errorDescription: String? {
            switch self {
            case .keychain(let step, let status): CWL("{1}失败（{2}）", [String(describing: step), String(describing: status)])
            case .certificate(let message): message
            }
        }
    }
}

extension LocalTLSIdentity {
    static func profile(root: Data) throws -> Data {
        let id = fingerprint(root).replacingOccurrences(of: ":", with: "").prefix(16)
        let identifier = "com.carwithin.https.\(id)"
        let certificate: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadUUID": UUID().uuidString, "PayloadIdentifier": identifier + ".root",
            "PayloadDisplayName": CWL("CarWithin HTTPS 根证书"), "PayloadContent": root
        ]
        let configuration: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadUUID": UUID().uuidString, "PayloadIdentifier": identifier,
            "PayloadDisplayName": "CarWithin HTTPS", "PayloadContent": [certificate]
        ]
        return try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
    }

    static func setupPage(root: Data, port: UInt16) -> Data {
        Data("""
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>CarWithin HTTPS</title><style>
        :root{color-scheme:light dark}body{max-width:40rem;margin:3rem auto;padding:0 1rem;font:16px/1.6 system-ui}
        code{overflow-wrap:anywhere}li{margin:.75rem 0}
        </style>
        <h1>\(CWL("配置 CarWithin HTTPS"))</h1>
        <ol>
        <li>\(CWL("在 CarWithin 的日志中核对根证书 SHA-256"))<br><code>\(fingerprint(root))</code></li>
        <li>iPhone / iPad：<a href="/carwithin.mobileconfig">\(CWL("下载描述文件"))</a>\(CWL("，在「设置」安装。之后进入「通用 → 关于本机 → 证书信任设置」，为该证书启用完全信任。"))</li>
        <li>Android：<a href="/carwithin.crt" download>\(CWL("下载 CA 证书"))</a>\(CWL("，在系统「设置」搜索「安装证书」，选择「CA 证书」，安装下载的文件。不同机型的菜单名称可能不同。安装后用支持系统用户证书的浏览器打开 HTTPS 接收页。"))</li>
        </ol>
        <p><a id="play" href="/">\(CWL("打开 HTTPS 接收页"))</a> · <a href="/">\(CWL("使用 HTTP 接收页"))</a></p>
        <script>document.getElementById('play').href='https://'+location.hostname+':\(port)/';</script>
        </html>
        """.utf8)
    }
}
