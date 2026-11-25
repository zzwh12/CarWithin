import Foundation
import Security

enum HTTPSConfiguration {
    enum Mode: Int { case local, sslip, duckDNS }
    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.integer(forKey: "httpsMode")) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "httpsMode") }
    }
    static var domain: String {
        get { UserDefaults.standard.string(forKey: "httpsDuckDomain") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "httpsDuckDomain") }
    }
    static func normalizedDomain(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.duckdns\\.org$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func host(address: String) -> String? {
        switch mode {
        case .local: return address
        case .sslip: return address.replacingOccurrences(of: ".", with: "-") + ".sslip.io"
        case .duckDNS: return normalizedDomain(domain)
        }
    }
    static func secret(_ name: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(name).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ConfigurationError(CWL("无法读取 HTTPS 安全配置。")) }
        return result as? Data
    }
    static func saveSecret(_ data: Data, name: String) throws {
        let query = query(name)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            let status = SecItemAdd(query.merging([kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw ConfigurationError(CWL("无法安全保存 HTTPS 配置。")) }
        } else if status != errSecSuccess { throw ConfigurationError(CWL("无法安全保存 HTTPS 配置。")) }
    }
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CarWithin.HTTPS", kSecAttrAccount as String: name]
    }
    static func importCertificate(_ data: Data, password: String) throws {
        guard let host = normalizedDomain(domain) else { throw ConfigurationError(CWL("请先填写有效的 DuckDNS 域名。")) }
        _ = try identity(data: data, password: password, host: host)
        let package = try PropertyListSerialization.data(fromPropertyList: ["data": data, "password": password], format: .binary, options: 0)
        try saveSecret(package, name: "certificate")
    }
    static func certificateIdentity() throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        guard let host = normalizedDomain(domain), let data = try secret("certificate"),
              let package = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let certificate = package["data"] as? Data, let password = package["password"] as? String else {
            throw ConfigurationError(CWL("请在 HTTPS 设置中配置 DuckDNS 域名并导入公开受信任的 P12 证书。"))
        }
        return try identity(data: certificate, password: password, host: host)
    }
    private static func identity(data: Data, password: String, host: String) throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        guard data.count <= 512 * 1024 else { throw ConfigurationError(CWL("证书文件过大。")) }
        var result: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]], items.count == 1,
              let rawIdentity = items[0][kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID(),
              let chain = items[0][kSecImportItemCertChain as String] as? [SecCertificate], !chain.isEmpty else {
            throw ConfigurationError(CWL("无法读取 P12 证书，请检查文件和密码，并包含完整证书链及私钥。"))
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            throw ConfigurationError(CWL("证书未通过系统信任、域名或有效期校验，请导入该域名的完整公开证书链。"))
        }
        return (rawIdentity as! SecIdentity, chain)
    }
    static func updateDNS(address: String) async throws {
        guard let domain = normalizedDomain(domain), let data = try secret("duckToken"),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw ConfigurationError(CWL("请填写 DuckDNS 域名和 Token。"))
        }
        var url = URLComponents(string: "https://www.duckdns.org/update")!
        url.queryItems = [URLQueryItem(name: "domains", value: String(domain.dropLast(".duckdns.org".count))),
                          URLQueryItem(name: "token", value: token), URLQueryItem(name: "ip", value: address)]
        do {
            let (body, response) = try await URLSession.shared.data(for: URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                throw ConfigurationError(CWL("DuckDNS 拒绝更新，请检查域名和 Token。"))
            }
        } catch let error as ConfigurationError { throw error }
        catch { throw ConfigurationError(CWL("无法连接 DuckDNS，请检查互联网连接后重试。")) }
    }
}
