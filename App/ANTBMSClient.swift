import CoreBluetooth
import Foundation
import UIKit

/// Read-only ANT telemetry, confined to the main queue. A peripheral is selected
/// explicitly and remembered by CoreBluetooth UUID, never by strongest signal.
final class ANTBMSClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device {
        let id: UUID
        let name: String
        let rssi: Int
    }

    private static let service = CBUUID(string: "FFE0")
    private static let characteristic = CBUUID(string: "FFE1")
    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var found: [UUID: Device] = [:]
    private var writer: CBCharacteristic?
    private var reader: CBCharacteristic?
    private var parser = ANTBMSProtocol()
    private var timer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var enabled = false
    private var scanRequested = false
    private var writePending = false
    private var connectedAt: TimeInterval?
    private var retryDelay: TimeInterval = 2
    private var disconnecting = Set<UUID>()
    private(set) var status = "未连接 BMS"
    private(set) var sample: ANTBMSSample?
    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?

    var devices: [Device] { found.values.sorted { $0.rssi > $1.rssi } }
    var selectedID: UUID? { defaults.string(forKey: "antBMSPeripheral").flatMap(UUID.init(uuidString:)) }
    var selectedName: String { defaults.string(forKey: "antBMSName") ?? "未选择" }
    var freshReading: ANTBMSReading? {
        guard let sample, sample.isFresh(at: ProcessInfo.processInfo.systemUptime) else { return nil }
        return sample.reading
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    deinit {
        timer?.invalidate(); reconnectWork?.cancel(); scanTimeout?.cancel()
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            connectRememberedOrScan()
        } else {
            update("等待蓝牙可用")
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        enabled = false; scanRequested = false
        timer?.invalidate(); timer = nil
        reconnectWork?.cancel(); reconnectWork = nil
        scanTimeout?.cancel(); scanTimeout = nil
        central?.stopScan()
        clearConnection()
        update("未连接 BMS")
    }

    func scan() {
        guard enabled else { return }
        scanRequested = true
        found.removeAll(); discovered.removeAll()
        beginScan()
    }

    func select(_ id: UUID) {
        guard enabled, let device = found[id] else { return }
        defaults.set(id.uuidString, forKey: "antBMSPeripheral")
        defaults.set(device.name, forKey: "antBMSName")
        reconnectWork?.cancel(); reconnectWork = nil
        central?.stopScan(); scanRequested = false
        scanTimeout?.cancel(); scanTimeout = nil
        clearConnection()
        retryDelay = 2
        connectRememberedOrScan()
    }

    func forget() {
        clearConnection()
        reconnectWork?.cancel(); reconnectWork = nil
        defaults.removeObject(forKey: "antBMSPeripheral")
        defaults.removeObject(forKey: "antBMSName")
        if enabled { scan() } else { update("未选择 BMS") }
    }

    /// Restores a previously chosen device from a vehicle profile, never a scan guess.
    func restoreSelection(id: UUID?, name: String?) {
        clearConnection()
        reconnectWork?.cancel(); reconnectWork = nil
        if let id {
            defaults.set(id.uuidString, forKey: "antBMSPeripheral")
            defaults.set(name ?? "ANT BMS", forKey: "antBMSName")
        } else {
            defaults.removeObject(forKey: "antBMSPeripheral")
            defaults.removeObject(forKey: "antBMSName")
        }
        if enabled { connectRememberedOrScan() } else { update("已恢复车辆 BMS 配置") }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { disconnecting.removeAll() }
        guard enabled else { return }
        if central.state == .poweredOn {
            if scanRequested { beginScan() } else { connectRememberedOrScan() }
        } else {
            reconnectWork?.cancel(); reconnectWork = nil
            scanTimeout?.cancel(); scanTimeout = nil
            clearConnection()
            disconnecting.removeAll()
            switch central.state {
            case .unauthorized: update("蓝牙权限未允许，请在系统设置中开启")
            case .poweredOff: update("蓝牙已关闭")
            case .unsupported: update("此设备不支持 BMS 蓝牙读取")
            default: update("等待蓝牙可用")
            }
        }
    }

    private func connectRememberedOrScan() {
        guard enabled, let central, central.state == .poweredOn, peripheral == nil else { return }
        guard let id = selectedID else { scan(); return }
        guard !disconnecting.contains(id) else { scheduleReconnect(); return }
        if let target = discovered[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            central.stopScan()
            peripheral = target; target.delegate = self
            connectedAt = ProcessInfo.processInfo.systemUptime
            update("正在连接 \(selectedName)…")
            central.connect(target, options: nil)
        } else {
            scanRequested = true
            beginScan()
        }
    }

    private func beginScan() {
        guard enabled, let central, central.state == .poweredOn else { return }
        scanTimeout?.cancel()
        // Known ANT service filtering also supports iOS background discovery.
        central.scanForPeripherals(withServices: UIApplication.shared.applicationState == .active ? nil : [Self.service], options: nil)
        update("正在扫描 ANT BMS…")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.central?.stopScan(); self.scanRequested = false
            if self.peripheral == nil {
                self.update(self.found.isEmpty ? "未找到 ANT BMS，请确认蓝牙模块已开启" : "请选择自己的 ANT BMS")
                if self.selectedID != nil { self.scheduleReconnect() }
            }
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名 FFE0 设备"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.uppercased().hasPrefix("ANT") || services.contains(Self.service) || peripheral.identifier == selectedID else { return }
        // Service FFE0 is shared by many brands; selecting a candidate never
        // confirms ANT support. Only a validated realtime frame does that.
        discovered[peripheral.identifier] = peripheral
        found[peripheral.identifier] = Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        onChange?()
        if selectedID == peripheral.identifier, self.peripheral == nil { connectRememberedOrScan() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard enabled, peripheral === self.peripheral else { return }
        update("已连接蓝牙，正在发现 ANT 通道…")
        connectedAt = ProcessInfo.processInfo.systemUptime
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if disconnecting.remove(peripheral.identifier) != nil {
            if enabled, self.peripheral == nil { scheduleReconnect() }
            return
        }
        disconnected(peripheral, reason: "BMS 连接失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if disconnecting.remove(peripheral.identifier) != nil {
            if enabled, self.peripheral == nil { scheduleReconnect() }
            return
        }
        disconnected(peripheral, reason: "BMS 已断开")
    }

    private func disconnected(_ device: CBPeripheral, reason: String) {
        guard device === peripheral else { return }
        clearConnection()
        guard enabled else { return }
        update(reason + "，等待重连")
        scheduleReconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, enabled else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failConnection("设备没有可用的 ANT FFE0 服务"); return
        }
        peripheral.discoverCharacteristics([Self.characteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, enabled else { return }
        let candidates = service.characteristics ?? []
        guard error == nil,
              let writer = candidates.first(where: { $0.uuid == Self.characteristic &&
                  ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }),
              let reader = candidates.first(where: { $0.uuid == Self.characteristic &&
                  ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) else {
            failConnection("设备没有可用的 ANT FFE1 收发通道"); return
        }
        self.writer = writer; self.reader = reader
        peripheral.setNotifyValue(true, for: reader)
        update("正在订阅 ANT 实时数据…")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === reader, enabled else { return }
        guard error == nil, characteristic.isNotifying else { failConnection("BMS 通知订阅失败"); return }
        update("等待首个校验有效的 ANT 实时帧…")
        poll()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === reader, enabled,
              error == nil, let data = characteristic.value else { return }
        let readings = parser.append(data)
        guard let reading = readings.last else { return }
        sample = ANTBMSSample(reading: reading, uptime: ProcessInfo.processInfo.systemUptime)
        retryDelay = 2
        update("ANT 实时数据已连接")
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === writer else { return }
        writePending = false
        if let error { failConnection("BMS 读取请求失败：\(error.localizedDescription)") }
    }

    private func tick() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let sample, !sample.isFresh(at: now) {
            update("BMS 数据已过期，等待恢复")
        }
        if let connectedAt, now - (sample?.uptime ?? connectedAt) > 12 {
            failConnection("BMS 未返回有效实时数据，正在重连")
            return
        }
        poll()
        onChange?()
    }

    private func poll() {
        guard enabled, let peripheral, peripheral.state == .connected,
              let writer, reader?.isNotifying == true, !writePending else { return }
        let type: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
        // The single outbound command is the documented read-only realtime query.
        writePending = type == .withResponse
        peripheral.writeValue(ANTBMSProtocol.realtimeRequest, for: writer, type: type)
    }

    private func failConnection(_ message: String) {
        clearConnection()
        update(message)
        scheduleReconnect()
    }

    private func clearConnection() {
        let previous = peripheral
        peripheral = nil; writer = nil; reader = nil; sample = nil
        connectedAt = nil; writePending = false; parser = ANTBMSProtocol()
        previous?.delegate = nil
        if let previous, previous.state != .disconnected {
            disconnecting.insert(previous.identifier)
            central?.cancelPeripheralConnection(previous)
        }
    }

    private func scheduleReconnect() {
        guard enabled, selectedID != nil, reconnectWork == nil, central?.state == .poweredOn else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            self.connectRememberedOrScan()
        }
        reconnectWork = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retry)
        retryDelay = min(retryDelay * 2, 30)
    }

    private func update(_ text: String) {
        if text != status { status = text; onLog?(text) }
        onChange?()
    }
}
