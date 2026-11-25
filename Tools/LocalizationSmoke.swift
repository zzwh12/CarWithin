import Foundation

@main
struct LocalizationSmoke {
    static func main() {
        let english = CommandLine.arguments.contains("--expect-english")
        assert(CarWithinLanguage.isEnglish == english, "Unexpected bundle language: \(Bundle.main.preferredLocalizations)")
        assert(CWL("设置") == (english ? "Settings" : "设置"))
        let inserted = "Cafe {2}"
        let result = CWL("已保存 Wi-Fi 预设“{1}”", [inserted])
        assert(result.contains(inserted), "Arguments must not be reinterpreted as placeholders")
        assert(!result.contains("{1}"))
        assert(CWL("版本 {1}（{2}）", ["1.0.4", "16"]) == (english ? "Version 1.0.4 (16)" : "版本 1.0.4（16）"))
        assert(CWL("An unknown key") == "An unknown key")
        let page = String(decoding: BrowserReceiverPage.html, as: UTF8.self)
        assert(!page.contains("\\#(version)"), "Page version must be expanded")
        assert(page.contains("const PAGE_VERSION='" + BrowserReceiverPage.version + "'"))
        assert(page.contains(english ? "Connecting to CarWithin…" : "正在连接 CarWithin…"))
        print("Localization lookup, language selection, fallback and parameter checks passed: \(Bundle.main.preferredLocalizations)")
    }
}
