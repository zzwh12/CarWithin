import Foundation

/// Reads connection hints locally. A download URL or an opaque pairing token is not an endpoint.
struct CarbitConnectionCode {
    static let serviceType = "_EasyConn._tcp."
    let address: String?
    let ssid: String?

    static func isLocalAddress(_ text: String) -> Bool {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let octets = fields.compactMap { UInt8($0) }
        guard octets.count == 4, octets.map({ String($0) }).joined(separator: ".") == text else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
               (octets[0] == 192 && octets[1] == 168)
    }

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        var host: String?
        if text.utf8.count <= 8192 {
            if Self.isLocalAddress(text) {
                host = text
            } else if text.hasPrefix("WIFI:") {
                // The Wi-Fi QR format escapes semicolons and backslashes in field values.
                var field = ""
                var escaped = false
                for character in text.dropFirst(5) {
                    if escaped {
                        field.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == ";" {
                        if field.hasPrefix("S:") { fields["ssid"] = String(field.dropFirst(2)); break }
                        field = ""
                    } else {
                        field.append(character)
                    }
                }
            } else if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                for (key, value) in object { fields[key.lowercased()] = value as? String }
            } else if let url = URLComponents(string: text) {
                host = url.host
                for item in url.queryItems ?? [] { fields[item.name.lowercased()] = item.value }
            }
        }
        address = [fields["huip"], fields["ip"], fields["host"], fields["address"], host]
            .compactMap { $0 }.first(where: Self.isLocalAddress)
        ssid = [fields["ssid"], fields["wifiname"]].compactMap { $0 }.first {
            !$0.isEmpty && $0.utf8.count <= 32 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}
