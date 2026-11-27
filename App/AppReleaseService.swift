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

    private static let repositoryPath = "zzwh12/CarWithin"
    static let repository = URL(string: "https://github.com/\(repositoryPath)")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/\(repositoryPath)/releases")!
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var pageURL: URL { Self.repository.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }
    var isStable: Bool { !draft && !prerelease && ReleaseVersion(version) != nil }
    var ipa: Asset? {
        let expected = Self.repository.appendingPathComponent("releases/download").appendingPathComponent(tag_name)
        return assets.first {
            $0.name.lowercased().hasSuffix(".ipa") && !$0.name.contains("/") && !$0.name.contains("\\")
                && $0.size > 0 && $0.size <= 500 * 1024 * 1024
                && $0.browser_download_url == expected.appendingPathComponent($0.name)
        }
    }
}

struct ReleaseVersion: Equatable {
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
}

enum ReleaseError: LocalizedError {
    case missing, invalid, response(Int), checksum, fileSize

    var errorDescription: String? {
        switch self {
        case .missing: return CWL("GitHub 暂无公开版本。")
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

    func history(page: Int) async throws -> Page {
        var components = URLComponents(url: AppRelease.releasesAPI, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "30"), URLQueryItem(name: "page", value: String(page))]
        let (data, response) = try await read(components.url!)
        let releases = try Self.decoder().decode([AppRelease].self, from: data).filter(\.isStable)
        return Page(releases: releases, hasNext: response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true)
    }

    private func read(_ address: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
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
