import Foundation

struct LyTpmsReading: Equatable {
    let kPa: Int
    let celsius: Int
}

enum LyTpms175CWire {
    static let freshFor: TimeInterval = 60

    static func decode(_ data: Data) -> LyTpmsReading? {
        let b = Array(data.prefix(17))
        guard b.count == 17, b[0] == 0xac, b[1] == 0x00, b[2] == 0xc7,
              b[5] <= 2, b[8] == 0 else { return nil }
        let c = Int(b[4]) - 55
        let mv = Int(b[6]) * 256 + Int(b[7])
        guard (-40...110).contains(c), (1_800...3_600).contains(mv) else { return nil }
        return LyTpmsReading(kPa: (Int(b[3]) * 100 + 16) / 32, celsius: c)
    }

    static func packet(front: LyTpmsReading?, rear: LyTpmsReading?) -> String {
        "#TP|\(front?.kPa ?? -1)|\(rear?.kPa ?? -1)|\(front?.celsius ?? -99)|\(rear?.celsius ?? -99)"
    }

    static func isFresh(_ seenAt: TimeInterval, now: TimeInterval) -> Bool {
        now >= seenAt && now - seenAt < freshFor
    }
}

#if os(iOS)
import CoreBluetooth
import SwiftUI
import UIKit

/// Passive scanning only; a user explicitly identifies and assigns each installed valve.
final class Tpms175C: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = Tpms175C()

    struct Sensor: Identifiable {
        let id: UUID
        let name: String
        let reading: LyTpmsReading
        let at: TimeInterval
        var shortID: String { String(id.uuidString.suffix(5)) }
    }

    @Published private(set) var candidates: [Sensor] = []
    @Published private(set) var scanning = false
    @Published private(set) var enabled = false
    @Published private(set) var frontID: UUID?
    @Published private(set) var rearID: UUID?
    private var central: CBCentralManager?
    private var seen: [UUID: Sensor] = [:]
    private var lastPacket: String?
    private var lastSentAt = 0.0
    private var wasConnected = false
    private let prefs = UserDefaults.standard

    private override init() {
        frontID = prefsUUID("tpms_175c_front")
        rearID = prefsUUID("tpms_175c_rear")
        enabled = UserDefaults.standard.bool(forKey: "tpms_175c_enabled")
        super.init()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        prefs.set(value, forKey: "tpms_175c_enabled")
        if !value { sendEmptyIfNeeded(); seen.removeAll(); candidates = [] }
        tick()
    }

    func assign(_ front: Bool, id: UUID?) {
        if front {
            if id == rearID { rearID = nil }
            frontID = id
        } else {
            if id == frontID { frontID = nil }
            rearID = id
        }
        prefs.set(frontID?.uuidString, forKey: "tpms_175c_front")
        prefs.set(rearID?.uuidString, forKey: "tpms_175c_rear")
        tick()
    }

    func current(_ id: UUID?) -> Sensor? {
        guard let id, let s = seen[id], LyTpms175CWire.isFresh(s.at, now: now) else { return nil }
        return s
    }

    func tick() {
        let link = BleLink.shared
        let connected = link.isReady && link.verified && link.extras175CEnabled
        if !connected, wasConnected {
            lastPacket = nil
            lastSentAt = 0
        }
        wasConnected = connected
        let shouldScan = enabled && connected && UIApplication.shared.applicationState == .active
        if shouldScan {
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            if central?.state == .poweredOn, !scanning {
                central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                scanning = true
            }
        } else if scanning {
            central?.stopScan()
            scanning = false
        }
        guard enabled, connected else { return }
        let t = now
        seen = seen.filter { LyTpms175CWire.isFresh($0.value.at, now: t) }
        let rows = seen.values.sorted { $0.id.uuidString < $1.id.uuidString }
        if rows.map(\.at) != candidates.map(\.at) { candidates = rows }
        let front = current(frontID)?.reading, rear = current(rearID)?.reading
        let packet = LyTpms175CWire.packet(front: front, rear: rear)
        if packet != lastPacket || (front != nil || rear != nil) && t - lastSentAt >= 4 {
            link.sendOnce(packet)
            lastPacket = packet
            lastSentAt = t
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { scanning = false }
        tick()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard enabled, scanning, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = LyTpms175CWire.decode(data) else { return }
        let id = peripheral.identifier
        if seen[id] == nil && seen.count >= 20 {
            guard let oldest = seen.values.filter({ $0.id != frontID && $0.id != rearID }).min(by: { $0.at < $1.at }) else { return }
            seen.removeValue(forKey: oldest.id)
        }
        seen[id] = Sensor(id: id, name: peripheral.name ?? "LyTPMS", reading: reading, at: now)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func sendEmptyIfNeeded() {
        let link = BleLink.shared
        guard link.isReady, link.verified, link.extras175CEnabled else { return }
        link.sendOnce(LyTpms175CWire.packet(front: nil, rear: nil))
        lastPacket = nil
    }
}

private func prefsUUID(_ key: String) -> UUID? {
    UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
}

struct Tpms175CControls: View {
    @ObservedObject private var tpms = Tpms175C.shared

    var body: some View {
        Toggle("LyTPMS 胎压", isOn: Binding(get: { tpms.enabled }, set: { tpms.setEnabled($0) }))
        if tpms.enabled {
            wheel("前轮", front: true, selection: tpms.frontID)
            wheel("后轮", front: false, selection: tpms.rearID)
            Text("仅支持 LyTPMS 指定广播格式。请停车，在前台逐个唤醒气嘴并手动指定前后轮。60 秒无数据将显示无读数；不能替代胎压表或原车警报。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func wheel(_ title: String, front: Bool, selection: UUID?) -> some View {
        let reading = tpms.current(selection)
        return Menu {
            Button("取消绑定") { tpms.assign(front, id: nil) }
            ForEach(tpms.candidates) { sensor in
                Button("\(sensor.name) · \(sensor.shortID)") { tpms.assign(front, id: sensor.id) }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(reading.map { "\($0.reading.kPa) kPa · \($0.reading.celsius) °C" }
                     ?? (selection == nil ? "选择气嘴" : "无新读数"))
            }
        }
    }
}
#endif
