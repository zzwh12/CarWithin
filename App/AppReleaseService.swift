import Foundation
import CryptoKit

struct AppRelease: Decodable, Identifiable, Sendable {
    struct Asset: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let size: Int64
        let browser_download_url: URL
        let digest: String?

        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let value = String(digest.dropFirst(7)).lowercased()
            return value.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            } ? value : nil
        }
    }

    let id: Int
    let tag_name: String
    let name: String?
    let body: String?
    let published_at: Date?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var update: IOSUpdateMetadata?

    static let repository = URL(string: "https://github.com/xmz28/CarWithin")!
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var pageURL: URL { Self.repository.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }
    var isStable: Bool { !draft && !prerelease && ReleaseVersion(version) != nil }
    var ipa: Asset? {
        let expected = Self.repository.appendingPathComponent("releases/download").appendingPathComponent(tag_name)
        return assets.first {
            (update == nil || $0.name == update?.ipaName) && $0.name.lowercased().hasSuffix(".ipa") && !$0.name.contains("/") && !$0.name.contains("\\")
                && $0.size > 0 && $0.size <= 500 * 1024 * 1024
                && $0.browser_download_url == expected.appendingPathComponent($0.name)
        }
    }
}

struct IOSUpdateMetadata: Codable, Sendable {
    let schemaVersion: Int
    let product: String
    let platform: String
    let version: String
    let build: Int
    let minimumOSVersion: String
    let releaseTag: String
    let ipaName: String
    let size: Int64
    let sha256: String
    let notes: String
    var notesEn: String? = nil

    func localizedNotes(english: Bool = CarWithinLanguage.isEnglish) -> String {
        guard english, let translated = notesEn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else { return notes }
        return translated
    }

    func validate(for release: AppRelease) throws {
        var specifiedRelease = release
        specifiedRelease.update = self
        guard schemaVersion == 1, product == "CarWithin", platform == "ios", build > 0,
              ReleaseVersion(version) != nil, version == release.version, releaseTag == release.tag_name,
              ReleaseVersion(minimumOSVersion) != nil, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              release.assets.filter({ $0.name == ipaName }).count == 1,
              let ipa = specifiedRelease.ipa, ipa.name == ipaName, ipa.size == size,
              ipa.digest == nil || ipa.sha256 == sha256 else { throw ReleaseError.invalid }
    }
}

struct ReleaseVersion: Comparable {
    let components: [Int]
    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum ReleaseError: LocalizedError {
    case missing, missingMetadata, invalid, response(Int), checksum, fileSize

    var errorDescription: String? {
        switch self {
        case .missing: return CWL("GitHub 暂无公开版本。")
        case .missingMetadata: return CWL("当前公开版本尚未提供 ios-update.json，请在 GitHub 查看发布记录。")
        case .invalid: return CWL("版本信息无效，请查看 GitHub 发布记录。")
        case .response(let status) where status == 403 || status == 429:
            return CWL("GitHub 暂时限制了请求，请稍后重试。")
        case .response(let status): return CWL("服务器返回 {1}，请稍后重试。", [String(describing: status)])
        case .checksum: return CWL("文件校验失败，请重新下载。")
        case .fileSize: return CWL("下载文件大小异常，请重新下载。")
        }
    }
}

struct AppReleaseService {
    struct Page {
        let releases: [AppRelease]
        let hasNext: Bool
    }
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func latest() async throws -> AppRelease {
        var release = try await publishedLatest()
        let manifests = release.assets.filter { $0.name == "ios-update.json" }
        guard !manifests.isEmpty else { throw ReleaseError.missingMetadata }
        let address = AppRelease.repository.appendingPathComponent("releases/download")
            .appendingPathComponent(release.tag_name).appendingPathComponent("ios-update.json")
        guard manifests.count == 1, manifests[0].browser_download_url == address,
              manifests[0].size > 0, manifests[0].size <= 128 * 1024 else { throw ReleaseError.invalid }
        // Fetch on every actual check, even when already current. The attachment's download_count
        // is only an approximate request count, not unique users or guaranteed successful checks.
        let (metadataData, _) = try await read(address.absoluteString)
        guard metadataData.count <= 128 * 1024 else { throw ReleaseError.invalid }
        let metadata = try JSONDecoder().decode(IOSUpdateMetadata.self, from: metadataData)
        try metadata.validate(for: release)
        release.update = metadata
        if let index = release.assets.firstIndex(where: { $0.name == metadata.ipaName }) {
            var assets = release.assets
            let ipa = assets[index]
            assets[index] = AppRelease.Asset(id: ipa.id, name: ipa.name, size: ipa.size,
                                           browser_download_url: ipa.browser_download_url, digest: "sha256:" + metadata.sha256)
            release = AppRelease(id: release.id, tag_name: release.tag_name, name: release.name, body: release.body,
                                 published_at: release.published_at, draft: release.draft, prerelease: release.prerelease,
                                 assets: assets, update: metadata)
        }
        return release
    }

    // Browsing history must not download the manifest or inflate its check-count proxy.
    func latestTag() async throws -> String { try await publishedLatest().tag_name }

    private func publishedLatest() async throws -> AppRelease {
        let (data, _) = try await read("https://api.github.com/repos/xmz28/CarWithin/releases/latest")
        let release = try Self.decoder().decode(AppRelease.self, from: data)
        guard release.isStable else { throw ReleaseError.invalid }
        return release
    }

    func history(page: Int) async throws -> Page {
        let (data, response) = try await read("https://api.github.com/repos/xmz28/CarWithin/releases?per_page=30&page=\(page)")
        let releases = try Self.decoder().decode([AppRelease].self, from: data).filter(\.isStable)
        return Page(releases: releases, hasNext: response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true)
    }

    private func read(_ address: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CarWithin-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReleaseError.invalid }
        if http.statusCode == 404 { throw ReleaseError.missing }
        guard http.statusCode == 200 else { throw ReleaseError.response(http.statusCode) }
        guard data.count < 4 * 1024 * 1024 else { throw ReleaseError.invalid }
        return (data, http)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func verify(_ file: URL, asset: AppRelease.Asset) throws {
        guard asset.digest == nil || asset.sha256 != nil else { throw ReleaseError.invalid }
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? 0) == asset.size else { throw ReleaseError.fileSize }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        var first = true
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            if first {
                guard bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw ReleaseError.invalid }
                first = false
            }
            digest.update(data: bytes)
        }
        guard !first else { throw ReleaseError.invalid }
        if let expected = asset.sha256 {
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw ReleaseError.checksum }
        }
    }
}

struct AppUpdatePolicy {
    static let interval: TimeInterval = 24 * 60 * 60
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private let prefix = "carwithin.updates."

    func shouldCheck(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let retry = defaults.double(forKey: prefix + "retry")
        let checked = defaults.double(forKey: prefix + "checked")
        let snooze = defaults.double(forKey: prefix + "snooze")
        return now >= retry && now >= snooze && (now < checked || now - checked >= Self.interval)
    }
    func succeeded(now: TimeInterval = Date().timeIntervalSince1970) {
        defaults.set(now, forKey: prefix + "checked")
        defaults.removeObject(forKey: prefix + "retry")
    }
    func failed(now: TimeInterval = Date().timeIntervalSince1970) {
        defaults.set(now + 15 * 60, forKey: prefix + "retry")
    }
    func shouldOffer(_ release: AppRelease, installedBuild: Int) -> Bool {
        guard let update = release.update else { return false }
        return update.build > installedBuild && defaults.string(forKey: prefix + "ignoredBuild") != String(update.build)
    }
    func snooze() { defaults.set(Date().timeIntervalSince1970 + Self.interval, forKey: prefix + "snooze") }
    func ignore(_ release: AppRelease) {
        if let build = release.update?.build { defaults.set(String(build), forKey: prefix + "ignoredBuild") }
    }
}
