// OXP-Wire v0 adapter for the OpenXPlay oxp-clink relay.
// https://github.com/OpenXPlay/OpenXPlay-Stream
import Foundation
import Network
import CoreMedia

final class CarLinkRelay {
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var input = Data()
    private var ready = false
    private var waitingForKeyframe = true
    private var sentFormat = false
    private var pendingBytes = 0
    private var sequence: UInt32 = 0
    private var parameterSets = VideoParameterSets(codec: .h264)
    private var fps = 30
    private let maximumQueuedBytes = 2 * 1024 * 1024
    var onState: ((String) -> Void)?
    var onTouches: (([TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframe: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start(host: String, port: UInt16, fps: Int) {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        self.fps = fps
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let candidate = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                     using: NWParameters(tls: nil, tcp: tcp))
        connection = candidate
        onState?(CWL("正在连接 CarLink 中继…"))
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.connection === candidate else { return }
            switch state {
            case .ready:
                self.sendJSON(["type": "hello", "version": 0, "role": "producer", "name": "CarWithin", "client": "default"])
                self.receive(candidate)
            case .failed(let error):
                self.fail(CWL("CarLink 中继连接失败：{1}", [String(describing: error.localizedDescription)]))
            default: break
            }
        }
        candidate.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak candidate] in
            guard let self, let candidate, self.connection === candidate, !self.ready else { return }
            self.fail(CWL("连接 CarLink 中继超时，请检查中继地址及运行状态。"))
        }
    }

    func append(_ unit: Data, codec: VideoCodec) {
        guard connection != nil, unit.count <= maximumQueuedBytes,
              codec == .h264, let nals = try? AnnexB.units(in: unit) else { return }
        var picture: [Data] = []
        var keyframe = false
        for nal in nals {
            if codec.parameterSet(nal) != nil {
                if parameterSets.absorb(nal) {
                    sentFormat = false
                    waitingForKeyframe = true
                }
            } else {
                picture.append(nal)
                keyframe = keyframe || codec.isRandomAccess(nal)
            }
        }
        guard ready, parameterSets.isComplete, !picture.isEmpty, !waitingForKeyframe || keyframe,
              let bytes = try? AnnexB.lengthPrefixed(picture) else { return }
        if pendingBytes + bytes.count + 28 > maximumQueuedBytes {
            waitingForKeyframe = true
            return
        }
        if !sentFormat {
            guard let config = try? parameterSets.decoderConfigurationRecord(),
                  let codecString = try? parameterSets.codecString(),
                  let dimensions = displayDimensions() else { return }
            sendJSON(["type": "video-format", "screen": 0, "format": [
                "codec": "H264", "codecString": codecString,
                "config": config.base64EncodedString(), "fpsHint": fps,
                "width": Int(dimensions.width.rounded()), "height": Int(dimensions.height.rounded())
            ]])
            sentFormat = true
        }
        let now = DispatchTime.now().uptimeNanoseconds / 1000
        var payload = Data([1, 0, keyframe ? 1 : 0, 0])
        appendLE(sequence, to: &payload)
        appendLE(now, to: &payload)
        appendLE(now, to: &payload)
        payload.append(bytes)
        sequence &+= 1
        waitingForKeyframe = false
        send(payload)
    }

    private func displayDimensions() -> CGSize? {
        let units = parameterSets.ordered.map { $0 as NSData }
        let pointers = units.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var description: CMVideoFormatDescription?
        let status = withExtendedLifetime(units) {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: units.map(\.length),
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return nil }
        return CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: false, useCleanAperture: true)
    }

    func stop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        if connection != nil { onTouches?([]) }
        connection = nil
        input.removeAll()
        ready = false; waitingForKeyframe = true; sentFormat = false
        pendingBytes = 0; sequence = 0
        parameterSets = VideoParameterSets(codec: .h264)
    }

    private func fail(_ message: String) {
        stop()
        onState?(message)
    }

    private func receive(_ candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak candidate] bytes, _, done, error in
            guard let self, let candidate, self.connection === candidate else { return }
            if let bytes { self.input.append(bytes) }
            while self.input.count >= 4 {
                let size = self.input.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard (1...65_536).contains(size) else { self.fail(CWL("CarLink 中继消息长度无效")); return }
                guard self.input.count >= 4 + size else { break }
                let body = Data(self.input.dropFirst(4).prefix(size))
                self.input.removeFirst(4 + size)
                self.handle(body)
                guard self.connection === candidate else { return }
            }
            if done || error != nil { self.fail(CWL("CarLink 中继已断开。请启动中继后重新开始 CarPlay。")) }
            else { self.receive(candidate) }
        }
    }

    private func handle(_ message: Data) {
        if message.first == 123,
           let json = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
           let type = json["type"] as? String {
            if !ready {
                guard type == "hello", json["version"] as? Int == 0, json["role"] as? String == "consumer" else {
                    fail(CWL("CarLink 中继握手无效")); return
                }
                ready = true
                sendJSON(["type": "session", "session": ["id": "1", "phase": "ACTIVE"]])
                onState?(CWL("中继已连接，等待车机配对或投屏。"))
                onKeyframe?()
            } else if type == "keyframe" || type == "restart" {
                waitingForKeyframe = true
                onKeyframe?()
            } else if type == "error" {
                let detail = (json["message"] as? String).map { String($0.prefix(100)) } ?? CWL("请查看中继日志")
                fail(CWL("CarLink 中继出错：{1}", [String(describing: detail)]))
            }
            return
        }
        guard ready, message.count >= 24, message[1] == 0, message[3] == 0 else { return }
        let payload = Array(message.dropFirst(24))
        switch message[0] {
        case 16:
            guard let count = payload.first, count <= 10, payload.count == 1 + Int(count) * 6 else { return }
            var points: [TouchPoint] = []
            var ids = Set<UInt8>()
            for offset in stride(from: 1, to: payload.count, by: 6) {
                let id = payload[offset]
                guard id < 10, ids.insert(id).inserted, payload[offset + 1] <= 1 else { return }
                guard payload[offset + 1] == 1 else { continue }
                func coordinate(_ index: Int) -> Double {
                    Double(UInt16(payload[index]) | UInt16(payload[index + 1]) << 8) / 65535
                }
                points.append(TouchPoint(id: Int(id), x: coordinate(offset + 2), y: coordinate(offset + 4)))
            }
            onTouches?(points)
        case 17:
            let keys: [CarPlayControl] = [.home, .back, .select, .knobPrevious, .knobNext, .knobPrevious,
                                          .knobNext, .playPause, .next, .previous, .siri]
            if payload.count == 3, payload[1] == 0, payload[2] == 1, Int(payload[0]) < keys.count {
                onControl?(keys[Int(payload[0])])
            }
        default: break
        }
    }

    private func sendJSON(_ json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json) { send(data) }
    }

    private func send(_ payload: Data) {
        guard let candidate = connection else { return }
        var wire = Data()
        appendLE(UInt32(payload.count), to: &wire)
        wire.append(payload)
        let count = wire.count
        pendingBytes += count
        candidate.send(content: wire, completion: .contentProcessed { [weak self, weak candidate] error in
            guard let self, let candidate, self.connection === candidate else { return }
            let previouslyQueued = self.pendingBytes
            self.pendingBytes -= count
            if let error { self.fail(CWL("CarLink 中继发送失败：{1}", [String(describing: error.localizedDescription)])) }
            else if self.waitingForKeyframe && (self.pendingBytes == 0 ||
                        previouslyQueued >= self.maximumQueuedBytes / 2 && self.pendingBytes < self.maximumQueuedBytes / 2) {
                self.onKeyframe?()
            }
        })
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
