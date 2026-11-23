import Foundation
import Darwin
import Security

struct ReceiverConfiguration {
    var name = "CarWithin"
    static let discoveryType = "_tds-carkit._tcp."
    var address: String
    var ssid: String
    var password: String
    var port: UInt16 = 7000
    var width = 1280
    var height = 720
    var maxFPS = 60
    var videoCodec: VideoCodec = .h264
    var wifiChannel: UInt8 = 36
    var audioEnabled = true
    var browserAudio = false
    var airPlayStreamID: UUID?
    var rightHandDrive = false
    var videoOutputPort: UInt16?
    /// HTTPS (WebCodecs) port; nil disables it. Defaults to the HTTP port + 1.
    var secureVideoOutputPort: UInt16?
    let deviceID: String
    /// Experimental CarLife output to a head unit; needs H.264 at or below 1920×1080.
    var carLifeEnabled = false
    /// Head unit IPv4 for CarLife discovery; nil sweeps the local network.
    var carLifeAddress: String?
    var carbitAddress: String?
    var zeehoAddress: String?
    var ninebotAddress: String?
    var tailingAddress: String?
    var tailingPhoneInfo: TailingPhoneInfo?
    var carLinkRelayAddress: String?
    static let carLinkRelayPort: UInt16 = 24890
    /// Physical width declared to the iPhone; larger values fit more (smaller) icons per page.
    var widthPhysicalMM = CarPlayInfo.defaultWidthPhysicalMM
    var browserPerformance: BrowserPerformance = .auto
    var showTouches = false
    /// Square PNG (≤ 192 px) for the car button on the CarPlay home screen; nil hides it.
    var oemIconPNG: Data?
    var oemIconLabel = "CarWithin"

    /// Choices for "CarPlay 图标大小", as declared screen widths (OpenXPlay offers the same four).
    static let iconSizes: [(title: String, widthMM: Int)] = [("大", 125), ("默认", 200), ("较小", 250), ("最小", 300)]

    /// CarPlay day/night appearance. Raw values are persisted.
    enum Appearance: Int, CaseIterable {
        case system = 0, light = 1, dark = 2
        var title: String { ["跟随系统", "白天", "夜间"][rawValue] }
    }

    struct Resolution { let label: String; let width: Int; let height: Int }
    /// Offered display sizes, landscape. Index order matches the settings control.
    static let resolutions = [
        Resolution(label: "480P", width: 800, height: 480),
        Resolution(label: "720P", width: 1280, height: 720),
        Resolution(label: "1080P", width: 1920, height: 1080),
        Resolution(label: "2K", width: 2560, height: 1440),
        Resolution(label: "4K", width: 3840, height: 2160)
    ]
    static let defaultResolutionIndex = 1

    struct AspectRatio {
        let width: Int
        let height: Int
        var title: String { "\(width):\(height)" }
    }
    static let aspectRatios = [
        AspectRatio(width: 16, height: 9), .init(width: 16, height: 10),
        .init(width: 4, height: 3), .init(width: 3, height: 2), .init(width: 1, height: 1),
        .init(width: 21, height: 9), .init(width: 32, height: 9),
        .init(width: 3, height: 1), .init(width: 4, height: 1),
        .init(width: 3, height: 4), .init(width: 9, height: 16), .init(width: 9, height: 19),
        .init(width: 9, height: 20), .init(width: 1, height: 3), .init(width: 1, height: 4)
    ]

    /// Treat the resolution tier as a pixel budget. Align both edges for video encoding.
    static func fixedDisplaySize(area: Int, ratio: AspectRatio, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        let aspect = min(max(Double(ratio.width) / Double(ratio.height), 320 / Double(maxHeight)),
                         Double(maxWidth) / 320)
        let height = max(320, 320 / aspect, min(Double(maxHeight), Double(maxWidth) / aspect,
                                               (Double(area) / aspect).squareRoot()))
        return (min(maxWidth, max(320, Int(height * aspect / 2) * 2)),
                min(maxHeight, max(320, Int(height / 2) * 2)))
    }

    static func wifiIPv4Address() -> String? {
        localIPv4Addresses(interface: "en0").first
    }

    static func localIPv4Addresses(interface: String? = nil) -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard interface == nil || interface == name,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if interface != nil && (value.hasPrefix("169.254.") || value.hasPrefix("0.")) { continue }
                if name == "en0" { result.insert(value, at: 0) }
                else { result.append(value) }
            }
        }
        return result
    }

    static func persistentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "receiverDeviceID") { return existing }
        var random = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        random[0] = (random[0] | 2) & 0xfe
        let value = random.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(value, forKey: "receiverDeviceID")
        return value
    }

    func validate(requiresLocalAddress: Bool = true, requiresWiFiCredentials: Bool = true) throws {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else {
            throw ConfigurationError("请选择有效的 IPv4 地址。")
        }
        if requiresLocalAddress && !Self.localIPv4Addresses().contains(address) {
            throw ConfigurationError("请选择属于本机当前网络连接的 IP 地址。")
        }
        // Fixed presets or a size that follows the head unit: even, within 320…3840 per side and
        // at most 4K in area; frame rate 30–60 in steps of 5.
        guard (320...3840).contains(width), (320...3840).contains(height), width % 2 == 0, height % 2 == 0,
              width * height <= 3840 * 2160,
              (30...60).contains(maxFPS), maxFPS % 5 == 0, (100...400).contains(widthPhysicalMM) else {
            throw ConfigurationError("请选择受支持的分辨率和帧率。")
        }
        if let carLifeAddress {
            var parsedCarLife = in_addr()
            guard inet_pton(AF_INET, carLifeAddress, &parsedCarLife) == 1 else {
                throw ConfigurationError("CarLife 车机 IP 地址无效，请填写 IPv4 地址或留空。")
            }
        }
        if let carbitAddress, !CarbitConnectionCode.isLocalAddress(carbitAddress) || carbitAddress == address {
            throw ConfigurationError("请在亿连输出设置中选择车机或填写它的局域网 IPv4 地址。")
        }
        if let zeehoAddress {
            var target = in_addr()
            guard inet_pton(AF_INET, zeehoAddress, &target) == 1, zeehoAddress != address,
                  !zeehoAddress.hasPrefix("127."), !zeehoAddress.hasPrefix("0."),
                  !zeehoAddress.hasPrefix("169.254."), UInt32(bigEndian: target.s_addr) < 0xe0000000 else {
                throw ConfigurationError("请输入有效的极核仪表 IPv4 地址，与本机 IP 不同。")
            }
        }
        if let ninebotAddress {
            var target = in_addr()
            guard inet_pton(AF_INET, ninebotAddress, &target) == 1, ninebotAddress != address,
                  !ninebotAddress.hasPrefix("127."), !ninebotAddress.hasPrefix("0."),
                  !ninebotAddress.hasPrefix("169.254."), UInt32(bigEndian: target.s_addr) < 0xe0000000 else {
                throw ConfigurationError("请输入有效的九号仪表 IPv4 地址，与本机 IP 不同。")
            }
        }
        if let tailingAddress {
            var target = in_addr()
            guard inet_pton(AF_INET, tailingAddress, &target) == 1, tailingAddress != address,
                  !tailingAddress.hasPrefix("127."), !tailingAddress.hasPrefix("0."),
                  UInt32(bigEndian: target.s_addr) < 0xe0000000 else {
                throw ConfigurationError("请输入有效的台铃仪表 IPv4 地址，与本机 IP 不同。")
            }
        }
        if let carLinkRelayAddress {
            var address = in_addr()
            guard inet_pton(AF_INET, carLinkRelayAddress, &address) == 1 else {
                throw ConfigurationError("请输入 CarLink 中继的 IPv4 地址。")
            }
        }
        guard requiresWiFiCredentials else { return }
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            throw ConfigurationError(ssid.isEmpty ? "启动前请输入 Wi-Fi 名称。" : "Wi-Fi 名称不能超过 32 个 UTF-8 字节。")
        }
        guard password.isEmpty || (8...63).contains(password.utf8.count) else {
            throw ConfigurationError("请输入 8–63 字节的 Wi-Fi 密码，开放网络则留空。")
        }
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
