import UIKit
import SwiftUI
import AVKit
import Network
import NetworkExtension
import CoreLocation
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
#if !targetEnvironment(macCatalyst)
import VisionKit
#endif
import Security

final class ReceiverViewController: UIViewController, CLLocationManagerDelegate {
    private let receiver = NativeReceiver()
    private let antBMS = ANTBMSController()
    private let bluetooth = BLEBootstrap()
    private let sameDevice = SameDeviceProbe()
    private let transportProbe = DirectAccessoryTransport()
    private let controlBrowser = CarPlayControlBrowser()
    private let receiverBrowser = TDSCarKitReceiverBrowser()
    private let receiverPicker = UIButton(type: .system)
    private var remoteTarget: TDSCarKitReceiverBrowser.Target?
    private let modeControl = UISegmentedControl(items: [CWL("接收其他设备"), CWL("本机 CarPlay"), CWL("投送到 iPad")])
    private let nameField = UITextField()
    private let ipField = UITextField()
    private let ssidField = UITextField()
    private let passwordField = UITextField()
    private var passwordLoadedForSSID: String?
    private let channelField = UITextField()
    private let openNetworkSwitch = UISwitch()
    private enum SoundOutput: Int, CaseIterable {
        // Retain the persisted values so the existing Wi-Fi preference survives this change.
        case carWithin = 0, phone = 1, browser = 2

        var title: String { [CWL("在接收设备上播放"), CWL("由 iPhone 输出"), CWL("随画面传输（Wi-Fi）")][rawValue] }

        var explanation: String {
            switch self {
            case .carWithin: return CWL("声音由当前接收设备播放，例如 iPad 的扬声器。")
            case .phone: return CWL("用 iPhone 当前的声音输出。想让车机出声，请先配对并选中车机蓝牙。")
            case .browser: return CWL("由接收画面的设备播放。画面自动播放后，若网页提示「开启声音」，点一下即可。")
            }
        }
    }
    private var selectedSoundOutput: SoundOutput = {
        let defaults = UserDefaults.standard
        let receivesOnPad = UIDevice.current.userInterfaceIdiom == .pad
        let legacy: SoundOutput = receivesOnPad && (defaults.object(forKey: "speakerAudio") as? Bool ?? true)
            ? .carWithin : .phone
        let saved = (defaults.object(forKey: "soundOutput") as? Int).flatMap(SoundOutput.init(rawValue:)) ?? legacy
        if saved == .carWithin && !receivesOnPad {
            defaults.set(SoundOutput.phone.rawValue, forKey: "soundOutput")
            return .phone
        }
        return saved
    }()
    private var receivesAudioFromAnotherDevice: Bool { modeControl.selectedSegmentIndex == 0 }
    private var soundOutput: SoundOutput {
        if outputMode != .browser { return .phone }
        if selectedSoundOutput == .carWithin && !receivesAudioFromAnotherDevice { return .phone }
        if selectedSoundOutput == .browser && !videoOutputSwitch.isOn { return .phone }
        return selectedSoundOutput
    }
    private let videoOutputSwitch = UISwitch()
    private let videoOutputPortField = UITextField()
    private let secureVideoOutputPortField = UITextField()
    private let httpsMode = ChoiceMenu(items: [CWL("本地 IP"), "sslip.io", "DuckDNS"])
    private let httpsDomainField = UITextField()
    private let httpsTokenField = UITextField()
    private let httpsStatus = StatusLabel()
    private let portStatus = StatusLabel()
    private let pictureInPictureButton = UIButton(type: .system)
    private let driveControl = ChoiceMenu(items: [CWL("左舵"), CWL("右舵")])
    private let networkSummary = UILabel()
    private let locationManager = CLLocationManager()
    private var awaitingNetworkPermission = false
    private var activeWiFiForm: UUID?
    private var fetchingNetwork = false
    private var canDetectWiFiName: Bool { (Bundle.main.object(forInfoDictionaryKey: "TDSWiFiNameDetection") as? String) == "YES" }
    /// The settings sheet while it is shown.
    private weak var settingsNavigation: UINavigationController?
    private let transportProbeButton = UIButton(type: .system)
    private let orientationControl = ChoiceMenu(items: [CWL("横屏"), CWL("竖屏")])
    private let wifiPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var networkStartupTask: Task<Void, Never>?
    private var waitingForNetwork = false
    private var networkRestartCount = 0
    private var localStartupID: UUID?
    private let aspectRatioControl = ChoiceMenu(items: [CWL("预设比例")] + ReceiverConfiguration.aspectRatios.map(\.title))
    private let resolutionControl = ChoiceMenu(items: ReceiverConfiguration.resolutions.map { "\($0.label)（\($0.width)×\($0.height)）" })
    private let frameRateControl = ChoiceMenu(items: [CWL("自动"), "30 FPS", "60 FPS"])
    private let codecControl = ChoiceMenu(items: [CWL("自动"), "H.264", "H.265"])
    /// 0 = follow the head unit's screen, 1 = the fixed resolution.
    private let sizeModeControl = ChoiceMenu(items: [CWL("跟随车机"), CWL("固定尺寸"), CWL("自定义尺寸")])
    private let carbitSizeModeControl = ChoiceMenu(items: [CWL("固定尺寸"), CWL("自定义尺寸")])
    /// CarbitLink output cadence; 60 FPS is opt-in because the head unit must keep up.
    private let carbitFrameRateControl = ChoiceMenu(items: [CWL("30 FPS"), CWL("60 FPS")])
    private var selectedCarbitFrameRate: ZeehoFrameRate {
        carbitFrameRateControl.selectedSegmentIndex == 1 ? .fps60 : .fps30
    }
    private let iconSizeControl = ChoiceMenu(items: ReceiverConfiguration.iconSizes.map { "\($0.title)（\($0.widthMM) mm）" })
    private let autoRestartSwitch = UISwitch()
    private let autoConnectOnLaunchSwitch = UISwitch()
    private let performanceControl = ChoiceMenu(items: BrowserPerformance.allCases.map(\.title))
    private let showTouchesSwitch = UISwitch()
    private let carButtonSwitch = UISwitch()
    private static let customVehicleIconKey = "customVehicleButtonPNG"
    private var customVehicleIcon: Data? { UserDefaults.standard.data(forKey: Self.customVehicleIconKey) }
    private var importingVehicleIcon = false
    /// 0 = off, 1 = when leaving the app, 2 = as soon as CarPlay shows.
    private let pictureInPictureTiming = ChoiceMenu(items: [CWL("关闭"), CWL("离开 App 时"), CWL("出画面后立即")])
    private var didRequestImmediatePiP = false
    /// What the running session was started with; compared against what the head unit reports.
    private var liveDisplay: DisplayPlan?
    /// Screen reported by a browser in this run; it wins over the saved default.
    private var reportedScreen: CarScreen?
    private var primaryViewer: UUID?
    private var screenAdaptation: DispatchWorkItem?
    /// Automatic restarts for lighter settings in this connection; at most two.
    private var autoRestarts = 0
    /// 0 = normal, 1 = 30 FPS, 2 = also at most 720p. Raised by CWL("自动重启") when a browser keeps hitching.
    private var lightLevel = 0
    private var restartingAutomatically = false
    private var pendingRestartReason: String?
    private let appearanceControl = ChoiceMenu(items: ReceiverConfiguration.Appearance.allCases.map(\.title))
    /// CarPlay keys under the inline video.
    private let controlBar = UIStackView()
    private let secureBrowserURLLabel = UILabel()
    private let secureBrowserCopyButton = UIButton(type: .system)
    private let secureBrowserRow = UIStackView()
    private let secureBrowserDisclosure = UIButton(type: .system)
    private let httpsExpandedKey = "browserHTTPSExpanded"
    private var httpsExpanded: Bool { UserDefaults.standard.bool(forKey: httpsExpandedKey) }
    private let browserCard = UIStackView()
    private let zeehoCard = UIStackView()
    private let zeehoCardStatus = UILabel()
    private let zeehoStatus = StatusLabel()
    private let zeehoAddressField = UITextField()
    private let zeehoSEPlusAddressField = UITextField()
    private let zeehoSEPlusAutomaticSwitch = UISwitch()
    private let zeeho62AutomaticSwitch = UISwitch()
    private let zeehoSEPlusFrameRateControl = ChoiceMenu(items: ZeehoFrameRate.allCases.map(\.title))
    private let zeehoSEPlusCanvasControl = ChoiceMenu(items: ZeehoCanvas.allCases.map(\.title))
    private let zeehoSEPlusVideoModeControl = ChoiceMenu(items: ZeehoVideoMode.allCases.map(\.title))
    private let audioRoutePicker: AVRoutePickerView = {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.widthAnchor.constraint(equalToConstant: 44).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return picker
    }()
    private var selectedZeehoCanvas: ZeehoCanvas {
        ZeehoCanvas(rawValue: zeehoSEPlusCanvasControl.selectedSegmentIndex) ?? .wide
    }
    private var selectedZeehoVideoMode: ZeehoVideoMode {
        guard outputMode == .zeehoSEPlus else { return .transcode }
        let mode = ZeehoVideoMode(rawValue: zeehoSEPlusVideoModeControl.selectedSegmentIndex) ?? .transcode
        return mode.effective(for: selectedZeehoFrameRate)
    }
    private var audioRouteDescription: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portName)（\($0.portType.rawValue)）" }.joined(separator: "、")
    }
    private var selectedZeehoFrameRate: ZeehoFrameRate {
        guard outputMode == .zeehoSEPlus else { return .fps25 }
        let rates = ZeehoFrameRate.allCases
        let index = max(0, min(zeehoSEPlusFrameRateControl.selectedSegmentIndex, rates.count - 1))
        return rates[index]
    }
    private var usesAutomaticZeehoAddress: Bool {
        if outputMode == .zeehoSEPlus { return zeehoSEPlusAutomaticSwitch.isOn }
        return outputMode == .zeeho && zeeho62AutomaticSwitch.isOn
    }
    private var activeZeehoAddressField: UITextField {
        outputMode == .zeehoSEPlus ? zeehoSEPlusAddressField : zeehoAddressField
    }
    private func updateZeehoStatus(_ message: String) {
        zeehoStatus.text = message
        zeehoCardStatus.text = message
    }
    private let cfmotoCard = UIStackView()
    private let cfmotoCardStatus = UILabel()
    private let cfmotoStatus = StatusLabel()
    private let cfmotoAddressField = UITextField()
    /// 春风 5 寸 / 6.2 寸共用地址与端口，只有画面规格不同。
    private var cfmotoProfile: CfmotoProfile? {
        switch outputMode {
        case .cfmoto5: return .fiveInch
        case .cfmoto62: return .sixInch
        default: return nil
        }
    }
    private func updateCfmotoStatus(_ message: String) {
        cfmotoStatus.text = message
        cfmotoCardStatus.text = message
    }
    private let ninebotCard = UIStackView()
    private var ninebotCardInstructions: UILabel?
    private static let ninebotFiveInstructions = CWL("连接仪表 Wi-Fi，先启动本机 CarPlay。没有画面时，再到九号出行开启投屏导航。")
    private static let ninebotOfficialInstructions = CWL("加入仪表 Wi-Fi 后，先在这里启动 CarPlay，再到九号出行开启投屏导航，并让九号出行留在后台。")
    private let ninebotCardStatus = UILabel()
    private let ninebotStatus = StatusLabel()
    private let ninebotAddressField = UITextField()
    private let ninebot43AddressField = UITextField()
    private var activeNinebotAddressField: UITextField { outputMode == .ninebot43 ? ninebot43AddressField : ninebotAddressField }
    private var ninebotInstructions: String {
        outputMode == .ninebot ? Self.ninebotFiveInstructions : Self.ninebotOfficialInstructions
    }
    private func updateNinebotStatus(_ message: String) {
        ninebotStatus.text = message
        ninebotCardStatus.text = message
    }
    private let tailingCard = UIStackView()
    private let tailingCardStatus = UILabel()
    private let tailingAddressField = UITextField()
    private let tailingStatus = StatusLabel()
    private func updateTailingStatus(_ message: String) {
        tailingStatus.text = message; tailingCardStatus.text = message
    }
    private let carLifeCard = UIStackView()
    private let carbitCard = UIStackView()
    private let carbitCardStatus = UILabel()
    private let carbitStatus = StatusLabel()
    private let carbitAddressField = UITextField()
    private func updateCarbitStatus(_ text: String) {
        carbitStatus.text = text
        carbitCardStatus.text = text
    }
    private let airPlayCard = UIStackView()
    private let carLifeCardStatus = UILabel()
    private let airPlayCardStatus = UILabel()
    private let airPlayRoutePicker = AVRoutePickerView()
    private let airPlayRetryButton = UIButton(type: .system)
    private let browserURLLabel = UILabel()
    private let browserViewersLabel = UILabel()
    private let browserCopyButton = UIButton(type: .system)
    private let bluetoothSetupSwitch = UISwitch()
    private var needsNetworkDetails: Bool { modeControl.selectedSegmentIndex != 0 || bluetoothSetupSwitch.isOn }
    private let startButton = UIButton(type: .system)
    private let heading = UILabel()
    private let explanation = UILabel()
    private let statusLabel = UILabel()
    private let startupHint = UILabel()
    private var startupHintTask: DispatchWorkItem?
    private var startupHintGeneration = UUID()
    private let connectionHelp = UILabel()
    private let logView = UITextView()
    private let videoSurface = H264Surface()
    private let inlineVideoContainer = UIView()
    private var inlineVideoConstraints: [NSLayoutConstraint] = []
    private lazy var pictureInPicture = CarPlayPictureInPicture(surface: videoSurface)
    private let keepAlive = BackgroundKeepAlive()
    private let keepAliveSwitch = UISwitch()
    private let headUnitOutput = ChoiceMenu(items: HeadUnitOutput.menuOrder.map(\.title))
    private enum HeadUnitOutput: Int {
        // Persisted in headUnitOutputV2. Append new modes after existing values.
        case browser, carLife, airPlay, tailing, ninebot, zeeho, ninebotSeven, ninebot43, zeehoSEPlus, zeehoAE2, cfmoto5, cfmoto62, carbit
        // Display order is independent of the persisted raw values above.
        @MainActor static let menuOrder: [Self] = [.browser, .carLife, .airPlay]
            + (UIDevice.current.userInterfaceIdiom == .phone ? [.carbit] : [])
            + [.ninebot43, .ninebot, .ninebotSeven, .tailing, .zeeho, .zeehoSEPlus, .zeehoAE2, .cfmoto5, .cfmoto62]
        @MainActor var menuIndex: Int { Self.menuOrder.firstIndex(of: self)! }
        var title: String {
            switch self {
            case .browser: return CWL("浏览器")
            case .carLife: return "CarLife"
            case .airPlay: return "AirPlay"
            case .ninebot43: return CWL("九号 4.3 寸")
            case .ninebot: return CWL("九号 5 寸")
            case .ninebotSeven: return CWL("九号 7 寸")
            case .tailing: return CWL("台铃 4.3 寸")
            case .zeeho: return CWL("极核 6.2 寸")
            case .zeehoSEPlus: return CWL("极核 SE+ 5/5.5 寸")
            case .zeehoAE2: return CWL("极核 AE2 Pro 5 寸")
            case .cfmoto5: return CWL("春风 5 寸")
            case .cfmoto62: return CWL("春风 6.2 寸")
            case .carbit: return CWL("亿连直连（实验）")
            }
        }
        var ninebotMode: NinebotOutput.Mode? {
            switch self {
            case .ninebot: .fiveInch
            case .ninebotSeven: .sevenInch
            case .ninebot43: .fourThreeInch
            default: nil
            }
        }
        var zeehoProfile: TailingDisplayProfile? {
            switch self {
            case .zeeho: return .zeeho62
            case .zeehoAE2: return .zeehoAE2
            case .zeehoSEPlus: return .zeehoSEPlus
            default: return nil
            }
        }
        var cfmoto: Bool { self == .cfmoto5 || self == .cfmoto62 }
        var usesInstrumentWiFi: Bool { cfmoto || self == .tailing || zeehoProfile != nil || ninebotMode != nil }
        var requiresWiFiInterface: Bool { usesInstrumentWiFi || self == .carbit }
    }
    private var airPlayStreamID: UUID?
    private var airPlayStreamURL: URL?
    private var airPlayPlayer: AVPlayer?
    private var airPlayRouteObservation: NSKeyValueObservation?
    private var airPlayItemObservation: NSKeyValueObservation?
    private var airPlayHealthTimer: Timer?
    private var airPlayLastVideoAt: TimeInterval?
    private var airPlayWaitingSince: TimeInterval?
    private var airPlaySourceWasStale = false
    private var airPlayTimeObservation: NSKeyValueObservation?
    #if DEBUG
    private var airPlayDiagnostic = ""
    #endif
    private static let lastAirPlayDeviceKey = "lastAirPlayDeviceName"
    private var airPlayReady = false
    private let airPlayStatus = StatusLabel()
    private func updateAirPlayStatus(_ message: String) {
        airPlayStatus.text = message
        airPlayCardStatus.text = message
        airPlayRoutePicker.isUserInteractionEnabled = airPlayReady
        airPlayRoutePicker.alpha = airPlayReady ? 1 : 0.45
        if airPlayReady {
            airPlayRoutePicker.accessibilityTraits.remove(.notEnabled)
        } else {
            airPlayRoutePicker.accessibilityTraits.insert(.notEnabled)
        }
    }
    private var outputMode: HeadUnitOutput {
        let index = headUnitOutput.selectedSegmentIndex
        return HeadUnitOutput.menuOrder.indices.contains(index) ? HeadUnitOutput.menuOrder[index] : .browser
    }
    private let carLifeAddressField = UITextField()
    private let carLifeStatus = StatusLabel()
    private func updateCarLifeStatus(_ message: String) {
        carLifeStatus.text = message
        carLifeCardStatus.text = message
    }
    struct DisplayPlan: Equatable {
        var width: Int; var height: Int; var fps: Int; var codec: VideoCodec; var iconWidthMM: Int
    }
    /// Local frames were dropped in the background; the display needs a new keyframe on return.
    private var skippedLocalVideo = false
    /// The session survives backgrounding through PiP or the silent keep-alive audio.
    private var canRunInBackground: Bool { keepAlive.isRunning || pictureInPicture.canKeepSessionInBackground }
    private let fullscreenButton = UIButton(type: .system)
    private let videoActions = UIStackView()
    private let passwordStatus = StatusLabel()
    private var videoHeight: NSLayoutConstraint!
    private var fullscreenContainer: UIView?
    private var fullscreenConstraints: [NSLayoutConstraint] = []
    private var sessionHasVehicleButton = false
    private weak var fullscreenExitButton: UIButton?
    private var fullscreenFadeTimer: Timer?
    override var prefersStatusBarHidden: Bool { fullscreenContainer != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { fullscreenContainer != nil }
    private var displayedVideo = false
    private var identity: AccessoryIdentity?
    private var running = false
    private var lines: [String] = []
    private var handledLaunch = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !running && !waitingForNetwork { modeChanged() }
        guard !handledLaunch else { return }
        handledLaunch = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-same-device-transport") {
            revealSettings()
            testSameDeviceTransport()
            return
        } else if ProcessInfo.processInfo.arguments.contains("--test-local-transport") {
            modeControl.selectedSegmentIndex = 1; modeChanged(); toggleReceiver()
            return
        } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--open-settings") {
            // Screenshots: --open-settings [display|screens|wifi|presets|vehicle|sound|output|web|log|lab|about|usage]
            revealSettings()
            let arguments = ProcessInfo.processInfo.arguments
            let pages: [String: () -> UIViewController] = [
                "display": displayPage, "screens": screensPage, "wifi": wifiPage, "presets": presetsPage,
                "vehicle": vehiclePage, "sound": soundPage, "output": headUnitPage,
                "tailing": { [unowned self] in self.headUnitOutput.selectedSegmentIndex = HeadUnitOutput.tailing.menuIndex; self.refreshVideoOutputSummary(); return self.headUnitPage() },
                "web": headUnitPage, "log": logPage, "lab": diagnosticsPage, "about": aboutPage,
                "usage": usagePage, "https": httpsSettingsPage,
                "thanks": { ContributionsViewController() }, "support": { DeveloperSupportViewController(openAlipayOnEntry: false) }, "support-auto": { DeveloperSupportViewController() },
                "support-info": { SupportInformationViewController() }]
            if arguments.indices.contains(index + 1), let make = pages[arguments[index + 1]] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.settingsNavigation?.pushViewController(make(), animated: false)
                }
            } else if arguments.indices.contains(index + 1), arguments[index + 1] == "history" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.showVersionHistory()
                }
            }
            return
        }
        #endif
        if autoConnectOnLaunchSwitch.isOn, startButton.isEnabled, !running, !waitingForNetwork {
            toggleReceiver()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CarWithin"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape.fill"), style: .plain, target: self, action: #selector(toggleSettings))
        navigationItem.rightBarButtonItem?.accessibilityLabel = CWL("设置")
        locationManager.delegate = self
        heading.font = .systemFont(ofSize: 32, weight: .bold)
        heading.numberOfLines = 0

        explanation.font = .preferredFont(forTextStyle: .body); explanation.textColor = .secondaryLabel; explanation.numberOfLines = 0
        [heading, explanation, statusLabel, connectionHelp, networkSummary].forEach { $0.adjustsFontForContentSizeCategory = true; $0.lineBreakMode = .byWordWrapping }
        statusLabel.font = .preferredFont(forTextStyle: .headline); statusLabel.numberOfLines = 0
        statusLabel.textColor = .systemBlue
        let savedName = UserDefaults.standard.string(forKey: "receiverName")
        // Earlier default names follow the rename; a name the user typed is kept.
        let legacyDefaults: Set<String> = ["TDS Car Kit", "CarPlays"]
        nameField.text = savedName.map { legacyDefaults.contains($0) ? "CarWithin" : $0 } ?? "CarWithin"
        ipField.text = ReceiverConfiguration.localIPv4Addresses().first
        let selectedPreset = WiFiPresetStore.selected()
        ssidField.text = selectedPreset?.ssid ?? UserDefaults.standard.string(forKey: "wifiSSID")
        ssidField.addTarget(self, action: #selector(networkNameChanged), for: .editingChanged)
        ssidField.addTarget(self, action: #selector(loadWiFiPassword), for: .editingDidEnd)
        channelField.text = String(Int(selectedPreset?.channel ?? UInt8(UserDefaults.standard.object(forKey: "wifiChannel") as? Int ?? 36)))
        openNetworkSwitch.isOn = selectedPreset?.isOpen ?? false
        channelField.keyboardType = .numberPad
        channelField.placeholder = CWL("默认 36，一般无需修改")
        bluetoothSetupSwitch.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.selectedSegmentIndex = UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0
        modeControl.isHidden = UIDevice.current.userInterfaceIdiom == .phone
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 1)
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 2)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        connectionHelp.font = .preferredFont(forTextStyle: .body)
        connectionHelp.textColor = .secondaryLabel; connectionHelp.numberOfLines = 0
        receiverPicker.configuration = .bordered(); receiverPicker.showsMenuAsPrimaryAction = true
        let heroIcon = UIImageView(image: UIImage(systemName: "car.side.fill"))
        heroIcon.tintColor = .systemBlue
        heroIcon.contentMode = .scaleAspectFit
        heroIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        heroIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let titleStack = UIStackView(arrangedSubviews: [heroIcon, heading])
        titleStack.axis = .horizontal; titleStack.alignment = .center; titleStack.spacing = 14
        let statusIcon = UIImageView(image: UIImage(systemName: "circle.fill"))
        statusIcon.tintColor = .systemBlue
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 9).isActive = true
        let statusRow = UIStackView(arrangedSubviews: [statusIcon, statusLabel])
        statusRow.axis = .horizontal; statusRow.alignment = .center; statusRow.spacing = 8
        statusRow.isLayoutMarginsRelativeArrangement = true
        statusRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        statusRow.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        statusRow.layer.cornerRadius = 12; statusRow.layer.cornerCurve = .continuous
        startupHint.font = .preferredFont(forTextStyle: .footnote)
        startupHint.textColor = .secondaryLabel
        startupHint.numberOfLines = 0
        startupHint.adjustsFontForContentSizeCategory = true
        startupHint.isHidden = true
        let heroStack = UIStackView(arrangedSubviews: [titleStack, explanation, statusRow, startupHint, connectionHelp, receiverPicker, networkSummary])
        heroStack.axis = .vertical; heroStack.spacing = 14
        heroStack.isLayoutMarginsRelativeArrangement = true
        heroStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 20, bottom: 22, trailing: 20)
        heroStack.backgroundColor = .secondarySystemGroupedBackground
        heroStack.layer.cornerRadius = 24; heroStack.layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: [heroStack])
        configureSettingsControls()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in self.applyAppearance() }
        }
        applyAppearance()
        refreshVideoOutputSummary()

        startButton.configuration = .filled(); startButton.setTitle(CWL("启动本机 CarPlay"), for: .normal)
        startButton.addTarget(self, action: #selector(toggleReceiver), for: .touchUpInside)
        startButton.configuration?.cornerStyle = .large
        startButton.configuration?.image = UIImage(systemName: "play.fill")
        startButton.configuration?.imagePadding = 8
        startButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        heroStack.addArrangedSubview(startButton)

        let browserIcon = UIImageView(image: UIImage(systemName: "globe"))
        browserIcon.tintColor = .systemGreen; browserIcon.contentMode = .scaleAspectFit
        browserIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let browserTitle = UILabel(); browserTitle.text = CWL("局域网浏览器访问")
        browserTitle.font = .preferredFont(forTextStyle: .headline); browserTitle.adjustsFontForContentSizeCategory = true
        let browserHeader = UIStackView(arrangedSubviews: [browserIcon, browserTitle])
        browserHeader.spacing = 8; browserHeader.alignment = .center
        browserURLLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        browserURLLabel.adjustsFontSizeToFitWidth = true; browserURLLabel.minimumScaleFactor = 0.65
        browserURLLabel.textColor = .label
        browserViewersLabel.font = .preferredFont(forTextStyle: .footnote); browserViewersLabel.textColor = .secondaryLabel
        browserViewersLabel.numberOfLines = 0
        browserCopyButton.configuration = .tinted()
        browserCopyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        browserCopyButton.configuration?.imagePadding = 6
        browserCopyButton.setTitle(CWL("复制"), for: .normal)
        browserCopyButton.addTarget(self, action: #selector(copyVideoURL), for: .touchUpInside)
        browserCopyButton.setContentHuggingPriority(.required, for: .horizontal)
        browserCopyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let urlRow = UIStackView(arrangedSubviews: [browserURLLabel, browserCopyButton])
        urlRow.spacing = 10; urlRow.alignment = .center
        secureBrowserURLLabel.font = browserURLLabel.font
        secureBrowserURLLabel.adjustsFontSizeToFitWidth = true; secureBrowserURLLabel.minimumScaleFactor = 0.65
        secureBrowserCopyButton.configuration = .tinted()
        secureBrowserCopyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        secureBrowserCopyButton.configuration?.imagePadding = 6
        secureBrowserCopyButton.setTitle(CWL("复制"), for: .normal)
        secureBrowserCopyButton.addTarget(self, action: #selector(copySecureVideoURL), for: .touchUpInside)
        secureBrowserCopyButton.setContentHuggingPriority(.required, for: .horizontal)
        secureBrowserCopyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        secureBrowserRow.addArrangedSubview(secureBrowserURLLabel)
        secureBrowserRow.addArrangedSubview(secureBrowserCopyButton)
        secureBrowserRow.spacing = 10; secureBrowserRow.alignment = .center
        var disclosure = UIButton.Configuration.plain()
        disclosure.title = CWL("HTTPS（低延迟）")
        disclosure.imagePlacement = .trailing
        disclosure.imagePadding = 6
        disclosure.contentInsets = .zero
        secureBrowserDisclosure.configuration = disclosure
        secureBrowserDisclosure.contentHorizontalAlignment = .leading
        secureBrowserDisclosure.addTarget(self, action: #selector(toggleHTTPSAddress), for: .touchUpInside)
        func caption(_ text: String) -> UILabel {
            let label = UILabel(); label.text = text
            label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
            return label
        }
        browserCard.addArrangedSubview(browserHeader)
        browserCard.addArrangedSubview(caption(CWL("兼容模式（HTTP）")))
        browserCard.addArrangedSubview(urlRow)
        browserCard.addArrangedSubview(secureBrowserDisclosure)
        browserCard.addArrangedSubview(secureBrowserRow)
        browserCard.addArrangedSubview(browserViewersLabel)
        configureOutputCard(browserCard)
        stack.addArrangedSubview(browserCard)
        configureConnectionCard(carLifeCard, title: CWL("CarLife 连接"), symbol: "car.rear.fill", color: .systemGreen,
            instructions: CWL("让车机和 iPhone 连同一个 Wi-Fi。打开车机上的 CarLife，再启动本机 CarPlay。"),
            status: carLifeCardStatus)
        let carLifeSettings = UIButton(type: .system)
        carLifeSettings.configuration = .tinted()
        carLifeSettings.configuration?.title = CWL("连接设置")
        carLifeSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        carLifeCard.addArrangedSubview(carLifeSettings)
        stack.addArrangedSubview(carLifeCard)
        configureConnectionCard(carbitCard, title: CWL("亿连直连"), symbol: "car.fill", color: .systemIndigo,
            instructions: CWL("打开车机上的亿连，让 iPhone 和车机连入同一 Wi-Fi。在连接设置中扫码或选择车机，然后启动本机 CarPlay。"),
            status: carbitCardStatus)
        let carbitSettings = UIButton(type: .system)
        carbitSettings.configuration = .tinted()
        carbitSettings.configuration?.title = CWL("连接设置")
        carbitSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        carbitCard.addArrangedSubview(carbitSettings)
        stack.addArrangedSubview(carbitCard)

        configureConnectionCard(zeehoCard, title: "极核仪表连接", symbol: "scooter", color: .systemBlue,
            instructions: CWL("让 iPhone 加入极核仪表 Wi-Fi，打开仪表投屏后启动 CarPlay。"), status: zeehoCardStatus)
        let zeehoSettings = UIButton(type: .system)
        zeehoSettings.configuration = .tinted()
        zeehoSettings.configuration?.title = CWL("连接设置")
        zeehoSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        zeehoCard.addArrangedSubview(zeehoSettings)
        stack.addArrangedSubview(zeehoCard)

        configureConnectionCard(cfmotoCard, title: "春风仪表连接", symbol: "scooter", color: .systemBlue,
            instructions: "让 iPhone 加入春风仪表 Wi-Fi，打开仪表投屏后启动 CarPlay。春风和极核同一套 PXC 协议（TCP 10920/10921/10922 + 10930 通知），由仪表回连后再逐帧拉画面。", status: cfmotoCardStatus)
        let cfmotoSettings = UIButton(type: .system)
        cfmotoSettings.configuration = .tinted()
        cfmotoSettings.configuration?.title = CWL("连接设置")
        cfmotoSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        cfmotoCard.addArrangedSubview(cfmotoSettings)
        stack.addArrangedSubview(cfmotoCard)
        ninebotCardInstructions = configureConnectionCard(ninebotCard, title: CWL("九号仪表连接"), symbol: "scooter", color: .systemBlue,
            instructions: Self.ninebotFiveInstructions, status: ninebotCardStatus)
        let ninebotSettings = UIButton(type: .system)
        ninebotSettings.configuration = .tinted()
        ninebotSettings.configuration?.title = CWL("连接设置")
        ninebotSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        ninebotCard.addArrangedSubview(ninebotSettings)
        stack.addArrangedSubview(ninebotCard)
        configureConnectionCard(tailingCard, title: CWL("台铃 4.3 寸连接"), symbol: "scooter", color: .systemOrange,
            instructions: CWL("iPhone 加入仪表的 Wi-Fi，打开仪表投屏，再启动本机 CarPlay。画面在仪表上显示，操作在 iPhone 上完成。"),
            status: tailingCardStatus)
        let tailingSettings = UIButton(type: .system)
        tailingSettings.configuration = .tinted()
        tailingSettings.configuration?.title = CWL("连接设置")
        tailingSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        tailingCard.addArrangedSubview(tailingSettings)
        stack.addArrangedSubview(tailingCard)

        configureConnectionCard(airPlayCard, title: CWL("AirPlay 连接"), symbol: "airplayvideo", color: .systemBlue,
            instructions: CWL("接收设备与 iPhone 连同一 Wi-Fi。启动 CarPlay 后，可在这里选择设备。"),
            status: airPlayCardStatus)
        let routeTitle = UILabel()
        routeTitle.text = CWL("选择 AirPlay 设备")
        routeTitle.font = .preferredFont(forTextStyle: .body)
        routeTitle.adjustsFontForContentSizeCategory = true
        routeTitle.numberOfLines = 0
        airPlayRoutePicker.prioritizesVideoDevices = true
        airPlayRoutePicker.tintColor = .systemBlue
        airPlayRoutePicker.activeTintColor = .systemGreen
        airPlayRoutePicker.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        airPlayRoutePicker.layer.cornerRadius = 14
        airPlayRoutePicker.accessibilityLabel = routeTitle.text
        routeTitle.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            airPlayRoutePicker.widthAnchor.constraint(equalToConstant: 44),
            airPlayRoutePicker.heightAnchor.constraint(equalToConstant: 44)
        ])
        let routeRow = UIStackView(arrangedSubviews: [routeTitle, airPlayRoutePicker])
        routeRow.alignment = .center
        routeRow.spacing = 8
        airPlayCard.addArrangedSubview(routeRow)
        airPlayRetryButton.configuration = .tinted()
        airPlayRetryButton.configuration?.title = CWL("重试 AirPlay")
        airPlayRetryButton.addAction(UIAction { [weak self] _ in self?.retryAirPlayTransport() }, for: .touchUpInside)
        airPlayRetryButton.isHidden = true
        airPlayCard.addArrangedSubview(airPlayRetryButton)
        stack.addArrangedSubview(airPlayCard)

        inlineVideoContainer.isHidden = true
        inlineVideoContainer.clipsToBounds = true
        inlineVideoContainer.layer.cornerRadius = 20
        inlineVideoContainer.layer.cornerCurve = .continuous
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        restoreInlineVideoSurface()
        videoHeight = inlineVideoContainer.heightAnchor.constraint(equalTo: inlineVideoContainer.widthAnchor,
                                                                    multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
        stack.addArrangedSubview(inlineVideoContainer)
        videoActions.addArrangedSubview(fullscreenButton)
        videoActions.addArrangedSubview(pictureInPictureButton)
        videoActions.axis = .horizontal; videoActions.distribution = .fillEqually; videoActions.spacing = 10
        fullscreenButton.configuration = .borderedProminent()
        fullscreenButton.setTitle(CWL("全屏显示"), for: .normal)
        fullscreenButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        fullscreenButton.addTarget(self, action: #selector(showFullscreen), for: .touchUpInside)
        pictureInPictureButton.configuration = .bordered()
        pictureInPictureButton.setTitle(CWL("画中画"), for: .normal)
        pictureInPictureButton.setImage(UIImage(systemName: "pip.enter"), for: .normal)
        pictureInPictureButton.addTarget(self, action: #selector(startPictureInPicture), for: .touchUpInside)
        videoActions.isHidden = true
        fullscreenButton.isHidden = false; pictureInPictureButton.isHidden = false
        videoActions.tag = 8801
        stack.addArrangedSubview(videoActions)
        Self.barControls.forEach { controlBar.addArrangedSubview(makeControlButton($0)) }
        controlBar.axis = .horizontal; controlBar.distribution = .fillEqually; controlBar.spacing = 8
        controlBar.isHidden = true
        stack.addArrangedSubview(controlBar)
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground; logView.layer.cornerRadius = 12
        logView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        transportProbeButton.addTarget(self, action: #selector(testSameDeviceTransport), for: .touchUpInside)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.panGestureRecognizer.require(toFail: videoSurface.touchOwnershipGestureRecognizer)
        view.addSubview(scroll); scroll.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            preferredWidth, stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        receiver.onLog = { [weak self] in self?.log($0) }; bluetooth.onLog = { [weak self] in self?.log($0) }
        receiver.onControlConnected = { [weak self] in self?.sameDevice.didConnectControl() }
        receiver.onCarbitPreview = { [weak self] sample in
            guard let self, self.running, self.videoSurface.usesPreviewFrames else { return }
            // Keep feeding the PiP window once it is up, even while the app is backgrounded.
            guard UIApplication.shared.applicationState != .background
                    || self.pictureInPicture.canKeepSessionInBackground else { return }
            self.videoSurface.showPreviewFrame(sample)
            self.didDisplayLocalPicture()
            self.pictureInPicture.sourceMayBeReady()
        }
        receiver.onVideo = { [weak self] data, codec in
            guard let self, self.running, !self.videoSurface.usesPreviewFrames else { return }
            if self.outputMode == .airPlay { self.airPlayLastVideoAt = ProcessInfo.processInfo.systemUptime }
            // Nothing local is visible in the background without PiP: save the decoding work.
            // The browser output is fed before this callback and keeps running.
            if (self.outputMode == .zeehoSEPlus && UIApplication.shared.applicationState != .active)
                || (UIApplication.shared.applicationState == .background && !self.pictureInPicture.canKeepSessionInBackground) {
                self.skippedLocalVideo = true; return
            }
            do {
                try self.videoSurface.enqueue(accessUnit: data, codec: codec)
                self.didDisplayLocalPicture()
                self.pictureInPicture.sourceMayBeReady()
            } catch {
                self.statusLabel.text = CWL("视频显示异常")
                self.log(CWL("视频显示失败：{1}", [String(describing: error.localizedDescription)]))
            }
        }
        antBMS.onLog = { [weak self] in self?.log($0) }
        antBMS.onImage = { [weak self] image, configuration in
            self?.receiver.setBMSOverlay(image, configuration: configuration)
        }
        antBMS.attach(to: videoSurface)
        videoSurface.onLog = { [weak self] in self?.log($0) }
        videoSurface.onKeyframeNeeded = { [weak self] reason in
            guard let self else { return }
            if self.outputMode == .zeehoSEPlus, UIApplication.shared.applicationState != .active { return }
            // In the background without PiP nothing is drawn locally; asking for keyframes then
            // would only bloat the browser stream with repeated IDRs.
            guard UIApplication.shared.applicationState != .background || self.pictureInPicture.canKeepSessionInBackground else { return }
            self.receiver.requestKeyFrame(reason: reason)
        }
        videoSurface.onTouches = { [weak self] points in
            self?.receiver.touches(source: "local", points)
            self?.refreshFullscreenExitButton()
        }
        receiver.onZeehoState = { [weak self] message in
            guard let self, self.running, self.outputMode.zeehoProfile != nil else { return }
            self.updateZeehoStatus(message)
        }
        receiver.onCfmotoState = { [weak self] message in
            guard let self, self.running, self.outputMode.cfmoto else { return }
            self.updateCfmotoStatus(message)
        }
        receiver.onNinebotState = { [weak self] message in
            guard let self, self.running, self.outputMode.ninebotMode != nil else { return }
            self.updateNinebotStatus(message)
        }
        receiver.onTailingState = { [weak self] message in
            guard let self, self.running, self.outputMode == .tailing else { return }
            self.updateTailingStatus(message)
        }
        receiver.onCarLifeState = { [weak self] message in
            guard let self, self.running, self.outputMode == .carLife else { return }
            self.updateCarLifeStatus(message)
        }
        receiver.onCarbitState = { [weak self] message in
            guard let self, self.running, self.outputMode == .carbit else { return }
            self.updateCarbitStatus(message)
        }
        receiver.onBrowserDisplay = { [weak self] display, viewerID in self?.browserReportedDisplay(display, viewerID: viewerID) }
        receiver.onBrowserStruggling = { [weak self] peer, reason in self?.browserStruggling(peer: peer, reason: reason) }
        receiver.onCarUIRequested = { [weak self] in
            guard let self else { return }
            self.log(CWL("在 CarPlay 中点按了 CarWithin 车辆按钮"))
            self.hideFullscreen(); self.revealSettings()
        }
        receiver.onAirPlayReady = { [weak self] id in
            guard let self, self.airPlayStreamID == id else { return }
            self.airPlayReady = true
            self.startAirPlayTransport()
        }
        receiver.onVideoOutputState = { [weak self] message in
            self?.portStatus.text = message
            self?.browserViewersLabel.text = message
            if let self, self.outputMode == .airPlay, self.running, !self.airPlayReady { self.updateAirPlayStatus(message) }
        }
        pictureInPicture.onLog = { [weak self] in self?.log($0) }
        pictureInPicture.onFailure = { [weak self] in
            guard let self, self.running else { return }
            if UIApplication.shared.applicationState == .background {
                // Without a PiP window nothing shows the preview anymore.
                if self.videoSurface.usesPreviewFrames { self.receiver.setLocalVideoEnabled(false) }
                if !self.keepAlive.isRunning { self.stop() }
            } else {
                self.statusLabel.text = CWL("画中画未开启，可点「画中画」重试")
            }
        }
        pictureInPicture.onStopped = { [weak self] in
            guard let self, self.running else { return }
            if UIApplication.shared.applicationState == .background {
                if self.videoSurface.usesPreviewFrames { self.receiver.setLocalVideoEnabled(false) }
                if !self.keepAlive.isRunning { self.stop() }
            } else {
                self.resumeLocalVideo()
            }
        }
        keepAlive.onLog = { [weak self] in self?.log($0) }
        pictureInPicture.onRestore = { [weak self] in
            self?.hideFullscreen()
        }
        receiver.onFailure = { [weak self] in self?.stop() }
        bluetooth.onFailure = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        bluetooth.onAdvertising = { [weak self] in
            guard let self, self.running else { return }
            self.statusLabel.text = CWL("蓝牙广播已开启，正在等待 iPhone")
        }
        controlBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onTargets = { [weak self] targets in
            guard let self, !self.running, self.modeControl.selectedSegmentIndex == 2 else { return }
            if let selected = self.remoteTarget, !targets.contains(selected) { self.remoteTarget = nil }
            self.receiverPicker.isEnabled = !targets.isEmpty
            self.receiverPicker.setTitle(self.remoteTarget.map { "\($0.name) · \($0.address)" }
                ?? (targets.isEmpty ? CWL("正在搜索 iPad 接收端…") : CWL("选择 iPad 接收端")), for: .normal)
            self.receiverPicker.menu = UIMenu(children: targets.map { target in
                UIAction(title: target.name, subtitle: "\(target.address):\(target.port)") { [weak self] _ in
                    self?.remoteTarget = target
                    self?.receiverPicker.setTitle("\(target.name) · \(target.address)", for: .normal)
                }
            })
        }
        sameDevice.onStage = { [weak self] message in
            guard let self, self.running, !self.displayedVideo else { return }
            if self.modeControl.selectedSegmentIndex == 2 {
                self.statusLabel.text = CWL("正在连接 iPad…")
            } else {
                self.statusLabel.text = CWL("正在连接 CarPlay…")
                self.scheduleStartupHint()
            }
        }
        sameDevice.onLog = { [weak self] in self?.log($0) }
        sameDevice.onFinished = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        #if DEBUG
        // Clears screens recorded by automated tests with a simulated browser.
        if ProcessInfo.processInfo.arguments.contains("--reset-car-screens") {
            CarScreenStore.screens().forEach { CarScreenStore.remove($0.key) }
            refreshScreenMenu()
        }
        #endif
        wifiPathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshNetworkAddresses() }
        }
        wifiPathMonitor.start(queue: DispatchQueue(label: "CarWithin.wifiPath"))
        loadIdentity()
        loadWiFiPassword()
        modeChanged()
        #if targetEnvironment(macCatalyst)
        log(CWL("正在 Mac Catalyst 上运行原生 UIKit 接收端"))
        #elseif targetEnvironment(simulator)
        log(CWL("模拟器无法验证蓝牙和 CoreAccessories 真机能力"))
        #else
        log(CWL("正在 iPhone/iPad 真机上运行"))
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(airPlayAudioRouteChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }
    deinit {
        wifiPathMonitor.cancel()
        networkStartupTask?.cancel()
    }

    /// Presets are listed on their own settings page; refresh it if it is open.
    private func refreshWiFiPresetMenu() { reloadVisibleSettings() }
    private func applyWiFiPreset(_ preset: WiFiPreset) {
        WiFiPresetStore.select(preset.ssid)
        ssidField.text = preset.ssid
        channelField.text = String(preset.channel)
        openNetworkSwitch.isOn = preset.isOpen
        passwordField.text = ""
        passwordLoadedForSSID = nil
        loadWiFiPassword()
        refreshWiFiPresetMenu(); refreshNetworkSummary()
    }
    private func saveCurrentWiFiPreset() -> Bool {
        let ssid = ssidField.text ?? ""
        let channelText = channelField.text ?? ""
        let channel = channelText.isEmpty ? UInt8(36) : UInt8(channelText)
        guard !ssid.isEmpty, ssid.utf8.count <= 32, let channel, (1...196).contains(channel) else {
            passwordStatus.text = CWL("请输入有效的 Wi-Fi 名称和 1–196 的兼容信道。"); return false
        }
        let password = openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        guard openNetworkSwitch.isOn || (8...63).contains(password.utf8.count) else {
            passwordStatus.text = CWL("Wi-Fi 密码需要 8–63 字节。"); return false
        }
        do {
            try WiFiCredentials.save(password, for: ssid)
            WiFiPresetStore.upsert(ssid: ssid, channel: channel, isOpen: openNetworkSwitch.isOn)
            passwordStatus.text = WiFiCredentials.isTemporary(for: ssid)
                ? WiFiCredentials.temporaryNotice : CWL("已保存 Wi-Fi 预设“{1}”", [String(describing: ssid)])
            refreshWiFiPresetMenu()
            return true
        } catch { passwordStatus.text = CWL("保存 Wi-Fi 预设失败：{1}", [String(describing: error.localizedDescription)]); return false }
    }
    @objc private func displaySettingChanged() {
        guard !running else { return }
        saveDisplaySettings()
        updateVideoAspect()
        reloadVisibleSettings()
    }
    private func saveDisplaySettings() {
        let defaults = UserDefaults.standard
        defaults.set(resolutionControl.selectedSegmentIndex, forKey: "displayResolutionIndex")
        defaults.set(aspectRatioControl.selectedTitle, forKey: "displayAspectRatio")
        defaults.set([0, 30, 60][max(0, frameRateControl.selectedSegmentIndex)], forKey: "displayMaxFPS")
        defaults.set(["auto", "h264", "h265"][max(0, codecControl.selectedSegmentIndex)], forKey: "videoCodec")
        defaults.set(sizeModeControl.selectedSegmentIndex, forKey: "displaySizeMode")
        defaults.set(carbitSizeModeControl.selectedSegmentIndex == 1, forKey: "carbitCustomSizeEnabled")
        defaults.set(selectedCarbitFrameRate.rawValue, forKey: "carbitFrameRate")
        defaults.set(ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM, forKey: "widthPhysicalMM")
        defaults.set(selectedPerformance.rawValue, forKey: "browserPerformance")
        defaults.set(autoRestartSwitch.isOn, forKey: "autoRestart")
        defaults.set(showTouchesSwitch.isOn, forKey: "showTouches")
        defaults.set(carButtonSwitch.isOn, forKey: "carButton")
    }
    private var selectedPerformance: BrowserPerformance { BrowserPerformance.allCases[max(0, performanceControl.selectedSegmentIndex)] }
    private var followsCarScreen: Bool { outputMode != .carbit && sizeModeControl.selectedSegmentIndex == 0 }
    private var usesCustomSize: Bool {
        switch outputMode {
        case .carbit: return carbitSizeModeControl.selectedSegmentIndex == 1
        case .browser, .airPlay, .carLife: return sizeModeControl.selectedSegmentIndex == 2
        default: return false
        }
    }
    private var customSizeKey: String { outputMode == .browser ? "browserCustomDisplaySize" : "headUnitCustomDisplaySize" }
    private func acceptsCustomSize(width: Int, height: Int) -> Bool {
        ReceiverConfiguration.supportsDisplaySize(width: width, height: height) &&
        (outputMode == .browser || (width <= 1920 && height <= 1080))
    }
    private var customSize: (width: Int, height: Int) {
        if let pair = UserDefaults.standard.array(forKey: customSizeKey) as? [Int], pair.count == 2,
           acceptsCustomSize(width: pair[0], height: pair[1]) { return (pair[0], pair[1]) }
        return (1280, 720)
    }
    /// The screen "跟随车机" sizes for: reported in this run, else the ticked or latest saved one.
    private var targetScreen: CarScreen? { outputMode == .browser ? reportedScreen ?? CarScreenStore.preferred() : nil }

    /// Size, frame rate and codec for the next session from the settings, the known head-unit
    /// screen and any lighter level chosen by CWL("自动重启").
    private func planDisplay(for screen: CarScreen?) -> DisplayPlan {
        if let cfmoto = cfmotoProfile {
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            // 按偶数对齐：H.264 4:2:0 不接受 515 这样的奇数高度。
            return DisplayPlan(width: cfmoto.encodeWidth, height: cfmoto.encodeHeight,
                               fps: cfmoto.fps, codec: .h264, iconWidthMM: icon)
        }
        if let profile = outputMode.zeehoProfile {
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            let size = profile == .zeehoSEPlus ? selectedZeehoCanvas.size : profile.preferredSize
            return DisplayPlan(width: size.width, height: size.height, fps: selectedZeehoFrameRate.sourceFPS,
                               codec: .h264, iconWidthMM: icon)
        }
        if let mode = outputMode.ninebotMode {
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            let dimensions: (Int, Int)
            switch mode {
            case .fiveInch: dimensions = (NinebotOutput.width, NinebotOutput.height)
            case .sevenInch: dimensions = (NinebotOutput.sevenInchFormat.width, NinebotOutput.sevenInchFormat.height)
            case .fourThreeInch: dimensions = (NinebotOutput.fourThreeFormat.width * 2, NinebotOutput.fourThreeFormat.height * 2)
            }
            // CarPlay advertises at least 30 FPS. NinebotOutput limits the instrument independently.
            return DisplayPlan(width: dimensions.0, height: dimensions.1, fps: 30, codec: .h264, iconWidthMM: icon)
        }
        if outputMode == .tailing {
            // CarPlay requires at least 320 per side; render 2× the instrument then downsample.
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            return DisplayPlan(width: 960, height: 544, fps: 30, codec: .h264, iconWidthMM: icon)
        }
        let cap = usesCustomSize ? customSize : selectedResolution()
        let portrait = !usesCustomSize && UIDevice.current.userInterfaceIdiom == .pad && orientationControl.selectedSegmentIndex == 1
        var width = portrait ? cap.height : cap.width, height = portrait ? cap.width : cap.height
        var capArea = cap.width * cap.height
        if lightLevel >= 2 { capArea = min(capArea, 1280 * 720) }
        // CarLife head units decode H.264 up to 1080p and usually ask for 30 FPS.
        if outputMode != .browser { capArea = min(capArea, 1920 * 1080) }
        if followsCarScreen, let screen {
            width = screen.width; height = screen.height
        }
        // Scale down, keeping the aspect ratio, to the chosen maximum area and 3840 per side.
        var scale = min(1, (Double(capArea) / Double(width * height)).squareRoot(), 3840 / Double(max(width, height)))
        if outputMode != .browser {
            scale = min(scale, 1920 / Double(width), 1080 / Double(height))
        }
        width = max(320, Int(Double(width) * scale) / 2 * 2); height = max(320, Int(Double(height) * scale) / 2 * 2)
        if !usesCustomSize, !followsCarScreen, let ratio = selectedAspectRatio {
            (width, height) = ReceiverConfiguration.fixedDisplaySize(area: capArea, ratio: ratio,
                maxWidth: outputMode == .browser ? 3840 : 1920,
                maxHeight: outputMode == .browser ? 3840 : 1080)
        }
        var fps: Int
        switch frameRateControl.selectedSegmentIndex {
        case 1: fps = 30
        case 2: fps = 60
        default: fps = screen.map { (1..<45).contains($0.refreshHz) ? 30 : 60 } ?? 60
        }
        if lightLevel >= 1 { fps = min(fps, 30) }
        if outputMode == .carbit { fps = selectedCarbitFrameRate.sourceFPS }
        if outputMode != .browser { fps = min(fps, outputMode == .carbit ? 60 : 30) }
        var codec: VideoCodec
        switch codecControl.selectedSegmentIndex {
        case 1: codec = .h264
        case 2: codec = .h265
        default: codec = screen?.supportsH265 == true ? .h265 : .h264
        }
        if outputMode != .browser { codec = .h264 }
        let defaultIconWidth = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
        let iconWidth = followsCarScreen ? screen?.iconWidthMM ?? defaultIconWidth : defaultIconWidth
        return DisplayPlan(width: width, height: height, fps: fps, codec: codec, iconWidthMM: iconWidth)
    }
    private func refreshScreenMenu() { reloadVisibleSettings() }
    private var selectedAspectRatio: ReceiverConfiguration.AspectRatio? {
        ReceiverConfiguration.aspectRatios.first { $0.title == aspectRatioControl.selectedTitle }
    }
    private func selectedResolution() -> (width: Int, height: Int) {
        let options = ReceiverConfiguration.resolutions
        let index = resolutionControl.selectedSegmentIndex
        let option = options.indices.contains(index) ? options[index] : options[ReceiverConfiguration.defaultResolutionIndex]
        return (option.width, option.height)
    }
    private func reloadVisibleSettings() {
        (settingsNavigation?.topViewController as? SettingsPageController)?.reload()
    }
    private func updateVideoAspect() {
        antBMS.aspectRatio = outputMode == .ninebotSeven ? 1024 / 600 : 848 / 480
        guard videoHeight != nil else { return }
        let plan = running ? (liveDisplay ?? planDisplay(for: targetScreen)) : planDisplay(for: targetScreen)
        let width = plan.width, height = plan.height
        videoHeight.isActive = false
        videoHeight = inlineVideoContainer.heightAnchor.constraint(equalTo: inlineVideoContainer.widthAnchor,
                                                           multiplier: CGFloat(height) / CGFloat(width))
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
    }
    @objc private func keepAliveChanged() {
        UserDefaults.standard.set(keepAliveSwitch.isOn, forKey: "backgroundKeepAlive")
        if !keepAliveSwitch.isOn { keepAlive.stop() }
        else if running, UIApplication.shared.applicationState == .active { keepAlive.start() }
    }
    @objc private func appearanceChanged() {
        UserDefaults.standard.set(appearanceControl.selectedSegmentIndex, forKey: "carPlayAppearance")
        applyAppearance()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { applyAppearance() }
    }
    /// Sends the wanted day/night state; the receiver keeps it for the next session too.
    private func applyAppearance() {
        // iOS flips light/dark while taking the app-switcher snapshot; ignore changes off screen.
        guard UIApplication.shared.applicationState != .background else { return }
        let choice = ReceiverConfiguration.Appearance(rawValue: appearanceControl.selectedSegmentIndex) ?? .system
        let night: Bool
        switch choice {
        case .system: night = traitCollection.userInterfaceStyle == .dark
        case .light: night = false
        case .dark: night = true
        }
        receiver.setNightMode(night)
    }
    private func makeControlButton(_ control: CarPlayControl) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: control.symbol)
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.receiver.press(control)
        })
        button.accessibilityLabel = control.title
        button.showsLargeContentViewer = true; button.largeContentTitle = control.title
        return button
    }
    /// The keys worth a button on a touch screen; knob up/down/select stay on keyboards.
    private static let barControls: [CarPlayControl] = [.home, .back, .siri, .previous, .playPause, .next, .hookSwitch]
    @objc private func videoOutputSettingChanged() {
        guard !running else { return }
        refreshVideoOutputSummary()
        (settingsNavigation?.topViewController as? SettingsPageController)?.refreshDetails()
    }
    @objc private func saveBrowserPorts() {
        guard !running, let browserPort else { return }
        let defaults = UserDefaults.standard
        if outputMode == .airPlay {
            defaults.set(Int(browserPort), forKey: "videoOutputPort")
            return
        }
        guard browserPortError == nil else { return }
        defaults.set(Int(browserPort), forKey: "videoOutputPort")
        if secureVideoOutputPortField.text?.isEmpty == false, let secureBrowserPort {
            defaults.set(Int(secureBrowserPort), forKey: "secureVideoOutputPort")
        } else {
            defaults.removeObject(forKey: "secureVideoOutputPort")
        }
    }
    @objc private func videoOutputToggled() {
        guard !running else { return }
        UserDefaults.standard.set(videoOutputSwitch.isOn, forKey: "videoOutputEnabled")
        refreshVideoOutputSummary()
        reloadVisibleSettings()
    }
    private var browserAddress: String? {
        ReceiverConfiguration.wifiIPv4Address()
            ?? (UIDevice.current.userInterfaceIdiom == .phone ? nil : ReceiverConfiguration.localIPv4Addresses().first)
    }
    private func portNumber(_ text: String?) -> UInt16? {
        guard let text, let port = UInt16(text), port > 0 else { return nil }
        return port
    }
    private var browserPort: UInt16? { portNumber(videoOutputPortField.text) }
    private var defaultSecurePort: UInt16 {
        guard let browserPort, browserPort < UInt16.max else { return 9889 }
        return browserPort + 1
    }
    private var secureBrowserPort: UInt16? {
        if secureVideoOutputPortField.text?.isEmpty != false { return defaultSecurePort }
        return portNumber(secureVideoOutputPortField.text)
    }
    private var browserPortError: String? {
        guard let browserPort else { return CWL("HTTP 端口请输入 1–65535。") }
        guard let secureBrowserPort else { return CWL("HTTPS 端口请输入 1–65535，或留空使用默认值。") }
        guard browserPort != secureBrowserPort else { return CWL("HTTP 和 HTTPS 端口不能相同。") }
        return nil
    }
    private var browserURL: String? {
        guard let address = browserAddress, let browserPort else { return nil }
        return "http://\(address):\(browserPort)"
    }
    private var localBrowserURL: URL? {
        browserPort.flatMap { URL(string: "http://127.0.0.1:\($0)/") }
    }
    private var secureBrowserURL: String? {
        guard let address = browserAddress, let port = secureBrowserPort, port != browserPort else { return nil }
        guard let host = HTTPSConfiguration.host(address: address) else { return nil }
        return "https://\(host):\(port)"
    }
    private func configureOutputCard(_ card: UIStackView) {
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
    }

    @discardableResult
    private func configureConnectionCard(_ card: UIStackView, title: String, symbol: String, color: UIColor,
                                         instructions: String, status: UILabel) -> UILabel {
        configureOutputCard(card)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.spacing = 8; header.alignment = .center
        let help = UILabel()
        help.text = instructions
        help.font = .preferredFont(forTextStyle: .subheadline)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        for label in [help, status] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        card.addArrangedSubview(header)
        card.addArrangedSubview(help)
        card.addArrangedSubview(status)
        return help
    }

    private func refreshBrowserAddressLabels() {
        browserURLLabel.text = browserURL ?? (browserPort == nil ? CWL("HTTP 端口无效") : CWL("未连接 Wi-Fi"))
        browserCopyButton.isEnabled = browserURL != nil
        secureBrowserURLLabel.text = secureBrowserURL ?? (browserPortError == nil ? CWL("未连接 Wi-Fi") : CWL("请检查 HTTPS 端口"))
        secureBrowserCopyButton.isEnabled = secureBrowserURL != nil
    }

    private func refreshVideoOutputSummary() {
        videoOutputSwitch.isEnabled = !running && outputMode == .browser
        videoOutputPortField.isEnabled = !running && outputMode == .browser && videoOutputSwitch.isOn
        secureVideoOutputPortField.isEnabled = videoOutputPortField.isEnabled
        if outputMode == .airPlay {
            videoOutputPortField.isEnabled = !running
            if !running {
                updateAirPlayStatus(browserPort == nil ? CWL("播放端口请输入 1–65535。") : CWL("等待启动 CarPlay。"))
            }
        }
        secureVideoOutputPortField.placeholder = String(defaultSecurePort)
        portStatus.text = browserPortError ?? (running ? CWL("停止 CarPlay 后可修改端口。") : CWL("启动 CarPlay 后即可打开上方地址。"))
        let showsLocalOutput = modeControl.selectedSegmentIndex != 2
        zeehoCard.isHidden = !showsLocalOutput || outputMode.zeehoProfile == nil
        if !running {
            let address = usesAutomaticZeehoAddress ? "自动查找仪表 IP" : "仪表 IP：\(activeZeehoAddressField.text ?? "192.168.0.1")"
            updateZeehoStatus("等待启动 CarPlay · \(address)")
        }
        ninebotCard.isHidden = !showsLocalOutput || outputMode.ninebotMode == nil
        ninebotCardInstructions?.text = ninebotInstructions
        if !running { updateNinebotStatus("等待启动 CarPlay · 仪表 IP：\(activeNinebotAddressField.text ?? "")") }
        cfmotoCard.isHidden = !showsLocalOutput || !outputMode.cfmoto
        if !running {
            updateCfmotoStatus("等待启动 CarPlay · 仪表 IP：\(cfmotoAddressField.text?.isEmpty == false ? cfmotoAddressField.text! : "自动取网关")")
        }
        tailingCard.isHidden = !showsLocalOutput || outputMode != .tailing
        if !running { updateTailingStatus(CWL("等待启动 CarPlay · 仪表 IP：{1}", [String(describing: tailingAddressField.text ?? "192.168.1.1")])) }
        carLifeCard.isHidden = !showsLocalOutput || outputMode != .carLife
        carbitCard.isHidden = !showsLocalOutput || outputMode != .carbit
        airPlayCard.isHidden = !showsLocalOutput || outputMode != .airPlay
        browserCard.isHidden = outputMode != .browser || !videoOutputSwitch.isOn
        guard outputMode == .browser, videoOutputSwitch.isOn else { return }
        refreshBrowserAddressLabels()
        secureBrowserDisclosure.configuration?.image = UIImage(systemName: httpsExpanded ? "chevron.up" : "chevron.down")
        secureBrowserDisclosure.accessibilityValue = httpsExpanded ? CWL("已展开") : CWL("已折叠")
        secureBrowserRow.isHidden = !httpsExpanded
        if !running {
            browserViewersLabel.text = CWL("启动后最多 {1} 台同时观看。", [String(describing: VideoOutputServer.maximumViewers)])
        }
    }
    @objc private func toggleHTTPSAddress() {
        UserDefaults.standard.set(!httpsExpanded, forKey: httpsExpandedKey)
        refreshVideoOutputSummary()
    }
    @objc private func copyVideoURL() { copy(browserURL, button: browserCopyButton) }
    @objc private func copySecureVideoURL() { copy(secureBrowserURL, button: secureBrowserCopyButton) }
    private func copy(_ url: String?, button: UIButton) {
        guard let url else { return }
        UIPasteboard.general.string = url
        button.setTitle(CWL("已复制"), for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { button.setTitle(CWL("复制"), for: .normal) }
    }
    @objc private func startPictureInPicture() {
        if !pictureInPicture.start() { statusLabel.text = CWL("暂时无法开启画中画") }
    }
    private func didDisplayLocalPicture() {
        guard !displayedVideo else { return }
        displayedVideo = true
        inlineVideoContainer.isHidden = false; statusLabel.text = CWL("正在显示 CarPlay")
        clearStartupHint()
        networkStartupTask?.cancel(); networkStartupTask = nil
        videoActions.isHidden = false; controlBar.isHidden = false
        pictureInPictureButton.isHidden = outputMode == .zeehoSEPlus
        log(videoSurface.usesPreviewFrames ? CWL("亿连本机预览已送入显示层") : CWL("视频已送入本机显示层"))
        if UIDevice.current.userInterfaceIdiom == .pad { showFullscreen() }
        updatePictureInPicturePolicy()
    }
    private var displayAspectHeight: CGFloat {
        let plan = planDisplay(for: targetScreen)
        return CGFloat(plan.height) / CGFloat(plan.width)
    }
    private func configureDisplay(_ config: inout ReceiverConfiguration) {
        let screen = targetScreen
        let plan = planDisplay(for: screen)
        config.rightHandDrive = driveControl.selectedSegmentIndex == 1
        config.width = plan.width; config.height = plan.height
        config.maxFPS = plan.fps; config.videoCodec = plan.codec
        config.widthPhysicalMM = plan.iconWidthMM
        config.browserPerformance = selectedPerformance
        config.showTouches = showTouchesSwitch.isOn
        if carButtonSwitch.isOn {
            config.oemIconPNG = customVehicleIcon ?? Self.carButtonIcon
            config.oemIconLabel = String((nameField.text ?? "").prefix(12)).isEmpty ? "CarWithin" : String((nameField.text ?? "").prefix(12))
        }
        let source = outputMode != .browser ? headUnitOutput.selectedTitle
            : followsCarScreen ? (screen.map { CWL("车机屏幕 {1}", [String(describing: $0.title)]) } ?? CWL("尚无车机屏幕，用固定分辨率")) : sizeModeControl.selectedTitle
        log(CWL("画面计划：{1}×{2} @ {3} FPS {4}（{5}{6}）", [String(describing: plan.width), String(describing: plan.height), String(describing: plan.fps), String(describing: plan.codec.displayName), String(describing: source), String(describing: lightLevel > 0 ? CWL("，减轻档 {1}", [String(describing: lightLevel)]) : "")]))
        config.browserAudio = soundOutput == .browser && config.videoOutputPort != nil && outputMode == .browser
        if outputMode == .airPlay, config.videoOutputPort != nil { config.airPlayStreamID = UUID() }
        if let profile = outputMode.zeehoProfile {
            config.zeehoProfile = profile
            config.zeehoFrameRate = selectedZeehoFrameRate
            config.zeehoVideoMode = selectedZeehoVideoMode
            config.zeehoAutomaticAddress = usesAutomaticZeehoAddress
            config.zeehoAddress = (activeZeehoAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let profile = cfmotoProfile {
            config.cfmotoAddress = (cfmotoAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            config.cfmotoProfile = profile
        }
        if let mode = outputMode.ninebotMode {
            config.ninebotAddress = (activeNinebotAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            config.ninebotMode = mode
        }
        if outputMode == .carbit {
            config.carbitAddress = carbitAddress
            config.carbitFrameRate = selectedCarbitFrameRate
        }
        if outputMode.requiresWiFiInterface {
            let screen = view.window?.screen ?? UIScreen.main
            let orientation = view.window?.windowScene?.interfaceOrientation
            let rotation: Int
            switch orientation {
            case .landscapeLeft: rotation = 1
            case .portraitUpsideDown: rotation = 2
            case .landscapeRight: rotation = 3
            default: rotation = 0
            }
            config.tailingPhoneInfo = TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                model: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion,
                width: Int(screen.bounds.width * screen.scale), height: Int(screen.bounds.height * screen.scale), rotation: rotation)
        }
        if outputMode == .tailing {
            config.tailingAddress = (tailingAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        }
        config.carLifeEnabled = outputMode == .carLife
        let carLifeAddress = (carLifeAddressField.text ?? "").trimmingCharacters(in: .whitespaces)
        config.carLifeAddress = !config.carLifeEnabled || carLifeAddress.isEmpty ? nil : carLifeAddress
    }
    @objc private func toggleSettings() { revealSettings() }
    @objc private func driveChanged() {
        UserDefaults.standard.set(driveControl.selectedSegmentIndex == 1, forKey: "rightHandDrive")
    }
    @objc private func orientationChanged() {
        guard !running else { return }
        UserDefaults.standard.set(orientationControl.selectedSegmentIndex == 1, forKey: "portraitDisplay")
        updateVideoAspect()
        reloadVisibleSettings()
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard fullscreenContainer != nil, UIDevice.current.userInterfaceIdiom == .pad else { return .all }
        if usesCustomSize { return customSize.height > customSize.width ? .portrait : .landscape }
        return orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscape
    }
    @objc private func showFullscreen() {
        guard displayedVideo, fullscreenContainer == nil else { return }
        view.endEditing(true)
        NSLayoutConstraint.deactivate(inlineVideoConstraints)
        videoSurface.removeFromSuperview()
        let container = UIView(); container.backgroundColor = .black; container.translatesAutoresizingMaskIntoConstraints = false
        fullscreenContainer = container; view.addSubview(container); container.addSubview(videoSurface)
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        fullscreenConstraints = [container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor), videoSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor), videoSurface.topAnchor.constraint(equalTo: container.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        NSLayoutConstraint.activate(fullscreenConstraints)
        if !sessionHasVehicleButton { addFullscreenExitButton(to: container) }
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        if UIDevice.current.userInterfaceIdiom == .pad {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                self?.log(CWL("请把 iPad 旋转到所选方向以获得全屏画面"))
            }
        }
    }

    private func addFullscreenExitButton(to container: UIView) {
        let exit = UIButton(type: .system)
        let icon = UIImage(systemName: "arrow.down.right.and.arrow.up.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        exit.setImage(icon, for: .normal)
        exit.tintColor = .white
        exit.backgroundColor = .clear
        exit.layer.cornerRadius = 22
        exit.layer.borderWidth = 1
        exit.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        exit.layer.shadowColor = UIColor.black.cgColor
        exit.layer.shadowOpacity = 0.8
        exit.layer.shadowRadius = 2
        exit.layer.shadowOffset = .zero
        exit.accessibilityLabel = CWL("退出全屏")
        exit.addTarget(self, action: #selector(hideFullscreen), for: .touchUpInside)
        exit.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(exit)
        fullscreenExitButton = exit

        let constraints = [
            exit.widthAnchor.constraint(equalToConstant: 44), exit.heightAnchor.constraint(equalToConstant: 44),
            exit.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            exit.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 8)]
        NSLayoutConstraint.activate(constraints)
        fullscreenConstraints += constraints
        refreshFullscreenExitButton()
    }
    private func refreshFullscreenExitButton() {
        guard let exit = fullscreenExitButton else { return }
        if exit.alpha < 1 {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                exit.alpha = 1
            }
        }
        if let fullscreenFadeTimer {
            fullscreenFadeTimer.fireDate = Date(timeIntervalSinceNow: 5)
            return
        }
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self, weak exit] _ in
            self?.fullscreenFadeTimer = nil
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                exit?.alpha = 0.3
            }
        }
        fullscreenFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func hideFullscreen() {
        guard let container = fullscreenContainer else { return }
        fullscreenFadeTimer?.invalidate()
        fullscreenFadeTimer = nil
        fullscreenExitButton = nil
        UIView.performWithoutAnimation {
            NSLayoutConstraint.deactivate(fullscreenConstraints)
            fullscreenConstraints = []
            videoSurface.removeFromSuperview()
            container.removeFromSuperview()
            fullscreenContainer = nil
            restoreInlineVideoSurface()
            navigationController?.setNavigationBarHidden(false, animated: false)
            setNeedsUpdateOfSupportedInterfaceOrientations()
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            view.layoutIfNeeded()
        }
        pictureInPicture.sourceMayBeReady()
    }

    private func restoreInlineVideoSurface() {
        inlineVideoContainer.addSubview(videoSurface)
        inlineVideoConstraints = [
            videoSurface.leadingAnchor.constraint(equalTo: inlineVideoContainer.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: inlineVideoContainer.trailingAnchor),
            videoSurface.topAnchor.constraint(equalTo: inlineVideoContainer.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: inlineVideoContainer.bottomAnchor)
        ]
        NSLayoutConstraint.activate(inlineVideoConstraints)
    }

    @objc private func networkNameChanged() {
        passwordLoadedForSSID = nil
        passwordField.text = ""; openNetworkSwitch.isOn = false; passwordStatus.text = ""
        // No table rebuild while the user is typing an SSID or composing Chinese text.
        refreshNetworkSummary()
    }
    @objc private func loadWiFiPassword() {
        let ssid = ssidField.text ?? ""
        // Merely revisiting the name field must not overwrite an edited password with Keychain.
        guard passwordLoadedForSSID != ssid else { return }
        passwordLoadedForSSID = ssid
        do {
            if let saved = try WiFiCredentials.password(for: ssid) {
                passwordField.text = saved; openNetworkSwitch.isOn = saved.isEmpty
                passwordStatus.text = WiFiCredentials.isTemporary(for: ssid)
                    ? WiFiCredentials.temporaryNotice : CWL("已读取保存的 Wi-Fi 配置")
            }
        } catch {
            if (error as NSError).domain == NSOSStatusErrorDomain,
               (error as NSError).code == Int(errSecMissingEntitlement) {
                passwordStatus.text = CWL("当前签名无法读取钥匙串（-34018）。请手动输入 Wi-Fi 密码，密码仅在本次 App 运行期间保留。")
            } else { passwordStatus.text = CWL("无法读取已保存的密码，请重新输入。") }
        }
    }
    private func refreshNetworkSummary() {
        let name = ssidField.text ?? ""
        if needsNetworkDetails, !name.isEmpty {
            networkSummary.text = CWL("CarPlay Wi-Fi 预设：{1}", [String(describing: name)])
        } else if needsNetworkDetails {
            networkSummary.text = CWL("请在设置中添加或选择 Wi-Fi 预设。")
        } else {
            networkSummary.text = CWL("让两台设备连接同一个 Wi-Fi。")
        }
    }
    @objc private func detectNetwork() { refreshCurrentNetwork(requestPermission: true) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingNetworkPermission, manager.authorizationStatus != .notDetermined else { return }
        awaitingNetworkPermission = false
        guard activeWiFiForm != nil else { return }
        refreshCurrentNetwork(requestPermission: true)
    }
    private func refreshCurrentNetwork(requestPermission: Bool) {
        guard canDetectWiFiName, !running, !waitingForNetwork, !fetchingNetwork, needsNetworkDetails,
              requestPermission || (activeWiFiForm == nil && (ssidField.text ?? "").isEmpty) else { return }
        let authorization = locationManager.authorizationStatus
        if authorization == .notDetermined, requestPermission {
            awaitingNetworkPermission = true; locationManager.requestWhenInUseAuthorization(); return
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            if requestPermission {
                passwordStatus.text = CWL("可以手动填写 Wi-Fi 名称，也可允许定位后自动读取。")
                reloadVisibleSettings()
            }
            return
        }
        fetchingNetwork = true
        let previousSSID = ssidField.text
        let form = activeWiFiForm
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self else { return }; self.fetchingNetwork = false
                guard !self.running, !self.ssidField.isFirstResponder, !self.passwordField.isFirstResponder,
                      self.ssidField.text == previousSSID, self.activeWiFiForm == form, !self.waitingForNetwork else { return }
                guard let network else {
                    if requestPermission {
                        self.passwordStatus.text = CWL("无法读取 Wi-Fi 名称，请手动填写。")
                        self.reloadVisibleSettings()
                    }
                    return
                }
                if self.ssidField.text != network.ssid {
                    self.ssidField.text = network.ssid; self.networkNameChanged(); self.loadWiFiPassword()
                }
                self.refreshNetworkSummary()
                if requestPermission { self.reloadVisibleSettings() }
            }
        }
    }
    @objc private func forgetWiFiPassword() {
        let ssid = ssidField.text ?? ""
        guard !ssid.isEmpty else { return }
        do {
            try WiFiCredentials.forget(ssid)
            WiFiPresetStore.remove(ssid)
            if let next = WiFiPresetStore.selected() { applyWiFiPreset(next) }
            else {
                ssidField.text = ""; passwordField.text = ""; channelField.text = "36"; openNetworkSwitch.isOn = false
                passwordLoadedForSSID = nil
                refreshWiFiPresetMenu(); refreshNetworkSummary()
            }
            passwordStatus.text = CWL("已删除 Wi-Fi 预设“{1}”", [String(describing: ssid)])
        } catch { passwordStatus.text = CWL("无法删除 Wi-Fi 预设：{1}", [String(describing: error.localizedDescription)]) }
    }
    private func saveSettings(_ config: ReceiverConfiguration) -> Bool {
        do { if needsNetworkDetails { try WiFiCredentials.save(config.password, for: config.ssid) } }
        catch { statusLabel.text = CWL("无法安全保存 Wi-Fi 密码，请重试。"); return false }
        if needsNetworkDetails {
            passwordStatus.text = WiFiCredentials.savedMessage(for: config.ssid)
            UserDefaults.standard.set(config.ssid, forKey: "wifiSSID")
            UserDefaults.standard.set(Int(config.wifiChannel), forKey: "wifiChannel")
            WiFiPresetStore.upsert(ssid: config.ssid, channel: config.wifiChannel, isOpen: openNetworkSwitch.isOn)
            refreshWiFiPresetMenu()
        }
        audioSettingChanged()
        UserDefaults.standard.set(resolutionControl.selectedSegmentIndex, forKey: "displayResolutionIndex")
        saveDisplaySettings()
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex != 0, forKey: "pictureInPictureEnabled")
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex, forKey: "pictureInPictureTiming")
        UserDefaults.standard.set(videoOutputSwitch.isOn, forKey: "videoOutputEnabled")
        saveHeadUnitOutput()
        if config.videoOutputPort != nil { saveBrowserPorts() }
        if modeControl.selectedSegmentIndex != 2 { UserDefaults.standard.set(config.name, forKey: "receiverName") }
        return true
    }
    @objc private func testSameDeviceTransport() {
        guard !running else {
            statusLabel.text = CWL("请先停止 CarPlay，再测试本机传输。")
            saveTransportProbeResult(CWL("blocked: CarPlay 正在运行"))
            return
        }
        transportProbeButton.isEnabled = false
        transportProbe.stop()
        do {
            let identifier = "CarWithin-Transport-Probe-\(UUID().uuidString)"
            try transportProbe.start(withIdentifier: identifier, transportType: 2)
            statusLabel.text = CWL("本机传输能力可用")
            log(CWL("CoreAccessories 已创建并发布 protocol-4 iAP2 endpoint"))
            saveTransportProbeResult(CWL("success: CoreAccessories 已发布 protocol-4 iAP2 endpoint"))
        } catch {
            statusLabel.text = CWL("本机传输能力不可用")
            log(CWL("CoreAccessories 传输测试失败：{1}", [String(describing: error.localizedDescription)]))
            saveTransportProbeResult("failure: \(error.localizedDescription)")
        }
        transportProbe.stop()
        transportProbeButton.isEnabled = true
    }
    private func saveTransportProbeResult(_ result: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let value = "\(ISO8601DateFormatter().string(from: Date()))\n\(result)\n"
        do {
            try value.write(to: documents.appendingPathComponent("transport-probe.txt"), atomically: true, encoding: .utf8)
        } catch {
            log(CWL("无法保存传输测试结果：{1}", [String(describing: error.localizedDescription)]))
        }
    }
    private func loadIdentity() {
        let importing = ProcessInfo.processInfo.arguments.contains("--import-mfi-identity")
        do {
            if importing {
                identity = try AccessoryIdentityStore.importFromDocuments()
                log(CWL("MFi 身份验证通过并已保存到本机 Keychain"))
                saveIdentityImportResult(CWL("success: MFi 身份已验证并保存到 Keychain"))
            } else if let keychainIdentity = try? AccessoryIdentityStore.load() {
                identity = keychainIdentity
                log(CWL("已从 Keychain 载入 MFi 身份，ECDSA 自检通过"))
            } else {
                identity = try AccessoryIdentityStore.loadFromBundle()
                log(CWL("已从内置资源载入 MFi 身份，ECDSA 自检通过"))
            }
            startButton.isEnabled = true
            statusLabel.text = CWL("可以开始连接")
        } catch {
            identity = nil
            statusLabel.text = CWL("尚未导入有效的 MFi 身份"); startButton.isEnabled = false
            log(CWL("请通过 Documents/IdentityImport 导入 certificate.p7b、leaf.cer 和 private.x963。错误：{1}", [String(describing: error.localizedDescription)]))
            if importing { saveIdentityImportResult("failure: \(error.localizedDescription)") }
        }
    }
    private func saveIdentityImportResult(_ result: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let value = "\(ISO8601DateFormatter().string(from: Date()))\n\(result)\n"
        do {
            try value.write(to: documents.appendingPathComponent("identity-import-result.txt"), atomically: true, encoding: .utf8)
        } catch {
            log(CWL("无法保存身份导入结果：{1}", [String(describing: error.localizedDescription)]))
        }
    }
    @objc private func autoConnectOnLaunchChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "autoConnectOnLaunch")
    }

    @objc private func toggleReceiver() {
        if running || waitingForNetwork { stop(); return }
        if modeControl.selectedSegmentIndex != 2, outputMode == .carbit, !CarbitConnectionCode.isLocalAddress(carbitAddress) {
            updateCarbitStatus(CWL("请先扫码、查找车机或填写车机的局域网 IPv4 地址。"))
            revealSettings(output: true)
            return
        }
        if !restartingAutomatically { networkRestartCount = 0 }
        clearStartupHint()
        view.endEditing(true)
        refreshNetworkAddresses()
        let channel = UInt8(channelField.text ?? "") ?? 36
        guard (1...196).contains(channel) else {
            revealSettings(); statusLabel.text = CWL("兼容信道请输入 1–196，或留空使用默认值 36。"); return
        }
        let outputPort: UInt16?
        let httpsPort: UInt16?
        if outputMode == .browser && videoOutputSwitch.isOn {
            if let error = browserPortError {
                statusLabel.text = error
                revealSettings(output: true)
                return
            }
            outputPort = browserPort
            httpsPort = secureBrowserPort
        } else if outputMode == .airPlay {
            guard let browserPort else {
                revealSettings(output: true)
                return
            }
            outputPort = browserPort
            httpsPort = nil
        } else {
            outputPort = nil
            httpsPort = nil
        }
        guard !needsNetworkDetails || openNetworkSwitch.isOn || !(passwordField.text ?? "").isEmpty else {
            statusLabel.text = CWL("请输入 Wi-Fi 密码；开放网络请选择“无密码”。")
            revealSettings(wifi: true); return
        }
        let password = !needsNetworkDetails || openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        if modeControl.selectedSegmentIndex == 2 {
            guard let identity, let target = remoteTarget else {
                statusLabel.text = CWL("请先选择 iPad 接收端，并确保两台设备位于同一 Wi-Fi。"); return
            }
            let config = ReceiverConfiguration(name: target.name, address: target.address,
                ssid: ssidField.text ?? "", password: password, port: target.port,
                wifiChannel: channel, audioEnabled: false, videoOutputPort: nil, deviceID: target.deviceID)
            do { try config.validate(requiresLocalAddress: false) } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            if keepAliveSwitch.isOn { keepAlive.start() }
            view.endEditing(true); running = true; modeControl.isEnabled = false; setEditing(false)
            receiverPicker.isEnabled = false; receiverBrowser.stop()
            UIApplication.shared.isIdleTimerDisabled = true
            startButton.setTitle(CWL("停止 iPad 连接"), for: .normal)
            log(CWL("正在请求把本机 CarPlay 投送到 {1}（{2}:{3}）", [String(describing: target.name), String(describing: target.address), String(describing: target.port)]))
            sameDevice.start(configuration: config, identity: identity, expectsLocalControl: false)
            return
        }
        if modeControl.selectedSegmentIndex == 1 {
            guard let identity else { return }
            guard let address = localCarPlayAddress else { waitForLocalNetwork(); return }
            var config = ReceiverConfiguration(name: nameField.text ?? "CarWithin", address: address,
                ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: soundOutput != .phone,
                videoOutputPort: outputPort, secureVideoOutputPort: httpsPort,
                deviceID: ReceiverConfiguration.persistentDeviceID())
            if !restartingAutomatically { autoRestarts = 0; lightLevel = 0; reportedScreen = nil; primaryViewer = nil }
            configureDisplay(&config)
            do { try config.validate() } catch {
                log(CWL("无法启动本机 CarPlay：{1}", [String(describing: error.localizedDescription)]))
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            liveDisplay = DisplayPlan(width: config.width, height: config.height, fps: config.maxFPS,
                                      codec: config.videoCodec, iconWidthMM: config.widthPhysicalMM)
            updateVideoAspect()
            guard saveSettings(config) else { return }
            sessionHasVehicleButton = CarPlayInfo.vehicleButtonSize(in: config) != nil
            // Activate while foregrounded, before the virtual CarPlay route is selected.
            // Waiting until willResignActive can fail to acquire an audio session on CarAudio.
            if keepAliveSwitch.isOn { keepAlive.start() }
            view.endEditing(true)
            running = true; modeControl.isEnabled = false; setEditing(false)
            startButton.setTitle(CWL("停止 CarPlay"), for: .normal)
            startButton.configuration?.image = UIImage(systemName: "stop.fill")
            statusLabel.text = CWL("正在启动本机 CarPlay…")
            UIApplication.shared.isIdleTimerDisabled = true
            let startupID = UUID()
            localStartupID = startupID
            receiver.onListening = { [weak self] port in
                guard let self, self.running, self.localStartupID == startupID else { return }
                var live = config; live.port = port
                self.controlBrowser.start()
                self.sameDevice.start(configuration: live, identity: identity)
            }
            prepareExternalOutput(configuration: config)
            receiver.start(configuration: config, identity: identity, preferredViewer: primaryViewer)
            watchStartupAddress(address)
            return
        }
        guard let identity else { return }
        let addresses = ReceiverConfiguration.localIPv4Addresses()
        if !addresses.contains(ipField.text ?? "") { ipField.text = browserAddress ?? addresses.first }
        var config = ReceiverConfiguration(name: nameField.text ?? "CarWithin", address: ipField.text ?? "",
            ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: soundOutput != .phone,
            videoOutputPort: outputPort, secureVideoOutputPort: httpsPort,
            deviceID: ReceiverConfiguration.persistentDeviceID())
        configureDisplay(&config)
        do { try config.validate(requiresWiFiCredentials: needsNetworkDetails) } catch {
            statusLabel.text = error.localizedDescription
            log(CWL("无法启动：{1}", [String(describing: error.localizedDescription)]))
            revealSettings(wifi: config.ssid.isEmpty)
            return
        }
        guard saveSettings(config) else { return }
        sessionHasVehicleButton = CarPlayInfo.vehicleButtonSize(in: config) != nil
        if keepAliveSwitch.isOn { keepAlive.start() }
        view.endEditing(true)
        running = true; modeControl.isEnabled = false; setEditing(false); startButton.setTitle(CWL("停止接收"), for: .normal)
        startButton.configuration?.image = UIImage(systemName: "stop.fill")
        UIApplication.shared.isIdleTimerDisabled = true; statusLabel.text = CWL("正在启动接收服务…")
        receiver.onListening = { [weak self] port in
            guard let self, self.running else { return }
            var live = config; live.port = port
            self.statusLabel.text = CWL("正在等待 iPhone 连接")
            if self.bluetoothSetupSwitch.isOn { self.bluetooth.start(configuration: live) }
        }
        prepareExternalOutput(configuration: config)
        receiver.start(configuration: config, identity: identity)
    }
    private var localCarPlayAddress: String? {
        outputMode.requiresWiFiInterface ? ReceiverConfiguration.wifiIPv4Address() : browserAddress
    }

    private func refreshNetworkAddresses() {
        refreshBrowserAddressLabels()
    }

    private func waitForLocalNetwork() {
        waitingForNetwork = true
        modeControl.isEnabled = false
        setEditing(false)
        startButton.setTitle(CWL("取消连接"), for: .normal)
        statusLabel.text = CWL("正在等待 Wi-Fi 分配 IP 地址…")
        networkStartupTask?.cancel()
        networkStartupTask = Task { [weak self] in
            var candidate: String?
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                let address = self.localCarPlayAddress
                if let address, address == candidate, UIApplication.shared.applicationState == .active {
                    self.waitingForNetwork = false
                    self.modeControl.isEnabled = true
                    self.setEditing(true)
                    self.restartingAutomatically = self.networkRestartCount > 0
                    self.toggleReceiver()
                    self.restartingAutomatically = false
                    return
                }
                candidate = address
            }
            guard let self else { return }
            self.stop()
            self.statusLabel.text = CWL("未获得 Wi-Fi 地址。请连接正确的 Wi-Fi 后重试。")
        }
    }

    private func watchStartupAddress(_ initialAddress: String) {
        networkStartupTask?.cancel()
        networkStartupTask = Task { [weak self] in
            var candidate: String?
            var stableSamples = 0
            var lostAddress = false
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.running, !self.displayedVideo else { return }
                let address = self.localCarPlayAddress
                self.refreshNetworkAddresses()
                if address == nil { lostAddress = true }
                if address != candidate { candidate = address; stableSamples = 0 }
                stableSamples += 1
                guard let address, address != initialAddress || lostAddress, stableSamples >= 3,
                      self.networkRestartCount < 2, UIApplication.shared.applicationState == .active else { continue }
                self.networkRestartCount += 1
                self.log(CWL("启动期间 Wi-Fi 已切换或恢复，使用当前地址重新连接 CarPlay"))
                self.stop()
                self.restartingAutomatically = true
                self.toggleReceiver()
                self.restartingAutomatically = false
                return
            }
        }
    }

    private func stop() {
        localStartupID = nil
        networkStartupTask?.cancel()
        networkStartupTask = nil
        waitingForNetwork = false
        clearStartupHint()
        airPlayReady = false
        airPlayItemObservation = nil
        airPlayRouteObservation = nil
        airPlayTimeObservation = nil
        airPlayHealthTimer?.invalidate(); airPlayHealthTimer = nil
        airPlayLastVideoAt = nil; airPlayWaitingSince = nil
        airPlaySourceWasStale = false
        airPlayPlayer?.pause()
        airPlayPlayer?.replaceCurrentItem(with: nil)
        airPlayPlayer?.allowsExternalPlayback = false
        airPlayPlayer = nil
        airPlayStreamID = nil; airPlayStreamURL = nil
        airPlayRetryButton.isHidden = true
        updateAirPlayStatus(CWL("等待启动 CarPlay。"))
        updateCarLifeStatus(CWL("等待启动 CarPlay。"))
        updateCarbitStatus(CWL("等待启动 CarPlay。"))
        running = false
        sessionHasVehicleButton = false
        screenAdaptation?.cancel(); screenAdaptation = nil
        reportedScreen = nil; primaryViewer = nil; pendingRestartReason = nil
        pictureInPicture.stop(); keepAlive.stop(); skippedLocalVideo = false
        hideFullscreen(); videoActions.isHidden = true; controlBar.isHidden = true
        displayedVideo = false; didRequestImmediatePiP = false
        videoSurface.reset(); videoSurface.usePreviewFrames(false); inlineVideoContainer.isHidden = true
        receiver.onListening = nil; bluetooth.stop(); sameDevice.stop(); controlBrowser.stop(); receiver.stop()
        receiverBrowser.stop()
        modeControl.isEnabled = true
        UIApplication.shared.isIdleTimerDisabled = false; setEditing(true)
        modeChanged()
        statusLabel.text = identity == nil ? CWL("需要导入 MFi 身份") : CWL("已停止")
        log(CWL("CarPlay 接收已停止"))
    }

    private func clearStartupHint() {
        startupHintTask?.cancel()
        startupHintTask = nil
        startupHintGeneration = UUID()
        startupHint.text = nil
        startupHint.isHidden = true
    }

    private func scheduleStartupHint() {
        guard modeControl.selectedSegmentIndex == 1, startupHintTask == nil else { return }
        let generation = startupHintGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.startupHintGeneration == generation, self.running,
                  !self.displayedVideo, self.modeControl.selectedSegmentIndex == 1 else { return }
            self.startupHint.text = CWL("连接较久时，可尝试在系统设置中关闭再打开 Wi-Fi。当前仍在继续连接。")
            self.startupHint.isHidden = false
        }
        startupHintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    @objc private func modeChanged() {
        if UIDevice.current.userInterfaceIdiom == .phone { modeControl.selectedSegmentIndex = 1 }
        UserDefaults.standard.set(modeControl.selectedSegmentIndex, forKey: "connectionMode")
        let local = modeControl.selectedSegmentIndex == 1
        let remote = modeControl.selectedSegmentIndex == 2
        receiverBrowser.stop(); remoteTarget = nil
        receiverPicker.isHidden = !remote
        if remote {
            receiverPicker.menu = nil; receiverPicker.isEnabled = false
            receiverPicker.setTitle(CWL("正在搜索 iPad 接收端…"), for: .normal)
            receiverBrowser.start()
        }
        let title = remote ? CWL("连接到 iPad") : local ? CWL("本机 CarPlay") : CWL("CarPlay 接收屏")
        let headingText = NSMutableAttributedString(string: title)
        if local, let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            headingText.append(NSAttributedString(string: "（\(version)）", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]))
        }
        heading.attributedText = headingText
        explanation.text = remote ? CWL("选择一台 iPad，把这台 iPhone 的 CarPlay 投送到它的屏幕。")
            : local ? CWL("无需外接盒子，直接在这台 iPhone 上启动并显示 CarPlay。") : CWL("接收另一台 iPhone 的导航、音乐和触控画面。")
        connectionHelp.text = remote
            ? CWL("让 iPhone 和 iPad 连接同一个 Wi-Fi。")
            : local ? CWL("先在系统设置连接 Wi-Fi，再在 CarWithin 选择对应预设。")
            : CWL("先启动此接收屏，再从另一台 iPhone 发起连接。")
        refreshNetworkSummary()
        refreshVideoOutputSummary()
        startButton.isEnabled = identity != nil
        startButton.configuration?.image = UIImage(systemName: "play.fill")
        startButton.setTitle(remote ? CWL("连接到 iPad") : local ? CWL("启动本机 CarPlay") : CWL("启动 CarPlay 接收屏"), for: .normal)
        statusLabel.text = identity == nil ? CWL("需要导入 MFi 身份") : remote ? CWL("请选择接收端") : CWL("准备就绪")
        refreshCurrentNetwork(requestPermission: false)
    }
    private func setEditing(_ value: Bool) {
        [nameField, ipField, ssidField, passwordField, channelField, videoOutputPortField, secureVideoOutputPortField].forEach { $0.isEnabled = value }
        openNetworkSwitch.isEnabled = value
        videoOutputSwitch.isEnabled = value && outputMode == .browser
        orientationControl.isEnabled = value
        resolutionControl.isEnabled = value
        aspectRatioControl.isEnabled = value
        frameRateControl.isEnabled = value
        codecControl.isEnabled = value
        [sizeModeControl, carbitSizeModeControl, carbitFrameRateControl, iconSizeControl, performanceControl].forEach { $0.isEnabled = value }
        [autoRestartSwitch, showTouchesSwitch, carButtonSwitch].forEach { $0.isEnabled = value }
        driveControl.isEnabled = value
        bluetoothSetupSwitch.isEnabled = value
        transportProbeButton.isEnabled = value
        headUnitOutput.isEnabled = value
        zeehoAddressField.isEnabled = value
        zeehoSEPlusAddressField.isEnabled = value
        zeehoSEPlusAutomaticSwitch.isEnabled = value
        zeeho62AutomaticSwitch.isEnabled = value
        zeehoSEPlusFrameRateControl.isEnabled = value
        zeehoSEPlusCanvasControl.isEnabled = value
        zeehoSEPlusVideoModeControl.isEnabled = value
        cfmotoAddressField.isEnabled = value
        ninebotAddressField.isEnabled = value
        ninebot43AddressField.isEnabled = value
        tailingAddressField.isEnabled = value
        carLifeAddressField.isEnabled = value
        carbitAddressField.isEnabled = value
    }
    @objc private func willResignActive() {
        guard running else { return }
        // Normally already running; retry if foreground activation failed.
        if keepAliveSwitch.isOn { keepAlive.start() }
        if videoSurface.usesPreviewFrames {
            // The preview publisher is the only source of PiP frames in this mode.
            if pictureInPictureTiming.selectedSegmentIndex != 0 {
                pictureInPicture.awaitAutomaticStart()
            } else {
                receiver.setLocalVideoEnabled(false)
            }
            return
        }
        if outputMode == .zeehoSEPlus {
            receiver.setLocalVideoEnabled(false)
            skippedLocalVideo = true
            pictureInPicture.stop()
            videoSurface.suspendForExternalOutput()
            log("极核仪表继续输出，手机预览已暂停；直传模式不需要手机端视频解码和编码")
            return
        }
        pictureInPicture.awaitAutomaticStart()
    }
    @objc private func becameActive() {
        refreshNetworkAddresses()
        pictureInPicture.returnedToForeground()
        receiver.setLocalVideoEnabled(true)
        if running { UIApplication.shared.isIdleTimerDisabled = true }
        resumeLocalVideo()
        pictureInPicture.sourceMayBeReady()
        if running, keepAliveSwitch.isOn { keepAlive.start() }
        if let reason = pendingRestartReason {
            pendingRestartReason = nil
            restartCarPlay(reason: reason, forPerformance: true)
        } else {
            scheduleScreenAdaptation()
        }
    }
    @objc private func pictureInPictureTimingChanged() {
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex, forKey: "pictureInPictureTiming")
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex != 0, forKey: "pictureInPictureEnabled")
        didRequestImmediatePiP = false
        pictureInPicture.cancelPendingStart()
        updatePictureInPicturePolicy()
    }

    private func updatePictureInPicturePolicy() {
        if outputMode == .zeehoSEPlus {
            pictureInPicture.setAutomatic(false)
            return
        }
        let timing = pictureInPictureTiming.selectedSegmentIndex
        pictureInPicture.setAutomatic(running && displayedVideo && timing != 0)
        guard running, displayedVideo, timing == 2, !didRequestImmediatePiP,
              presentedViewController == nil else { return }
        didRequestImmediatePiP = true
        _ = pictureInPicture.start()
    }

    // MARK: Follow the head unit

    private func browserReportedDisplay(_ display: BrowserDisplay?, viewerID: UUID?) {
        guard running else { return }
        reportedScreen = display.map(CarScreenStore.record)
        primaryViewer = viewerID
        refreshScreenMenu()
        scheduleScreenAdaptation()
    }

    private func scheduleScreenAdaptation() {
        screenAdaptation?.cancel(); screenAdaptation = nil
        guard running, reportedScreen != nil, modeControl.selectedSegmentIndex == 1 else { return }
        // Refresh rate and viewport reports can arrive separately. Apply the settled plan once.
        let work = DispatchWorkItem { [weak self] in self?.adaptToPrimaryScreen() }
        screenAdaptation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func adaptToPrimaryScreen() {
        guard running, UIApplication.shared.applicationState == .active,
              let screen = reportedScreen, let live = liveDisplay else { return }
        let wanted = planDisplay(for: screen)
        // Ignore differences under 4 %: rounding, or a browser bar appearing.
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) * 25 <= max(a, b) }
        let sizeChanged = !(near(wanted.width, live.width) && near(wanted.height, live.height))
        var changes: [String] = []
        if sizeChanged { changes.append("\(live.width)×\(live.height) → \(wanted.width)×\(wanted.height)") }
        if wanted.fps != live.fps { changes.append("\(live.fps) → \(wanted.fps) FPS") }
        if wanted.codec != live.codec { changes.append("\(live.codec.displayName) → \(wanted.codec.displayName)") }
        if wanted.iconWidthMM != live.iconWidthMM { changes.append(CWL("图标大小")) }
        guard !changes.isEmpty else { return }
        restartCarPlay(reason: CWL("跟随主接收屏幕（{1}）", [String(describing: changes.joined(separator: "，"))]))
    }
    private func browserStruggling(peer: String, reason: String) {
        log(CWL("浏览器 {1} 持续卡顿（{2}）", [String(describing: peer), String(describing: reason)]))
        guard autoRestartSwitch.isOn, running, lightLevel < 2 else { return }
        lightLevel += 1
        requestRestart(reason: lightLevel == 1 ? CWL("画面卡顿，改用 30 FPS") : CWL("画面卡顿，改用 720P"))
    }
    private func requestRestart(reason: String) {
        guard autoRestarts < 2 else { log(CWL("本次连接已自动重启 2 次，不再重启：{1}", [String(describing: reason)])); return }
        // Restarting off screen would drop the background keep-alive; wait until the app is back.
        guard UIApplication.shared.applicationState == .active else {
            pendingRestartReason = reason; log(CWL("回到 CarWithin 后重启：{1}", [String(describing: reason)])); return
        }
        restartCarPlay(reason: reason, forPerformance: true)
    }
    private func restartCarPlay(reason: String, forPerformance: Bool = false) {
        guard running, modeControl.selectedSegmentIndex == 1 else { return }
        if forPerformance {
            guard autoRestarts < 2 else { return }
            autoRestarts += 1
        }
        log(CWL("自动重启 CarPlay：{1}", [String(describing: reason)]))
        let keepScreen = reportedScreen, keepViewer = primaryViewer, level = lightLevel, count = autoRestarts
        stop()
        statusLabel.text = CWL("正在按新的画面设置重启 CarPlay…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.running else { return }
            self.reportedScreen = keepScreen; self.primaryViewer = keepViewer
            self.lightLevel = level; self.autoRestarts = count
            self.restartingAutomatically = true
            self.toggleReceiver()
            self.restartingAutomatically = false
        }
    }

    /// The car button on the CarPlay home screen: 120 px, a white car on the app's blue.
    private static let carButtonIcon: Data? = {
        let size = CGSize(width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.18, green: 0.55, blue: 1, alpha: 1).cgColor, UIColor(red: 0.04, green: 0.32, blue: 0.86, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let symbol = UIImage(systemName: "car.side.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 58, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(in: CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
        }
        return image.pngData()
    }()
    private func resumeLocalVideo() {
        guard running else { return }
        videoSurface.resumeAfterBackground(skippedFrames: skippedLocalVideo)
        skippedLocalVideo = false
    }
    @objc private func foregrounded() {
        refreshNetworkAddresses()
        guard running else {
            if !waitingForNetwork { modeChanged() }
            return
        }
        // Light/dark changes were ignored while off screen; send the current state once.
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }
    @objc private func backgrounded() {
        receiverBrowser.stop()
        guard running else { return }
        // willResignActive may have failed to start it (e.g. the session was busy); try once more
        // before deciding the session cannot survive in the background.
        if keepAliveSwitch.isOn, !keepAlive.isRunning, keepAlive.start() { log(CWL("后台保持在进入后台时重试成功")) }
        if canRunInBackground {
            log(keepAlive.isRunning ? CWL("App 已进入后台，CarPlay 继续运行") : CWL("App 已进入后台，由画中画保持运行"))
        } else {
            log(CWL("App 已进入后台且没有画中画或后台保持，iOS 会挂起 App，已停止 CarPlay"))
            stop()
        }
    }
    @objc private func copyLog() { UIPasteboard.general.string = lines.joined(separator: "\n") }
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("\(timestamp)  \(message)"); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        if logView.window != nil {
            logView.text = lines.joined(separator: "\n")
            if !logView.text.isEmpty { logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1)) }
        }
        NSLog("[CarWithin] %@", message)
    }
}

// MARK: - Settings pages

extension ReceiverViewController {
    /// Initial values and change handlers for every setting control. The controls live on the
    /// settings pages; the rest of this controller reads them directly.
    fileprivate func configureSettingsControls() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didApplyLeftHandDefaultV2") {
            defaults.set(false, forKey: "rightHandDrive"); defaults.set(true, forKey: "didApplyLeftHandDefaultV2")
        }
        if !defaults.bool(forKey: "didApplyBrowserDefaultV3") {
            defaults.set(true, forKey: "videoOutputEnabled"); defaults.set(60, forKey: "displayMaxFPS")
            defaults.set(true, forKey: "didApplyBrowserDefaultV3")
        }
        driveControl.selectedSegmentIndex = defaults.bool(forKey: "rightHandDrive") ? 1 : 0
        driveControl.addTarget(self, action: #selector(driveChanged), for: .valueChanged)
        orientationControl.selectedSegmentIndex = defaults.bool(forKey: "portraitDisplay") ? 1 : 0
        orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
        resolutionControl.selectedSegmentIndex = min(ReceiverConfiguration.resolutions.count - 1, max(0,
            defaults.object(forKey: "displayResolutionIndex") as? Int ?? ReceiverConfiguration.defaultResolutionIndex))
        aspectRatioControl.selectedSegmentIndex = ReceiverConfiguration.aspectRatios.firstIndex {
            $0.title == defaults.string(forKey: "displayAspectRatio")
        }.map { $0 + 1 } ?? 0
        sizeModeControl.selectedSegmentIndex = defaults.object(forKey: "displaySizeMode") as? Int ?? 0
        carbitSizeModeControl.selectedSegmentIndex = defaults.bool(forKey: "carbitCustomSizeEnabled") ? 1 : 0
        carbitFrameRateControl.selectedSegmentIndex =
            (ZeehoFrameRate(rawValue: defaults.integer(forKey: "carbitFrameRate")) ?? .fps30) == .fps60 ? 1 : 0
        carbitFrameRateControl.addTarget(self, action: #selector(displaySettingChanged), for: .valueChanged)
        frameRateControl.selectedSegmentIndex = [0: 0, 30: 1, 60: 2][defaults.object(forKey: "displayMaxFPS") as? Int ?? 60] ?? 2
        codecControl.selectedSegmentIndex = ["auto": 0, "h264": 1, "h265": 2][defaults.string(forKey: "videoCodec") ?? "h264"] ?? 1
        let savedWidth = defaults.object(forKey: "widthPhysicalMM") as? Int ?? CarPlayInfo.defaultWidthPhysicalMM
        iconSizeControl.selectedSegmentIndex = ReceiverConfiguration.iconSizes.firstIndex { $0.widthMM == savedWidth } ?? 1
        performanceControl.selectedSegmentIndex = BrowserPerformance.allCases.firstIndex(of:
            BrowserPerformance(rawValue: defaults.string(forKey: "browserPerformance") ?? "") ?? .auto) ?? 0
        autoRestartSwitch.isOn = defaults.object(forKey: "autoRestart") as? Bool ?? false
        autoConnectOnLaunchSwitch.isOn = defaults.bool(forKey: "autoConnectOnLaunch")
        autoConnectOnLaunchSwitch.addTarget(self, action: #selector(autoConnectOnLaunchChanged(_:)), for: .valueChanged)
        showTouchesSwitch.isOn = defaults.bool(forKey: "showTouches")
        carButtonSwitch.isOn = defaults.object(forKey: "carButton") as? Bool ?? true
        for menu in [sizeModeControl, carbitSizeModeControl] {
            menu.addTarget(self, action: #selector(displaySizeModeChanged), for: .valueChanged)
        }
        let displayControls: [UIControl] = [resolutionControl, aspectRatioControl, frameRateControl, codecControl, iconSizeControl,
                                            performanceControl, autoRestartSwitch, showTouchesSwitch, carButtonSwitch]
        displayControls.forEach { $0.addTarget(self, action: #selector(displaySettingChanged), for: .valueChanged) }
        appearanceControl.selectedSegmentIndex = defaults.integer(forKey: "carPlayAppearance")
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        passwordField.isSecureTextEntry = true
        httpsMode.selectedSegmentIndex = HTTPSConfiguration.mode.rawValue
        httpsMode.addTarget(self, action: #selector(httpsModeChanged), for: .valueChanged)
        httpsDomainField.text = HTTPSConfiguration.domain
        httpsDomainField.keyboardType = .URL
        httpsTokenField.isSecureTextEntry = true
        httpsStatus.text = CWL("修改地址或证书后，重新启动 CarPlay 生效。")
        httpsTokenField.text = (try? HTTPSConfiguration.secret("duckToken")).flatMap { String(data: $0, encoding: .utf8) }
        httpsDomainField.addTarget(self, action: #selector(saveHTTPSFields), for: .editingDidEnd)
        httpsTokenField.addTarget(self, action: #selector(saveHTTPSFields), for: .editingDidEnd)
        passwordField.textContentType = .password
        ipField.keyboardType = .decimalPad
        let legacyPiPEnabled = defaults.object(forKey: "pictureInPictureEnabled") as? Bool ?? true
        pictureInPictureTiming.selectedSegmentIndex = defaults.object(forKey: "pictureInPictureTiming") as? Int ?? (legacyPiPEnabled ? 1 : 0)
        pictureInPictureTiming.addTarget(self, action: #selector(pictureInPictureTimingChanged), for: .valueChanged)
        keepAliveSwitch.isOn = defaults.object(forKey: "backgroundKeepAlive") as? Bool ?? true
        keepAliveSwitch.addTarget(self, action: #selector(keepAliveChanged), for: .valueChanged)
        let savedOutput = defaults.object(forKey: "headUnitOutputV2") as? Int
        let previousOutput = defaults.object(forKey: "headUnitOutput") as? Int
        let legacyOutput: HeadUnitOutput = defaults.bool(forKey: "carLifeEnabled") ? .carLife : .browser
        let migratedOutput = previousOutput.map { $0 == 1 ? HeadUnitOutput.carLife : .browser } ?? legacyOutput
        // The fork previously stored Carbit as 6, now used by upstream for Ninebot 7.
        let restored: HeadUnitOutput
        if savedOutput == HeadUnitOutput.ninebotSeven.rawValue, defaults.object(forKey: "carbitAddress") != nil,
           defaults.object(forKey: "ninebot43Address") == nil {
            restored = .carbit
            defaults.set(restored.rawValue, forKey: "headUnitOutputV2")
        } else {
            restored = savedOutput.flatMap(HeadUnitOutput.init(rawValue:)) ?? migratedOutput
        }
        headUnitOutput.selectedSegmentIndex = HeadUnitOutput.menuOrder.firstIndex(of: restored) ?? HeadUnitOutput.browser.menuIndex
        headUnitOutput.addTarget(self, action: #selector(headUnitOutputChanged), for: .valueChanged)
        carbitAddressField.text = defaults.string(forKey: "carbitAddress")
        carbitAddressField.keyboardType = .decimalPad
        carbitAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        updateCarbitStatus(CWL("等待启动 CarPlay。"))
        for (field, key) in [(zeehoAddressField, "zeehoAddress"), (zeehoSEPlusAddressField, "zeehoSEPlusAddress")] {
            field.text = defaults.string(forKey: key) ?? "192.168.0.1"
            field.keyboardType = .decimalPad
            field.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        }
        zeehoSEPlusAutomaticSwitch.isOn = defaults.object(forKey: "zeehoSEPlusAutomaticAddress") as? Bool ?? true
        zeehoSEPlusAutomaticSwitch.addTarget(self, action: #selector(zeehoAutomaticAddressChanged), for: .valueChanged)
        zeeho62AutomaticSwitch.isOn = defaults.object(forKey: "zeeho62AutomaticAddress") as? Bool ?? true
        zeeho62AutomaticSwitch.addTarget(self, action: #selector(zeehoAutomaticAddressChanged), for: .valueChanged)
        let savedZeehoFrameRate = ZeehoFrameRate(rawValue: defaults.integer(forKey: "zeehoSEPlusFrameRate")) ?? .fps30
        zeehoSEPlusFrameRateControl.selectedSegmentIndex = ZeehoFrameRate.allCases.firstIndex(of: savedZeehoFrameRate) ?? 1
        zeehoSEPlusFrameRateControl.addTarget(self, action: #selector(zeehoFrameRateChanged), for: .valueChanged)
        zeehoSEPlusCanvasControl.selectedSegmentIndex = (ZeehoCanvas(rawValue: defaults.integer(forKey: "zeehoSEPlusCanvas")) ?? .wide).rawValue
        zeehoSEPlusCanvasControl.addTarget(self, action: #selector(zeehoVideoSettingsChanged), for: .valueChanged)
        zeehoSEPlusVideoModeControl.selectedSegmentIndex = (ZeehoVideoMode(rawValue: defaults.integer(forKey: "zeehoSEPlusVideoMode")) ?? .transcode).rawValue
        zeehoSEPlusVideoModeControl.addTarget(self, action: #selector(zeehoVideoSettingsChanged), for: .valueChanged)
        cfmotoAddressField.text = defaults.string(forKey: "cfmotoAddress") ?? "192.168.0.1"
        cfmotoAddressField.keyboardType = .decimalPad
        cfmotoAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        ninebotAddressField.text = defaults.string(forKey: "ninebotAddress") ?? "192.168.1.1"
        ninebotAddressField.keyboardType = .decimalPad
        ninebotAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        ninebot43AddressField.text = defaults.string(forKey: "ninebot43Address") ?? "192.168.169.1"
        ninebot43AddressField.keyboardType = .decimalPad
        ninebot43AddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        tailingAddressField.text = defaults.string(forKey: "tailingAddress") ?? "192.168.1.1"
        tailingAddressField.keyboardType = .decimalPad
        tailingAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        carLifeAddressField.text = defaults.string(forKey: "carLifeAddress")
        carLifeAddressField.keyboardType = .decimalPad
        carLifeAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        updateCarLifeStatus(CWL("等待启动 CarPlay。"))
        updateAirPlayStatus(CWL("等待启动 CarPlay。"))
        videoOutputSwitch.isOn = defaults.object(forKey: "videoOutputEnabled") as? Bool ?? true
        videoOutputSwitch.addTarget(self, action: #selector(videoOutputToggled), for: .valueChanged)
        videoOutputPortField.text = String(defaults.object(forKey: "videoOutputPort") as? Int ?? 9888)
        secureVideoOutputPortField.text = (defaults.object(forKey: "secureVideoOutputPort") as? Int).map { String($0) }
        for (field, label) in [(videoOutputPortField, CWL("HTTP 端口")), (secureVideoOutputPortField, CWL("HTTPS 端口"))] {
            field.keyboardType = .numberPad
            field.accessibilityLabel = label
            field.addTarget(self, action: #selector(videoOutputSettingChanged), for: .editingChanged)
            field.addTarget(self, action: #selector(saveBrowserPorts), for: .editingDidEnd)
            let toolbar = UIToolbar()
            toolbar.items = [.flexibleSpace(), UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak field] _ in
                field?.resignFirstResponder()
            })]
            toolbar.sizeToFit()
            field.inputAccessoryView = toolbar
        }
        nameField.addTarget(self, action: #selector(receiverNameChanged), for: .editingDidEnd)
        channelField.keyboardType = .numberPad
        [nameField, ipField, ssidField, passwordField, channelField, carLifeAddressField, tailingAddressField, ninebotAddressField, ninebot43AddressField, zeehoAddressField, zeehoSEPlusAddressField, cfmotoAddressField, carbitAddressField, videoOutputPortField, secureVideoOutputPortField, httpsDomainField, httpsTokenField].forEach {
            $0.returnKeyType = .done
            $0.addTarget($0, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
            if $0.inputAccessoryView == nil {
                let field = $0
                let toolbar = UIToolbar()
                toolbar.items = [.flexibleSpace(), UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak field] _ in
                    field?.resignFirstResponder()
                })]
                toolbar.sizeToFit()
                field.inputAccessoryView = toolbar
            }
        }
    }

    @objc private func saveHeadUnitOutput() {
        UserDefaults.standard.set(outputMode.rawValue, forKey: "headUnitOutputV2")
        UserDefaults.standard.set(carbitAddress, forKey: "carbitAddress")
        UserDefaults.standard.set(carLifeAddressField.text ?? "", forKey: "carLifeAddress")
        UserDefaults.standard.set(zeehoAddressField.text ?? "", forKey: "zeehoAddress")
        UserDefaults.standard.set(zeehoSEPlusAddressField.text ?? "", forKey: "zeehoSEPlusAddress")
        UserDefaults.standard.set(cfmotoAddressField.text ?? "", forKey: "cfmotoAddress")
        UserDefaults.standard.set(ninebotAddressField.text ?? "", forKey: "ninebotAddress")
        UserDefaults.standard.set(ninebot43AddressField.text ?? "", forKey: "ninebot43Address")
        UserDefaults.standard.set(tailingAddressField.text ?? "", forKey: "tailingAddress")
        refreshVideoOutputSummary()
    }
    @objc private func zeehoFrameRateChanged() {
        guard !running else { return }
        UserDefaults.standard.set(selectedZeehoFrameRate.rawValue, forKey: "zeehoSEPlusFrameRate")
        refreshVideoOutputSummary()
        reloadVisibleSettings()
    }
    @objc private func zeehoVideoSettingsChanged() {
        guard !running else { return }
        UserDefaults.standard.set(selectedZeehoCanvas.rawValue, forKey: "zeehoSEPlusCanvas")
        UserDefaults.standard.set(zeehoSEPlusVideoModeControl.selectedSegmentIndex, forKey: "zeehoSEPlusVideoMode")
        updateVideoAspect()
        refreshVideoOutputSummary()
        reloadVisibleSettings()
    }
    @objc private func zeehoAutomaticAddressChanged() {
        UserDefaults.standard.set(zeehoSEPlusAutomaticSwitch.isOn, forKey: "zeehoSEPlusAutomaticAddress")
        UserDefaults.standard.set(zeeho62AutomaticSwitch.isOn, forKey: "zeeho62AutomaticAddress")
        refreshVideoOutputSummary()
        reloadVisibleSettings()
    }
    @objc private func headUnitOutputChanged() {
        saveHeadUnitOutput()
        refreshVideoOutputSummary()
        updateVideoAspect()
        reloadVisibleSettings()
    }
    @objc private func audioSettingChanged() {
        UserDefaults.standard.set(selectedSoundOutput.rawValue, forKey: "soundOutput")
    }
    @objc private func receiverNameChanged() {
        guard !running else { return }
        UserDefaults.standard.set(nameField.text ?? "CarWithin", forKey: "receiverName")
    }

    /// Shows settings and, when needed, takes the user to the relevant connection settings.
    func revealSettings(wifi: Bool = false, output: Bool = false) {
        view.endEditing(true)
        if let navigation = settingsNavigation {
            if wifi, activeWiFiForm == nil {
                navigation.popToRootViewController(animated: false)
                navigation.pushViewController(wifiPage(), animated: true)
            }
            return
        }
        let root = rootSettingsPage()
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = false
        root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.settingsNavigation?.view.endEditing(true)
            self?.settingsNavigation?.dismiss(animated: true) { self?.settingsDismissed() }
        })
        navigation.presentationController?.delegate = self
        if wifi { navigation.pushViewController(wifiPage(), animated: false) }
        if output { navigation.pushViewController(headUnitPage(), animated: false) }
        settingsNavigation = navigation
        present(navigation, animated: true)
    }

    fileprivate func settingsDismissed() {
        view.endEditing(true)
        UserDefaults.standard.set(nameField.text ?? "CarWithin", forKey: "receiverName")
        saveHeadUnitOutput()
        refreshNetworkSummary(); refreshVideoOutputSummary(); updateVideoAspect()
        updatePictureInPicturePolicy()
    }

    private var editingLockedFooter: String? { running ? CWL("CarPlay 运行中，停止后才能修改这些设置。") : nil }
    private func onOff(_ toggle: UISwitch) -> () -> String? { { toggle.isOn ? CWL("开") : CWL("关") } }
    private func page(_ title: String, _ build: @escaping () -> [SettingsSection]) -> SettingsPageController {
        SettingsPageController(title: title, build: build)
    }
    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CWL("好"), style: .default))
        (settingsNavigation ?? self).present(alert, animated: true)
    }

    private func aboutLinks() -> [SettingsRow] {
        [
            .externalLink(CWL("GitHub 项目"), icon: ("chevron.left.forwardslash.chevron.right", .systemIndigo)) {
                UIApplication.shared.open(AppRelease.repository)
            },
            .action(CWL("版本记录"), icon: ("clock.arrow.circlepath", .systemPurple)) { [unowned self] in
                self.showVersionHistory()
            },
            .page(CWL("赞赏与支持"), icon: ("hands.sparkles.fill", .systemOrange)) { ContributionsViewController() }
        ]
    }

    private func usagePage() -> SettingsPageController {
        page(CWL("使用说明")) {
            [
                SettingsSection(CWL("1. 先连 Wi-Fi"), [
                    .guide(CWL("让 iPhone 加入 Wi-Fi"), icon: ("wifi", .systemBlue),
                           CWL("路由器、车机 Wi-Fi 或另一台手机的热点都可以。有网、没网都能投屏。运行 CarWithin 的 iPhone 需要实际加入 Wi-Fi，自己开热点不能代替这一步。")),
                    .guide(CWL("选择同名预设"), icon: ("list.bullet", .systemBlue),
                           CWL("回到 CarWithin，在「Wi-Fi 预设」选择刚连的网络。第一次用，在「Wi-Fi 与网络」添加。"))
                ]),
                SettingsSection(CWL("2. 选一种输出"), [
                    .guide(CWL("浏览器"), icon: ("globe", .systemTeal),
                           CWL("车机连同一个 Wi-Fi。在「当前输出」选浏览器，启动 CarPlay，再用车机打开首页显示的 HTTP 地址。")),
                    .guide(CWL("车机或仪表"), icon: ("car.fill", .systemIndigo),
                           CWL("使用仪表时先加入仪表 Wi-Fi，再按首页连接卡的顺序操作。CarLife 先打开车机上的 CarLife；AirPlay 在首页选接收设备。"))
                ]),
                SettingsSection(CWL("3. 常见问题"), [
                    .guide(CWL("卡在正在连接"), icon: ("arrow.clockwise", .systemOrange),
                           CWL("核对 iPhone 连的 Wi-Fi 和预设是否同名。仍连不上，关开一次 Wi-Fi，回到 App 重新启动。")),
                    .guide(CWL("网页打不开或没有画面"), icon: ("exclamationmark.circle", .systemOrange),
                           CWL("先核对两台设备的 Wi-Fi 和首页地址。能打开但没画面时，先试 HTTP，再把画面设为 H.264、720P、30 帧。")),
                    .guide(CWL("仪表没有画面"), icon: ("display", .systemPurple),
                           CWL("确认选对仪表型号、仪表已打开投屏，并在「输出设置」核对仪表 IP。先结束其他投屏。"))
                ])
            ]
        }
    }

    private func httpsHelpPage() -> SettingsPageController {
        page(CWL("HTTPS 低延迟")) {
            [
                SettingsSection(CWL("从 HTTP 接收页开始"), footer: CWL("在接收设备上打开 HTTP 接收页，点「配置 HTTPS」，再按页面步骤为该设备安装证书。"), []),
                SettingsSection(CWL("iPhone 和 iPad"), footer: CWL("下载描述文件后，在系统设置安装，再前往「通用 › 关于本机 › 证书信任设置」开启完全信任，最后打开 HTTPS 地址。"), []),
                SettingsSection("Android", footer: CWL("下载 Android 证书，按接收页指引在系统设置中安装为 CA 证书，再打开 HTTPS 地址。系统菜单名称随品牌而异。"), [])
            ]
        }
    }

    private var installedAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func showVersionHistory() {
        let presenter = settingsNavigation ?? self
        guard presenter.presentedViewController == nil else { return }
        let history = ReleaseHistoryView(installed: installedAppVersion, canDownload: { [weak self] in
            self?.running == false && UIApplication.shared.applicationState == .active
        })
        let controller = UIHostingController(rootView: NavigationStack { history })
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.large()]
        presenter.present(controller, animated: true)
    }

    // MARK: Root

    fileprivate func rootSettingsPage() -> SettingsPageController {
        page(CWL("设置")) { [unowned self] in
            var connection: [SettingsRow] = [
                .page(CWL("使用说明"), icon: ("book.fill", .systemOrange)) { [unowned self] in self.usagePage() }
            ]
            if needsNetworkDetails {
                connection.append(.page(CWL("Wi-Fi 与网络"), icon: ("wifi", .systemBlue), detail: { [unowned self] in
                    self.running || self.waitingForNetwork ? nil : CWL("添加")
                }) { [unowned self] in self.wifiForm(adding: true) })
            }
            connection.append(.page(CWL("Wi-Fi 预设"), icon: ("list.bullet", .systemBlue), detail: { WiFiPresetStore.selected()?.ssid ?? CWL("未选择") }) { [unowned self] in self.presetsPage() })
            connection.append(.control(CWL("当前输出"), icon: ("point.3.connected.trianglepath.dotted", .systemIndigo), headUnitOutput))
            connection.append(.page(CWL("输出设置"), icon: ("slider.horizontal.3", .systemGray)) { [unowned self] in self.headUnitPage() })
            connection.append(.control(CWL("启动时自动连接"), icon: ("power", .systemGreen), autoConnectOnLaunchSwitch))
            if outputMode == .browser {
                connection.append(.page(CWL("HTTPS 设置"), icon: ("lock.shield", .systemBlue)) { [unowned self] in self.httpsSettingsPage() })
            }
            return [
                SettingsSection(CWL("连接与输出"), connection),
                SettingsSection("CarPlay", [
                    .page(CWL("画面"), icon: ("rectangle.on.rectangle", .systemGreen), detail: { [unowned self] in
                        if self.usesCustomSize { return "\(self.customSize.width)×\(self.customSize.height)" }
                        if self.outputMode == .carbit { return CWL("按车机请求输出") }
                        if self.outputMode == .zeehoSEPlus { return "跟随仪表上报尺寸" }
                        return self.outputMode.usesInstrumentWiFi ? CWL("仪表固定尺寸") : self.followsCarScreen ? CWL("跟随车机") : self.resolutionControl.selectedTitle.components(separatedBy: "（").first
                    }) { [unowned self] in self.displayPage() },
                    .control(CWL("CarPlay 外观"), icon: ("circle.lefthalf.filled", .systemBlue), appearanceControl),
                    .page(CWL("声音"), icon: ("speaker.wave.2.fill", .systemOrange), detail: { [unowned self] in
                        switch self.soundOutput {
                        case .carWithin: return CWL("接收设备播放")
                        case .phone: return CWL("iPhone 输出")
                        case .browser: return CWL("Wi-Fi 伴音")
                        }
                    }) { [unowned self] in self.soundPage() },
                    .control(CWL("驾驶位"), icon: ("steeringwheel", .systemTeal), driveControl),
                    .page(CWL("车辆"), icon: ("car.fill", .systemTeal)) { [unowned self] in self.vehiclePage() }
                ]),
                SettingsSection("电池", [
                    .page("电池与 BMS", icon: ("battery.100", .systemGreen)) { [unowned self] in self.antBMS.settingsPage() }
                ]),
                SettingsSection(CWL("后台与画中画"), footer: CWL("锁屏前，请在 iPhone「设置 › 通用 › CarPlay › CarWithin」中打开「锁定时允许 CarPlay」。后台运行会增加耗电。画中画仅显示实时画面。离开 App 时自动开启需打开 iPhone「设置 › 通用 › 画中画」中的自动选项。"), [
                    .control(CWL("锁屏与后台继续运行"), icon: ("lock.fill", .systemPurple), keepAliveSwitch),
                    .control(CWL("画中画开启时机"), icon: ("pip.fill", .systemIndigo), pictureInPictureTiming)
                ]),
                SettingsSection(CWL("支持"), [
                    .page(CWL("诊断与实验"), icon: ("stethoscope", .systemTeal)) { [unowned self] in self.diagnosticsPage() },
                    .page(CWL("日志反馈"), icon: ("text.bubble.fill", .systemBlue)) { LogFeedbackViewController() },
                    .page(CWL("关于"), icon: ("info.circle.fill", .systemGray)) { [unowned self] in self.aboutPage() }
                ])
            ]
        }
    }

    // MARK: CarPlay 画面

    @objc private func displaySizeModeChanged() {
        guard !running, !waitingForNetwork else { return }
        guard usesCustomSize else { displaySettingChanged(); return }
        let carbit = outputMode == .carbit
        let menu = carbit ? carbitSizeModeControl : sizeModeControl
        let defaults = UserDefaults.standard
        let previous = carbit ? (defaults.bool(forKey: "carbitCustomSizeEnabled") ? 1 : 0) : defaults.integer(forKey: "displaySizeMode")
        editCustomSize { menu.selectedSegmentIndex = previous }
    }

    private func customSizeRow() -> SettingsRow {
        let size = customSize
        let value = "\(size.width) × \(size.height)"
        if running || waitingForNetwork { return .info(CWL("宽 × 高（像素）"), value) }
        return .action(CWL("宽 × 高（像素）"), detail: { value }) { [weak self] in self?.editCustomSize() }
    }

    private func editCustomSize(onCancel: (() -> Void)? = nil) {
        guard usesCustomSize, !running, !waitingForNetwork, let navigation = settingsNavigation else { return }
        let limits = outputMode == .browser
            ? CWL("宽、高均为 320–3840 的偶数，总像素不超过 3840 × 2160。")
            : CWL("宽为 320–1920 的偶数，高为 320–1080 的偶数。")
        let editor = UIAlertController(title: CWL("自定义尺寸"), message: limits, preferredStyle: .alert)
        let size = customSize
        for (title, value) in [(CWL("宽"), size.width), (CWL("高"), size.height)] {
            editor.addTextField { field in
                let label = UILabel()
                label.text = " \(title)  "
                label.sizeToFit()
                field.leftView = label
                field.leftViewMode = .always
                field.accessibilityLabel = CWL("{1}（像素）", [title])
                field.keyboardType = .numberPad
                field.text = String(value)
                field.clearButtonMode = .whileEditing
            }
        }
        func pixels(in editor: UIAlertController?) -> [Int]? {
            guard let fields = editor?.textFields,
                  let w = Int(fields[0].text ?? ""), let h = Int(fields[1].text ?? ""),
                  acceptsCustomSize(width: w, height: h) else { return nil }
            return [w, h]
        }
        editor.addAction(UIAlertAction(title: CWL("取消"), style: .cancel) { _ in onCancel?() })
        let save = UIAlertAction(title: "保存", style: .default) { [weak editor] _ in
            guard let pair = pixels(in: editor) else { return }
            UserDefaults.standard.set(pair, forKey: self.customSizeKey)
            self.displaySettingChanged()
        }
        editor.addAction(save)
        for field in editor.textFields ?? [] {
            field.addAction(UIAction { [weak editor, weak save] _ in
                save?.isEnabled = pixels(in: editor) != nil
            }, for: .editingChanged)
        }
        navigation.present(editor, animated: true)
    }

    fileprivate func displayPage() -> SettingsPageController {
        page(CWL("画面")) { [unowned self] in
            if outputMode == .carbit {
                var rows: [SettingsRow] = [.control(CWL("画面尺寸"), icon: ("aspectratio.fill", .systemGreen), carbitSizeModeControl)]
                if usesCustomSize {
                    rows.append(customSizeRow())
                } else {
                    rows.append(.control(CWL("分辨率"), icon: ("display", .systemGreen), resolutionControl))
                    rows.append(.control(CWL("画面比例"), icon: ("aspectratio", .systemGreen), aspectRatioControl))
                }
                rows.append(.control(CWL("帧率"), icon: ("speedometer", .systemOrange), carbitFrameRateControl))
                rows.append(.control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl))
                return [
                    SettingsSection(CWL("亿连画面"), footer: CWL("按车机请求的尺寸等比缩放 CarPlay 画面，宽高比不同时保留黑边。实际发送帧率取决于车机拉帧速度。"), [
                        .info(CWL("车机视频"), CWL("H.264 / JPEG · 最高 1920×1080 · 30/60 FPS"))
                    ]),
                    SettingsSection(CWL("本机 CarPlay"), rows)
                ]
            }
            if let cfmoto = cfmotoProfile {
                let name = outputMode == .cfmoto5 ? "春风 5 寸" : "春风 6.2 寸"
                return [
                    SettingsSection(name, [.info(CWL("仪表画面"), "\(cfmoto.width)×\(cfmoto.height) · H.264 · PXC(TCP) · \(cfmoto.fps) FPS")]),
                    SettingsSection(CWL("图标"), [.control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            if let profile = outputMode.zeehoProfile {
                let size = profile != .zeeho62 ? "跟随仪表上报尺寸" : profile.preferredSize.description
                return [
                    SettingsSection(headUnitOutput.selectedTitle, [.info(CWL("仪表画面"), "\(size) · H.264 · 目标 \(selectedZeehoFrameRate.rawValue) FPS")]),
                    SettingsSection(CWL("图标"), [.control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            if let mode = outputMode.ninebotMode {
                let format: String
                switch mode {
                case .fiveInch: format = CWL("848×480 · H.264 · 最高 30 FPS")
                case .sevenInch: format = CWL("1024×600 · H.264 · 最高 25 FPS")
                case .fourThreeInch: format = CWL("480×272 · JPEG · 最高 10 FPS")
                }
                return [
                    SettingsSection(headUnitOutput.selectedTitle, [
                        .info(CWL("仪表画面"), format)
                    ]),
                    SettingsSection(CWL("图标"), [.control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            if outputMode == .tailing {
                return [
                    SettingsSection(CWL("台铃 4.3 寸"), footer: CWL("选择台铃输出时自动使用匹配的画面参数；切回其他输出后恢复原设置。"), [
                        .info(CWL("仪表画面"), CWL("480×272 · JPEG · 最高 20 FPS")),
                        .info(CWL("本机 CarPlay"), "960×544 · H.264 · 30 FPS")
                    ]),
                    SettingsSection(CWL("图标"), [.control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            var size: [SettingsRow] = [.control(CWL("画面尺寸"), icon: ("aspectratio.fill", .systemGreen), sizeModeControl)]
            if followsCarScreen {
                size.append(.page(CWL("车机屏幕"), icon: ("display", .systemGreen), detail: { [unowned self] in
                    self.targetScreen?.title ?? CWL("尚未记录")
                }) { [unowned self] in self.screensPage() })
            }
            if usesCustomSize {
                size.append(customSizeRow())
            } else {
                size.append(.control(followsCarScreen ? CWL("最高分辨率") : CWL("分辨率"), icon: ("arrow.up.left.and.arrow.down.right", .systemGreen), resolutionControl))
                if !followsCarScreen {
                    size.append(.control(CWL("画面比例"), icon: ("aspectratio", .systemGreen), aspectRatioControl))
                }
            }
            if !usesCustomSize, UIDevice.current.userInterfaceIdiom == .pad, modeControl.selectedSegmentIndex != 2 {
                size.append(.control(CWL("CarPlay 方向"), icon: ("rotate.right.fill", .systemGreen), orientationControl))
            }
            let plan = planDisplay(for: targetScreen)
            return [
                SettingsSection(footer: (usesCustomSize ? CWL("按输入的宽和高启动 CarPlay。") : followsCarScreen
                    ? CWL("启动时先用勾选的屏幕或最近一次设置。第一个网页接管后，窗口尺寸变化会在 CarWithin 回到前台时应用。更大的窗口按最高分辨率等比缩小。")
                    : CWL("选择比例后按分辨率档位计算尺寸，短边至少 320 像素，实际值见下方。2K/4K 会增加发热和带宽。"))
                    + (!usesCustomSize && !followsCarScreen && outputMode != .browser ? CWL("\n此输出受 1920×1080 限制，较长的竖屏比例以实际尺寸为准。") : "")
                    + CWL("\n下次启动：{1}×{2} · {3} FPS · {4}", [String(describing: plan.width), String(describing: plan.height), String(describing: plan.fps), String(describing: plan.codec.displayName)]), size),
                SettingsSection(footer: CWL("自动帧率根据主网页选择 30 或 60 FPS。支持 H.265 的主网页会优先使用 H.265。"), [
                    .control(CWL("视频编码"), icon: ("film.fill", .systemGreen), codecControl),
                    .control(CWL("帧率"), icon: ("gauge.with.dots.needle.67percent", .systemGreen), frameRateControl)
                ]),
                SettingsSection(footer: CWL("浏览器画面持续卡顿时，自动以更轻的画面重启 CarPlay（先降到 30 FPS，再降到 720P），每次连接最多两次。"), [
                    .control(CWL("自动重启"), icon: ("arrow.clockwise", .systemGreen), autoRestartSwitch)
                ]),
                SettingsSection(CWL("图标"), footer: CWL("图标越小，一页放下的越多。可以在「车机屏幕」为不同屏幕保存图标大小。"), [
                    .control(CWL("CarPlay 图标大小"), icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)
                ]),
                SettingsSection(footer: editingLockedFooter, [])
            ].filter { !$0.rows.isEmpty || $0.footer != nil }
        }
    }

    /// Third level: screens CWL("跟随车机") has recorded. Tap to tick, swipe to delete.
    fileprivate func screensPage() -> SettingsPageController {
        page(CWL("车机屏幕")) { [unowned self] in
            let screens = CarScreenStore.screens()
            guard !screens.isEmpty else {
                return [SettingsSection(footer: CWL("启动 CarPlay 后，在车机浏览器打开接收页，屏幕会自动记录在这里。"), [])]
            }
            var rows: [SettingsRow] = screens.map { screen in
                var row = SettingsRow.action(screen.title) { CarScreenStore.setDefault(screen.key) }
                row.subtitle = { screen.subtitle }
                row.checked = { CarScreenStore.defaultKeyValue == screen.key }
                row.onDelete = { [unowned self] in
                    CarScreenStore.remove(screen.key)
                    if self.reportedScreen?.key == screen.key { self.reportedScreen = nil }
                }
                return row
            }
            var latest = SettingsRow.action(CWL("不勾选，使用最近一次")) { CarScreenStore.setDefault(nil) }
            latest.checked = { CarScreenStore.defaultKeyValue == nil }
            rows.append(latest)
            let iconRows = screens.map { screen in
                SettingsRow.page(screen.title, detail: {
                    ReceiverConfiguration.iconSizes.first { $0.widthMM == screen.iconWidthMM }?.title ?? CWL("跟随默认")
                }) { [unowned self] in
                    self.screenIconSizePage(key: screen.key, title: screen.title)
                }
            }
            return [
                SettingsSection(footer: CWL("启动时使用勾选的屏幕。左滑可删除。"), rows),
                SettingsSection(CWL("按屏幕设置图标大小"), iconRows)
            ]
        }
    }

    private func screenIconSizePage(key: String, title: String) -> SettingsPageController {
        page(title) {
            guard let screen = CarScreenStore.screens().first(where: { $0.key == key }) else { return [] }
            let choices: [(title: String, width: Int?)] =
                [(CWL("跟随默认"), nil)] + ReceiverConfiguration.iconSizes.map { ($0.title, Optional($0.widthMM)) }
            let rows = choices.map { choice in
                var row = SettingsRow.action(choice.title) { CarScreenStore.setIconWidth(choice.width, for: key) }
                row.checked = { screen.iconWidthMM == choice.width }
                return row
            }
            return [SettingsSection(footer: CWL("设置会在下次使用这块屏幕时应用。"), rows)]
        }
    }

    // MARK: 声音 / 车辆

    fileprivate func soundPage() -> SettingsPageController {
        page(CWL("声音")) { [unowned self] in
            guard outputMode == .browser else {
                let phone = SoundOutput.phone
                return [SettingsSection(footer: phone.explanation + " 停止 CarPlay 后普通音乐仍无声时，先在这里或控制中心选中耳机，并检查媒体音量。", [
                    .info(CWL("声音输出"), CWL("由 iPhone 输出")),
                    .info("当前声音路由", audioRouteDescription),
                    .control("选择耳机或扬声器", icon: ("headphones", .systemOrange), audioRoutePicker)
                ])]
            }
            let choices = SoundOutput.allCases.filter { output in
                switch output {
                case .carWithin: return receivesAudioFromAnotherDevice
                case .phone: return true
                case .browser: return videoOutputSwitch.isOn
                }
            }
            let rows = choices.map { output in
                let icons = ["speaker.wave.2.fill", "iphone", "wifi"]
                var row = SettingsRow.action(output.title, icon: (icons[output.rawValue], .systemOrange)) { [unowned self] in
                    guard !self.running else {
                        self.alert(CWL("请先停止 CarPlay"), CWL("停止后即可修改声音输出。"))
                        return
                    }
                    self.selectedSoundOutput = output
                    self.audioSettingChanged()
                }
                row.subtitle = { output.explanation }
                row.checked = { [unowned self] in self.soundOutput == output }
                return row
            }
            let footer = videoOutputSwitch.isOn
                ? CWL("更改在下次启动 CarPlay 时生效。使用 Wi-Fi 伴音时，通话和 Siri 留在 iPhone。")
                : CWL("打开局域网接收页后可使用 Wi-Fi 伴音。更改在下次启动 CarPlay 时生效。")
            return [SettingsSection(footer: footer, rows)]
        }
    }

    fileprivate func vehiclePage() -> SettingsPageController {
        page(CWL("车辆")) { [unowned self] in
            var sections: [SettingsSection] = []
            if modeControl.selectedSegmentIndex != 2 {
                sections.append(SettingsSection(footer: CWL("车辆名称显示在 iPhone 的 CarPlay 车辆列表中。"), [
                    .field(CWL("车辆名称"), nameField, placeholder: "CarWithin")
                ]))
            }
            var button: [SettingsRow] = [.control(CWL("显示车辆按钮"), icon: ("car.side.fill", .systemTeal), carButtonSwitch)]
            if let data = customVehicleIcon ?? Self.carButtonIcon, let image = UIImage(data: data) {
                let thumbnail = UIImageView(image: image)
                thumbnail.layer.cornerRadius = 8
                thumbnail.clipsToBounds = true
                thumbnail.widthAnchor.constraint(equalToConstant: 36).isActive = true
                thumbnail.heightAnchor.constraint(equalToConstant: 36).isActive = true
                let preview = UILabel()
                preview.text = customVehicleIcon == nil ? CWL("当前图标 · 默认") : CWL("当前图标 · 自选图片")
                preview.font = .preferredFont(forTextStyle: .body)
                let row = UIStackView(arrangedSubviews: [thumbnail, preview])
                row.spacing = 12; row.alignment = .center
                button.append(.view(row))
            }
            if importingVehicleIcon {
                button.append(.info(CWL("正在读取照片…"), ""))
            } else if !running {
                button.append(.action(CWL("从照片选择图标"), icon: ("photo", .systemBlue)) { [unowned self] in
                    self.pickVehicleIcon()
                })
                if customVehicleIcon != nil {
                    button.append(.action(CWL("恢复默认图标")) { [unowned self] in
                        UserDefaults.standard.removeObject(forKey: Self.customVehicleIconKey)
                        self.reloadVisibleSettings()
                    })
                }
            }
            let footer = running ? CWL("停止 CarPlay 后可更换图标。") : CWL("图片会居中裁成正方形，下次启动 CarPlay 时生效。")
            sections.append(SettingsSection(CWL("CarPlay 车辆按钮"), footer: footer, button))
            return sections
        }
    }

    private func pickVehicleIcon() {
        guard !running, !importingVehicleIcon else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        (settingsNavigation ?? self).present(picker, animated: true)
    }

    private static func vehicleIconPNG(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let size = CGSize(width: 120, height: 120)
        let image = UIImage(cgImage: thumbnail)
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
    }

    // MARK: Wi-Fi

    fileprivate func wifiPage() -> SettingsPageController { wifiForm(adding: false) }

    private func wifiForm(adding: Bool) -> SettingsPageController {
        let editable = !running && !waitingForNetwork
        let form = UUID()
        let previous = (ssidField.text, passwordField.text, channelField.text,
                        openNetworkSwitch.isOn, passwordLoadedForSSID, passwordStatus.text)
        let isAdding = adding && editable
        if isAdding {
            ssidField.text = ""; passwordField.text = ""; channelField.text = "36"
            openNetworkSwitch.isOn = false; passwordLoadedForSSID = nil; passwordStatus.text = nil
        }
        activeWiFiForm = form
        let title = isAdding ? CWL("添加 Wi-Fi") : editable ? CWL("编辑 Wi-Fi") : CWL("Wi-Fi 与网络")
        let controller = page(title) { [unowned self] in
            var current: [SettingsRow] = []
            if canDetectWiFiName && editable {
                current.append(.action(CWL("读取当前 Wi-Fi"), icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in
                    guard !self.running else { return }
                    self.detectNetwork()
                })
            }
            var fields: [SettingsRow] = []
            if modeControl.selectedSegmentIndex == 0 {
                fields.append(.field(CWL("本机 IP 地址"), ipField))
            }
            fields += [
                .field(CWL("Wi-Fi 名称"), ssidField),
                .field(CWL("密码"), passwordField, placeholder: CWL("开放网络留空")),
                .control(CWL("开放网络（无密码）"), openNetworkSwitch),
                .field(CWL("兼容信道"), channelField, placeholder: "36")
            ]
            var sections: [SettingsSection] = []
            if !current.isEmpty { sections.append(SettingsSection(current)) }
            sections.append(SettingsSection(footer: editingLockedFooter ?? CWL("返回自动保存。同名网络会更新原预设，兼容信道通常保持 36。"), fields))
            if editable, passwordStatus.text?.isEmpty == false { sections.append(SettingsSection([.note(passwordStatus)])) }
            return sections
        }
        controller.onLeave = { [weak self] in
            guard let self, self.activeWiFiForm == form else { return }
            self.activeWiFiForm = nil
            self.awaitingNetworkPermission = false
            guard editable, !self.running, !self.waitingForNetwork else { return }
            let hasName = !(self.ssidField.text ?? "").isEmpty
            if hasName, self.saveCurrentWiFiPreset() {
                self.refreshNetworkSummary()
                if WiFiCredentials.isTemporary(for: self.ssidField.text ?? "") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.alert(CWL("Wi-Fi 密码仅本次使用"), WiFiCredentials.temporaryNotice)
                    }
                }
                return
            }
            let reason = hasName ? self.passwordStatus.text : nil
            (self.ssidField.text, self.passwordField.text, self.channelField.text,
             self.openNetworkSwitch.isOn, self.passwordLoadedForSSID, self.passwordStatus.text) = previous
            self.refreshNetworkSummary()
            if let reason {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.alert(CWL("Wi-Fi 未保存"), reason)
                }
            }
        }
        return controller
    }

    /// Select, edit or remove a saved Wi-Fi preset.
    fileprivate func presetsPage() -> SettingsPageController {
        page(CWL("Wi-Fi 预设")) { [unowned self] in
            let presets = WiFiPresetStore.presets()
            let editable = !running && !waitingForNetwork
            guard !presets.isEmpty else {
                return [SettingsSection(footer: editable ? CWL("添加预设后，切换网络时可直接选用。") : editingLockedFooter, editable ? [
                    .page(CWL("添加 Wi-Fi"), icon: ("plus", .systemBlue)) { [unowned self] in self.wifiForm(adding: true) }
                ] : [])]
            }
            let rows = presets.map { preset in
                var row = SettingsRow.action(preset.ssid) { [unowned self] in if editable { self.applyWiFiPreset(preset) } }
                if preset.isOpen { row.subtitle = { CWL("开放网络") } }
                row.checked = { WiFiPresetStore.selected()?.ssid == preset.ssid }
                row.onDelete = { [unowned self] in
                    guard !self.running else { return }
                    do { try WiFiCredentials.forget(preset.ssid) }
                    catch { self.alert(CWL("删除失败"), CWL("无法删除保存的密码，请重试。")); return }
                    WiFiPresetStore.remove(preset.ssid)
                    if self.ssidField.text == preset.ssid {
                        if let next = WiFiPresetStore.selected() { self.applyWiFiPreset(next) }
                        else {
                            self.ssidField.text = ""; self.passwordField.text = ""
                            self.passwordLoadedForSSID = nil; self.openNetworkSwitch.isOn = false
                            self.refreshNetworkSummary()
                        }
                    }
                }
                if !editable { row.onDelete = nil }
                return row
            }
            var sections = [SettingsSection(footer: editable ? CWL("轻点选用，左滑后确认删除。") : editingLockedFooter, rows)]
            if editable {
                sections.append(SettingsSection([.page(CWL("编辑当前预设"), icon: ("pencil", .systemBlue)) { [unowned self] in self.wifiPage() }]))
            }
            return sections
        }
    }

    // MARK: 输出方式

    fileprivate func headUnitPage() -> SettingsPageController {
        page(CWL("输出设置")) { [unowned self] in
            switch outputMode {
            case .browser: return browserOutputSections()
            case .carbit: return carbitOutputSections()
            case .carLife: return carLifeOutputSections()
            case .airPlay: return airPlayOutputSections()
            case .tailing: return tailingOutputSections()
            case .zeeho, .zeehoSEPlus, .zeehoAE2:
                let name = outputMode == .zeehoAE2 ? "极核 AE2 Pro 5 寸" : outputMode == .zeehoSEPlus ? "极核 AE4 SE+ 升级版 5/5.5 寸" : CWL("极核 AE4 MAX2+ 6.2 寸")
                var rows: [SettingsRow] = []
                rows.append(.control("自动查找仪表 IP", icon: ("network", .systemBlue), outputMode == .zeehoSEPlus ? zeehoSEPlusAutomaticSwitch : zeeho62AutomaticSwitch))
                if outputMode == .zeehoSEPlus {
                    rows.append(.control("仪表目标帧率", icon: ("gauge.with.dots.needle.67percent", .systemGreen), zeehoSEPlusFrameRateControl))
                    rows.append(.control("CarPlay 画面", icon: ("aspectratio", .systemGreen), zeehoSEPlusCanvasControl))
                    rows.append(.control("视频发送方式", icon: ("film", .systemIndigo), zeehoSEPlusVideoModeControl))
                    rows.append(.info("当前发送方式", selectedZeehoVideoMode.title))
                    rows.append(.info(CWL("使用说明"), "全宽适合本机 1600×770 仪表。直传兼容性待实测，黑屏时改回兼容转码。25 FPS 自动使用转码。锁屏时暂停手机预览，后台保持需开启。"))
                }
                if usesAutomaticZeehoAddress {
                    rows.append(.info("仪表 IP", "连接时自动匹配，结果见日志"))
                } else {
                    rows.append(.field(CWL("仪表 IP 地址"), activeZeehoAddressField, placeholder: "192.168.0.1"))
                }
                rows.append(.note(zeehoStatus))
                return [SettingsSection(name, footer: CWL("让 iPhone 加入仪表 Wi-Fi，选择同名预设。结束其他投屏，打开仪表投屏后启动 CarPlay。声音由 iPhone 或蓝牙输出。"), rows)]
            case .cfmoto5, .cfmoto62:
                return [SettingsSection(headUnitOutput.selectedTitle, footer: "iPhone 加入春风仪表 Wi-Fi 并开启仪表投屏，TCP 10920/10921/10922，探测 10930。留空 IP 时尝试同网段 .1，失败请填写实际仪表 IP。", [
                    .field(CWL("仪表 IP 地址"), cfmotoAddressField, placeholder: "留空尝试 .1"),
                    .note(cfmotoStatus)
                ])]
            case .ninebot, .ninebotSeven, .ninebot43:
                let fiveInch = outputMode == .ninebot
                let startup = fiveInch
                    ? CWL("iPhone 连上仪表 Wi-Fi，选择对应预设，在 CarWithin 启动 CarPlay。")
                    : Self.ninebotOfficialInstructions
                let keepOfficialApp = fiveInch
                    ? CWL("没有画面时，保持 CarWithin 运行，再到九号出行开启投屏导航。仪表出画后，可尝试从多任务界面划掉九号出行；若仪表随之退出投屏，则该型号需要保留官方会话。")
                    : CWL("九号出行必须保留在后台，不能从多任务界面划掉。切换 App 前请打开「锁屏与后台继续运行」。")
                var instructions: [SettingsRow] = [
                    .guide(CWL("启动顺序"), icon: ("play.circle", .systemBlue), startup),
                    .guide(fiveInch ? CWL("没有画面时") : CWL("九号出行需保留后台"),
                           icon: ("info.circle", .systemBlue), keepOfficialApp)
                ]
                if fiveInch {
                    instructions.append(.guide(CWL("端口被占用"), icon: ("exclamationmark.triangle", .systemOrange),
                        CWL("若提示 UDP 5012 被占用，先停止 CarWithin，退出九号出行投屏导航及其他投屏 App，再按上面的顺序重试。")))
                }
                return [
                    SettingsSection(headUnitOutput.selectedTitle, [
                        .field(CWL("仪表 IP 地址"), activeNinebotAddressField, placeholder: outputMode == .ninebot43 ? "192.168.169.1" : "192.168.1.1"),
                        .note(ninebotStatus)
                    ]),
                    SettingsSection(CWL("使用说明"), instructions)
                ]
            }
        }
    }

    private var carbitAddress: String {
        (carbitAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func carbitOutputSections() -> [SettingsSection] {
        var rows: [SettingsRow] = []
        if !running && !waitingForNetwork {
            #if !targetEnvironment(macCatalyst)
            rows.append(.action(CWL("扫描车机二维码"), icon: ("qrcode.viewfinder", .systemIndigo)) { [weak self] in self?.scanCarbitCode() })
            #endif
            rows.append(.page(CWL("查找局域网车机"), icon: ("wifi", .systemBlue)) { [unowned self] in self.carbitDiscoveryPage() })
        }
        rows.append(.field(CWL("车机 IP"), carbitAddressField, placeholder: CWL("车机的局域网 IPv4")))
        if running {
            rows.append(.action(CWL("发送 5 秒测试色条"), icon: ("tv", .systemBlue)) { [weak self] in
                self?.receiver.requestCarbitTestPicture()
            })
        }
        rows.append(.note(carbitStatus))
        return [SettingsSection(CWL("亿连直连（实验）"), footer: CWL("在车机打开亿连，iPhone 加入同一局域网并保存 Wi-Fi 预设。支持触控回传的车机可点按和拖动 CarPlay 画面。iPhone 提供可触控的低帧率预览，也可开启画中画；声音走 iPhone 或蓝牙。"), rows)]
    }

    private func carbitDiscoveryPage() -> SettingsPageController {
        let browser = TDSCarKitReceiverBrowser(serviceType: CarbitConnectionCode.serviceType)
        var targets: [TDSCarKitReceiverBrowser.Target] = []
        var help = CWL("正在此 Wi-Fi 查找亿连服务。若车机未广播服务，可返回填写车机 IP。")
        let controller = page(CWL("选择亿连车机")) { [unowned self] in
            [SettingsSection(footer: help, targets.map { target in
                .action(target.name, detail: { target.address }) { [weak self] in
                    guard let self, !self.running, !self.waitingForNetwork else { return }
                    self.carbitAddressField.text = target.address
                    self.saveHeadUnitOutput()
                    self.updateCarbitStatus(CWL("已选择 {1}，启动 CarPlay 后连接。", [target.name]))
                    self.settingsNavigation?.popViewController(animated: true)
                }
            })]
        }
        browser.onTargets = { [weak controller] found in targets = found; controller?.reload() }
        browser.onDiscoveryFailure = { [weak controller] in
            help = CWL("未能发现车机，请检查本地网络权限和 Wi-Fi 连接。")
            controller?.reload()
        }
        controller.onAppear = { targets = []; browser.start() }
        controller.onLeave = { browser.stop() }
        return controller
    }

    private func airPlayOutputSections() -> [SettingsSection] {
        [
            SettingsSection(CWL("AirPlay（实验）"), footer: CWL("在主界面的 AirPlay 连接卡选择设备。画面有缓冲，触控在 iPhone 上操作，声音沿用 iPhone 或车机蓝牙。"), [
                .field(CWL("播放端口"), videoOutputPortField),
                .note(airPlayStatus)
            ])
        ]
    }

    private func prepareExternalOutput(configuration: ReceiverConfiguration) {
        let previewFrames = configuration.carbitAddress != nil
        videoSurface.usePreviewFrames(previewFrames)
        receiver.setLocalVideoEnabled(true)
        if configuration.zeehoAddress != nil { updateZeehoStatus(CWL("正在连接极核仪表…")) }
        if configuration.cfmotoProfile != nil { updateCfmotoStatus("正在推流到春风仪表…") }
        if configuration.ninebotAddress != nil { updateNinebotStatus(CWL("正在连接九号仪表…")) }
        if configuration.tailingAddress != nil { updateTailingStatus(CWL("正在连接台铃仪表…")) }
        if configuration.carLifeEnabled {
            updateCarLifeStatus(CWL("正在等待车机连接…"))
        }
        guard let id = configuration.airPlayStreamID, let port = configuration.videoOutputPort else { return }
        airPlayStreamID = id
        airPlayStreamURL = URL(string: "http://\(configuration.address):\(port)/airplay/\(id.uuidString)/master.m3u8")
        updateAirPlayStatus(CWL("正在准备直播画面…"))
    }

    private var airPlaySourceIsStale: Bool {
        guard let last = airPlayLastVideoAt else { return false }
        return ProcessInfo.processInfo.systemUptime - last >= 10
    }

    private func retryAirPlayTransport() {
        guard running, outputMode == .airPlay else { return }
        if airPlaySourceIsStale {
            // Reloading old HLS segments cannot restore the CarPlay producer.
            restartCarPlay(reason: CWL("AirPlay 长时间未收到新画面，重新建立 CarPlay 会话"))
        } else {
            startAirPlayTransport()
        }
    }

    private func startAirPlayTransport() {
        guard airPlayReady, let url = airPlayStreamURL else { return }
        let player: AVPlayer
        if let existing = airPlayPlayer {
            player = existing
        } else {
            // Local video stays on the CarPlay surface. Each session owns its player.
            player = AVPlayer()
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            airPlayRouteObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refreshAirPlayPlaybackStatus() }
            }
            airPlayPlayer = player
        }
        // Replacing an item must also discard observations of that item's wait state.
        airPlayItemObservation = nil
        airPlayTimeObservation = nil
        airPlayWaitingSince = nil
        let item = AVPlayerItem(url: url)
        if airPlayHealthTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshAirPlayPlaybackStatus() }
            RunLoop.main.add(timer, forMode: .common)
            airPlayHealthTimer = timer
        }
        #if DEBUG
        airPlayDiagnostic = ""
        log(CWL("AirPlay HLS 已就绪：{1}", [String(describing: url.absoluteString)]))
        #endif
        airPlayTimeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.refreshAirPlayPlaybackStatus() }
        }
        airPlayItemObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.airPlayPlayer?.currentItem === item else { return }
                self.refreshAirPlayPlaybackStatus()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        refreshAirPlayPlaybackStatus()
    }

    @objc private func airPlayAudioRouteChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshAirPlayPlaybackStatus()
            self.log("当前声音路由：\(self.audioRouteDescription)")
            self.reloadVisibleSettings()
        }
    }

    private func refreshAirPlayPlaybackStatus() {
        guard running, outputMode == .airPlay, airPlayReady, let player = airPlayPlayer,
              let item = player.currentItem else { return }
        #if DEBUG
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)/\($0.portName)" }.joined(separator: ", ")
        let error = item.error as NSError?
        let errorDetail = error.map { "\($0.domain)(\($0.code)) \($0.localizedDescription)" } ?? "–"
        let diagnostic = CWL("AirPlay 播放器：item={1} time={2} 外部视频={3} 路由={4} 等待={5} 错误={6}", [String(describing: item.status.rawValue), String(describing: player.timeControlStatus.rawValue), String(describing: player.isExternalPlaybackActive), String(describing: outputs), String(describing: player.reasonForWaitingToPlay?.rawValue ?? "–"), String(describing: errorDetail)])
        if diagnostic != airPlayDiagnostic { airPlayDiagnostic = diagnostic; log(diagnostic) }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if airPlayWaitingSince == nil { airPlayWaitingSince = now }
        } else { airPlayWaitingSince = nil }
        let prolongedWait = airPlayWaitingSince.map { now - $0 >= 10 } ?? false
        let sourceStale = airPlaySourceIsStale
        if sourceStale != airPlaySourceWasStale {
            airPlaySourceWasStale = sourceStale
            log(sourceStale ? CWL("已超过 10 秒未收到新画面，可重试连接 CarPlay。") : CWL("AirPlay 已恢复接收新画面。"))
        }
        let paused = item.status == .readyToPlay && player.timeControlStatus == .paused
        airPlayRetryButton.isHidden = item.status != .failed && !sourceStale && !prolongedWait && !paused
        if sourceStale {
            updateAirPlayStatus(CWL("已超过 10 秒未收到新画面，可重试连接 CarPlay。"))
            return
        }
        if item.status == .failed {
            updateAirPlayStatus(CWL("AirPlay 画面加载失败，可以重试。"))
            return
        }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            updateAirPlayStatus(prolongedWait ? CWL("AirPlay 缓冲时间较长，可以重试。") : CWL("AirPlay 正在缓冲画面…"))
            return
        }
        if paused {
            updateAirPlayStatus(CWL("AirPlay 已暂停，可以重试。"))
            return
        }
        let defaults = UserDefaults.standard
        if player.isExternalPlaybackActive {
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
            if let name = route?.portName, !name.isEmpty {
                defaults.set(name, forKey: Self.lastAirPlayDeviceKey)
                updateAirPlayStatus(CWL("正在投放到 {1}", [String(describing: name)]))
            } else {
                updateAirPlayStatus(CWL("正在通过 AirPlay 投放"))
            }
        } else if let previous = defaults.string(forKey: Self.lastAirPlayDeviceKey) {
            updateAirPlayStatus(CWL("上次设备：{1}", [String(describing: previous)]))
        } else {
            updateAirPlayStatus(CWL("画面已就绪，可选择设备。"))
        }
    }

    private func tailingOutputSections() -> [SettingsSection] {
        [
            SettingsSection(CWL("台铃 4.3 寸"), footer: CWL("适用于 TL-DASH-V2 仪表。iPhone 加入仪表 Wi-Fi，在「Wi-Fi 与网络」填写该网络信息；开启仪表投屏后启动 CarPlay。请先退出其他投屏 App。"), [
                .field(CWL("仪表 IP 地址"), tailingAddressField, placeholder: "192.168.1.1")
            ]),
            SettingsSection(footer: CWL("仪表输出固定为 480×272、JPEG，最高 20 FPS。本机 CarPlay 使用 H.264、960×544、30 FPS。声音由 iPhone／蓝牙输出；仪表不回传触控。"), [.note(tailingStatus)])
        ]
    }

    private func carLifeOutputSections() -> [SettingsSection] {
        [
            SettingsSection("CarLife", footer: CWL("车机与 iPhone 连同一个 Wi-Fi，打开车机上的 CarLife 后启动 CarPlay。使用 H.264，最高 1080p、30 FPS。"), [
                .field(CWL("车机 IP 地址"), carLifeAddressField, placeholder: CWL("留空自动发现"))
            ]),
            SettingsSection(CWL("连接状态"), footer: CWL("CarLife 传输画面和触控，声音走 iPhone 与车机的蓝牙。"), [.note(carLifeStatus)])
        ]
    }

    private func browserOutputSections() -> [SettingsSection] {
        let browser = SettingsSection(footer: videoOutputSwitch.isOn ? nil : CWL("开启后，同一局域网的浏览器可以查看并触控 CarPlay。"), [
            .control(CWL("局域网接收页"), icon: ("globe", .systemTeal), videoOutputSwitch)
        ])
        guard videoOutputSwitch.isOn else { return [browser] }
        return [
            browser,
            SettingsSection(CWL("HTTP · 兼容模式"), [
                .field(CWL("HTTP 端口"), videoOutputPortField),
                browserAddressRow(secure: false),
                .action(CWL("在本机浏览器打开")) { [unowned self] in
                    guard self.running, let url = self.localBrowserURL else {
                        self.alert(CWL("请先启动 CarPlay"), CWL("启动后就可以在本机浏览器查看画面。"))
                        return
                    }
                    UIApplication.shared.open(url)
                }
            ]),
            SettingsSection(CWL("高级"), footer: CWL("浏览器性能默认自动。低延迟频繁跳帧时会回到兼容模式。"), [
                .control(CWL("浏览器性能"), icon: ("speedometer", .systemBlue), performanceControl),
                .control(CWL("显示触摸点"), icon: ("hand.tap.fill", .systemOrange), showTouchesSwitch)
            ])
        ]
    }

    @objc private func httpsModeChanged() {
        guard !running else { httpsMode.selectedSegmentIndex = HTTPSConfiguration.mode.rawValue; return }
        HTTPSConfiguration.mode = HTTPSConfiguration.Mode(rawValue: httpsMode.selectedSegmentIndex) ?? .local
        refreshVideoOutputSummary(); reloadVisibleSettings()
    }

    @objc private func saveHTTPSFields() {
        guard !running else { return }
        let input = httpsDomainField.text ?? ""
        if let domain = HTTPSConfiguration.normalizedDomain(input) {
            HTTPSConfiguration.domain = domain
        } else if input.isEmpty { HTTPSConfiguration.domain = "" }
        else { httpsStatus.text = CWL("域名格式应为 name.duckdns.org，不包含协议或端口。"); return }
        do {
            try HTTPSConfiguration.saveSecret(Data((httpsTokenField.text ?? "").utf8), name: "duckToken")
            httpsStatus.text = CWL("配置已保存，停止并重新启动 CarPlay 后使用新证书或地址。")
        } catch { httpsStatus.text = CWL("无法安全保存 Token，请重试。") }
        refreshVideoOutputSummary()
    }

    fileprivate func httpsSettingsPage() -> SettingsPageController {
        let controller = page(CWL("HTTPS 设置")) { [unowned self] in
            self.httpsMode.isEnabled = !self.running
            self.httpsDomainField.isEnabled = !self.running
            self.httpsTokenField.isEnabled = !self.running
            var sections = [SettingsSection(CWL("地址与证书"), footer: self.editingLockedFooter ?? CWL("本地 IP 和 sslip.io 使用这台设备的本地根证书。DuckDNS 可使用自行申请的公开 CA 证书。"), [
                .control(CWL("地址方案"), icon: ("globe", .systemTeal), self.httpsMode),
                .field(CWL("HTTPS 端口"), self.secureVideoOutputPortField), self.browserAddressRow(secure: true)
            ])]
            switch HTTPSConfiguration.mode {
            case .local:
                sections.append(SettingsSection(footer: CWL("在接收设备的 HTTP 页面点「配置 HTTPS」，安装并信任本机根证书。"), [
                    .page(CWL("证书安装说明"), icon: ("doc.text", .systemBlue)) { [unowned self] in self.httpsHelpPage() }
                ]))
            case .sslip:
                sections.append(SettingsSection(footer: CWL("地址根据手机当前 IP 自动生成，无需账号；DNS 解析需要网络。仍需在接收设备信任本机根证书。只改变域名，不保证绕过特斯拉的私网限制。"), [
                    .page(CWL("证书安装说明"), icon: ("doc.text", .systemBlue)) { [unowned self] in self.httpsHelpPage() }
                ]))
            case .duckDNS:
                sections.append(SettingsSection("DuckDNS", footer: CWL("先在 duckdns.org 注册自己的域名。Token 可修改账号中的域名，请像密码一样保管；仅保存在本机 Keychain。此处将域名指向当前局域网地址，不开放公网端口。"), [
                    .externalLink(CWL("注册或管理域名"), icon: ("link", .systemBlue)) { UIApplication.shared.open(URL(string: "https://www.duckdns.org")!) },
                    .field(CWL("域名"), self.httpsDomainField, placeholder: "name.duckdns.org"),
                    .field("Token", self.httpsTokenField),
                    .action(CWL("更新到当前 IP")) { [unowned self] in self.updateDuckDNS() }
                ]))
                sections.append(SettingsSection(CWL("受信任证书"), footer: CWL("使用 ACME DNS-01 等方式在外部申请该域名的公开证书，导出包含私钥与完整证书链的 P12 后导入。当前不自动签发或续期；到期后需重新导入。仅在本机受信任不能保证车机信任；域名和证书也不能保证绕过车机的私网限制。"), [
                    .action(CWL("导入 P12 证书")) { [unowned self] in self.chooseHTTPSCertificate() },
                    .info(CWL("证书文件"), (try? HTTPSConfiguration.secret("certificate")) == nil ? CWL("尚未导入") : CWL("已保存，启动时校验"))
                ]))
            }
            sections.append(SettingsSection([.note(self.httpsStatus), .note(self.portStatus)]))
            return sections
        }
        controller.onLeave = { [weak self] in self?.saveHTTPSFields() }
        return controller
    }

    private func updateDuckDNS() {
        guard !running, let address = browserAddress else { httpsStatus.text = CWL("请先停止 CarPlay，并连接 Wi-Fi。"); return }
        saveHTTPSFields()
        guard HTTPSConfiguration.normalizedDomain(httpsDomainField.text ?? "") != nil else { return }
        httpsStatus.text = CWL("正在更新解析…")
        Task { [weak self] in
            do { try await HTTPSConfiguration.updateDNS(address: address); self?.httpsStatus.text = CWL("解析已更新到 {1}，DNS 缓存生效可能需要稍等。", [String(describing: address)]) }
            catch { self?.httpsStatus.text = error.localizedDescription }
        }
    }

    private func chooseHTTPSCertificate() {
        guard !running else { return }
        saveHTTPSFields()
        guard HTTPSConfiguration.normalizedDomain(httpsDomainField.text ?? "") != nil else { httpsStatus.text = CWL("请先填写有效域名。"); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data], asCopy: true)
        picker.delegate = self
        (settingsNavigation ?? self).present(picker, animated: true)
    }

    private func browserAddressRow(secure: Bool) -> SettingsRow {
        let address = { [unowned self] in secure ? self.secureBrowserURL : self.browserURL }
        var row = SettingsRow.action(secure ? CWL("复制 HTTPS 地址") : CWL("复制 HTTP 地址")) { [unowned self] in
            self.copySettingsAddress(address())
        }
        row.subtitle = { address() ?? CWL("地址暂不可用") }
        return row
    }

    private func copySettingsAddress(_ url: String?) {
        guard let url else {
            alert(CWL("无法复制地址"), browserPortError ?? CWL("请先连接 Wi-Fi。"))
            return
        }
        UIPasteboard.general.string = url
        alert(CWL("已复制"), url)
    }

    // MARK: 日志 / 实验 / 关于

    fileprivate func logPage() -> SettingsPageController {
        let controller = page(CWL("日志")) { [unowned self] in
            [
                SettingsSection(footer: CWL("最近 200 条，不含 Wi-Fi 密码和 MFi 私钥。"), [.view(logView)]),
                SettingsSection([.action(CWL("复制日志"), icon: ("doc.on.doc.fill", .systemBlue)) { [unowned self] in
                    self.copyLog(); self.alert(CWL("已复制"), CWL("日志已复制到剪贴板。"))
                }])
            ]
        }
        logView.constraints.filter { $0.firstAttribute == .height }.forEach { $0.constant = 380 }
        controller.onAppear = { [unowned self] in
            self.logView.text = self.lines.joined(separator: "\n")
            if !self.logView.text.isEmpty { self.logView.scrollRangeToVisible(NSRange(location: self.logView.text.utf16.count - 1, length: 1)) }
        }
        return controller
    }

    private func experimentSections() -> [SettingsSection] {
        var sections = [SettingsSection(CWL("实验性功能"), footer: CWL("检查这台 iPhone 是否允许 App 发布本机 iAP2 配件端点（本机 CarPlay 的前提）。CarPlay 运行中不能测试。"), [
            .action(CWL("测试本机传输能力"), icon: ("checkmark.shield.fill", .systemPink), detail: { [unowned self] in self.statusLabel.text }) { [unowned self] in
                self.testSameDeviceTransport()
            }
        ])]
        if UIDevice.current.userInterfaceIdiom == .pad {
            sections.append(SettingsSection(CWL("iPad 模式"), footer: CWL("接收其他 iPhone 的 CarPlay，或把这台设备的 CarPlay 投送到另一台 iPad。"), [.view(modeControl)]))
            if modeControl.selectedSegmentIndex == 0 {
                sections.append(SettingsSection(footer: CWL("用蓝牙通知 iPhone 连接这块接收屏。"), [
                    .control(CWL("蓝牙引导"), icon: ("dot.radiowaves.right", .systemBlue), bluetoothSetupSwitch)
                ]))
            }
        }
        return sections
    }

    private func diagnosticsSection() -> SettingsSection {
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return SettingsSection(CWL("诊断信息"), [
            .page(CWL("日志"), icon: ("doc.text.fill", .systemGray)) { [unowned self] in self.logPage() },
            .info(CWL("浏览器页面"), BrowserReceiverPage.version),
            .info(CWL("设备"), "\(model) · iOS \(UIDevice.current.systemVersion)"),
            .info(CWL("MFi 身份"), identity != nil ? CWL("已载入") : CWL("未载入"))
        ])
    }

    private func diagnosticsPage() -> SettingsPageController {
        page(CWL("诊断与实验")) { [unowned self] in
            [diagnosticsSection()] + experimentSections()
        }
    }

    fileprivate func aboutPage() -> SettingsPageController {
        page(CWL("关于")) { [unowned self] in
            [
                SettingsSection([.view(self.aboutIdentityCard())]),
                SettingsSection(footer: "Copyright © 2026 xmz28", self.aboutLinks())
            ]
        }
    }

    private func aboutIdentityCard() -> UIView {
        let info = Bundle.main.infoDictionary ?? [:]
        let primaryIcon = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconName = (primaryIcon?["CFBundleIconFiles"] as? [String])?.first
        let image = iconName.flatMap { UIImage(named: $0) } ?? Self.carButtonIcon.flatMap { UIImage(data: $0) }
        let icon = UIImageView(image: image)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 17
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        let name = UILabel()
        name.text = "CarWithin"
        name.font = .preferredFont(forTextStyle: .title2)
        name.adjustsFontForContentSizeCategory = true
        name.accessibilityTraits.insert(.header)
        let version = UILabel()
        version.text = CWL("版本 {1}（{2}）", [String(describing: info["CFBundleShortVersionString"] as? String ?? "-"), String(describing: info["CFBundleVersion"] as? String ?? "-")])
        version.font = .preferredFont(forTextStyle: .subheadline)
        version.textColor = .secondaryLabel
        version.adjustsFontForContentSizeCategory = true
        let introduction = UILabel()
        introduction.text = CWL("在 iPhone 上启动 CarPlay，通过浏览器或兼容的 CarLife 车机查看和操控。")
        introduction.font = .preferredFont(forTextStyle: .subheadline)
        introduction.textColor = .secondaryLabel
        introduction.adjustsFontForContentSizeCategory = true
        introduction.textAlignment = .center
        introduction.numberOfLines = 0

        let card = UIStackView(arrangedSubviews: [icon, name, version, introduction])
        card.axis = .vertical
        card.alignment = .center
        card.spacing = 4
        card.setCustomSpacing(12, after: icon)
        card.setCustomSpacing(12, after: version)
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 8, bottom: 16, trailing: 8)
        return card
    }

}

#if !targetEnvironment(macCatalyst)
extension ReceiverViewController: DataScannerViewControllerDelegate {
    private func scanCarbitCode() {
        guard DataScannerViewController.isSupported else {
            alert(CWL("当前 iPhone 无法使用实时扫码"), CWL("请使用「查找局域网车机」，或手动输入车机 IP。"))
            return
        }
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, !running, !waitingForNetwork, let navigation = settingsNavigation,
                  navigation.presentedViewController == nil else { return }
            guard granted, DataScannerViewController.isAvailable else {
                alert(CWL("相机不可用"), CWL("请允许相机权限，或使用「查找局域网车机」。"))
                return
            }
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                   recognizesMultipleItems: false, isHighlightingEnabled: true)
            scanner.delegate = self
            scanner.title = CWL("点按车机二维码")
            scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak scanner] _ in
                scanner?.stopScanning()
                scanner?.dismiss(animated: true)
            })
            navigation.present(UINavigationController(rootViewController: scanner), animated: true) {
                do { try scanner.startScanning() }
                catch {
                    scanner.dismiss(animated: true) { self.alert(CWL("无法开始扫码"), CWL("请查找局域网车机或手动输入 IP。")) }
                }
            }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { return }
        dataScanner.stopScanning()
        let code = CarbitConnectionCode(text)
        dataScanner.dismiss(animated: true) { [weak self] in
            guard let self, self.outputMode == .carbit, !self.running, !self.waitingForNetwork else { return }
            // A new QR code must never silently reuse the previous vehicle's address.
            self.carbitAddressField.text = code.address
            self.saveHeadUnitOutput()
            let network = code.ssid.map { CWL("请先加入 Wi-Fi「{1}」。", [$0]) } ?? ""
            if let ip = code.address {
                self.updateCarbitStatus(CWL("{1}已读取车机地址 {2}，可启动 CarPlay。", [network, ip]))
            } else {
                self.updateCarbitStatus(CWL("{1}二维码中未找到局域网地址。请在同一 Wi-Fi 下查找车机，或填写车机 IP。", [network]))
            }
        }
    }
}
#endif

extension ReceiverViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, !running else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: url) else { alert(CWL("无法导入"), CWL("请选择不超过 512 KB 的 P12 证书。")); return }
        let prompt = UIAlertController(title: CWL("证书密码"), message: CWL("密码与证书仅保存在本机 Keychain。"), preferredStyle: .alert)
        prompt.addTextField { $0.isSecureTextEntry = true; $0.placeholder = CWL("P12 密码，可为空") }
        prompt.addAction(UIAlertAction(title: CWL("取消"), style: .cancel))
        prompt.addAction(UIAlertAction(title: CWL("导入"), style: .default) { [weak self, weak prompt] _ in
            do {
                try HTTPSConfiguration.importCertificate(data, password: prompt?.textFields?.first?.text ?? "")
                self?.httpsStatus.text = CWL("证书通过本机域名、有效期和信任校验，重新启动 CarPlay 后生效。")
                self?.reloadVisibleSettings()
            } catch { self?.httpsStatus.text = error.localizedDescription }
        })
        let presentPrompt = { [weak self] in
            guard let self else { return }
            (self.settingsNavigation ?? self).present(prompt, animated: true)
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: presentPrompt)
        } else {
            DispatchQueue.main.async(execute: presentPrompt)
        }
    }
}

extension ReceiverViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        settingsDismissed()
    }
}

extension ReceiverViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else {
            picker.dismiss(animated: true)
            return
        }
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        picker.dismiss(animated: true) { [weak self] in
            self?.importVehicleIcon(from: provider, typeIdentifier: identifier)
        }
    }

    private func importVehicleIcon(from provider: NSItemProvider, typeIdentifier: String) {
        importingVehicleIcon = true
        reloadVisibleSettings()
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            let png = url.flatMap(Self.vehicleIconPNG(at:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.importingVehicleIcon = false
                defer { self.reloadVisibleSettings() }
                guard let png else {
                    self.alert(CWL("无法读取图片"), CWL("请选择另一张照片再试。"))
                    return
                }
                UserDefaults.standard.set(png, forKey: Self.customVehicleIconKey)
            }
        }
    }
}
