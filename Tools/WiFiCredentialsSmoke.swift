import Foundation
import Security

// Substitute the Security calls in this smoke-test executable only. This exercises
// entitlement errors deterministically without changing the developer's real Keychain.
private var items: [String: Data] = [:]
private var forcedStatus: OSStatus?
private var forcedAddStatus: OSStatus?

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if let forcedStatus { return forcedStatus }
    let account = (query as NSDictionary)[kSecAttrAccount] as! String
    guard let data = items[account] else { return errSecItemNotFound }
    result?.pointee = data as CFData
    return errSecSuccess
}

func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    if let forcedStatus { return forcedStatus }
    let account = (query as NSDictionary)[kSecAttrAccount] as! String
    guard items[account] != nil else { return errSecItemNotFound }
    items[account] = (attributes as NSDictionary)[kSecValueData] as? Data
    return errSecSuccess
}

func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if let forcedStatus { return forcedStatus }
    if let forcedAddStatus { return forcedAddStatus }
    let values = attributes as NSDictionary
    items[values[kSecAttrAccount] as! String] = values[kSecValueData] as? Data
    return errSecSuccess
}

func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    if let forcedStatus { return forcedStatus }
    let account = (query as NSDictionary)[kSecAttrAccount] as! String
    return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
}

enum ProtocolError: Error { case malformed(String) }

@main
enum WiFiCredentialsSmoke {
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        try WiFiCredentials.save("test-password", for: "normal")
        expect(!WiFiCredentials.isTemporary(for: "normal"), "Normal saves must use Keychain")
        expect(try WiFiCredentials.password(for: "normal") == "test-password", "Keychain read")

        forcedAddStatus = errSecMissingEntitlement
        try WiFiCredentials.save("add-fallback-password", for: "restricted-add")
        expect(WiFiCredentials.isTemporary(for: "restricted-add"), "Entitlement error while adding a new item")
        expect(items["restricted-add"] == nil, "Failed add must not persist a password")
        forcedAddStatus = nil

        forcedStatus = errSecMissingEntitlement
        try WiFiCredentials.save("temporary-password", for: "restricted")
        expect(WiFiCredentials.isTemporary(for: "restricted"), "Entitlement fallback")
        expect(items["restricted"] == nil, "Fallback must not persist a password")
        expect(try WiFiCredentials.password(for: "restricted") == "temporary-password", "Read temporary password")
        try WiFiCredentials.save("", for: "open")
        expect(try WiFiCredentials.password(for: "open") == "", "Open networks must retain an empty password")
        expect(WiFiCredentials.isTemporary(for: "open"), "Empty password is still temporary")

        forcedStatus = errSecInteractionNotAllowed
        do {
            try WiFiCredentials.save("replacement", for: "restricted")
            preconditionFailure("Unrelated Keychain errors must propagate")
        } catch let error as NSError {
            expect(error.code == Int(errSecInteractionNotAllowed), "Preserve error code")
        }
        expect(try WiFiCredentials.password(for: "restricted") == "temporary-password", "Failed save must preserve the active password")

        forcedStatus = nil
        try WiFiCredentials.save("persistent-password", for: "restricted")
        expect(!WiFiCredentials.isTemporary(for: "restricted"), "Successful save must clear temporary override")
        expect(try WiFiCredentials.password(for: "restricted") == "persistent-password", "Read migrated password")
        try WiFiCredentials.forget("restricted")
        expect(try WiFiCredentials.password(for: "restricted") == nil, "Delete persisted password")
        try WiFiCredentials.forget("open")
        expect(!WiFiCredentials.isTemporary(for: "open"), "Delete temporary password")
        print("Wi-Fi credential smoke tests passed")
    }
}
