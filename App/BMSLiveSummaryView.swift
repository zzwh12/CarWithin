import UIKit

/// A compact overview of fresh telemetry. Missing data never retains old values.
final class BMSLiveSummaryView: UIView {
    private var values: [ANTBMSCardConfiguration.Field: UILabel] = [:]
    private var tiles: [ANTBMSCardConfiguration.Field: UIView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let grid = UIStackView(); grid.axis = .vertical; grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor), grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let fields: [ANTBMSCardConfiguration.Field] = [.charge, .voltage, .current, .power, .temperature, .cellDelta]
        for offset in stride(from: 0, to: fields.count, by: 2) {
            let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
            for field in fields[offset..<(offset + 2)] {
                let label = UILabel(); label.text = field.title
                label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
                label.adjustsFontForContentSizeCategory = true
                let value = UILabel(); value.text = "--"; value.font = .preferredFont(forTextStyle: .title3)
                value.adjustsFontForContentSizeCategory = true
                value.adjustsFontSizeToFitWidth = true; value.minimumScaleFactor = 0.65
                let tile = UIStackView(arrangedSubviews: [label, value])
                tile.axis = .vertical; tile.spacing = 4
                tile.isLayoutMarginsRelativeArrangement = true
                tile.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
                tile.backgroundColor = .tertiarySystemFill; tile.layer.cornerRadius = 12
                tile.isAccessibilityElement = true; tile.accessibilityLabel = field.title
                values[field] = value; tiles[field] = tile; row.addArrangedSubview(tile)
            }
            grid.addArrangedSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ reading: ANTBMSReading?) {
        for (field, label) in values {
            let text = reading.map { field.text($0).replacingOccurrences(of: "压差 ", with: "") } ?? "--"
            label.text = text
            label.textColor = reading == nil ? .secondaryLabel : .label
            tiles[field]?.accessibilityValue = reading == nil ? "没有实时数据" : text
        }
    }
}
