import Foundation

final class ReleaseStub: URLProtocol {
    static var responses: [String: (Int, Data)] = [:]
    static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url.absoluteString)
        let (status, data) = Self.responses[url.absoluteString] ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct ReleaseHistorySmoke {
    static func main() async throws {
        let api = "https://api.github.com/repos/zzwh12/CarWithin/releases?per_page=30&page="
        let downloads = "https://github.com/zzwh12/CarWithin/releases/download/v1.0.5/"
        let checksum = String(repeating: "a", count: 64)
        let asset: [String: Any] = ["id": 1, "name": "CarWithin.ipa", "size": 100,
            "browser_download_url": downloads + "CarWithin.ipa", "digest": "sha256:" + checksum]
        var foreignAsset = asset
        foreignAsset["browser_download_url"] = "https://example.com/CarWithin.ipa"
        let release: [String: Any] = ["id": 1, "tag_name": "v1.0.5", "body": "Release notes",
            "draft": false, "prerelease": false, "assets": [foreignAsset, asset]]
        var draft = release, prerelease = release
        draft["draft"] = true
        prerelease["prerelease"] = true
        ReleaseStub.responses[api + "1"] = (200, try JSONSerialization.data(withJSONObject: [draft, release, prerelease]))
        ReleaseStub.responses[api + "2"] = (200, Data("[]".utf8))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseStub.self]
        let service = AppReleaseService(session: URLSession(configuration: configuration))
        precondition(ReleaseStub.requests.isEmpty)
        let first = try await service.history(page: 1)
        precondition(first.releases.map(\.tag_name) == ["v1.0.5"])
        let entry = first.releases[0]
        precondition(entry.body == "Release notes")
        precondition(entry.ipa?.browser_download_url.absoluteString == downloads + "CarWithin.ipa")
        precondition(entry.ipa?.sha256 == checksum)

        let second = try await service.history(page: 2)
        precondition(second.releases.isEmpty && !second.hasNext)
        precondition(ReleaseStub.requests == [api + "1", api + "2"])
        print("PASS: release history reads only the requested pages and uses this repository's IPA assets")
    }
}
