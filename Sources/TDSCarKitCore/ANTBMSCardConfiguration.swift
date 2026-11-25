import Foundation

/// Shared card content and scale for the phone and instrument video.
public struct ANTBMSCardConfiguration: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case charge, voltage, temperature, current, power, cellDelta

        public var title: String {
            switch self {
            case .charge: "电量"
            case .voltage: "总压"
            case .temperature: "最高温度"
            case .current: "电流"
            case .power: "功率"
            case .cellDelta: "单体压差"
            }
        }

        public func text(_ reading: ANTBMSReading) -> String {
            switch self {
            case .charge: return "\(reading.stateOfCharge)%"
            case .voltage: return String(format: "%.2fV", reading.voltage)
            case .temperature: return reading.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--°C"
            case .current: return String(format: "%+.1fA", reading.current)
            case .power: return "\(reading.power)W"
            case .cellDelta: return "压差 " + (reading.cellDelta.map { String(format: "%.0fmV", $0 * 1000) } ?? "--mV")
            }
        }
    }

    public enum Size: Int, CaseIterable, Sendable {
        case small, medium, large
        public var title: String { ["小", "中", "大"][rawValue] }
        /// Both compositors use this fraction of their video width.
        public var widthFraction: Double { [0.36, 0.46, 0.58][rawValue] }
    }

    /// Keep the two original right-side values so existing preferences migrate.
    public enum Position: Int, CaseIterable, Sendable {
        case topRight, bottomRight, topLeft, bottomLeft
        public var title: String { ["右上角", "右下角", "左上角", "左下角"][rawValue] }
        public var isAtTop: Bool { self == .topRight || self == .topLeft }
        public var isAtRight: Bool { self == .topRight || self == .bottomRight }
    }

    public enum Background: Int, CaseIterable, Sendable {
        case light, standard, opaque
        public var title: String { ["轻透", "标准", "不透明"][rawValue] }
        public var opacity: Double { [0.45, 0.86, 1][rawValue] }
    }

    public static let compactFields: [Field] = [.charge, .voltage, .cellDelta]
    public private(set) var fields: [Field]
    public var size: Size
    public var position: Position
    public var background: Background

    /// Missing/invalid saved preferences preserve the original six-field card.
    public init(savedFields: [String]? = nil, sizeRawValue: Int? = nil,
                positionRawValue: Int? = nil, backgroundRawValue: Int? = nil) {
        var seen = Set<Field>()
        let normalized = (savedFields?.compactMap(Field.init(rawValue:)) ?? Field.allCases)
            .filter { seen.insert($0).inserted }
        fields = normalized.isEmpty ? Field.allCases : normalized
        size = sizeRawValue.flatMap(Size.init(rawValue:)) ?? .medium
        position = positionRawValue.flatMap(Position.init(rawValue:)) ?? .topRight
        background = backgroundRawValue.flatMap(Background.init(rawValue:)) ?? .standard
    }

    /// Keep at least one metric visible, preserving the user's preferred order.
    @discardableResult
    public mutating func set(_ field: Field, visible: Bool) -> Bool {
        if !visible, fields == [field] { return false }
        if visible {
            if !fields.contains(field) { fields.append(field) }
        } else { fields.removeAll { $0 == field } }
        return true
    }

    public mutating func move(_ field: Field, to destination: Int) {
        guard let index = fields.firstIndex(of: field), fields.indices.contains(destination) else { return }
        fields.remove(at: index)
        fields.insert(field, at: destination)
    }

    public func lines(for reading: ANTBMSReading) -> [String] {
        let tokens = fields.map { $0.text(reading) }
        let split = tokens.count <= 3 ? tokens.count : (tokens.count + 1) / 2
        var lines = ["ANT  " + tokens.prefix(split).joined(separator: "  ")]
        if reading.hasAlarm { lines[0] += " · 告警" }
        if split < tokens.count { lines.append(tokens.dropFirst(split).joined(separator: "  ")) }
        return lines
    }
}
