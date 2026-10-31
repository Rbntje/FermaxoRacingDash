import Foundation
import Combine
import Network
import Darwin

final class TelemetryReceiver: ObservableObject {
    @Published private(set) var status = "WAITING FOR PS5"
    @Published private(set) var isListening = false
    @Published private(set) var port: UInt16 = 20777
    @Published private(set) var localIPv4: String?
    @Published private(set) var apiStatus = "STARTING"
    @Published private(set) var apiPort: UInt16 = 8081
    var apiBaseURL: String? { localIPv4.map { "http://\($0):\(apiPort)" } }
    var onSnapshot: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "com.fermaxo.udp")
    private var listener: NWListener?
    private var apiServer: TelemetryAPIServer?
    private var snapshot: [String: Any] = [
        "format": 2026, "status": "WAITING FOR PS5", "updated": NSNull(),
        "trackName": NSNull(), "sessionName": NSNull(),
        "speed": NSNull(), "gear": NSNull(), "rpm": NSNull(), "rpmPercent": NSNull(),
        "throttle": NSNull(), "brake": NSNull(), "currentLapMs": NSNull(),
        "lastLapMs": NSNull(), "bestLapMs": NSNull(), "lap": NSNull(), "position": NSNull(),
        "sectors": [NSNull(), NSNull(), NSNull()],
        "tyreTemps": [NSNull(), NSNull(), NSNull(), NSNull()],
        "tyrePressures": [NSNull(), NSNull(), NSNull(), NSNull()],
        "tyreWear": [NSNull(), NSNull(), NSNull(), NSNull()],
        "compound": NSNull(), "ersPercent": NSNull(), "ersKj": NSNull(),
        "ersMode": NSNull(), "harvestKj": NSNull(), "deployKj": NSNull(),
        "fuelKg": NSNull(), "straightMode": "UNAVAILABLE", "overtake": NSNull(),
        "safetyCar": NSNull(), "safetyDelta": NSNull(), "flag": "--",
        "sessionGroup": "UNKNOWN", "mapReady": false
    ]
    private var lastPacket = Date.distantPast
    private var sessionUID: UInt64?

    private let packetLengths: [UInt8: Int] = [
        1: 926, 2: 1399, 3: 45, 4: 1470, 5: 1233, 6: 1448, 7: 1445,
        8: 1134, 9: 1062, 10: 1133, 11: 1460, 12: 231, 13: 273,
        14: 104, 15: 1231, 16: 269
    ]

    func start(port newPort: UInt16 = 20777) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: newPort) else { return }
        port = newPort
        status = "WAITING FOR PS5"
        snapshot["status"] = "WAITING FOR PS5"
        localIPv4 = Self.wifiIPv4()
        startAPIServer()
        do {
            let listener = try NWListener(using: .udp, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        if self.status == "WAITING FOR PS5" { self.publishStatus("WAITING FOR PS5") }
                    case .failed(let error):
                        self.isListening = false
                        self.publishStatus("UDP ERROR: \(error.localizedDescription)")
                    case .cancelled:
                        self.isListening = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publishStatus("UDP ERROR: \(error.localizedDescription)")
        }
    }

    func sendCurrent() { publish() }

    func stop() {
        listener?.cancel()
        listener = nil
        apiServer?.stop()
        apiServer = nil
        isListening = false
    }

    private func startAPIServer() {
        let server = TelemetryAPIServer(port: apiPort) { [weak self] in
            guard let self else { return [:] }
            return self.queue.sync { self.snapshot }
        }
        server.onStatus = { [weak self] status in self?.apiStatus = status }
        apiServer = server
        server.start()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.async {
                    if self.decode(data) {
                        self.lastPacket = Date()
                        self.snapshot["status"] = "LIVE"
                        self.snapshot["updated"] = Date().timeIntervalSince1970
                        self.publish()
                    }
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func decode(_ data: Data) -> Bool {
        guard data.count >= 29, u16(data, 0) == 2026 else { return false }
        let pid = data[6]
        guard let expected = packetLengths[pid], data.count == expected else { return false }
        let car = Int(data[28])
        guard car < 24 else { return false }
        if pid == 0 || pid == 13 { return false }
        let uid = u64(data, 8)
        if sessionUID != uid {
            sessionUID = uid
            snapshot["trackName"] = NSNull()
            snapshot["sessionName"] = NSNull()
            snapshot["bestLapMs"] = NSNull()
            snapshot["mapReady"] = false
        }

        switch pid {
        case 1:
            let sessionType = Int(data[35])
            let trackID = i8(data, 36)
            snapshot["trackName"] = trackID >= 0 ? "TRACK \(trackID)" : NSNull()
            snapshot["sessionName"] = Self.sessionNames[sessionType] ?? "SESSION"
            snapshot["sessionGroup"] = sessionType >= 1 && sessionType <= 4 ? "PRACTICE" :
                (sessionType >= 5 && sessionType <= 14 ? "QUALIFYING" :
                (sessionType >= 15 && sessionType <= 17 ? "RACE" :
                (sessionType == 18 ? "TIME TRIAL" : "UNKNOWN")))
            let safety = Int(data[29 + 125])
            snapshot["safetyCar"] = [1: "SAFETY CAR", 2: "VSC", 3: "FORMATION"][safety] ?? (NSNull() as Any)
        case 2:
            let off = 29 + car * 57
            snapshot["lastLapMs"] = nonzero(Double(u32(data, off)))
            snapshot["currentLapMs"] = nonzero(Double(u32(data, off + 4)))
            let s1 = Double(u16(data, off + 8)) + Double(data[off + 10]) * 60000
            let s2 = Double(u16(data, off + 11)) + Double(data[off + 13]) * 60000
            snapshot["sectors"] = [s1 > 0 ? s1 as Any : NSNull(), s2 > 0 ? s2 as Any : NSNull(), (snapshot["sectors"] as? [Any])?[2] ?? NSNull()]
            snapshot["safetyDelta"] = finite(f32(data, off + 28)) as Any? ?? NSNull()
            snapshot["position"] = data[off + 32] == 0 ? NSNull() : Int(data[off + 32])
            snapshot["lap"] = data[off + 33] == 0 ? NSNull() : Int(data[off + 33])
        case 6:
            let off = 29 + car * 59
            snapshot["speed"] = Int(u16(data, off))
            let throttle = finite(f32(data, off + 2))
            let brake = finite(f32(data, off + 10))
            snapshot["throttle"] = throttle.map { Int((max(0, min(1, $0)) * 100).rounded()) } as Any? ?? NSNull()
            snapshot["brake"] = brake.map { Int((max(0, min(1, $0)) * 100).rounded()) } as Any? ?? NSNull()
            snapshot["gear"] = Int(i8(data, off + 15))
            snapshot["rpm"] = Int(u16(data, off + 16))
            let maxRPM = (snapshot["maxRpm"] as? Double) ?? 0
            snapshot["rpmPercent"] = maxRPM > 0 ? min(100, Double(u16(data, off + 16)) * 100 / maxRPM) : NSNull()
            snapshot["tyreTemps"] = [Int(data[off + 32]), Int(data[off + 33]), Int(data[off + 30]), Int(data[off + 31])]
            let rawPressures = (0..<4).map { finite(f32(data, off + 39 + $0 * 4)) }
            snapshot["tyrePressures"] = [rawPressures[2], rawPressures[3], rawPressures[0], rawPressures[1]].map { $0 as Any? ?? NSNull() }
        case 7:
            let off = 29 + car * 59
            let fuel = finite(f32(data, off + 5))
            snapshot["fuelKg"] = fuel.map { ($0 * 10).rounded() / 10 } as Any? ?? NSNull()
            snapshot["maxRpm"] = Double(u16(data, off + 17))
            snapshot["compound"] = String(data[off + 26])
            let flag = i8(data, off + 28)
            snapshot["flag"] = [-1: "--", 0: "--", 1: "GREEN", 2: "BLUE", 3: "YELLOW"][Int(flag)] ?? "--"
            let energy = finite(f32(data, off + 37))
            snapshot["ersKj"] = energy.flatMap { $0 >= 0 ? ($0 / 1000) as Double? : nil } as Any? ?? NSNull()
            snapshot["ersMode"] = [0: "NONE", 1: "MEDIUM", 2: "HOTLAP", 3: "BOOST"][Int(data[off + 41])] ?? "--"
            let harvest = finite(f32(data, off + 42))
            let harvestH = finite(f32(data, off + 46))
            snapshot["harvestKj"] = (harvest != nil && harvestH != nil) ? ((harvest! + harvestH!) / 1000) as Any : NSNull()
            let deployed = finite(f32(data, off + 54))
            snapshot["deployKj"] = deployed.map { $0 / 1000 } as Any? ?? NSNull()
        case 10:
            let off = 29 + car * 46
            let wear = (0..<4).map { finite(f32(data, off + $0 * 4)) }
            snapshot["tyreWear"] = [wear[2], wear[3], wear[0], wear[1]].map { value in
                value.map { max(0, min(100, $0)) } as Any? ?? NSNull()
            }
        case 11:
            if Int(data[29]) == car {
                let count = min(Int(data[30]), 100)
                let bestLap = Int(data[32])
                let history = 29 + 7
                if bestLap >= 1 && bestLap <= count {
                    let off = history + (bestLap - 1) * 14
                    let lap = u32(data, off)
                    if lap > 0 && data[off + 13] & 1 != 0 { snapshot["bestLapMs"] = Int(lap) }
                }
                if count > 0 {
                    for lapIndex in stride(from: count - 1, through: 0, by: -1) {
                        let off = history + lapIndex * 14
                        if data[off + 13] & 1 != 0 {
                            let s3 = Double(u16(data, off + 10)) + Double(data[off + 12]) * 60000
                            if s3 > 0 {
                                var sectors = snapshot["sectors"] as? [Any] ?? [NSNull(), NSNull(), NSNull()]
                                sectors[2] = s3
                                snapshot["sectors"] = sectors
                            }
                            break
                        }
                    }
                }
            }
        case 14:
            let off = 29 + 25
            let valid = data[off + 24]
            let lap = u32(data, off + 3)
            if valid == 1 && lap > 0 { snapshot["bestLapMs"] = Int(lap) }
        case 16:
            let off = 29 + car * 10
            let available = data[off + 1] != 0
            let mode = data[off]
            snapshot["straightMode"] = available ? (mode == 1 ? "STRAIGHT" : "CORNER") : "UNAVAILABLE"
            let overtakeAvailable = data[off + 4] != 0
            let overtakeActive = data[off + 5] != 0
            snapshot["overtake"] = overtakeActive ? "ACTIVE" : (overtakeAvailable ? "AVAILABLE" : "UNAVAILABLE")
        case 3:
            let event = String(bytes: data[29..<33], encoding: .ascii) ?? ""
            if event == "RDFL" { snapshot["flag"] = "RED" }
            else if event == "CHQF" { snapshot["flag"] = "CHEQUERED" }
            else if event == "SSTA" || event == "SEND" { snapshot["flag"] = "GREEN" }
        default:
            break
        }
        return true
    }

    private func publishStatus(_ newStatus: String) {
        snapshot["status"] = newStatus
        publish()
    }

    private func publish() {
        let current = snapshot
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = current["status"] as? String ?? "WAITING FOR PS5"
            self.onSnapshot?(current)
        }
    }

    private func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private func i8(_ d: Data, _ o: Int) -> Int8 { Int8(bitPattern: d[o]) }
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    private func u64(_ d: Data, _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(d[o + $1]) << UInt64($1 * 8)) }
    }
    private func f32(_ d: Data, _ o: Int) -> Double { Double(Float(bitPattern: u32(d, o))) }
    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    private func nonzero(_ value: Double) -> Any { value > 0 ? value : NSNull() }

    private static let sessionNames: [Int: String] = [
        0: "UNKNOWN", 1: "PRACTICE 1", 2: "PRACTICE 2", 3: "PRACTICE 3", 4: "SHORT PRACTICE",
        5: "QUALIFYING 1", 6: "QUALIFYING 2", 7: "QUALIFYING 3", 8: "SHORT QUALIFYING",
        9: "ONE-SHOT QUALIFYING", 10: "SPRINT SHOOTOUT 1", 11: "SPRINT SHOOTOUT 2",
        12: "SPRINT SHOOTOUT 3", 13: "SHORT SPRINT SHOOTOUT", 14: "ONE-SHOT SPRINT SHOOTOUT",
        15: "RACE", 16: "RACE 2", 17: "RACE 3", 18: "TIME TRIAL"
    ]

    private static func wifiIPv4() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard let name = interface.ifa_name,
                  String(cString: name) == "en0",
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }
}
