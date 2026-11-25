import Foundation
import AVFoundation
import Network
import CryptoKit

/// What a browser page reports about its screen; used to size CarPlay to the head unit.
struct BrowserDisplay: Equatable {
    let width: Int, height: Int
    let screenWidth: Int?, screenHeight: Int?
    let devicePixelRatio: Double
    let refreshHz: Int
    let supportsH265: Bool
    let fullscreen: Bool
    let peer: String
}

/// Browser page options chosen on the iPhone.
enum BrowserPerformance: String, CaseIterable {
    case auto, quality, speed
    var title: String { switch self { case .auto: CWL("自动"); case .quality: CWL("质量优先"); case .speed: CWL("速度优先") } }
}

/// Serves a browser-based CarPlay view over HTTP and WebSocket to several LAN devices at once.
/// It also keeps /video.h264 (raw Annex-B, whichever codec CarPlay sends) for diagnostic clients.
final class VideoOutputServer {
    private enum Mode { case request, raw, webSocket }
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        let peer: String
        var mode: Mode = .request
        var buffer = Data()
        var browserReady = false
        var viewerID: UUID?
        var browserOrder: UInt64 = 0
        var awaitingDisplay = true
        var display: BrowserDisplay?
        var waitingForIDR = true
        var streamStarted = false
        /// Behind on the network: frames are skipped until the next keyframe (no disconnect).
        var skippingToIDR = false
        var gaps = 0
        var pendingBytes = 0
        var reportedMessages = 0
        var fragmentSequence: UInt32 = 1
        var decodeTime: UInt64 = 0
        /// True while this viewer holds at least one CarPlay finger.
        var touching = false
        /// WebCodecs viewers get raw AVCC/HVCC samples instead of fMP4 fragments.
        var webCodecs = false
        var wantsAudio = false
        var usesAudioClock = false
        let secure: Bool
        init(connection: NWConnection, secure: Bool) {
            self.connection = connection; self.secure = secure
            if case .hostPort(let host, _) = connection.endpoint { peer = "\(host)" } else { peer = CWL("未知设备") }
        }
    }
    /// One cached access unit; `arrivalUs` is when CarWithin received it (monotonic µs).
    private struct Frame { let annexB: Data; let sample: Data; let keyframe: Bool; let arrivalUs: UInt64 }

    /// Simultaneous viewers (browser or raw). Extra viewers get 503.
    static let maximumViewers = 4
    /// All TCP connections, including short page requests.
    private let maximumConnections = 12

    private let queue = DispatchQueue(label: "CarPlays.browser-output", qos: .userInitiated)
    private var listener: NWListener?
    private var secureListener: NWListener?
    private var securePort: UInt16?
    private var httpsRoot: Data?
    private var clients: [UUID: Client] = [:]
    private var nextBrowserOrder: UInt64 = 0
    private var primaryBrowser: UUID?
    private var returningViewer: UUID?
    private var generation = UUID()
    private var parameters = VideoParameterSets(codec: .h264)
    private var format: FragmentedMP4.Format?
    /// avcC/hvcC for WebCodecs `description`.
    private var decoderRecord: Data?
    /// Frames from the latest random-access picture onward, so late viewers start at once.
    private var gop: [Frame] = []
    private var gopBytes = 0
    private let maximumGOPBytes = 24 * 1024 * 1024
    private var width = 1280
    private var height = 720
    private var fps = 60
    private let maximumRequestBytes = 8 * 1024
    private let maximumInputBytes = 64 * 1024
    /// Above this backlog a viewer skips to the next keyframe (about 0.5 s of 4K video).
    private let skipPendingBytes = 2 * 1024 * 1024
    /// Above this backlog the socket is considered dead and closed.
    private let maximumPendingBytes = 16 * 1024 * 1024
    /// A late viewer replays the cached GOP only when it is short; otherwise it asks for a new IDR,
    /// so it does not start seconds behind live or decode a huge burst first.
    private let maximumReplayFrames = 45
    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    /// Source id (one per viewer) and every finger it holds, normalized; empty releases them.
    var onTouches: ((String, [TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframeRequest: ((String) -> Void)?
    /// The primary page's screen changed or the primary page disconnected.
    var onDisplay: ((BrowserDisplay?, UUID?) -> Void)?
    /// A page keeps hitching (skips, stalls) despite its performance mode. Called on the server queue.
    var onStruggling: ((String, String) -> Void)?
    private var performance: BrowserPerformance = .auto
    private var showTouches = false
    private var browserAudio = false
    private var hls: CarPlayHLS?
    private var hlsKeyframeTimer: DispatchSourceTimer?
    #if DEBUG
    private var airPlayRequestDiagnostics = Set<String>()
    #endif
    var onAirPlayReady: ((UUID) -> Void)?

    private var viewerCount: Int { clients.values.filter { $0.mode != .request }.count }
    private static func nowUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    func start(port: UInt16, securePort: UInt16? = nil, width: Int, height: Int, fps: Int,
               performance: BrowserPerformance = .auto, showTouches: Bool = false, preferredViewer: UUID? = nil,
               browserAudio: Bool = false, airPlayStreamID: UUID? = nil, airPlayAddress: String? = nil) {
        queue.async { [weak self] in
            self?.performance = performance; self?.showTouches = showTouches
            self?.startOnQueue(port: port, securePort: securePort, width: width, height: height, fps: fps,
                               preferredViewer: preferredViewer, browserAudio: browserAudio, airPlayStreamID: airPlayStreamID,
                               airPlayAddress: airPlayAddress)
        }
    }

    func append(_ accessUnit: Data, codec: VideoCodec) {
        guard !accessUnit.isEmpty else { return }
        queue.async { [weak self] in self?.appendOnQueue(accessUnit, codec: codec) }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer, stream: Int, stamp: UInt64) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard (1...4096).contains(frames), (1...2).contains(channels), let planes = buffer.floatChannelData else { return }
        var packet = Data([BrowserPacket.audio.rawValue])
        Self.appendTimestamp(stamp, to: &packet)
        let sampleRate = UInt32(buffer.format.sampleRate)
        withUnsafeBytes(of: sampleRate.bigEndian) { packet.append(contentsOf: $0) }
        packet.append(UInt8(channels)); packet.append(UInt8(stream))
        var samples = [Int16]()
        samples.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = planes[channel][frame]
                let bounded = value.isFinite ? min(1, max(-1, value)) : 0
                samples.append(Int16(bounded * 32767).littleEndian)
            }
        }
        samples.withUnsafeBytes { packet.append(contentsOf: $0) }
        let wire = packet
        queue.async { [weak self] in
            guard let self, self.browserAudio else { return }
            // Video can wait for the next keyframe while the same connection still has
            // capacity for audio. Only the actual socket backlog limits audio writes.
            for client in Array(self.clients.values) where client.wantsAudio && client.streamStarted
                && client.pendingBytes < self.skipPendingBytes {
                self.sendWebSocket(wire, opcode: 2, to: client)
            }
        }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    // MARK: Listener

    private func startOnQueue(port: UInt16, securePort: UInt16?, width: Int, height: Int, fps: Int, preferredViewer: UUID?,
                              browserAudio: Bool, airPlayStreamID: UUID?, airPlayAddress: String?) {
        stopOnQueue()
        self.browserAudio = browserAudio
        if let airPlayStreamID, let airPlayAddress {
            hls = CarPlayHLS(id: airPlayStreamID, origin: "http://\(airPlayAddress):\(port)")
            // A static CarPlay screen may stop emitting frames. Requests must not depend
            // on append(), otherwise the live playlist can never advance again.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.hls != nil else { return }
                self.onKeyframeRequest?(CWL("AirPlay 分段"))
            }
            timer.resume(); hlsKeyframeTimer = timer
        }
        self.width = width; self.height = height; self.fps = fps
        let run = generation
        returningViewer = preferredViewer
        if preferredViewer != nil {
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.generation == run, self.returningViewer != nil else { return }
                self.returningViewer = nil
                self.updatePrimaryDisplay(force: true)
            }
        }
        // Small frame tails and control replies must not wait for Nagle.
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let plain = NWParameters(tls: nil, tcp: tcp)
        plain.allowLocalEndpointReuse = true
        listener = makeListener(port: port, parameters: plain, secure: false, run: run)
        guard let securePort else { return }
        do {
            let addresses = ReceiverConfiguration.localIPv4Addresses()
            let tlsIdentity = try LocalTLSIdentity.load(addresses: addresses)
            onLog?(CWL("{1}浏览器 HTTPS 证书（{2}）", [String(describing: tlsIdentity.created ? CWL("已生成") : CWL("已载入")), String(describing: addresses.joined(separator: ", "))]))
            if !tlsIdentity.rootDER.isEmpty { onLog?(CWL("HTTPS 根证书 SHA-256：{1}", [String(describing: LocalTLSIdentity.fingerprint(tlsIdentity.rootDER))])) }
            let nativeIdentity = tlsIdentity.chain.isEmpty ? sec_identity_create(tlsIdentity.identity)
                : sec_identity_create_with_certificates(tlsIdentity.identity, tlsIdentity.chain as CFArray)
            guard let identity = nativeIdentity else { throw LocalTLSIdentity.TLSIdentityError.certificate(CWL("无法使用证书")) }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let secureTCP = NWProtocolTCP.Options(); secureTCP.noDelay = true
            let parameters = NWParameters(tls: tls, tcp: secureTCP)
            parameters.allowLocalEndpointReuse = true
            self.securePort = securePort
            httpsRoot = tlsIdentity.rootDER
            secureListener = makeListener(port: securePort, parameters: parameters, secure: true, run: run)
        } catch { report(CWL("低延迟 HTTPS 接收页未开启：{1}", [String(describing: error.localizedDescription)])) }
    }

    private func makeListener(port: UInt16, parameters: NWParameters, secure: Bool, run: UUID) -> NWListener? {
        let name = hls == nil ? (secure ? CWL("低延迟 HTTPS 接收页") : CWL("浏览器接收页")) : CWL("AirPlay 播放服务")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { report(CWL("{1}端口无效", [String(describing: name)])); return nil }
        do {
            let candidate = try NWListener(using: parameters, on: endpointPort)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate, self.generation == run,
                      self.listener === candidate || self.secureListener === candidate else { return }
                switch state {
                case .ready: self.report(CWL("{1}已开启，端口 {2}", [String(describing: name), String(describing: port)]))
                case .failed(let error):
                    self.report(CWL("{1}启动失败：{2}", [String(describing: name), String(describing: error.localizedDescription)]))
                    candidate.cancel()
                    if secure { self.secureListener = nil; self.securePort = nil; self.httpsRoot = nil } else { self.listener = nil }
                default: break
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == run,
                      self.listener === candidate || self.secureListener === candidate else { connection.cancel(); return }
                self.accept(connection, secure: secure)
            }
            candidate.start(queue: queue)
            return candidate
        } catch { report(CWL("{1}启动失败：{2}", [String(describing: name), String(describing: error.localizedDescription)])); return nil }
    }

    private func accept(_ connection: NWConnection, secure: Bool) {
        guard clients.count < maximumConnections else {
            connection.start(queue: queue)
            sendHTTP(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8",
                     body: Data(CWL("连接数过多，请稍后再试").utf8), to: connection) { connection.cancel() }
            return
        }
        let candidate = Client(connection: connection, secure: secure)
        clients[candidate.id] = candidate
        connection.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate else { return }
            switch state {
            case .ready: self.receive(candidate)
            case .failed, .cancelled: self.remove(candidate, reason: nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak candidate] in
            guard let self, let candidate, self.clients[candidate.id] != nil, candidate.mode == .request else { return }
            self.close(candidate, reason: nil)
        }
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if let data { client.buffer.append(data) }
            switch client.mode {
            case .request: self.handleHTTPRequest(client)
            case .webSocket: self.handleWebSocketInput(client)
            case .raw: client.buffer.removeAll()
            }
            if complete || error != nil { self.close(client, reason: nil); return }
            if self.clients[client.id] != nil { self.receive(client) }
        }
    }

    // MARK: HTTP

    private func handleHTTPRequest(_ client: Client) {
        guard client.buffer.count <= maximumRequestBytes else {
            reject(client, status: "431 Request Header Fields Too Large"); return
        }
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound else { return }
        let headerText = String(decoding: client.buffer.prefix(upTo: end), as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count == 3 else { reject(client, status: "405 Method Not Allowed"); return }
        let path = String(request[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard request[0] == "GET" else {
            #if DEBUG
            logAirPlayRequest(from: client.peer, method: String(request[0]), path: path, status: 405)
            #endif
            reject(client, status: "405 Method Not Allowed"); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        client.buffer.removeAll(keepingCapacity: false)
        if let hls {
            let resource = hls.resource(at: path)
            #if DEBUG
            logAirPlayRequest(from: client.peer, method: "GET", path: path, status: resource == nil ? 404 : 200)
            #endif
            guard let resource else { reject(client, status: "404 Not Found"); return }
            sendHTTP(status: "200 OK", contentType: resource.type, body: resource.body, to: client.connection) { [weak self, weak client] in
                guard let self, let client else { return }
                self.close(client, reason: nil)
            }
            return
        }
        switch path {
        case "/", "/index.html":
            sendHTTP(status: "200 OK", contentType: "text/html; charset=utf-8", body: BrowserReceiverPage.html, to: client.connection) { [weak self, weak client] in
                guard let self, let client else { return }; self.close(client, reason: nil)
            }
        case "/https-setup", "/carwithin.cer", "/carwithin.crt", "/carwithin.mobileconfig":
            serveHTTPSSetup(path, to: client)
        case "/video.h264", "/video.h265", "/video":
            guard viewerCount < Self.maximumViewers else { reject(client, status: "503 Service Unavailable"); return }
            client.mode = .raw; client.waitingForIDR = true
            let type = parameters.codec == .h264 ? "video/h264" : "video/h265"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", to: client)
            report(CWL("{1} 已连接原始视频流（共 {2} 台）", [String(describing: client.peer), String(describing: viewerCount)]))
            replayGOP(to: client)
        case "/stream", "/oxp/v0":
            guard viewerCount < Self.maximumViewers else { reject(client, status: "503 Service Unavailable"); return }
            upgradeWebSocket(client, headers: headers)
        default:
            reject(client, status: "404 Not Found")
        }
    }

    private func serveHTTPSSetup(_ path: String, to client: Client) {
        guard let root = httpsRoot, let port = securePort else { reject(client, status: "404 Not Found"); return }
        if root.isEmpty {
            guard path == "/https-setup", let domain = HTTPSConfiguration.normalizedDomain(HTTPSConfiguration.domain) else { reject(client, status: "404 Not Found"); return }
            sendHTTP(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(CWL("<meta charset=utf-8><h1>HTTPS 已配置证书</h1><p>使用公开 CA 证书时无需安装本地根证书。</p><a href=\"https://{1}:{2}/\">打开 HTTPS 接收页</a>", [String(describing: domain), String(describing: port)]).utf8), to: client.connection) { [weak self, weak client] in
                guard let self, let client else { return }; self.close(client, reason: nil)
            }
            return
        }
        let content: (String, Data)
        switch path {
        case "/carwithin.cer", "/carwithin.crt": content = ("application/pkix-cert", root)
        case "/carwithin.mobileconfig":
            guard let profile = try? LocalTLSIdentity.profile(root: root) else {
                reject(client, status: "500 Internal Server Error"); return
            }
            content = ("application/x-apple-aspen-config", profile)
        default: content = ("text/html; charset=utf-8", LocalTLSIdentity.setupPage(root: root, port: port))
        }
        sendHTTP(status: "200 OK", contentType: content.0, body: content.1, to: client.connection,
                 attachment: path == "/carwithin.crt" ? "CarWithin-HTTPS.crt" : nil) { [weak self, weak client] in
            guard let self, let client else { return }; self.close(client, reason: nil)
        }
    }

    private func upgradeWebSocket(_ client: Client, headers: [String: String]) {
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              headers["sec-websocket-version"] == "13",
              let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            reject(client, status: "400 Bad Request"); return
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        client.mode = .webSocket
        client.browserOrder = nextBrowserOrder
        nextBrowserOrder += 1
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak client] in
            guard let self, let client, self.clients[client.id] != nil, client.awaitingDisplay else { return }
            client.awaitingDisplay = false
            self.updatePrimaryDisplay()
        }
        client.waitingForIDR = true
        sendRaw("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n", to: client)
        // Tells an HTTP page where the low-latency HTTPS page is, and lets an outdated page reload.
        sendJSON(["type": "hello", "page": BrowserReceiverPage.version, "securePort": Int(securePort ?? 0),
                  "controls": CarPlayControl.allCases.map(\.rawValue),
                  "perf": performance.rawValue, "showTouches": showTouches, "audio": browserAudio], to: client)
        report(CWL("{1} 已连接浏览器{2}（共 {3} 台）", [String(describing: client.peer), String(describing: client.secure ? "（HTTPS）" : ""), String(describing: viewerCount)]))
    }

    // MARK: WebSocket input

    private func handleWebSocketInput(_ client: Client) {
        guard client.buffer.count <= maximumInputBytes else { close(client, reason: CWL("{1} 输入过大，已断开", [String(describing: client.peer)])); return }
        do {
            while let frame = try takeWebSocketFrame(from: &client.buffer) {
                switch frame.opcode {
                case 1: try handleText(String(decoding: frame.payload, as: UTF8.self), client: client)
                case 8: close(client, reason: nil); return
                case 9: sendWebSocket(frame.payload, opcode: 10, to: client)
                case 10: break
                default: throw WebSocketError.unsupportedFrame
                }
            }
        } catch { close(client, reason: CWL("{1} 协议错误：{2}", [String(describing: client.peer), String(describing: error.localizedDescription)])) }
    }

    private func handleText(_ text: String, client: Client) throws {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw WebSocketError.invalidJSON }
        switch type {
        case "ready":
            if !client.browserReady, let id = object["viewer"] as? String { client.viewerID = UUID(uuidString: id) }
            client.browserReady = true; client.waitingForIDR = true; client.streamStarted = false; client.skippingToIDR = false
            let webCodecs = object["decoder"] as? String == "webcodecs"
            if webCodecs != client.webCodecs || !client.streamStarted {
                onLog?(CWL("{1} 使用{2}解码", [String(describing: client.peer), String(describing: webCodecs ? CWL(" WebCodecs 低延迟") : CWL(" MSE 兼容"))]))
            }
            client.webCodecs = webCodecs
            client.usesAudioClock = browserAudio && object["audioClock"] as? Bool == true
            sendJSON(["type": "status", "text": CWL("已连接 CarWithin，正在等待关键帧")], to: client)
            replayGOP(to: client)
        case "audio":
            client.wantsAudio = client.usesAudioClock && object["enabled"] as? Bool == true
        case "keyframe":
            // Browser decoder recovery (stall, decode error, buffer trim). The receiver throttles.
            let reason = (object["reason"] as? String).map { String($0.prefix(60)) } ?? CWL("浏览器请求")
            onKeyframeRequest?("\(client.peer)：\(reason)")
        case "error", "info":
            // Browser-side diagnostics land in the iPhone log; capped so a page cannot flood it.
            guard client.reportedMessages < 40, let text = object["text"] as? String else { break }
            client.reportedMessages += 1
            onLog?(CWL("浏览器 {1} {2}：{3}", [String(describing: client.peer), String(describing: type == "error" ? CWL("错误") : CWL("信息")), String(describing: text.prefix(300))]))
        case "touches":
            // Every finger this viewer currently holds; fingers missing from the list are released.
            guard let list = object["points"] as? [[String: Any]], list.count <= 10 else { throw WebSocketError.invalidTouch }
            let points = try list.map { item -> TouchPoint in
                guard let id = item["id"] as? Int, let x = item["x"] as? Double, let y = item["y"] as? Double,
                      (0...255).contains(id), x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                    throw WebSocketError.invalidTouch
                }
                return TouchPoint(id: id, x: x, y: y)
            }
            guard client.touching || !points.isEmpty else { break }
            client.touching = !points.isEmpty
            onTouches?(client.id.uuidString, points)
        case "control":
            guard let name = object["name"] as? String, let control = CarPlayControl(rawValue: name) else { break }
            onControl?(control)
        case "display":
            guard client.browserReady else { break }
            func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
            guard let width = int("w"), let height = int("h"), (160...8192).contains(width), (160...8192).contains(height) else { break }
            let dpr = (object["dpr"] as? NSNumber)?.doubleValue ?? 1
            func screenDimension(_ key: String) -> Int? {
                int(key).flatMap { (160...16_384).contains($0) ? $0 : nil }
            }
            let display = BrowserDisplay(width: width, height: height,
                screenWidth: screenDimension("sw"), screenHeight: screenDimension("sh"),
                devicePixelRatio: dpr.isFinite ? min(max(dpr, 0.5), 5) : 1,
                refreshHz: min(max(int("hz") ?? 0, 0), 240),
                supportsH265: object["h265"] as? Bool ?? false, fullscreen: object["fullscreen"] as? Bool ?? false,
                peer: client.peer)
            onLog?(CWL("{1} 屏幕 {2}×{3}（像素比 {4}，{5} Hz，H.265 {6}硬解{7}）", [String(describing: client.peer), String(describing: width), String(describing: height), String(describing: display.devicePixelRatio), String(describing: display.refreshHz), String(describing: display.supportsH265 ? CWL("可") : CWL("不可")), String(describing: display.fullscreen ? CWL("，全屏") : "")]))
            client.display = display
            client.awaitingDisplay = false
            updatePrimaryDisplay(changed: client.id)
        case "struggling":
            guard client.id == primaryBrowser else { break }
            let reason = (object["reason"] as? String).map { String($0.prefix(40)) } ?? CWL("卡顿")
            let decoder = object["decoder"] as? String == "webcodecs" ? "WebCodecs" : "MSE"
            onStruggling?(client.peer, "\(decoder) \(reason)")
        case "ping":
            // Clock sync: the page estimates the offset to CarWithin's clock for end-to-end latency.
            var reply: [String: Any] = ["type": "pong", "s": Double(Self.nowUs())]
            if let t0 = object["t0"] as? Double, t0.isFinite { reply["t0"] = t0 }
            sendJSON(reply, to: client)
        default:
            break
        }
    }

    // MARK: Video

    private func appendOnQueue(_ accessUnit: Data, codec: VideoCodec) {
        guard accessUnit.count <= 8 * 1024 * 1024 else { return }
        let units: [Data]
        do { units = try AnnexB.units(in: accessUnit) }
        catch { onLog?(CWL("浏览器输出忽略了无效视频数据：{1}", [String(describing: error.localizedDescription)])); return }
        if parameters.codec != codec { resetStream(codec: codec, reason: CWL("视频编码已切换为 {1}", [String(describing: codec.displayName)])) }
        var picture: [Data] = []
        var changed = false
        var keyframe = false
        for unit in units {
            if codec.parameterSet(unit) != nil { if parameters.absorb(unit) { changed = true }; continue }
            if codec.isRandomAccess(unit) { keyframe = true }
            picture.append(unit)
        }
        if changed, parameters.isComplete {
            let previous = format?.codecString
            do {
                format = try FragmentedMP4.format(parameters: parameters, width: width, height: height, fps: fps)
                decoderRecord = try parameters.decoderConfigurationRecord()
            } catch { onLog?(CWL("浏览器视频格式生成失败：{1}", [String(describing: error.localizedDescription)])); format = nil; decoderRecord = nil }
            gop.removeAll(); gopBytes = 0
            if previous != nil {
                for client in clients.values where client.streamStarted { close(client, reason: nil) }
            }
            if let format { onLog?(CWL("浏览器视频格式：{1}（{2}）", [String(describing: format.codecString), String(describing: parameters.summary)])) }
        }
        guard !picture.isEmpty else { return }
        let sample: Data
        do { sample = try AnnexB.lengthPrefixed(picture) }
        catch { onLog?(CWL("视频帧转换失败：{1}", [String(describing: error.localizedDescription)])); return }
        let annexB = picture.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
        if let hls, let format {
            let event = hls.append(sample: sample, keyframe: keyframe, format: format, arrivalUs: Self.nowUs())
            if event == .ready { onAirPlayReady?(hls.id) }
            if event == .keyframeNeeded { onKeyframeRequest?(CWL("AirPlay 分段")) }
            return
        }
        let frame = Frame(annexB: annexB, sample: sample, keyframe: keyframe, arrivalUs: Self.nowUs())
        cache(frame)
        for client in Array(clients.values) { deliver(frame, to: client) }
    }

    private func resetStream(codec: VideoCodec, reason: String) {
        parameters = VideoParameterSets(codec: codec)
        format = nil; decoderRecord = nil; gop.removeAll(); gopBytes = 0
        for client in clients.values where client.streamStarted || (client.mode == .raw && !client.waitingForIDR) {
            close(client, reason: nil)
        }
        onLog?(reason)
    }

    private func cache(_ frame: Frame) {
        if frame.keyframe { gop.removeAll(); gopBytes = 0 }
        guard !gop.isEmpty || frame.keyframe else { return }
        let size = frame.annexB.count + frame.sample.count
        guard gopBytes + size <= maximumGOPBytes else { gop.removeAll(); gopBytes = 0; return }
        gop.append(frame); gopBytes += size
    }

    private func replayGOP(to client: Client) {
        guard client.waitingForIDR else { return }
        if !gop.isEmpty, gop.count <= maximumReplayFrames {
            for item in gop { deliver(item, to: client) }
            return
        }
        // CarPlay sends a keyframe only at stream start, so a late viewer must ask for one.
        onKeyframeRequest?(CWL("{1} 新连接", [String(describing: client.peer)]))
        let run = generation
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self, weak client] in
            // Fallback if the iPhone ignores forceKeyFrame: start from the cached GOP anyway.
            guard let self, let client, self.generation == run, self.clients[client.id] != nil,
                  client.waitingForIDR, !self.gop.isEmpty else { return }
            self.onLog?(CWL("{1} 未等到新关键帧，改用缓存画面（{2} 帧）", [String(describing: client.peer), String(describing: self.gop.count)]))
            for item in self.gop { self.deliver(item, to: client) }
        }
    }

    /// Binary WebSocket messages carry a 1-byte header so the page knows what it appends:
    /// 2 = initialization segment, 1 = keyframe fragment, 0 = dependent fragment.
    /// WebCodecs viewers get the same first byte, then 8 bytes big-endian arrival time (µs),
    /// then the length-prefixed (AVCC/HVCC) sample.
    private enum BrowserPacket: UInt8 { case delta = 0, keyframe = 1, initialization = 2, audio = 3, timedDelta = 4, timedKeyframe = 5 }

    private static func appendTimestamp(_ timestamp: UInt64, to data: inout Data) {
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
    }

    private func deliver(_ frame: Frame, to client: Client) {
        let keyframe = frame.keyframe, annexB = frame.annexB, sample = frame.sample
        guard clients[client.id] != nil else { return }
        if !client.waitingForIDR, (client.mode == .raw || client.streamStarted) {
            if client.skippingToIDR {
                guard keyframe, client.pendingBytes < skipPendingBytes / 2 else { return }
                client.skippingToIDR = false
            } else if !keyframe, client.pendingBytes > skipPendingBytes {
                // Never drop a single dependent frame: skip the rest of this GOP and ask for an IDR.
                client.skippingToIDR = true; client.gaps += 1
                if client.gaps == 1 || client.gaps % 10 == 0 {
                    onLog?(CWL("{1} 网络跟不上，跳到下一个关键帧（第 {2} 次）", [String(describing: client.peer), String(describing: client.gaps)]))
                }
                onKeyframeRequest?(CWL("{1} 网络积压", [String(describing: client.peer)]))
                return
            }
        }
        switch client.mode {
        case .raw:
            if client.waitingForIDR {
                guard keyframe, parameters.isComplete else { return }
                client.waitingForIDR = false
                let header = parameters.ordered.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
                send(header + annexB, to: client)
            } else { send(annexB, to: client) }
        case .webSocket:
            guard client.browserReady, let format, let decoderRecord else { return }
            if client.waitingForIDR {
                guard keyframe else { return }
                client.waitingForIDR = false; client.streamStarted = true
                client.fragmentSequence = 1; client.decodeTime = 0
                var message: [String: Any] = ["type": "format", "codec": format.codecString, "name": parameters.codec.displayName,
                    "width": width, "height": height, "fps": fps, "viewers": viewerCount,
                    "duration": Int(format.sampleDuration), "timescale": Int(format.timescale),
                    "page": BrowserReceiverPage.version, "decoder": client.webCodecs ? "webcodecs" : "mse"]
                if client.webCodecs { message["description"] = decoderRecord.base64EncodedString() }
                sendJSON(message, to: client)
                if !client.webCodecs {
                    sendWebSocket(Data([BrowserPacket.initialization.rawValue]) + format.initializationSegment, opcode: 2, to: client)
                }
                report(CWL("{1} 已开始显示 CarPlay（{2}{3}）", [String(describing: client.peer), String(describing: parameters.codec.displayName), String(describing: client.webCodecs ? CWL("，低延迟") : "")]))
            }
            if client.webCodecs {
                var packet = Data([keyframe ? BrowserPacket.keyframe.rawValue : BrowserPacket.delta.rawValue])
                Self.appendTimestamp(frame.arrivalUs, to: &packet)
                packet.append(sample)
                sendWebSocket(packet, opcode: 2, to: client)
                return
            }
            let fragment = FragmentedMP4.fragment(sequence: client.fragmentSequence, decodeTime: client.decodeTime,
                                                   duration: format.sampleDuration, accessUnit: sample, keyframe: keyframe)
            client.fragmentSequence &+= 1; client.decodeTime &+= UInt64(format.sampleDuration)
            let kind: BrowserPacket = client.usesAudioClock
                ? (keyframe ? .timedKeyframe : .timedDelta) : (keyframe ? .keyframe : .delta)
            var packet = Data([kind.rawValue])
            if client.usesAudioClock { Self.appendTimestamp(frame.arrivalUs, to: &packet) }
            packet.append(fragment)
            sendWebSocket(packet, opcode: 2, to: client)
        case .request:
            break
        }
    }

    // MARK: Output

    private func sendJSON(_ object: [String: Any], to client: Client) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendWebSocket(data, opcode: 1, to: client)
    }

    private func sendWebSocket(_ payload: Data, opcode: UInt8, to client: Client) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            frame.append(126)
            frame.append(UInt8(truncatingIfNeeded: payload.count >> 8))
            frame.append(UInt8(truncatingIfNeeded: payload.count))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: UInt64(payload.count) >> shift)) }
        }
        frame.append(payload)
        send(frame, to: client)
    }

    private func send(_ data: Data, to client: Client) {
        guard clients[client.id] != nil else { return }
        guard client.pendingBytes + data.count <= maximumPendingBytes else {
            close(client, reason: CWL("{1} 读取过慢，已断开", [String(describing: client.peer)])); return
        }
        client.pendingBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            client.pendingBytes = max(0, client.pendingBytes - data.count)
            if error != nil { self.close(client, reason: nil) }
        })
    }

    private func sendRaw(_ text: String, to client: Client) { send(Data(text.utf8), to: client) }

    private func reject(_ client: Client, status: String) {
        let body = status.hasPrefix("503") ? CWL("最多支持 {1} 台设备同时观看", [String(describing: Self.maximumViewers)]) : CWL("请求不受支持")
        sendHTTP(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8), to: client.connection) { [weak self, weak client] in
            guard let self, let client else { return }; self.close(client, reason: nil)
        }
    }

    private func sendHTTP(status: String, contentType: String, body: Data, to connection: NWConnection,
                          attachment: String? = nil, completion: @escaping () -> Void) {
        let disposition = attachment.map { "Content-Disposition: attachment; filename=\"\($0)\"\r\n" } ?? ""
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\(disposition)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in completion() })
    }

    // MARK: Lifecycle

    private func updatePrimaryDisplay(changed: UUID? = nil, force: Bool = false) {
        let candidates = clients.values.filter { $0.display != nil }
        let selected: Client?
        if let returningViewer {
            guard let returning = candidates.first(where: { $0.viewerID == returningViewer }) else { return }
            self.returningViewer = nil
            selected = returning
        } else if let primaryBrowser, let current = clients[primaryBrowser] {
            selected = current
        } else {
            selected = candidates.min { $0.browserOrder < $1.browserOrder }
            if let selected, clients.values.contains(where: {
                $0.mode == .webSocket && $0.awaitingDisplay && $0.browserOrder < selected.browserOrder
            }) { return }
        }
        let previous = primaryBrowser
        primaryBrowser = selected?.id
        guard force || previous != primaryBrowser || (changed != nil && changed == primaryBrowser) else { return }
        if previous != primaryBrowser, let selected { onLog?(CWL("主接收屏幕：{1}", [String(describing: selected.peer)])) }
        onDisplay?(selected?.display, selected?.viewerID)
    }

    private func close(_ client: Client, reason: String?) {
        guard clients[client.id] != nil else { return }
        client.connection.cancel()
        remove(client, reason: reason)
    }

    private func remove(_ client: Client, reason: String?) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        if client.mode == .webSocket { updatePrimaryDisplay() }
        if client.touching { onTouches?(client.id.uuidString, []); client.touching = false }
        if let reason { report(reason) }
        else if client.mode != .request { report(CWL("{1} 已断开（剩余 {2} 台）", [String(describing: client.peer), String(describing: viewerCount)])) }
    }

    #if DEBUG
    private func logAirPlayRequest(from peer: String, method: String, path: String, status: Int) {
        guard hls != nil else { return }
        let kind = path.hasSuffix(".m3u8") ? CWL("播放列表") : path.hasSuffix(".mp4") ? CWL("初始化段") : path.hasSuffix(".m4s") ? CWL("视频分段") : CWL("其他资源")
        let message = "AirPlay HTTP：\(peer) \(String(method.prefix(12))) \(kind) → \(status)"
        if airPlayRequestDiagnostics.count < 24, airPlayRequestDiagnostics.insert(message).inserted { onLog?(message) }
    }
    #endif

    private func stopOnQueue() {
        hlsKeyframeTimer?.cancel(); hlsKeyframeTimer = nil
        generation = UUID(); listener?.cancel(); listener = nil
        secureListener?.cancel(); secureListener = nil; securePort = nil
        httpsRoot = nil; hls = nil; browserAudio = false
        #if DEBUG
        airPlayRequestDiagnostics.removeAll()
        #endif
        for client in Array(clients.values) {
            if client.touching { onTouches?(client.id.uuidString, []) }
            client.connection.cancel()
        }
        clients.removeAll()
        primaryBrowser = nil; returningViewer = nil; nextBrowserOrder = 0
        parameters = VideoParameterSets(codec: .h264); format = nil; decoderRecord = nil; gop.removeAll(); gopBytes = 0
    }

    private func report(_ message: String) {
        onLog?(message)
        DispatchQueue.main.async { [weak self] in self?.onState?(message) }
    }

    // MARK: WebSocket framing

    private struct WebSocketFrame { let opcode: UInt8; let payload: Data }
    private func takeWebSocketFrame(from buffer: inout Data) throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex], second = buffer[buffer.startIndex + 1]
        guard first & 0x80 != 0, first & 0x70 == 0, second & 0x80 != 0 else { throw WebSocketError.unsupportedFrame }
        let opcode = first & 0x0f
        var offset = 2
        var length = Int(second & 0x7f)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3]); offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 2..<10 { value = (value << 8) | UInt64(buffer[buffer.startIndex + index]) }
            guard value <= UInt64(maximumInputBytes) else { throw WebSocketError.frameTooLarge }
            length = Int(value); offset = 10
        }
        guard length <= maximumInputBytes else { throw WebSocketError.frameTooLarge }
        guard buffer.count >= offset + 4 + length else { return nil }
        let mask = Array(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)])
        offset += 4
        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
        payload.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<length { bytes[index] ^= mask[index & 3] }
        }
        buffer.removeFirst(offset + length)
        return WebSocketFrame(opcode: opcode, payload: payload)
    }

    private enum WebSocketError: LocalizedError {
        case unsupportedFrame, frameTooLarge, invalidJSON, invalidTouch
        var errorDescription: String? {
            switch self {
            case .unsupportedFrame: CWL("不支持的 WebSocket 帧")
            case .frameTooLarge: CWL("WebSocket 帧过大")
            case .invalidJSON: CWL("控制消息不是有效 JSON")
            case .invalidTouch: CWL("触控坐标无效")
            }
        }
    }
}
