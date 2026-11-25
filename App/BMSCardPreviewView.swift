import UIKit

/// A schematic background, using the same bitmap and scale as the real video.
/// Example readings stay in this settings view and never enter live telemetry.
final class BMSCardPreviewView: UIView {
    var configuration = ANTBMSCardConfiguration() { didSet { setNeedsDisplay() } }
    var image: CGImage? { didSet { setNeedsDisplay() } }
    var videoAspectRatio: CGFloat = 848 / 480 {
        didSet {
            guard videoAspectRatio != oldValue else { return }
            aspectConstraint?.isActive = false
            aspectConstraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / max(1, videoAspectRatio))
            aspectConstraint?.isActive = true
        }
    }
    private var aspectConstraint: NSLayoutConstraint?
    private var renderedText: [String]?
    private var renderedBackground: ANTBMSCardConfiguration.Background?

    func update(reading: ANTBMSReading?, configuration: ANTBMSCardConfiguration, aspectRatio: CGFloat) {
        if self.configuration != configuration { self.configuration = configuration }
        videoAspectRatio = aspectRatio
        let previewReading = reading ?? Self.example
        let text = configuration.lines(for: previewReading)
        if renderedText != text || renderedBackground != configuration.background {
            renderedText = text; renderedBackground = configuration.background
            image = BMSOverlayPresenter.preview(previewReading, configuration: configuration)
        }
        accessibilityValue = (reading == nil ? "示例数据，非实时读数。" : "实时数据。")
            + configuration.position.title + "，" + text.joined(separator: "，")
    }

    static let example = ANTBMSReading(voltage: 82.78, current: -12.3, power: -1018, stateOfCharge: 78,
        stateOfHealth: nil, stateCode: 4, capacityAh: 170, remainingAh: 131.92, cells: [4.1, 4.106],
        temperatures: [14], mosTemperature: 15, protectionBits: 0, warningBits: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isAccessibilityElement = true; accessibilityLabel = "BMS 卡片布局预览"
        layer.cornerRadius = 12; clipsToBounds = true
        aspectConstraint = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 480 / 848)
        aspectConstraint?.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        UIColor.secondarySystemBackground.setFill(); UIRectFill(bounds)
        let roads = UIBezierPath()
        for x in stride(from: CGFloat(24), to: bounds.width, by: 54) {
            roads.move(to: CGPoint(x: x, y: 0)); roads.addLine(to: CGPoint(x: x + 24, y: bounds.height))
        }
        for y in stride(from: CGFloat(22), to: bounds.height, by: 42) {
            roads.move(to: CGPoint(x: 0, y: y)); roads.addLine(to: CGPoint(x: bounds.width, y: y + 12))
        }
        UIColor.separator.withAlphaComponent(0.45).setStroke(); roads.lineWidth = 7; roads.stroke()
        let route = UIBezierPath()
        route.move(to: CGPoint(x: bounds.width * 0.3, y: bounds.height))
        route.addLine(to: CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.52))
        route.addLine(to: CGPoint(x: bounds.width * 0.63, y: bounds.height * 0.52))
        route.addLine(to: CGPoint(x: bounds.width * 0.68, y: 0))
        UIColor.systemBlue.withAlphaComponent(0.7).setStroke(); route.lineWidth = 5; route.lineJoinStyle = .round; route.stroke()
        guard let image else { return }
        let width = bounds.width * CGFloat(configuration.size.widthFraction)
        let height = width * CGFloat(image.height) / CGFloat(image.width)
        let margin: CGFloat = 6
        UIImage(cgImage: image).draw(in: CGRect(
            x: configuration.position.isAtRight ? bounds.width - margin - width : margin,
            y: configuration.position.isAtTop ? margin : bounds.height - margin - height,
            width: width, height: height))
    }
}
