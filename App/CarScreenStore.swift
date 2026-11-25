import Foundation

/// A head-unit screen as reported by its browser page.
struct CarScreen: Codable, Equatable {
    var width: Int
    var height: Int
    var devicePixelRatio: Double
    var refreshHz: Int
    var supportsH265: Bool
    var lastUsed: Date
    var profileKey: String?
    var iconWidthMM: Int?
    var key: String { profileKey ?? "\(width)x\(height)" }
    var title: String { "\(width) × \(height)\(refreshHz > 0 ? " · \(refreshHz) Hz" : "")" }
    var subtitle: String {
        CWL("像素比 {1} · H.265 {2} · 上次使用 ", [String(describing: String(format: "%g", devicePixelRatio)), String(describing: supportsH265 ? CWL("可硬解") : CWL("不可硬解"))])
            + DateFormatter.localizedString(from: lastUsed, dateStyle: .short, timeStyle: .short)
    }
}

/// Screens seen by "跟随车机", newest first. Stored in UserDefaults (no personal data).
enum CarScreenStore {
    private static let screensKey = "carScreens"
    private static let defaultKey = "carScreenDefault"
    private static let maximum = 8

    static func screens() -> [CarScreen] {
        guard let data = UserDefaults.standard.data(forKey: screensKey),
              let list = try? JSONDecoder().decode([CarScreen].self, from: data) else { return [] }
        return list.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// The screen the user ticked, else the most recently used one.
    static func preferred() -> CarScreen? {
        let list = screens()
        if let key = UserDefaults.standard.string(forKey: defaultKey), let chosen = list.first(where: { $0.key == key }) { return chosen }
        return list.first
    }

    static var defaultKeyValue: String? { UserDefaults.standard.string(forKey: defaultKey) }

    @discardableResult
    static func record(_ display: BrowserDisplay) -> CarScreen {
        let profileKey = profileKey(for: display)
        let listBeforeUpdate = screens()
        let legacyKey = "\(display.width)x\(display.height)"
        let legacy = listBeforeUpdate.first { $0.profileKey == nil && $0.key == legacyKey }
        let existing = listBeforeUpdate.first { $0.key == (profileKey ?? legacyKey) } ?? legacy
        let screen = CarScreen(width: display.width, height: display.height, devicePixelRatio: display.devicePixelRatio,
                               refreshHz: display.refreshHz, supportsH265: display.supportsH265, lastUsed: Date(),
                               profileKey: profileKey, iconWidthMM: existing?.iconWidthMM)
        var list = listBeforeUpdate.filter { $0.key != screen.key && $0.key != legacy?.key }
        list.insert(screen, at: 0)
        save(Array(list.prefix(maximum)))
        if let legacy, defaultKeyValue == legacy.key { setDefault(screen.key) }
        return screen
    }

    private static func profileKey(for display: BrowserDisplay) -> String? {
        guard let w = display.screenWidth, let h = display.screenHeight else { return nil }
        let scale = Int((display.devicePixelRatio * 100).rounded())
        return "screen:\(min(w, h))x\(max(w, h))@\(scale)"
    }

    static func setIconWidth(_ width: Int?, for key: String) {
        var list = screens()
        guard let index = list.firstIndex(where: { $0.key == key }) else { return }
        list[index].iconWidthMM = width
        save(list)
    }

    static func setDefault(_ key: String?) { UserDefaults.standard.set(key, forKey: defaultKey) }

    static func remove(_ key: String) {
        save(screens().filter { $0.key != key })
        if defaultKeyValue == key { setDefault(nil) }
    }

    private static func save(_ list: [CarScreen]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: screensKey) }
    }
}
