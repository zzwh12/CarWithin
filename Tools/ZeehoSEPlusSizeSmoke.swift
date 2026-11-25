import Foundation

@main
struct ZeehoSEPlusSizeSmoke {
    static func main() {
        precondition(ZeehoFrameRate.allCases.map(\.rawValue) == [25, 30, 60])
        precondition(ZeehoFrameRate.fps25.sourceFPS == 30 && ZeehoFrameRate.fps25.bitrate == 2_500_000)
        precondition(ZeehoFrameRate.fps30.sourceFPS == 30 && ZeehoFrameRate.fps30.bitrate == 3_000_000)
        precondition(ZeehoFrameRate.fps60.sourceFPS == 60 && ZeehoFrameRate.fps60.bitrate == 6_000_000)
        precondition(ZeehoFrameRate.fps60.title.contains("实验"))
        precondition(ZeehoFrameRate(rawValue: 0) == nil && ZeehoFrameRate(rawValue: 120) == nil)
        precondition(ZeehoCanvas.wide.size == InstrumentFrameSize(width: 1600, height: 770))
        precondition(ZeehoCanvas.compatible.size == InstrumentFrameSize(width: 800, height: 480))
        precondition(ZeehoVideoMode.relay.effective(for: .fps25) == .transcode)
        precondition(ZeehoVideoMode.relay.effective(for: .fps30) == .relay)
        precondition(ZeehoVideoMode.relay.effective(for: .fps60) == .relay)
        var relay = ZeehoRelayBuffer(maximumFrames: 3, maximumBytes: 12)
        precondition(relay.append(Data([1]), keyframe: false))
        precondition(relay.pop() == nil && relay.waitingForKeyframe)
        precondition(!relay.append(Data([0]), keyframe: true))
        precondition(!relay.append(Data([1]), keyframe: false))
        precondition(!relay.append(Data([2]), keyframe: false))
        for value: UInt8 in [0, 1, 2] { precondition(relay.pop() == Data([value])) }
        precondition(relay.pop() == nil)
        precondition(!relay.append(Data([3]), keyframe: true))
        precondition(!relay.append(Data([4]), keyframe: false))
        precondition(!relay.append(Data([5]), keyframe: false))
        precondition(relay.append(Data([6]), keyframe: false))
        precondition(relay.pop() == nil && relay.discardedGroups == 1)
        precondition(relay.append(Data([7]), keyframe: false))
        precondition(!relay.append(Data([8]), keyframe: true))
        precondition(relay.pop() == Data([8]))
        precondition(!relay.append(Data(repeating: 9, count: 8), keyframe: true))
        precondition(relay.append(Data(repeating: 10, count: 8), keyframe: false))
        precondition(relay.pop() == nil && relay.discardedGroups == 2)
        precondition(relay.append(Data(repeating: 11, count: 13), keyframe: true))
        precondition(relay.pop() == nil && relay.discardedGroups == 3)
        for value in 0..<1000 {
            let packet = Data([UInt8(value % 256)])
            precondition(!relay.append(packet, keyframe: value == 0))
            precondition(relay.pop() == packet)
        }
        let sePlus = TailingDisplayProfile.zeehoSEPlus
        precondition(sePlus.preferredSize == InstrumentFrameSize(width: 800, height: 480))
        for (w, h) in [(800, 480), (800, 488), (854, 480), (960, 540), (1024, 480), (1280, 720), (1600, 770), (1920, 1080)] {
            let reported = InstrumentFrameSize(width: w, height: h)
            precondition(sePlus.outputSize(for: reported) == reported)
        }
        for (w, h) in [(0, 480), (800, 0), (799, 480), (800, 479), (480, 800), (2048, 1080), (1920, 1082), (65535, 65535)] {
            precondition(sePlus.outputSize(for: InstrumentFrameSize(width: w, height: h)) == nil)
        }
        let original = InstrumentFrameSize(width: 1024, height: 480)
        precondition(TailingDisplayProfile.zeeho62.outputSize(for: original) == original)
        precondition(TailingDisplayProfile.zeeho62.outputSize(for: InstrumentFrameSize(width: 1024, height: 488)) == original)
        precondition(TailingDisplayProfile.zeeho62.outputSize(for: sePlus.preferredSize) == nil)
        let jpeg = InstrumentFrameSize(width: 480, height: 272)
        precondition(TailingDisplayProfile.tailing43.outputSize(for: jpeg) == jpeg)
        precondition(TailingDisplayProfile.tailing43.outputSize(for: original) == nil)
        let nonDefault = InstrumentFrameSize(width: 854, height: 480)
        let response = TailingProtocol.mediaConfiguration(size: nonDefault, h264: sePlus.isZeeho)
        precondition(Array(response) == [2, 0, 0, 0, 0x56, 0x03, 0xe0, 0x01])
        let legacyResponse = TailingProtocol.mediaConfiguration(size: jpeg, h264: TailingDisplayProfile.tailing43.isZeeho)
        precondition(Array(legacyResponse) == [1, 0, 0, 0, 0xe0, 0x01, 0x10, 0x01])
        let ae2 = TailingDisplayProfile.zeehoAE2
        for size in [InstrumentFrameSize(width: 800, height: 480), InstrumentFrameSize(width: 480, height: 800), InstrumentFrameSize(width: 1920, height: 1080)] {
            precondition(ae2.outputSize(for: size) == size)
        }
        precondition(ae2.outputSize(for: InstrumentFrameSize(width: 855, height: 481)) == InstrumentFrameSize(width: 854, height: 480))
        precondition(ae2.outputSize(for: InstrumentFrameSize(width: 0, height: 480)) == nil)
        precondition(ae2.outputSize(for: InstrumentFrameSize(width: 800, height: 65535)) == nil)
        let source = CGSize(width: 800, height: 480)
        precondition(sePlus.preferredSize.fittedRect(for: source) == CGRect(x: 0, y: 0, width: 800, height: 480))
        precondition(nonDefault.fittedRect(for: source) == CGRect(x: 27, y: 0, width: 800, height: 480))
        let taller = InstrumentFrameSize(width: 800, height: 488)
        precondition(taller.fittedRect(for: source) == CGRect(x: 0, y: 4, width: 800, height: 480))
        let smaller = InstrumentFrameSize(width: 640, height: 384)
        precondition(smaller.fittedRect(for: source) == CGRect(x: 0, y: 0, width: 640, height: 384))
        print("PASS: 25/30/60 FPS settings, wide canvas, 25 FPS transcode fallback, relay ordering/overflow/IDR recovery/byte bounds/1000 frames, 8 SE+ sizes, invalid sizes, media replies and aspect-fit")
    }
}
