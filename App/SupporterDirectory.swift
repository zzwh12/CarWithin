import Foundation

/// Shared public format. Payment evidence and transaction identifiers never belong in this file.
struct SupporterDirectory: Codable {
    let schemaVersion: Int
    let revision: Int
    let updatedAt: String
    let supporters: [Supporter]
    let contributors: [Contributor]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision, updatedAt = "updated_at", supporters, contributors
    }

    struct Supporter: Codable {
        let id: String
        let name: String
        let color: Color
        enum Color: String, Codable {
            case standard, green, blue, purple, gold
            var rank: Int {
                switch self {
                case .standard: return 1
                case .green: return 2
                case .blue: return 3
                case .purple: return 4
                case .gold: return 5
                }
            }
        }
        var tier: Int { color.rank }
    }

    struct Contributor: Codable {
        let name: String
        let contribution: String
        let category: String
        var github: String? = nil
    }

    // Code contributions ship with the app and remain visible across supporter-list refreshes.
    var appContributors: [Contributor] {
        let bundled = [
            Contributor(name: "yiquchangge1", contribution: "极核 SE+ 5/5.5 寸适配", category: "code", github: "yiquchangge1"),
            Contributor(name: "武汉", contribution: "极核 AE2 Pro 5 寸适配", category: "code", github: "yuliang-shuji"),
            Contributor(name: "Boos4721", contribution: "蚂蚁 ANT BMS 与电池卡片", category: "code", github: "Boos4721"),
            Contributor(name: "扫毒单位", contribution: "春风 5/6.2 寸适配", category: "code", github: "SDDW007")
        ]
        return bundled + contributors.filter { person in
            !bundled.contains { $0.name == person.name || (person.github != nil && $0.github == person.github) }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw DirectoryError.invalid }
        let directory = try JSONDecoder().decode(Self.self, from: data)
        guard directory.schemaVersion == 2, directory.revision > 0,
              directory.supporters.count <= 5000, directory.contributors.count <= 1000,
              Set(directory.supporters.map(\.id)).count == directory.supporters.count,
              directory.updatedAt.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              directory.supporters.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 })
        else { throw DirectoryError.invalid }
        return directory
    }
    enum DirectoryError: Error { case invalid }
}

/// Render bundled/cached content immediately, and replace only after a validated newer download.
@MainActor final class SupporterDirectoryStore {
    // A missing or invalid public file leaves the bundled/cached directory available.
    static let publishedURL = URL(string: "https://raw.githubusercontent.com/xmz28/support/main/supporters.json")!
    private let remoteURL: URL?
    private let cacheURL: URL
    private(set) var directory: SupporterDirectory?

    init(remoteURL: URL? = nil) {
        self.remoteURL = remoteURL ?? Self.publishedURL
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Supporters", isDirectory: true).appendingPathComponent("directory.json")
        let bundled = Bundle.main.url(forResource: "supporters", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? SupporterDirectory.decode($0) }
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? SupporterDirectory.decode($0) }
        directory = [bundled, cached].compactMap { $0 }.max(by: { $0.revision < $1.revision })
    }

    func refresh() async -> Bool {
        guard let remoteURL, remoteURL.scheme == "https" else { return false }
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return false }
            let next = try SupporterDirectory.decode(data)
            guard next.revision > (directory?.revision ?? 0) else { return false }
            // Memory can still update if storage is unavailable; existing cache is never replaced by bad data.
            directory = next
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return true
        } catch { return false }
    }
}
