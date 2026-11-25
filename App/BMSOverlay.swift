import CoreImage
import UIKit

/// Renders a small, noninteractive telemetry panel once per changed text. The
/// same bitmap is shown locally and composited into Ninebot's encoded video.
final class BMSOverlayPresenter {
    private let imageView = UIImageView()
    private var cachedText: String?
    private var cachedImage: CGImage?
    private var cachedConfiguration: ANTBMSCardConfiguration?
    private var constraints: [NSLayoutConstraint] = []
    var onImage: ((CGImage?, ANTBMSCardConfiguration) -> Void)?

    func attach(to surface: UIView) {
        imageView.isUserInteractionEnabled = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "电池实时信息"
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        surface.addSubview(imageView)
        cachedConfiguration = nil // Layout must be rebuilt even if telemetry arrived before attachment.
    }

    func update(enabled: Bool, reading: ANTBMSReading?, status: String,
                configuration: ANTBMSCardConfiguration) {
        guard enabled else {
            let wasVisible = !imageView.isHidden
            imageView.isHidden = true
            cachedText = nil; cachedImage = nil; cachedConfiguration = nil
            if wasVisible { onImage?(nil, configuration) }
            return
        }
        let text: String
        if let reading {
            text = configuration.lines(for: reading).joined(separator: "\n")
        } else {
            text = "ANT BMS · 无实时数据\n" + (status.contains("过期") || status.contains("断开") || status.contains("重连")
                ? "连接失联，等待恢复" : "等待电池数据")
        }
        let previousLineCount = cachedText?.components(separatedBy: "\n").count
        let lineCount = min(2, text.components(separatedBy: "\n").count)
        let changed = text != cachedText || cachedConfiguration != configuration || imageView.isHidden
        let needsLayout = previousLineCount != lineCount || cachedConfiguration != configuration
        if text != cachedText || cachedConfiguration?.background != configuration.background {
            cachedImage = Self.render(text, alarm: reading?.hasAlarm == true, background: configuration.background)
            imageView.image = cachedImage.map { UIImage(cgImage: $0) }
            imageView.accessibilityValue = text.replacingOccurrences(of: "\n", with: "，")
        }
        cachedText = text; cachedConfiguration = configuration
        imageView.isHidden = false
        if let surface = imageView.superview, needsLayout {
            layout(on: surface, configuration: configuration, lineCount: lineCount)
        }
        if changed { onImage?(cachedImage, configuration) }
    }

    /// Used by settings only. A sample reading must never enter the live overlay.
    static func preview(_ reading: ANTBMSReading, configuration: ANTBMSCardConfiguration) -> CGImage? {
        render(configuration.lines(for: reading).joined(separator: "\n"),
               alarm: reading.hasAlarm, background: configuration.background)
    }

    private func layout(on surface: UIView, configuration: ANTBMSCardConfiguration, lineCount: Int) {
        NSLayoutConstraint.deactivate(constraints)
        constraints = [
            configuration.position.isAtRight
                ? imageView.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6)
                : imageView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 6),
            imageView.widthAnchor.constraint(equalTo: surface.widthAnchor, multiplier: CGFloat(configuration.size.widthFraction)),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor,
                multiplier: CGFloat(lineCount == 1 ? 72 : 122) / 640),
            configuration.position.isAtTop
                ? imageView.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6)
                : imageView.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6)
        ]
        NSLayoutConstraint.activate(constraints)
    }

    private static func render(_ text: String, alarm: Bool, background: ANTBMSCardConfiguration.Background) -> CGImage? {
        let lineCount = min(2, text.components(separatedBy: "\n").count)
        let size = CGSize(width: 640, height: lineCount == 1 ? 72 : 122)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.withAlphaComponent(background.opacity).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let color: UIColor = alarm ? .systemOrange : .white
            for (index, line) in text.components(separatedBy: "\n").prefix(2).enumerated() {
                let baseFont = UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
                let width = (line as NSString).size(withAttributes: [.font: baseFont]).width
                let font = UIFont.monospacedDigitSystemFont(ofSize: min(36, max(18, 36 * 604 / max(1, width))), weight: .semibold)
                (line as NSString).draw(in: CGRect(x: 18, y: CGFloat(12 + index * 50), width: 604, height: 48), withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
        }.cgImage
    }
}
