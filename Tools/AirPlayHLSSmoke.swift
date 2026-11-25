import Foundation

@main
struct AirPlayHLSSmoke {
    static func main() throws {
        let id = UUID()
        let stream = CarPlayHLS(id: id, origin: "http://192.168.1.162:9888")
        let base = "/airplay/\(id.uuidString)/"
        let format = FragmentedMP4.Format(codecString: "avc1.640028", initializationSegment: Data([1, 2]), sampleDuration: 1000, timescale: 30_000)
        var arrival: UInt64 = 1_000_000
        func feed(_ count: Int, format: FragmentedMP4.Format) -> Int {
            var ready = 0
            for n in 0..<count {
                if case .ready = stream.append(sample: Data([0, 0, 0, 1, 0x65]), keyframe: n % 30 == 0, format: format, arrivalUs: arrival) { ready += 1 }
                arrival += 33_334
            }
            return ready
        }
        precondition(stream.resource(at: base + "master.m3u8") == nil)
        precondition(feed(91, format: format) == 1)
        let master = String(decoding: stream.resource(at: base + "master.m3u8")!.body, as: UTF8.self)
        precondition(master.contains("http://192.168.1.162:9888" + base + "index.m3u8"))
        precondition(stream.resource(at: base + "0.m4s") != nil)
        precondition(stream.resource(at: "/airplay/\(UUID().uuidString)/master.m3u8") == nil)
        let changed = FragmentedMP4.Format(codecString: "avc1.640029", initializationSegment: Data([3, 4]), sampleDuration: 1000, timescale: 30_000)
        precondition(feed(91, format: changed) == 1, "A new format must announce readiness again")
        precondition(stream.resource(at: base + "init-0.mp4") == nil)
        precondition(stream.resource(at: base + "init-1.mp4")?.body == Data([3, 4]))
        let playlist = String(decoding: stream.resource(at: base + "index.m3u8")!.body, as: UTF8.self)
        precondition(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        precondition(playlist.contains("init-1.mp4"))
        precondition(feed(450, format: changed) == 0)
        precondition(stream.resource(at: base + "0.m4s") == nil)
        let final = String(decoding: stream.resource(at: base + "index.m3u8")!.body, as: UTF8.self)
        precondition(final.components(separatedBy: "#EXTINF:").count - 1 <= 12)
        let slowID = UUID()
        let slow = CarPlayHLS(id: slowID, origin: "http://127.0.0.1:9888")
        for n in 0...30 {
            _ = slow.append(sample: Data([0, 0, 0, 1, 0x65]), keyframe: n % 10 == 0,
                format: format, arrivalUs: UInt64(n) * 100_000)
        }
        let slowList = String(decoding: slow.resource(at: "/airplay/\(slowID.uuidString)/index.m3u8")!.body, as: UTF8.self)
        let durations = slowList.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.map {
            Double($0.dropFirst(8).dropLast())!
        }
        precondition(durations.count == 3 && durations.reduce(0, +) > 2.9,
            "10 FPS input must represent about three seconds, not one second at configured 30 FPS")
        print("PASS: HLS readiness, absolute URLs, session scoping, format recovery, rolling eviction and variable-rate timing")
    }
}
