// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingIdentity.swift
import Foundation
import Security

/// 官方 iOS 样本为 RSA2048；只保存本 App 自己的身份，不复用官方身份或会话密文。
struct TailingIdentity {
    let key: SecKey
    let phoneID: String

    static func load() throws -> TailingIdentity {
        let service = (Bundle.main.bundleIdentifier ?? "com.hanlinzhou.SameDeviceCarPlayPoC") + ".tailing.identity.v1"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "identity"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var stored: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &stored)
        if status == errSecSuccess {
            guard let data = stored as? Data,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let id = object["phoneID"], UUID(uuidString: id) != nil,
                  let encoded = object["key"], let bytes = Data(base64Encoded: encoded) else {
                throw TailingError.protocolFailure("本机身份存储损坏")
            }
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(bytes as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
                throw error!.takeRetainedValue()
            }
            return TailingIdentity(key: key, phoneID: id)
        }
        guard status == errSecItemNotFound else { throw TailingError.system("读取本机身份", status) }
        let identity = try generate()
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(identity.key, &error) else { throw error!.takeRetainedValue() }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = try TailingProtocol.json([
            "phoneID": identity.phoneID, "key": (bytes as Data).base64EncodedString()
        ])
        let saved = SecItemAdd(item as CFDictionary, nil)
        // 两个同时启动的会话不能各用一个新身份。
        if saved == errSecDuplicateItem { return try load() }
        guard saved == errSecSuccess else { throw TailingError.system("保存本机身份", saved) }
        return identity
    }

    static func generate() throws -> TailingIdentity {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        return TailingIdentity(key: key, phoneID: UUID().uuidString)
    }

    func publicKey() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw TailingError.protocolFailure("无法读取本机公钥")
        }
        // Security 导出 PKCS#1；线上 pubkey 为 X.509 SubjectPublicKeyInfo。
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = Self.der(0x03, Data([0]) + (raw as Data))
        return Self.der(0x30, algorithm + bitString)
    }

    func sign(_ huid: String) throws -> Data {
        let message = Data(huid.utf8)
        guard !message.isEmpty, message.count <= SecKeyGetBlockSize(key) - 11 else {
            throw TailingError.protocolFailure("仪表身份长度异常")
        }
        // 协议是原始 HUID 加 PKCS#1 type 1 填充，不是 SHA 摘要签名。
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, message as CFData, &error) else {
            throw error!.takeRetainedValue()
        }
        return signature as Data
    }

    func verify(_ signature: Data, huid: String) throws {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw TailingError.protocolFailure("本机公钥缺失") }
        let message = Data(huid.utf8)
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15Raw,
                                   message as CFData, signature as CFData, &error) else {
            throw TailingError.protocolFailure("媒体通道身份回显校验失败")
        }
    }

    private static func der(_ tag: UInt8, _ payload: Data) -> Data {
        var header = Data([tag])
        if payload.count < 128 { header.append(UInt8(payload.count)) }
        else if payload.count < 256 { header.append(contentsOf: [0x81, UInt8(payload.count)]) }
        else { header.append(contentsOf: [0x82, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        return header + payload
    }
}
