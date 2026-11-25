// SPDX-License-Identifier: GPL-3.0-or-later
// Capability profile adapted from PlayPort AirPlayInfoPlist/AirPlayHid.
import Foundation

enum CarPlayInfo {
    static let displayID = "b7e6c5a0-1111-4000-8000-000000000001"
    /// HID device uuids; reports name them in hidSendReport.
    enum HID {
        static let touch = "2a2a2a2a"
        static let knob = "2a2a2a2b"
        static let media = "2a2a2a2c"
        static let telephony = "2a2a2a2d"
    }
    /// Touch slots declared in the descriptor. CarPlay Maps uses two for pinch and rotate.
    static let touchContacts = 2
    private static let displayFeatureKnobs = 0x02
    private static let displayFeatureHighFidelityTouch = 0x08
    static let defaultWidthPhysicalMM = 200

    static func features(audio: Bool) -> UInt64 { audio ? 0x615653aee2 : 0x615653aee2 & ~UInt64(0x10004540a00) }

    /// 30–60 in steps of 5 (round half up), as the iPhone expects for maxFPS.
    static func sanitizedFPS(_ fps: Int) -> Int {
        let clamped = min(60, max(30, fps))
        return ((clamped - 30) + 2) / 5 * 5 + 30
    }

    static func build(_ config: ReceiverConfiguration) -> [String: Any] {
        let area: [String: Any] = ["widthPixels": config.width, "heightPixels": config.height, "originXPixels": 0, "originYPixels": 0]
        var view = area; var safe = area; safe["drawUIOutsideSafeArea"] = true; view["safeArea"] = safe
        let widthPhysical = config.widthPhysicalMM
        let heightPhysical = max(1, Int((Double(widthPhysical) * Double(config.height) / Double(config.width)).rounded()))
        let display: [String: Any] = ["uuid": displayID, "type": 110, "maxFPS": sanitizedFPS(config.maxFPS),
            "widthPixels": config.width, "heightPixels": config.height,
            "widthPhysical": widthPhysical, "heightPhysical": heightPhysical,
            "features": displayFeatureHighFidelityTouch | displayFeatureKnobs, "primaryInputDevice": 1,
            // 0 = automatic; the live day/night state follows with setNightMode.
            "uiAppearanceMode": 0, "uiAppearanceSetting": 0, "mapAppearanceMode": 0, "mapAppearanceSetting": 0,
            "viewAreas": [view], "initialViewArea": 0]
        let resource: [String: Any] = ["resourceID": 1, "transferType": 1, "transferPriority": 100,
            "takeConstraint": 100, "borrowConstraint": 100, "unborrowConstraint": 100]
        var resources = [resource]
        if config.audioEnabled { var audio = resource; audio["resourceID"] = 2; resources.append(audio) }
        let modes: [String: Any] = ["resources": resources, "appStates": [
            ["appStateID": 2, "state": false], ["appStateID": 1, "speechMode": -1], ["appStateID": 3, "state": false]]]
        let hidDevices = [
            hidDevice(HID.touch, name: CWL("CarWithin 触控屏"), descriptor: touchDescriptor(width: config.width, height: config.height)),
            hidDevice(HID.knob, name: CWL("CarWithin 旋钮"), descriptor: knobDescriptor),
            hidDevice(HID.media, name: CWL("CarWithin 多媒体键"), descriptor: mediaDescriptor),
            hidDevice(HID.telephony, name: CWL("CarWithin 电话键"), descriptor: telephonyDescriptor)
        ]
        var info: [String: Any] = ["sourceVersion": "509.11", "features": NSNumber(value: features(audio: config.audioEnabled)), "statusFlags": 4,
            "model": "CarWithin1,1", "manufacturer": "CarWithin", "deviceID": config.deviceID,
            "bluetoothIDs": [config.deviceID], "name": config.name, "rightHandDrive": config.rightHandDrive,
            "keepAliveLowPower": false, "keepAliveSendStatsAsBody": false, "modes": modes,
            "extendedFeatures": ["vocoderInfo", "enhancedRequestCarUI"],
            "displays": [display], "hidDevices": hidDevices]
        if config.videoCodec == .h265 { info["hevcInfo"] = [String: Any]() }
        if let icon = config.oemIconPNG, let size = vehicleButtonSize(in: config) {
            // The car button on the CarPlay home screen; tapping it sends requestUI.
            info["oemIconVisible"] = true
            info["oemIconLabel"] = config.oemIconLabel
            info["oemIcons"] = [["imageData": icon, "widthPixels": size, "heightPixels": size, "prerendered": true] as [String: Any]]
        }
        if config.audioEnabled {
            // Wireless CarPlay requires a compressed codec for every interactive
            // voice/alternate category, even when only music is currently playing.
            let types: [(Int, String)] = [(100,"compatibility"),(101,"compatibility"),(100,"default"),
                (100,"media"),(100,"alert"),(100,"telephony"),(100,"speechRecognition"),(101,"default")]
            let profiles: [(Int, String, Int, Int)] = [
                (100, "compatibility", 0x8854, 0x54),
                (101, "compatibility", 0x8800, 0),
                (100, "default", 0x30000050, 0x30000050),
                (100, "media", 0x8800, 0),
                (100, "alert", 0x40008800, 0),
                (100, "telephony", 0x70000150, 0x70000150),
                (100, "speechRecognition", 0x20000040, 0x20000040),
                (101, "default", 0x40008800, 0),
                (102, "media", 0xc00000, 0)]
            info["audioFormats"] = profiles.map { type, audioType, output, input -> [String: Any] in
                var entry: [String: Any] = ["type": type, "audioType": audioType, "audioOutputFormats": output]
                if input != 0 { entry["audioInputFormats"] = input }
                return entry
            }
            // A type-only latency entry is the fallback for requests without an audioType.
            // Non-zero output latency matches the real prebuffer in CarPlayAudio (40 ms PCM/Opus, 180 ms AAC).
            info["audioLatencies"] = (types + [(102,"media"),(102,"default")]).map { ["type": $0.0, "audioType": $0.1, "inputLatencyMicros": 0, "outputLatencyMicros": $0.0 == 102 ? 200000 : 50000] as [String: Any] }
                + [100, 101, 102].map { ["type": $0, "inputLatencyMicros": 0, "outputLatencyMicros": $0 == 102 ? 200000 : 50000] as [String: Any] }
        }
        return info
    }

    /// Width of a square PNG from its IHDR chunk; nil unless it is square and at most 192 px.
    static func vehicleButtonSize(in config: ReceiverConfiguration) -> Int? {
        guard let png = config.oemIconPNG else { return nil }
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes[0] == 0x89, bytes[1] == 0x50 else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return width == height && (1...192).contains(width) ? width : nil
    }

    private static func hidDevice(_ uuid: String, name: String, descriptor: Data) -> [String: Any] {
        ["hidProductID": 1, "hidVendorID": 2, "hidCountryCode": 0, "uuid": uuid, "name": name,
         "displayUUID": displayID, "hidDescriptor": descriptor]
    }

    // MARK: HID reports

    struct TouchContact { let slot: Int; let x: UInt16; let y: UInt16; let down: Bool }
    /// 6 bytes per slot: [slot, tip, xL, xH, yL, yH]. Slots without a contact report up.
    static func touchReport(_ contacts: [TouchContact]) -> Data {
        var report = Data(count: 6 * touchContacts)
        for slot in 0..<touchContacts {
            let offset = slot * 6
            report[offset] = UInt8(slot)
            guard let contact = contacts.first(where: { $0.slot == slot }) else { continue }
            report[offset + 1] = contact.down ? 1 : 0
            report[offset + 2] = UInt8(truncatingIfNeeded: contact.x); report[offset + 3] = UInt8(truncatingIfNeeded: contact.x >> 8)
            report[offset + 4] = UInt8(truncatingIfNeeded: contact.y); report[offset + 5] = UInt8(truncatingIfNeeded: contact.y >> 8)
        }
        return report
    }
    /// [select | home<<1 | back<<2, x, y, wheel].
    static func knobReport(select: Bool = false, home: Bool = false, back: Bool = false, wheel: Int8 = 0) -> Data {
        Data([(select ? 1 : 0) | (home ? 2 : 0) | (back ? 4 : 0), 0, 0, UInt8(bitPattern: wheel)])
    }
    /// Indices into the media descriptor's usage array.
    enum MediaKey: UInt8 { case play = 1, pause = 2, playPause = 3, next = 4, previous = 5 }
    /// Indices into the telephony descriptor's usage array.
    enum TelephonyKey: UInt8 { case hookSwitch = 1, flash = 2, drop = 3, mute = 4 }

    // MARK: HID descriptors

    private static func touchDescriptor(width: Int, height: Int) -> Data {
        let finger: [UInt8] = [0x05,0x0d,0x09,0x22,0xa1,0x02,0x09,0x38,0x75,0x08,0x95,0x01,0x81,0x02,
            0x15,0x00,0x25,0x01,0x09,0x33,0x75,0x01,0x95,0x01,0x81,0x02,0x95,0x07,0x81,0x03,
            0x05,0x01,0x26,UInt8(truncatingIfNeeded: width),UInt8(truncatingIfNeeded: width >> 8),
            0x09,0x30,0x75,0x10,0x95,0x01,0x81,0x02,0x26,UInt8(truncatingIfNeeded: height),UInt8(truncatingIfNeeded: height >> 8),
            0x09,0x31,0x81,0x02,0xc0]
        return Data([0x05,0x0d,0x09,0x04,0xa1,0x01] + Array(repeating: finger, count: touchContacts).flatMap { $0 } + [0xc0])
    }
    /// Multi-axis controller: button 1 = select, consumer AC Home / AC Back, 5 pad bits,
    /// absolute X/Y (unused, kept 0) and a relative wheel for focus movement.
    private static let knobDescriptor = Data([
        0x05,0x01,0x09,0x08,0xa1,0x01,
        0x05,0x09,0x09,0x01,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x01,0x81,0x02,
        0x05,0x0c,0x0a,0x23,0x02,0x0a,0x24,0x02,0x95,0x02,0x81,0x02,
        0x95,0x05,0x81,0x01,
        0x05,0x01,0x09,0x01,0xa1,0x00,
        0x09,0x30,0x09,0x31,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x02,0x81,0x02,0xc0,
        0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x01,0x81,0x06,0xc0])
    /// Consumer control, 1-byte array: none, Play, Pause, Play/Pause, Next, Previous, AC Search.
    private static let mediaDescriptor = Data([
        0x05,0x0c,0x09,0x01,0xa1,0x01,0x15,0x00,0x25,0x06,0x05,0x0c,
        0x0a,0x00,0x00,0x0a,0xb0,0x00,0x0a,0xb1,0x00,0x0a,0xcd,0x00,
        0x0a,0xb5,0x00,0x0a,0xb6,0x00,0x0a,0x9e,0x02,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0])
    /// Telephony, 1-byte array: none, Hook Switch, Flash, Drop, Mute, keypad 0–9 * #, keyboard delete.
    private static let telephonyDescriptor = Data([
        0x05,0x0b,0x09,0x07,0xa1,0x01,0x15,0x00,0x25,0x11,0x05,0x0b,
        0x09,0x00,0x09,0x20,0x09,0x21,0x09,0x26,0x09,0x2f,
        0x09,0xb0,0x09,0xb1,0x09,0xb2,0x09,0xb3,0x09,0xb4,0x09,0xb5,
        0x09,0xb6,0x09,0xb7,0x09,0xb8,0x09,0xb9,0x09,0xba,0x09,0xbb,
        0x05,0x07,0x09,0x2a,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0])
}
