import Foundation

/// Buttons CarWithin can press on the iPhone's behalf. Raw values are the browser message names.
enum CarPlayControl: String, CaseIterable {
    case home, back, select, knobPrevious, knobNext
    case previous, playPause, next
    case siri, hookSwitch

    var title: String {
        switch self {
        case .home: CWL("主页")
        case .back: CWL("返回")
        case .select: CWL("选择")
        case .knobPrevious: CWL("上一项")
        case .knobNext: CWL("下一项")
        case .previous: CWL("上一曲")
        case .playPause: CWL("播放/暂停")
        case .next: CWL("下一曲")
        case .siri: "Siri"
        case .hookSwitch: CWL("接听/挂断")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .back: "chevron.backward"
        case .select: "smallcircle.filled.circle"
        case .knobPrevious: "chevron.up"
        case .knobNext: "chevron.down"
        case .previous: "backward.fill"
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        case .siri: "mic.fill"
        case .hookSwitch: "phone.fill"
        }
    }
}

/// A finger in normalized display coordinates (0…1). `id` is unique per source while held.
struct TouchPoint: Equatable { let id: Int; let x: Double; let y: Double }

/// Keeps each finger in one HID slot from press to release. Several sources (this iPhone,
/// browser viewers) share the two CarPlay slots; a finger beyond the free slots is ignored.
/// A released finger is reported up at its last position, never at (0,0), which would first
/// drag it into the corner.
struct TouchSlots {
    private struct Held { let source: String; let id: Int; var x: Double; var y: Double }
    private var slots: [Held?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }

    /// Replaces every finger of `source` with `points` and returns the report contents:
    /// (slot, x, y, down) for each slot that is or just was in use.
    mutating func update(source: String, points: [TouchPoint]) -> [(slot: Int, x: Double, y: Double, down: Bool)] {
        var released: [(Int, Held)] = []
        for (slot, held) in slots.enumerated() {
            guard let held, held.source == source, !points.contains(where: { $0.id == held.id }) else { continue }
            released.append((slot, held)); slots[slot] = nil
        }
        for point in points {
            if let slot = slots.firstIndex(where: { $0?.source == source && $0?.id == point.id }) {
                slots[slot]?.x = point.x; slots[slot]?.y = point.y
            } else if let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = Held(source: source, id: point.id, x: point.x, y: point.y)
            }
        }
        var report = slots.enumerated().compactMap { slot, held in held.map { (slot, $0.x, $0.y, true) } }
        report += released.map { ($0.0, $0.1.x, $0.1.y, false) }
        return report
    }

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }
    mutating func reset() { slots = Array(repeating: nil, count: slots.count) }
}
