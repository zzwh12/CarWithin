import UIKit
import CoreGraphics

/// Owns ANT telemetry and settings independently of CarPlay connection configuration.
/// CoreBluetooth callbacks and all UI work stay on the main queue.
final class ANTBMSController: NSObject {
    var onImage: ((CGImage?, ANTBMSCardConfiguration) -> Void)?
    var onLog: ((String) -> Void)?
    var aspectRatio: CGFloat = 848 / 480 { didSet { if aspectRatio != oldValue { refreshBMS() } } }
    private weak var rootPage: SettingsPageController?
    private var lastSelectedID: UUID?
    private let bmsClient = ANTBMSClient()
    private let bmsOverlay = BMSOverlayPresenter()
    private let bmsEnabledSwitch = UISwitch()
    private let bmsPosition = ChoiceMenu(items: ANTBMSCardConfiguration.Position.allCases.map(\.title))
    private let bmsCardSize = ChoiceMenu(items: ANTBMSCardConfiguration.Size.allCases.map(\.title))
    private let bmsCardBackground = ChoiceMenu(items: ANTBMSCardConfiguration.Background.allCases.map(\.title))
    private var bmsCardConfiguration = ANTBMSCardConfiguration()
    private var bmsFieldSwitches: [ANTBMSCardConfiguration.Field: UISwitch] = [:]
    private let bmsCardPreview = BMSCardPreviewView()
    private let bmsCardPreviewStatus = StatusLabel()
    private let bmsStatus = StatusLabel()
    private let bmsDetails = StatusLabel()
    private let bmsLiveSummary = BMSLiveSummaryView()
    private var bmsDeviceList: [UUID] = []

    override init() {
        super.init()
        configureBMS()
    }

    func attach(to surface: UIView) {
        bmsOverlay.attach(to: surface)
        refreshBMS()
    }

    private func page(_ title: String, _ build: @escaping () -> [SettingsSection]) -> SettingsPageController {
        SettingsPageController(title: title, build: build)
    }
    private func reloadVisibleSettings() {
        (rootPage?.navigationController?.topViewController as? SettingsPageController)?.reload()
    }
    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        let presenter: UIViewController? = rootPage?.navigationController ?? rootPage
        presenter?.present(alert, animated: true)
    }

    private func configureBMS() {
        bmsEnabledSwitch.isOn = UserDefaults.standard.bool(forKey: "antBMSEnabled")
        bmsEnabledSwitch.addTarget(self, action: #selector(bmsSettingsChanged), for: .valueChanged)
        bmsPosition.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardBackground.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardConfiguration = ANTBMSCardConfiguration(
            savedFields: UserDefaults.standard.stringArray(forKey: "antBMSCardFields"),
            sizeRawValue: UserDefaults.standard.object(forKey: "antBMSCardSize") as? Int,
            positionRawValue: UserDefaults.standard.object(forKey: "antBMSPosition") as? Int,
            backgroundRawValue: UserDefaults.standard.object(forKey: "antBMSCardBackground") as? Int)
        bmsCardSize.selectedSegmentIndex = bmsCardConfiguration.size.rawValue
        bmsPosition.selectedSegmentIndex = bmsCardConfiguration.position.rawValue
        bmsCardBackground.selectedSegmentIndex = bmsCardConfiguration.background.rawValue
        bmsCardSize.addTarget(self, action: #selector(bmsCardSizeChanged), for: .valueChanged)
        for field in ANTBMSCardConfiguration.Field.allCases {
            let control = UISwitch()
            control.isOn = bmsCardConfiguration.fields.contains(field)
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                guard self.bmsCardConfiguration.set(field, visible: control.isOn) else {
                    control.setOn(true, animated: true)
                    self.alert("至少显示一项", "如需隐藏整张卡片，请关闭「读取并显示 BMS」。")
                    return
                }
                self.saveBMSCardConfiguration()
            }, for: .valueChanged)
            bmsFieldSwitches[field] = control
        }
        bmsDetails.numberOfLines = 0
        bmsDetails.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        bmsOverlay.onImage = { [weak self] image, configuration in
            self?.onImage?(image, configuration)
        }
        bmsClient.onLog = { [weak self] message in self?.onLog?("BMS：" + message) }
        bmsClient.onChange = { [weak self] in self?.refreshBMS() }
        if bmsEnabledSwitch.isOn { bmsClient.start() }
        refreshBMS()
    }

    @objc private func bmsSettingsChanged() {
        UserDefaults.standard.set(bmsEnabledSwitch.isOn, forKey: "antBMSEnabled")
        if bmsEnabledSwitch.isOn { bmsClient.start() } else { bmsClient.stop() }
        refreshBMS()
        reloadVisibleSettings()
    }

    @objc private func bmsCardSizeChanged() {
        bmsCardConfiguration.size = ANTBMSCardConfiguration.Size(rawValue: bmsCardSize.selectedSegmentIndex) ?? .medium
        saveBMSCardConfiguration()
    }

    @objc private func bmsCardAppearanceChanged() {
        bmsCardConfiguration.position = ANTBMSCardConfiguration.Position(rawValue: bmsPosition.selectedSegmentIndex) ?? .topRight
        bmsCardConfiguration.background = ANTBMSCardConfiguration.Background(rawValue: bmsCardBackground.selectedSegmentIndex) ?? .standard
        saveBMSCardConfiguration()
    }

    private func saveBMSCardConfiguration() {
        UserDefaults.standard.set(bmsCardConfiguration.fields.map(\.rawValue), forKey: "antBMSCardFields")
        UserDefaults.standard.set(bmsCardConfiguration.size.rawValue, forKey: "antBMSCardSize")
        UserDefaults.standard.set(bmsCardConfiguration.position.rawValue, forKey: "antBMSPosition")
        UserDefaults.standard.set(bmsCardConfiguration.background.rawValue, forKey: "antBMSCardBackground")
        refreshBMS()
        reloadVisibleSettings()
    }

    private func applyBMSCardPreset(_ fields: [ANTBMSCardConfiguration.Field]) {
        bmsCardConfiguration = ANTBMSCardConfiguration(savedFields: fields.map(\.rawValue),
            sizeRawValue: bmsCardConfiguration.size.rawValue,
            positionRawValue: bmsCardConfiguration.position.rawValue,
            backgroundRawValue: bmsCardConfiguration.background.rawValue)
        for (field, control) in bmsFieldSwitches { control.isOn = bmsCardConfiguration.fields.contains(field) }
        saveBMSCardConfiguration()
    }

    private func refreshBMS() {
        let reading = bmsClient.freshReading
        bmsStatus.text = bmsEnabledSwitch.isOn ? bmsClient.status : "BMS 显示已关闭"
        bmsLiveSummary.update(reading)
        if let reading {
            let temperature = reading.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let mos = reading.mosTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let delta = reading.cellDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "--"
            let states = [0: "无状态", 1: "静止", 2: "充电", 3: "待机", 4: "放电", 5: "异常"]
            bmsDetails.text = String(format: "电量 %d%% · %.2f V · %+.1f A · %d W\n剩余 %.2f / %.2f Ah\n最高温度 %@ · MOS %@\n%d 串 · 单体压差 %@\n状态：%@\n保护位：0x%llX · 告警位：0x%llX",
                reading.stateOfCharge, reading.voltage, reading.current, reading.power,
                reading.remainingAh, reading.capacityAh, temperature, mos, reading.cells.count, delta,
                states[reading.stateCode] ?? "未知", reading.protectionBits, reading.alarmBits)
        } else {
            bmsDetails.text = "电量 -- · 电压 -- · 电流 -- · 功率 --\n等待校验有效的 ANT 实时数据。"
        }
        bmsOverlay.update(enabled: bmsEnabledSwitch.isOn, reading: reading, status: bmsClient.status,
                          configuration: bmsCardConfiguration)
        bmsCardPreview.update(reading: reading, configuration: bmsCardConfiguration,
                             aspectRatio: aspectRatio)
        bmsCardPreviewStatus.text = reading == nil ? "示例数据 · 当前没有实时读数" : "实时数据 · 当前连接的 ANT BMS"
        let ids = bmsClient.devices.map(\.id)
        if ids != bmsDeviceList || bmsClient.selectedID != lastSelectedID {
            lastSelectedID = bmsClient.selectedID
            bmsDeviceList = ids
            reloadVisibleSettings()
        }
    }
    func settingsPage() -> SettingsPageController {
        let root = page("电池与 BMS") { [unowned self] in
            [SettingsSection("蚂蚁 ANT BMS", [
                .control("读取并显示 BMS", self.bmsEnabledSwitch),
                .note(self.bmsStatus),
                .page("连接设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue), detail: { [unowned self] in
                    self.bmsClient.selectedName
                }) { [unowned self] in self.bmsDevicesPage() }
            ]),
            SettingsSection("实时电池", footer: "只显示最近 5 秒内的有效数据，断开后自动清空旧值。", [.view(self.bmsLiveSummary)]),
            SettingsSection("卡片与详情", [
                .page("卡片显示", icon: ("rectangle.topthird.inset.filled", .systemBlue), detail: { [unowned self] in
                    "\(self.bmsCardConfiguration.fields.count) 项 · \(self.bmsCardConfiguration.size.title)号"
                }) { [unowned self] in self.bmsCardPage() },
                .page("电池详情", icon: ("list.bullet.rectangle", .systemGray)) { [unowned self] in
                    self.page("电池详情") { [unowned self] in
                        [SettingsSection("实时参数", footer: "电流保留 ANT 原始符号。容量、温度、串数和状态由 BMS 上报。", [.note(self.bmsDetails)])]
                    }
                }
            ])]
        }
        rootPage = root
        return root
    }

    private func bmsDevicesPage() -> SettingsPageController {
        page("BMS 连接设备") { [unowned self] in
            var sections = [SettingsSection("当前设备", [
                .info("已记住的设备", self.bmsClient.selectedName),
                .note(self.bmsStatus)
            ])]
            guard self.bmsEnabledSwitch.isOn else {
                sections.append(SettingsSection(footer: "开启读取后搜索并选择自己的 ANT BMS。", [
                    .action("开启读取并查找设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in
                        self.bmsEnabledSwitch.setOn(true, animated: false)
                        self.bmsSettingsChanged()
                    }
                ]))
                return sections
            }
            sections.append(SettingsSection(footer: "选定后会记住并自动重连。连接不上时，先断开其他 BMS App。", [
                .action("扫描附近 BMS", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in self.bmsClient.scan() },
                .action("忘记当前 BMS", destructive: true) { [unowned self] in
                    self.bmsClient.forget()
                    self.reloadVisibleSettings()
                }
            ]))
            let devices = self.bmsClient.devices.map { device in
                var row = SettingsRow.action(device.name, detail: { "\(device.rssi) dBm" }) { [unowned self] in
                    self.bmsClient.select(device.id)
                }
                row.checked = { [weak self] in self?.bmsClient.selectedID == device.id }
                return row
            }
            sections.append(SettingsSection("附近设备", footer: "仅支持 ANT FFE0/FFE1 实时通道。扫描到 FFE0 不代表协议兼容，收到有效 ANT 数据后才确认连接。",
                devices.isEmpty ? [.info("暂无设备", "点击上方扫描")] : devices))
            return sections
        }
    }

    private func bmsCardPage() -> SettingsPageController {
        bmsCardPreview.update(reading: bmsClient.freshReading, configuration: bmsCardConfiguration,
                             aspectRatio: aspectRatio)
        return page("BMS 卡片显示") { [unowned self] in
            var sections = [SettingsSection("布局", footer: "修改后立即同步到手机和九号五寸、七寸投屏，并自动保存。卡片最多两行；减少显示项可留出更多地图空间。", [
                .control("字号", self.bmsCardSize),
                .control("显示位置", self.bmsPosition),
                .control("背景", self.bmsCardBackground),
                .page("字段顺序", icon: ("arrow.up.arrow.down", .systemBlue)) { [unowned self] in
                    BMSCardOrderViewController(fields: self.bmsCardConfiguration.fields) { [weak self] field, destination in
                        guard let self else { return }
                        self.bmsCardConfiguration.move(field, to: destination)
                        self.saveBMSCardConfiguration()
                    }
                }
            ])]
            sections.append(SettingsSection("布局预览", footer: "背景为布局示意，比例随所选仪表变化。没有实时读数时使用示例数据，示例不会进入实时读数或投屏画面。", [
                .note(self.bmsCardPreviewStatus), .view(self.bmsCardPreview)
            ]))
            sections.append(SettingsSection("快捷布局", [
                .action("精简：电量、总压、压差", icon: ("minus.circle", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.compactFields)
                },
                .action("常用：显示全部六项", icon: ("square.grid.2x2", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.Field.allCases)
                }
            ]))
            let fields = ANTBMSCardConfiguration.Field.allCases.compactMap { field -> SettingsRow? in
                guard let control = self.bmsFieldSwitches[field] else { return nil }
                return .control(field.title, control)
            }
            sections.append(SettingsSection("显示内容", footer: "至少保留一项。单体压差以 mV 显示；未知读数显示 --，BMS 告警会保留提示。", fields))
            return sections
        }
    }


}
