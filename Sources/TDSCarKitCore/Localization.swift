import Foundation

/// Chinese is the fallback for unsupported languages and non-app test hosts.
public enum CarWithinLanguage {
    static let argumentPattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public static var isEnglish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
    }
}

/// Expand numbered arguments in one pass so user content containing {1} stays intact.
public func CWL(_ key: String, _ arguments: [String] = []) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    let expression = CarWithinLanguage.argumentPattern
    var result = format
    for match in expression.matches(in: format, range: NSRange(format.startIndex..., in: format)).reversed() {
        guard let range = Range(match.range(at: 1), in: format),
              let index = Int(format[range]), arguments.indices.contains(index - 1),
              let whole = Range(match.range, in: result) else { continue }
        result.replaceSubrange(whole, with: arguments[index - 1])
    }
    return result
}
