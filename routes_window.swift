// 라우팅 보기 창: 규칙 대상으로 가는 새 연결이 앱 → 규칙 → 출구로 흐르는 모습을 그린다.
// 창이 열려 있는 동안만 엔진 사건 소켓에 붙는다 (붙어 있는 동안만 엔진이 pf 기록을 켠다).

import AppKit
import Combine
import Darwin
import SwiftUI

// MARK: - 사건 받기

@MainActor
final class EventStream: ObservableObject {
    @Published var recent: [ConnEvent] = []          // 최근 것이 앞
    @Published var connected = false
    @Published var animating = false             // 움직일 게 있을 때만 그림을 다시 그린다
    @Published var problem: String?
    @Published var allTraffic = UserDefaults.standard.bool(forKey: "routesAllTraffic")   // "전체": 규칙 밖 연결도 (연결 표를 1초마다 훑음). 고른 것을 기억한다
    @Published var replaying = false
    @Published var replayCursor: Int?            // 되감기로 보고 있는 시각 (ms)
    @Published var historyStamp = 0              // 기록이 바뀔 때마다 올라 타임라인을 다시 그리게 한다
    @Published var flowStamp = 0                 // 길(연결)이 생기거나 사라질 때 올라 포트 글자를 다시 그리게 한다
    let scene = RouteScene()
    var history: [ConnEvent] = []                // 최근 10분 (오래된 것이 앞). 메모리에만
    var names: HostNames?
    var statusProvider: () -> EngineStatus? = { nil }
    private let sampler = OutsideSampler()
    private var replayTask: Task<Void, Never>?
    static let keep: Double = 600                // 10분

    private var fd: Int32 = -1
    private var src: DispatchSourceRead?
    private var buffer = Data()
    private var wanted = false
    private var retry: Timer?

    func start() {
        wanted = true
        refreshSamplerContext()
        sampler.onEvents = { [weak self] evs in MainActor.assumeIsolated { evs.forEach { self?.deliver($0) } } }   // 메인 큐에서 불린다
        connect()
        if allTraffic { sampler.start() }
    }

    func stop() {
        wanted = false
        retry?.invalidate(); retry = nil
        sampler.stop()
        goLive()
        disconnect()
    }

    /// 상태가 바뀔 때마다 표본 수집기에 출구·규칙 주소 사본을 넘긴다.
    func refreshSamplerContext() {
        let st = statusProvider()
        sampler.setContext(exits: st?.exits ?? [], managed: Set(st?.rules.flatMap { $0.addresses.map(\.ip) } ?? []))
    }

    func setAllTraffic(_ on: Bool) {
        allTraffic = on
        UserDefaults.standard.set(on, forKey: "routesAllTraffic")
        if on && wanted { sampler.start() } else { sampler.stop() }
    }

    /// 사건 하나를 기록하고, 실시간이면 바로 그린다.
    func deliver(_ e: ConnEvent) {
        // 개발용: defaults write com.miel.WifiExit routesDebugLog -bool true 면 받은 사건을 파일에 남긴다
        if UserDefaults.standard.bool(forKey: "routesDebugLog"), var d = try? JSONEncoder().encode(e) {
            d.removeLast()                                          // 마지막 } 를 떼고 칸 이름을 붙인다
            let groups = scene.outsideGroups.map { "\"\($0)\"" }.joined(separator: ",")
            d.append(contentsOf: Array(",\"slot\":\"\(scene.slot(for: e))\",\"groups\":[\(groups)]}".utf8))
            d.append(0x0a)
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("wifi-exit-routes.jsonl")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: url) }
        }
        // 패킷이 오가는 사건(traffic)은 그림에만 쓰고 기록하지 않는다 (너무 많아서)
        if e.kind != "traffic" {
            history.append(e)
            let cut = Int((Date().timeIntervalSince1970 - Self.keep) * 1000)
            if let i = history.firstIndex(where: { $0.t >= cut }), i > 0 { history.removeFirst(i) }
            historyStamp &+= 1
        }
        if e.kind == nil {
            recent.insert(e, at: 0)
            if recent.count > 200 { recent.removeLast(recent.count - 200) }
        }
        if e.outside == true, e.kind == nil { names?.lookup(e.dst) }
        if !replaying {
            scene.ingest(e)
            animating = true
            if e.kind != "traffic" { flowStamp &+= 1 }
        }
    }

    /// from(ms) 부터 기록을 speed 배로 다시 흘린다. 그동안 새 사건은 기록만 한다.
    func replay(from: Int, speed: Double) {
        replayTask?.cancel()
        let events = history.filter { $0.t >= from }
        guard !events.isEmpty else { return }
        replaying = true
        replayCursor = from
        scene.caps.removeAll()
        scene.saveLiveFlows()
        replayTask = Task { [weak self] in
            var prev = from
            for e in events {
                let wait = Double(e.t - prev) / speed
                prev = e.t
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 5000) * 1_000_000)) }
                if Task.isCancelled { return }
                guard let self else { return }
                self.replayCursor = e.t
                self.scene.ingest(e, replay: true)
                self.animating = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.goLive()
        }
    }

    func goLive() {
        replayTask?.cancel(); replayTask = nil
        if replaying { scene.restoreLiveFlows(); flowStamp &+= 1 }
        replaying = false
        replayCursor = nil
    }

    private func connect() {
        guard wanted, fd < 0 else { return }
        guard FileManager.default.fileExists(atPath: Paths.eventsSock) else {
            problem = "엔진이 연결 사건을 내보내지 않아요. 엔진을 갱신해 주세요."
            scheduleRetry(); return
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Paths.eventsSock.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else {
            problem = errno == EACCES ? "사건 소켓에 붙을 권한이 없어요 (admin 그룹만)" : "엔진에 붙지 못했어요. 다시 시도하는 중…"
            close(s); scheduleRetry(); return
        }
        fd = s
        connected = true; problem = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(s, &chunk, chunk.count)
            let data = n > 0 ? Data(chunk[0..<n]) : nil
            Task { @MainActor in self?.received(data) }
        }
        source.setCancelHandler { close(s) }
        source.resume()
        src = source
    }

    private func disconnect() {
        src?.cancel(); src = nil
        fd = -1
        connected = false
    }

    private func scheduleRetry() {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
    }

    private func received(_ data: Data?) {
        guard let data else {
            disconnect()
            if wanted { problem = "엔진과 연결이 끊겼어요. 다시 붙는 중…"; scheduleRetry() }
            return
        }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let e = try? JSONDecoder().decode(ConnEvent.self, from: line) else { continue }   // {"hello":1} 등
            deliver(e)
        }
    }

    /// 장면이 멈췄다고 알려 오면 다시 그리기를 쉰다 (다음 사건이 오면 다시 깬다).
    func sceneWentIdle() { if animating { animating = false } }
}

// MARK: - 장면 (그리기 상태)

/// 매 프레임 Canvas 가 읽고 갱신한다. SwiftUI 갱신을 일으키지 않도록 참조형으로 둔다.
final class RouteScene {
    struct Cap {
        var ev: ConnEvent
        var app: String
        var t0: Date
        var n = 1
        var replay = false
        var pos = CGPoint.zero
        var flashed = false
        var slot = ""                    // 지나갈 규칙 칸: 규칙 id, 또는 규칙 밖이면 "~<도메인|IP>"
        var dir = 0                      // 0 = 막힌 연결(규칙까지 가서 부서짐), 1 = 나가는 패킷, -1 = 들어오는 패킷
        var info = ""                    // 마우스를 올렸을 때 덧붙일 말 ("나감 3패킷 · 4.1KB")
    }

    /// 수립된 연결 하나. 같은 (앱, 칸, 출구)의 연결들은 길 하나를 같이 쓴다.
    struct Flow {
        var key: String
        var app: String
        var slot: String
        var iface: String
        var ev: ConnEvent
        var opened: Date
        var closedAt: Date?
        var bundle: String { "\(app)|\(slot)|\(iface)" }
    }
    struct Spark { var p: CGPoint; var v: CGVector; var life: Double; var r: CGFloat }

    var caps: [Cap] = []
    var flows: [String: Flow] = [:]                                       // 연결 열쇠 → 연결
    var bundleOpened: [String: Date] = [:]                                // 길이 처음 생긴 때 (그려지는 애니메이션)
    var bundleHeat: [String: Double] = [:]                                // 패킷이 지나가면 길이 잠깐 밝아진다
    private var pending: [String: (out: Int, inn: Int, bout: Int, bin: Int, sample: Flow)] = [:]   // 이번 프레임에 모은 패킷
    private var savedFlows: [String: Flow]?
    var onFlowsChanged: (() -> Void)?
    static let flowDuration = 0.9             // 패킷 캡슐이 길 끝까지 가는 시간
    static let openDuration = 0.5             // 길이 그려지는 시간
    static let closeFade = 0.8

    /// 같은 (앱, 칸, 출구)를 쓰는 연결들 → 길 하나
    var bundles: [String: [Flow]] { Dictionary(grouping: flows.values, by: \.bundle) }

    func saveLiveFlows() { savedFlows = flows; flows.removeAll(); pending.removeAll() }
    func restoreLiveFlows() { if let s = savedFlows { flows = s }; savedFlows = nil; pending.removeAll() }

    /// 패킷 수 → 보낼 캡슐 수. 한 개라도 있으면 1개, 많아도 4개까지 (로그 눈금).
    static func sample(_ n: Int) -> Int { n <= 0 ? 0 : min(4, 1 + Int(log2(Double(n)))) }

    static func bytesText(_ b: Int) -> String { b >= 1_048_576 ? String(format: "%.1fMB", Double(b) / 1_048_576) : b >= 1024 ? String(format: "%.1fKB", Double(b) / 1024) : "\(b)B" }
    var sparks: [Spark] = []
    var heat: [String: Double] = [:]          // "r:<규칙>" / "a:<앱>|<규칙>" → 0…1.5
    var hits: [(Date, String)] = []           // 최근 60초 지나간 것 (규칙·출구 숫자)
    var apps: [String] = []                   // 왼쪽 기둥 (최근에 본 순서, 최대 7)
    var appSeen: [String: Date] = [:]
    var flash: [String: Double] = [:]         // 규칙 칸 반짝임
    var paused = false
    var reduceMotion = false
    var lastStep = Date()
    var onIdle: (() -> Void)?
    var icons: [String: NSImage] = [:]                                   // 앱 → 아이콘
    // 규칙 밖 연결은 목적지 도메인(역방향 조회 이름의 등록 도메인, 없으면 IP)마다 칸을 따로 둔다
    var outsideGroups: [String] = []                                     // "~amazonaws.com", "~1.0.0.1" … (최대 8)
    var groupSeen: [String: Date] = [:]
    var groupLatest: [String: String] = [:]                              // 칸 밑에 보여 줄 최근 호스트
    var groupIPs: [String: [String]] = [:]                               // 그 칸으로 간 IP 들 (규칙 만들기용)
    var groupExits: [String: Set<String>] = [:]                          // 그 칸이 실제로 쓴 출구들 (옅은 전선을 계속 그린다)
    var nameFor: (String) -> String? = { _ in nil }
    var zoom: Zoom?                                                      // 하나만 보기
    static let maxGroups = 8
    static let multiPartTLD: Set<String> = ["co.kr", "or.kr", "go.kr", "ac.kr", "ne.kr", "re.kr", "pe.kr", "co.jp", "ne.jp", "or.jp", "ac.jp",
                                            "co.uk", "org.uk", "ac.uk", "com.au", "net.au", "com.cn", "net.cn", "com.tw", "com.hk", "com.sg", "co.in", "com.br"]

    /// 호스트 이름 → 사람이 알아보는 등록 도메인 (nrt12s45-in-f14.1e100.net → 1e100.net)
    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host.lowercased() }
        let last2 = labels.suffix(2).joined(separator: ".")
        return multiPartTLD.contains(last2) ? labels.suffix(3).joined(separator: ".") : last2
    }

    /// 이름이 늦게 오면 그 IP 의 칸을 도메인 칸으로 옮긴다 (같은 목적지가 두 칸에 나뉘지 않게).
    func nameArrived(ip: String, name: String) {
        let from = "~" + ip, to = "~" + Self.registrable(name)
        guard from != to, let i = outsideGroups.firstIndex(of: from) else { return }
        if outsideGroups.contains(to) { outsideGroups.remove(at: i) } else { outsideGroups[i] = to }
        groupSeen[to] = max(groupSeen[to] ?? .distantPast, groupSeen[from] ?? .distantPast)
        groupLatest[to] = name
        groupIPs[to] = Array(Set((groupIPs[to] ?? []) + (groupIPs[from] ?? [])))
        groupSeen[from] = nil
        groupLatest[from] = nil; groupIPs[from] = nil
        groupExits[to, default: []].formUnion(groupExits[from] ?? [])
        groupExits[from] = nil
        for c in caps.indices where caps[c].slot == from { caps[c].slot = to }
        for (k, v) in heat where k.hasPrefix("o:\(from)|") { heat[k] = nil; heat["o:\(to)|" + k.split(separator: "|").last!] = v }
        for (k, v) in flash where k == "r:\(from)" { flash[k] = nil; flash["r:\(to)"] = v }
        hits = hits.map { $0.1 == "r:\(from)" ? ($0.0, "r:\(to)") : $0 }
    }

    /// 사건이 지나갈 칸
    func slot(for e: ConnEvent) -> String {
        guard e.outside == true else { return e.rule ?? "?" }
        return "~" + (nameFor(e.dst).map(Self.registrable) ?? e.dst)
    }
    var morphs: [String: (from: String, to: String, t0: Date)] = [:]     // 규칙 → 전선이 옮겨 가는 중 (출구 키)
    var notes: [String: (text: String, t0: Date)] = [:]                  // 규칙 옆에 잠깐 뜨는 "Wi-Fi → VPN"
    static let morphDuration = 0.9
    static let noteDuration = 2.8

    var idle: Bool {
        caps.isEmpty && sparks.isEmpty && heat.isEmpty && flash.isEmpty && morphs.isEmpty && notes.isEmpty && bundleHeat.isEmpty && pending.isEmpty
            && !flows.values.contains { $0.closedAt != nil }
            && !bundleOpened.values.contains { Date().timeIntervalSince($0) < Self.openDuration }
    }

    static let duration = 1.25                // 앱 → 규칙 0.5, 규칙 → 출구 0.75
    static let maxCaps = 150

    static func appLabel(_ e: ConnEvent) -> String {
        if let a = e.app, !a.isEmpty { return a }
        if let u = e.uid, let pw = getpwuid(uid_t(u)) { return "(\(String(cString: pw.pointee.pw_name)))" }
        return "(알 수 없음)"
    }

    func ingest(_ e: ConnEvent, replay: Bool = false) {
        if e.kind == "traffic" { traffic(e); return }
        if e.kind == "close" { close(e); return }
        let app = Self.appLabel(e)
        appSeen[app] = Date()
        if icons[app] == nil, let exe = e.exe, FileManager.default.fileExists(atPath: exe) {
            let img = NSWorkspace.shared.icon(forFile: exe)
            img.size = NSSize(width: 32, height: 32)
            icons[app] = img
        }
        if !apps.contains(app) {
            if apps.count >= 7, let oldest = apps.min(by: { (appSeen[$0] ?? .distantPast) < (appSeen[$1] ?? .distantPast) }) {
                apps.removeAll { $0 == oldest }
            }
            apps.append(app)
        }
        let slot = slot(for: e)
        if e.outside == true {
            groupSeen[slot] = Date()
            groupLatest[slot] = nameFor(e.dst) ?? e.dst
            var ips = groupIPs[slot] ?? []
            if !ips.contains(e.dst) { ips.append(e.dst); if ips.count > 20 { ips.removeFirst() } }
            groupIPs[slot] = ips
            if !outsideGroups.contains(slot) {
                if outsideGroups.count >= Self.maxGroups,
                   let oldest = outsideGroups.min(by: { (groupSeen[$0] ?? .distantPast) < (groupSeen[$1] ?? .distantPast) }) {
                    outsideGroups.removeAll { $0 == oldest }
                    groupExits[oldest] = nil
                }
                outsideGroups.append(slot)
            }
        }
        // 수립된 연결 = 길을 만든다 (캡슐은 패킷이 오갈 때)
        if e.act == "pass" {
            if flows[e.flowKey]?.closedAt != nil { return }      // 이미 닫힌 연결에 늦게 온 열림
            let f = Flow(key: e.flowKey, app: app, slot: slot, iface: e.iface, ev: e, opened: Date(), closedAt: nil)
            if !flows.values.contains(where: { $0.bundle == f.bundle && $0.closedAt == nil }) { bundleOpened[f.bundle] = Date() }
            flows[e.flowKey] = f
            var c = Cap(ev: e, app: app, t0: Date()); c.slot = slot
            land(c)                                    // 숫자·전선 밝기
            flash["r:\(slot)"] = 1
            return
        }
        guard !paused else { return }
        if let z = zoom, !z.matches(e, app: app, slot: slot) { return }
        if reduceMotion { var c = Cap(ev: e, app: app, t0: Date()); c.slot = slot; land(c); return }
        // 1초 안의 같은 흐름은 묶는다
        if let i = caps.firstIndex(where: { $0.app == app && $0.ev.dst == e.dst && $0.ev.act == e.act && $0.ev.iface == e.iface
                                            && Date().timeIntervalSince($0.t0) < 0.45 }) {
            caps[i].n += 1; return
        }
        if caps.count >= Self.maxCaps { caps.removeFirst() }
        var cap = Cap(ev: e, app: app, t0: Date(), replay: replay)
        cap.slot = slot
        caps.append(cap)
    }

    /// 패킷이 오갔다: 이번 프레임 동안 같은 길·방향끼리 모았다가 step 에서 캡슐로 보낸다.
    func traffic(_ e: ConnEvent) {
        var f = flows[e.flowKey]
        if f == nil {
            // 열림을 못 본 연결(창을 연 직후 등): 길만 만들어 둔다
            let nf = Flow(key: e.flowKey, app: Self.appLabel(e), slot: slot(for: e), iface: e.iface, ev: e, opened: Date(), closedAt: nil)
            flows[e.flowKey] = nf
            bundleOpened[nf.bundle] = Date()
            f = nf
        }
        // 닫힌 뒤 오가는 마무리 패킷(FIN·ACK)은 캡슐로 보내지 않는다: 길이 이미 흐려지는 중이라
        guard let flow = f, flow.closedAt == nil, !paused else { return }
        if let z = zoom, !z.matches(flow.ev, app: flow.app, slot: flow.slot) { return }
        var p = pending[flow.bundle] ?? (0, 0, 0, 0, flow)
        p.out += e.pout ?? 0; p.inn += e.pin ?? 0; p.bout += e.bout ?? 0; p.bin += e.bin ?? 0
        pending[flow.bundle] = p
    }

    func close(_ e: ConnEvent) {
        guard flows[e.flowKey] != nil else { return }
        flows[e.flowKey]?.closedAt = Date()
    }

    private func flushTraffic(_ now: Date) {
        for (b, p) in pending {
            bundleHeat[b] = min(1.5, (bundleHeat[b] ?? 0) + 0.5)
            if reduceMotion { continue }
            for (dir, n, bytes) in [(1, p.out, p.bout), (-1, p.inn, p.bin)] where n > 0 {
                let k = Self.sample(n)
                for i in 0..<k {
                    if caps.count >= Self.maxCaps { caps.removeFirst() }
                    var c = Cap(ev: p.sample.ev, app: p.sample.app, t0: now.addingTimeInterval(Double(i) * 0.11))
                    c.slot = p.sample.slot; c.dir = dir; c.flashed = true
                    c.info = "\(dir > 0 ? "나감" : "들어옴") \(n)패킷 · \(Self.bytesText(bytes))"
                    caps.append(c)
                }
            }
        }
        pending.removeAll()
    }

    /// 캡슐이 끝에 닿았을 때: 전선을 데우고, 숫자를 세고, 막혔으면 파편을 튀긴다.
    func land(_ c: Cap, at: CGPoint? = nil) {
        let rule = c.slot.isEmpty ? (c.ev.rule ?? "?") : c.slot
        if c.ev.outside == true {
            let k = "o:\(rule)|\(c.ev.iface)"
            heat[k] = min(1.5, (heat[k] ?? 0) + 0.5)
            groupExits[rule, default: []].insert(c.ev.iface)
        }
        heat["r:\(rule)"] = min(1.5, (heat["r:\(rule)"] ?? 0) + 0.5)
        heat["a:\(c.app)|\(rule)"] = min(1.5, (heat["a:\(c.app)|\(rule)"] ?? 0) + 0.6)
        let now = Date()
        hits.append((now, "r:\(rule)"))
        hits.append((now, c.ev.act == "block" ? "x:block" : "x:\(c.ev.iface)"))
        if c.ev.act == "block", let p = at, !reduceMotion {
            for _ in 0..<10 {
                let ang = Double.random(in: 0.55 ... 1.45) * .pi
                let sp = Double.random(in: 40...110)
                sparks.append(Spark(p: p, v: CGVector(dx: cos(ang) * sp, dy: sin(ang) * sp), life: 1, r: .random(in: 1.4...3.2)))
            }
        }
    }

    func step(now: Date, endpoints: (Cap) -> (CGPoint, CGPoint, CGPoint)?) {
        let dt = min(0.05, now.timeIntervalSince(lastStep))
        lastStep = now
        if paused { return }
        flushTraffic(now)
        var keep: [Cap] = []
        for var c in caps {
            if c.dir != 0 {                                   // 패킷 캡슐: 길 끝에 닿으면 사라진다
                if now.timeIntervalSince(c.t0) < Self.flowDuration { keep.append(c) }
                continue
            }
            let k = now.timeIntervalSince(c.t0) / Self.duration
            if k >= 1 {
                land(c, at: endpoints(c)?.2)
                continue
            }
            if k >= 0.4, !c.flashed { flash["r:\(c.slot)"] = 1; c.flashed = true }   // 규칙에서 결정되는 순간
            keep.append(c)
        }
        caps = keep
        sparks = sparks.compactMap { s in
            var s = s
            s.p.x += s.v.dx * dt; s.p.y += s.v.dy * dt; s.life -= dt * 1.8
            return s.life > 0 ? s : nil
        }
        for (k, v) in heat { let n = v - dt * 0.35; heat[k] = n > 0 ? n : nil }
        for (k, v) in bundleHeat { let n = v - dt * 0.8; bundleHeat[k] = n > 0 ? n : nil }
        // 닫힌 연결은 흐려진 뒤 지운다
        let gone = flows.filter { $0.value.closedAt.map { now.timeIntervalSince($0) > Self.closeFade } ?? false }
        if !gone.isEmpty {
            for k in gone.keys { flows[k] = nil }
            let live = Set(flows.values.map(\.bundle))
            bundleOpened = bundleOpened.filter { live.contains($0.key) }
            DispatchQueue.main.async { [weak self] in self?.onFlowsChanged?() }
        }
        for (k, v) in flash { let n = v - dt * 2.5; flash[k] = n > 0 ? n : nil }
        hits.removeAll { now.timeIntervalSince($0.0) > 60 }
        morphs = morphs.filter { now.timeIntervalSince($0.value.t0) < Self.morphDuration }
        notes = notes.filter { now.timeIntervalSince($0.value.t0) < Self.noteDuration }
        if idle { DispatchQueue.main.async { [weak self] in self?.onIdle?() } }
    }

    func count(_ key: String) -> Int { hits.filter { $0.1 == key }.count }
}

// MARK: - 집중 보기

/// 하나만 골라 그것과 이어진 연결만 보는 상태
enum Zoom: Equatable {
    case app(String)          // 앱 이름
    case rule(String)         // 규칙 id 또는 규칙 밖 칸 "~도메인"
    case exit(String)         // 출구 인터페이스, 또는 "block"(차단 벽)

    /// 이 사건이 이 집중 대상과 이어져 있는지 (slot = 사건이 지나간 칸)
    func matches(_ e: ConnEvent, app: String, slot: String) -> Bool {
        switch self {
        case .app(let a): return app == a
        case .rule(let r): return slot == r
        case .exit(let x): return x == "block" ? e.act == "block" : e.iface == x
        }
    }
}

// MARK: - 배치


struct RouteLayout {
    var app: [String: CGPoint] = [:]
    var rule: [String: CGPoint] = [:]
    var exit: [String: CGPoint] = [:]       // 인터페이스 → 자리
    var wall = CGPoint.zero
    var ruleSize = CGSize(width: 200, height: 34)
    var nodeSize = CGSize(width: 150, height: 40)
    var appSize = CGSize(width: 130, height: 30)

    init(size: CGSize, apps: [String], rules: [RuleStatus], exits: [ExitInfo], outside: [String]) {
        let top: CGFloat = 34, bottom = size.height - 14
        func ys(_ n: Int) -> [CGFloat] { (0..<max(n, 1)).map { top + (bottom - top) * (CGFloat($0) + 0.5) / CGFloat(max(n, 1)) } }
        let ax = max(80, size.width * 0.11), rx = size.width * 0.47, ex = size.width - max(90, size.width * 0.11)
        for (a, y) in zip(apps, ys(apps.count)) { app[a] = CGPoint(x: ax, y: y) }
        let slots = rules.count + outside.count
        let rh = min(34, (bottom - top) / CGFloat(max(slots, 1)) - 4)
        ruleSize = CGSize(width: min(220, size.width * 0.24), height: max(20, rh))
        let rys = ys(slots)
        for (r, y) in zip(rules, rys) { rule[r.id] = CGPoint(x: rx, y: y) }
        for (k, y) in zip(outside, rys.dropFirst(rules.count)) { rule[k] = CGPoint(x: rx, y: y) }
        let col = ys(exits.count + 1)
        for (e, y) in zip(exits, col) { exit[e.iface] = CGPoint(x: ex, y: y) }
        wall = CGPoint(x: ex, y: col.last ?? bottom)
        nodeSize = CGSize(width: min(160, size.width * 0.16), height: 40)
        appSize = CGSize(width: min(140, size.width * 0.15), height: 28)
    }
}

func cubic(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let mx = (b.x - a.x) * 0.5
    let p1 = CGPoint(x: a.x + mx, y: a.y), p2 = CGPoint(x: b.x - mx, y: b.y), u = 1 - t
    return CGPoint(x: u*u*u*a.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*b.x,
                   y: u*u*u*a.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*b.y)
}

func wirePath(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path()
    let mx = (b.x - a.x) * 0.5
    p.move(to: a)
    p.addCurve(to: b, control1: CGPoint(x: a.x + mx, y: a.y), control2: CGPoint(x: b.x - mx, y: b.y))
    return p
}

// MARK: - 창

struct RoutesWindow: View {
    @EnvironmentObject var m: AppModel
    @StateObject private var stream = EventStream()
    @StateObject private var names = HostNames()
    @State private var cursor: Double?            // 타임라인에서 고른 시각 (ms)
    @State private var speed = 4.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var paused = false
    @State private var hover: (RouteScene.Cap, CGPoint)?
    @State private var focusRule: String?
    @State private var focusExit: String?
    @State private var zoom: Zoom?                // 하나만 보기 (더블클릭 또는 머리의 "보기" 메뉴)
    @State private var lastTargets: [String: String] = [:]

    private let stage = Color(red: 0.05, green: 0.067, blue: 0.09)
    private let panel = Color(red: 0.083, green: 0.106, blue: 0.141)
    private let lineC = Color(red: 0.145, green: 0.188, blue: 0.255)
    private let fg = Color(red: 0.875, green: 0.902, blue: 0.937)
    private let muted = Color(red: 0.5, green: 0.545, blue: 0.627)

    private var allRules: [RuleStatus] { (m.status?.rules ?? []).filter(\.enabled) }

    /// 집중 보기일 때: 최근 10분 기록 중 그 대상과 이어진 사건들
    private var zoomEvents: [ConnEvent]? {
        guard let z = zoom else { return nil }
        let sc = stream.scene
        return stream.history.filter { $0.kind == nil && z.matches($0, app: RouteScene.appLabel($0), slot: sc.slot(for: $0)) }
    }
    private var rules: [RuleStatus] {
        guard let z = zoom, let evs = zoomEvents else { return allRules }
        if case .rule(let r) = z { return allRules.filter { $0.id == r } }
        let slots = Set(evs.map { stream.scene.slot(for: $0) })
        // 출구를 볼 때는 지금 그 출구를 쓰는 규칙도 보여 준다
        return allRules.filter { r in
            slots.contains(r.id) || { if case .exit(let x) = z { return r.chosenIface == x || (x == "block" && r.decision == "block") }; return false }()
        }
    }
    private var visibleGroups: [String] {
        guard let z = zoom, let evs = zoomEvents else { return stream.scene.outsideGroups }
        if case .rule(let r) = z { return stream.scene.outsideGroups.filter { $0 == r } }
        let slots = Set(evs.map { stream.scene.slot(for: $0) })
        return stream.scene.outsideGroups.filter { slots.contains($0) }
    }
    private var visibleApps: [String] {
        guard let z = zoom, let evs = zoomEvents else { return stream.scene.apps }
        if case .app(let a) = z { return [a] }
        var seen: [String] = []
        for e in evs.reversed() { let a = RouteScene.appLabel(e); if !seen.contains(a) { seen.append(a) } }
        return Array(seen.prefix(7))
    }
    private var visibleExits: [ExitInfo] {
        guard case .exit(let x)? = zoom else { return exits }
        return exits.filter { $0.iface == x }          // 차단 벽만 볼 때는 출구 칸 없이 벽만
    }
    /// 보기 메뉴의 앱 목록: 최근 10분에 본 앱
    private var knownApps: [String] {
        var seen: [String] = []
        for e in stream.history.reversed() where e.kind == nil {
            let a = RouteScene.appLabel(e)
            if !seen.contains(a) { seen.append(a) }
        }
        return seen
    }
    private func zoomLabel(_ z: Zoom) -> String {
        switch z {
        case .app(let a): return a
        case .rule(let r):
            if r.hasPrefix("~") { return "(규칙 없음) \(r.dropFirst())" }
            let i = (m.status?.rules.firstIndex { $0.id == r }).map { $0 + 1 } ?? 0
            return "#\(i) \(m.status?.rules.first { $0.id == r }?.title ?? r)"
        case .exit(let x): return x == "block" ? "차단된 연결" : "\(exits.first { $0.iface == x }?.label ?? x)(\(x))"
        }
    }
    private func setZoom(_ z: Zoom?) {
        zoom = z
        focusRule = nil; focusExit = nil
        let sc = stream.scene
        sc.zoom = z
        if let z { sc.caps.removeAll { !z.matches($0.ev, app: $0.app, slot: $0.slot) } }
        stream.animating = true
    }
    private var exits: [ExitInfo] { m.status?.exits ?? [] }
    /// 규칙 칸과 규칙 밖 칸이 많으면 그림을 세로로 늘리고 스크롤한다 (칸 하나에 30pt)
    private var stageNeeded: CGFloat { CGFloat(56 + (rules.count + visibleGroups.count) * 30) }

    /// 규칙마다 지금 전선이 가는 곳: 출구 인터페이스 / "block" / "none"
    private func targetKey(_ r: RuleStatus) -> String {
        r.decision == "route" ? (r.chosenIface ?? "none") : r.decision == "block" ? "block" : "none"
    }
    private var targetSignature: [String: String] { Dictionary(uniqueKeysWithValues: rules.map { ($0.id, targetKey($0)) }) }
    private func targetLabel(_ key: String) -> String {
        switch key {
        case "block": return "차단"
        case "none": return "적용 안 함"
        default: return exits.first { $0.iface == key }.map { "\($0.label)(\(key))" } ?? key
        }
    }

    /// 출구가 바뀐 규칙은 전선이 옮겨 가는 모습을 보여 준다 (상태 점검 전환, 네트워크 변화 등)
    private func targetsChanged(_ now: [String: String]) {
        let scene = stream.scene
        for (id, to) in now {
            guard let from = lastTargets[id], from != to else { continue }
            scene.morphs[id] = (from, to, Date())
            scene.notes[id] = ("\(targetLabel(from)) → \(targetLabel(to))", Date())
            stream.animating = true
        }
        lastTargets = now
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
              let stageH = max(geo.size.height, stageNeeded)
              ScrollView(.vertical) {
                ZStack {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || !stream.animating)) { tl in
                        Canvas { ctx, size in drawBack(&ctx, size: size, now: tl.date) }
                    }
                    Canvas { ctx, size in drawNodes(&ctx, size: size) }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || !stream.animating)) { tl in
                        Canvas { ctx, size in drawFront(&ctx, size: size, now: tl.date) }
                    }
                }
                .background(stage)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = nearestCap(p).map { ($0, p) }
                    case .ended: hover = nil
                    }
                }
                .onTapGesture(count: 2, coordinateSpace: .local) { p in doubleTap(p, size: CGSize(width: geo.size.width, height: stageH)) }
                .onTapGesture(coordinateSpace: .local) { p in tap(p, size: CGSize(width: geo.size.width, height: stageH)) }
                .overlay(alignment: .topLeading) { tooltip(width: geo.size.width) }
                .frame(width: geo.size.width, height: stageH)
              }
              .scrollDisabled(stageH <= geo.size.height)
            }
            .frame(minHeight: 420)
            Divider()
            timeline
            recentList
        }
        .background(stage)
        .frame(minWidth: 880, minHeight: 640)
        .onAppear {
            stream.names = names
            let nm = names
            stream.scene.nameFor = { [weak nm] ip in MainActor.assumeIsolated { nm?.name(ip) } }
            let sc = stream.scene, st2 = stream
            names.onResolved = { [weak st2] ip, name in sc.nameArrived(ip: ip, name: name); st2?.animating = true }
            sc.onFlowsChanged = { [weak st2] in st2?.flowStamp &+= 1 }
            let model = m
            stream.statusProvider = { [weak model] in model?.status }
            stream.scene.reduceMotion = reduceMotion
            let st = stream
            stream.scene.onIdle = { [weak st] in st?.sceneWentIdle() }
            stream.start()
        }
        .onDisappear { stream.stop() }      // 창을 닫으면 엔진이 pf 기록을 끈다
        .onChange(of: paused) { stream.scene.paused = paused }
        .onChange(of: targetSignature) { _, now in targetsChanged(now) }
        .onChange(of: m.status?.generatedAt) { stream.refreshSamplerContext() }
        .onAppear { lastTargets = targetSignature }
        .navigationTitle("라우팅 보기")
    }

    /// 규칙 밖 칸에서 새 규칙 초안을 만든다 (그 칸으로 간 IPv4 들, 메모는 도메인).
    private func makeRule(from key: String) {
        var d = RuleDraft(nil)
        d.targets = (stream.scene.groupIPs[key] ?? []).compactMap { Target.parse($0)?.0 }.prefix(10).map { $0 }
        d.name = String(key.dropFirst())
        m.drafts["new"] = d
        m.windowSelection = "new"
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "rules")
    }

    // MARK: 머리

    private var header: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
            Circle().fill(stream.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(stream.replaying ? "되감기 중 · \(stream.replayCursor.map(timeString) ?? "")"
                 : stream.connected ? "보는 중 · 최근 1분 \(stream.scene.hits.filter { $0.1.hasPrefix("x:") }.count)건"
                                    : (stream.problem ?? "엔진에 붙는 중…"))
                .font(.callout).foregroundStyle(stream.replaying ? Color.orange : fg)
            Spacer()
            Menu {
                Button("전체") { setZoom(nil) }
                Section("앱") { ForEach(knownApps, id: \.self) { a in Button(a) { setZoom(.app(a)) } } }
                Section("규칙") {
                    ForEach(allRules) { r in Button(zoomLabel(.rule(r.id))) { setZoom(.rule(r.id)) } }
                    ForEach(stream.scene.outsideGroups, id: \.self) { g in Button(zoomLabel(.rule(g))) { setZoom(.rule(g)) } }
                }
                Section("출구") {
                    ForEach(exits, id: \.iface) { e in Button(zoomLabel(.exit(e.iface))) { setZoom(.exit(e.iface)) } }
                    Button("차단된 연결") { setZoom(.exit("block")) }
                }
            } label: {
                Label(zoom.map { "보기: \(zoomLabel($0))" } ?? "보기: 전체", systemImage: zoom == nil ? "square.stack.3d.up" : "scope")
            }
            .fixedSize()
            .help("앱·규칙·출구 하나만 골라 그것과 이어진 연결만 봐요. 칸을 두 번 눌러도 돼요.")
            Picker("", selection: Binding(get: { stream.allTraffic }, set: { stream.setAllTraffic($0) })) {
                Text("규칙 대상만").tag(false)
                Text("전체").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("전체: 규칙에 없는 연결도 (규칙 없음) 칸으로 보여 줘요. 연결 표를 1초마다 훑어서, 아주 짧은 연결은 놓칠 수 있어요.")
            if let f = focusRule, f.hasPrefix("~") {
                Button { makeRule(from: f) } label: { Label("이 목적지로 규칙 만들기", systemImage: "plus.circle") }
                    .help("이 칸으로 간 IP들로 새 규칙을 편집 창에 채워 둬요. 역방향 조회 이름은 실제 도메인과 다를 수 있어 IP로 넣어요.")
            }
            if focusRule != nil || focusExit != nil {
                Button("강조 해제") { focusRule = nil; focusExit = nil }
            }
            Toggle(isOn: $paused) { Label("일시정지", systemImage: "pause.fill") }.toggleStyle(.button)
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "rules") } label: { Label("규칙 편집", systemImage: "list.bullet.rectangle") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        if let z = zoom {
            HStack(spacing: 8) {
                if case .app(let a) = z, let icon = stream.scene.icons[a] { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                else { Image(systemName: "scope").foregroundStyle(fg) }
                Text("\(zoomLabel(z))만 보는 중").font(.callout.bold()).foregroundStyle(fg)
                Text(zoomHint(z)).font(.caption).foregroundStyle(muted)
                Spacer()
                Button("전체로") { setZoom(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.18))
        }
      }
      .background(panel)
      .environment(\.colorScheme, .dark)
    }

    private func zoomHint(_ z: Zoom) -> String {
        switch z {
        case .app: return "이 앱이 최근 10분에 쓴 규칙·목적지·출구만 보여요"
        case .rule: return "이 칸을 지난 연결과 그 앱들만 보여요"
        case .exit(let x): return x == "block" ? "막힌 연결과 그 앱·규칙만 보여요" : "이 출구로 나갔거나 나가려다 막힌 연결만 보여요"
        }
    }

    // MARK: 그리기

    private func layout(_ size: CGSize) -> RouteLayout {
        RouteLayout(size: size, apps: visibleApps, rules: rules, exits: visibleExits, outside: visibleGroups)
    }

    /// 길의 네 점: 앱 오른쪽, 규칙 왼쪽·오른쪽, 출구 왼쪽
    private func bundlePoints(app: String, slot: String, iface: String, _ L: RouteLayout) -> (CGPoint, CGPoint, CGPoint, CGPoint)? {
        guard let a = L.app[app], let r = L.rule[slot], let e = L.exit[iface] else { return nil }
        return (CGPoint(x: a.x + L.appSize.width / 2, y: a.y), CGPoint(x: r.x - L.ruleSize.width / 2, y: r.y),
                CGPoint(x: r.x + L.ruleSize.width / 2, y: r.y), CGPoint(x: e.x - L.nodeSize.width / 2, y: e.y))
    }

    private func bundlePath(_ pts: (CGPoint, CGPoint, CGPoint, CGPoint)) -> Path {
        var p = wirePath(pts.0, pts.1)
        p.addLine(to: pts.2)
        p.addPath(wirePath(pts.2, pts.3))
        return p
    }

    /// 캡슐의 세 점: 앱, 규칙, 끝 (통과 = 출구, 막힘 = 나가려던 출구 앞 또는 차단 벽)
    private func endpoints(_ c: RouteScene.Cap, _ L: RouteLayout) -> (CGPoint, CGPoint, CGPoint)? {
        guard let a = L.app[c.app], let r = L.rule[c.slot] else { return nil }
        let half = L.nodeSize.width / 2
        if c.ev.act == "pass", let e = L.exit[c.ev.iface] { return (a, r, CGPoint(x: e.x - half, y: e.y)) }
        if c.ev.act == "block", let al = c.ev.allow, al != c.ev.iface, let e = L.exit[c.ev.iface] {
            return (a, r, CGPoint(x: e.x - half - 26, y: e.y))      // 나가려던 출구 바로 앞에서 부서진다
        }
        return (a, r, CGPoint(x: L.wall.x - half, y: L.wall.y))
    }

    private func exitColor(_ e: ExitInfo?) -> Color { e.map { Color.exit($0.name) } ?? muted }
    private let blockC = Color(red: 0.94, green: 0.39, blue: 0.44)

    private func dimmed(rule: String?, iface: String?) -> Bool {
        if let f = focusRule, f != rule { return true }
        if let f = focusExit, f != iface { return true }
        return false
    }

    /// 뒤 층 (매 프레임): 장면을 한 걸음 움직이고 전선을 그린다
    private func drawBack(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = layout(size)
        let scene = stream.scene
        scene.step(now: now) { endpoints($0, L) }
        // 전선: 규칙 → 지금 고른 출구. 출구가 바뀌었으면 옛 자리에서 새 자리로 휘어 옮겨 간다
        func endFor(_ key: String) -> CGPoint? {
            if key == "block" { return CGPoint(x: L.wall.x - L.nodeSize.width / 2, y: L.wall.y) }
            return L.exit[key].map { CGPoint(x: $0.x - L.nodeSize.width / 2, y: $0.y) }
        }
        func colorFor(_ key: String) -> Color { key == "block" ? blockC : exitColor(exits.first { $0.iface == key }) }
        for r in rules {
            guard let rp = L.rule[r.id] else { continue }
            let h = scene.heat["r:\(r.id)"] ?? 0
            let from = CGPoint(x: rp.x + L.ruleSize.width / 2, y: rp.y)
            let key = targetKey(r)
            let dim = dimmed(rule: r.id, iface: key == "none" ? nil : key)
            let stub = CGPoint(x: from.x + 36, y: from.y)       // 적용 안 함: 짧은 그루터기
            var end = endFor(key) ?? stub
            var col = key == "none" ? muted : colorFor(key)
            if let mo = scene.morphs[r.id] {
                let t = min(1, now.timeIntervalSince(mo.t0) / RouteScene.morphDuration)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2       // easeInOut
                let a = endFor(mo.from) ?? stub
                end = CGPoint(x: a.x + (end.x - a.x) * e, y: a.y + (end.y - a.y) * e)
                // 옛 전선이 흐려지며 남는다
                ctx.stroke(wirePath(from, a), with: .color(colorFor(mo.from).opacity(0.35 * (1 - t))), style: StrokeStyle(lineWidth: 1.4, dash: [4, 4]))
                col = col.opacity(0.4 + 0.6 * t)
                ctx.stroke(wirePath(from, end), with: .color(col.opacity(0.9)), lineWidth: 2.4)
                continue
            }
            if key == "none" {
                ctx.stroke(wirePath(from, stub), with: .color(muted.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                continue
            }
            ctx.stroke(wirePath(from, end), with: .color(col.opacity(dim ? 0.06 : 0.16 + h * 0.55)), lineWidth: 1.2 + min(4, h * 3))
        }
        // 전선: 규칙 밖 칸 → 실제로 쓴 출구 (평소 경로). 옅게 늘 그리고, 지나갈 때 밝아진다. 점선
        for key in visibleGroups {
            guard let op = L.rule[key] else { continue }
            let from = CGPoint(x: op.x + L.ruleSize.width / 2, y: op.y)
            for i in (scene.groupExits[key] ?? []).sorted() {
                guard let ep = L.exit[i] else { continue }
                let v = scene.heat["o:\(key)|\(i)"] ?? 0
                let c = exitColor(exits.first { $0.iface == i })
                ctx.stroke(wirePath(from, CGPoint(x: ep.x - L.nodeSize.width / 2, y: ep.y)),
                           with: .color(c.opacity(dimmed(rule: key, iface: i) ? 0.04 : 0.12 + v * 0.35)),
                           style: StrokeStyle(lineWidth: 1 + min(3, v * 2), dash: [5, 3]))
            }
        }
        // 길: 수립된 연결마다 (같은 앱·칸·출구는 하나). 생길 때 그려지고, 패킷이 지나가면 밝아지고, 닫히면 흐려진다
        for (b, fs) in scene.bundles {
            guard let f0 = fs.first, let pts = bundlePoints(app: f0.app, slot: f0.slot, iface: f0.iface, L) else { continue }
            let live = fs.filter { $0.closedAt == nil }
            var alpha = 1.0
            if live.isEmpty, let last = fs.compactMap(\.closedAt).max() { alpha = max(0, 1 - now.timeIntervalSince(last) / RouteScene.closeFade) }
            let grow = min(1, now.timeIntervalSince(scene.bundleOpened[b] ?? .distantPast) / RouteScene.openDuration)
            let h = scene.bundleHeat[b] ?? 0
            let col = exitColor(exits.first { $0.iface == f0.iface })
            let dim = dimmed(rule: f0.slot, iface: f0.iface)
            let path = bundlePath(pts).trimmedPath(from: 0, to: grow)
            let width = 1.4 + min(3, log2(Double(max(1, live.count)) + 1)) + h * 1.5
            ctx.stroke(path, with: .color(col.opacity((dim ? 0.08 : 0.32 + h * 0.4) * alpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: f0.ev.outside == true ? [6, 3] : []))
        }
        // 전선: 앱 → 규칙 (최근에 흐른 것만)
        for (k, v) in scene.heat where k.hasPrefix("a:") {
            let parts = k.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let ap = L.app[parts[0]], let rp = L.rule[parts[1]] else { continue }
            let from = CGPoint(x: ap.x + L.appSize.width / 2, y: ap.y), to = CGPoint(x: rp.x - L.ruleSize.width / 2, y: rp.y)
            ctx.stroke(wirePath(from, to), with: .color(fg.opacity(dimmed(rule: parts[1], iface: nil) ? 0.03 : 0.05 + v * 0.3)), lineWidth: 1 + v * 1.5)
        }

    }

    /// 가운데 층 (상태가 바뀔 때만): 칸과 글자. 매 프레임 글자를 다시 그리지 않아 CPU 를 아낀다
    private func drawNodes(_ ctx: inout GraphicsContext, size: CGSize) {
        let L = layout(size)
        let scene = stream.scene
        func label(_ s: String, _ p: CGPoint, _ c: Color, _ font: Font, anchor: UnitPoint = .center) {
            ctx.draw(Text(s).font(font).foregroundColor(c), at: p, anchor: anchor)
        }
        label("앱", CGPoint(x: L.app.values.first?.x ?? size.width * 0.11, y: 14), muted, .caption.bold())
        label("규칙 · 위에서부터", CGPoint(x: size.width * 0.47, y: 14), muted, .caption.bold())
        label("출구", CGPoint(x: L.wall.x, y: 14), muted, .caption.bold())

        // 규칙 밖 칸: 목적지 도메인(없으면 IP)마다 하나. 규칙에 없는 연결이 평소 경로로 나간다
        for key in visibleGroups {
            guard let p = L.rule[key] else { continue }
            let w = L.ruleSize.width, h = L.ruleSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            var c = ctx
            c.opacity = dimmed(rule: key, iface: nil) ? 0.35 : 1
            c.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(stage))
            c.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(focusRule == key ? fg : muted.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            c.draw(Text("규칙 없음").font(.system(size: 9, weight: .medium)).foregroundColor(muted.opacity(0.8)), at: CGPoint(x: rect.minX + 8, y: p.y), anchor: .leading)
            c.draw(Text(String(key.dropFirst())).font(.system(size: h < 26 ? 11 : 12, weight: .semibold, design: .monospaced)).foregroundColor(fg.opacity(0.85)),
                   at: CGPoint(x: rect.minX + 56, y: p.y - (h >= 30 ? 6 : 0)), anchor: .leading)
            if h >= 30, let latest = scene.groupLatest[key], latest != String(key.dropFirst()) {
                c.draw(Text(latest).font(.system(size: 9.5, design: .monospaced)).foregroundColor(muted),
                       at: CGPoint(x: rect.minX + 56, y: p.y + 8), anchor: .leading)
            }
            let n = scene.count("r:\(key)")
            if n > 0 { c.draw(Text("\(n)").font(.system(size: 10, design: .monospaced)).foregroundColor(muted), at: CGPoint(x: rect.maxX - 8, y: p.y), anchor: .trailing) }
        }

        // 길 양 끝의 포트: 앱 쪽은 출발 포트(여럿이면 개수), 출구 쪽은 목적지 포트
        for (_, fs) in scene.bundles {
            let live = fs.filter { $0.closedAt == nil }
            guard let f0 = live.first, let pts = bundlePoints(app: f0.app, slot: f0.slot, iface: f0.iface, L) else { continue }
            if dimmed(rule: f0.slot, iface: f0.iface) { continue }
            let left = live.count == 1 ? ":\(f0.ev.sport)" : "\(live.count)개 연결"
            let dports = Array(Set(live.map(\.ev.dport))).sorted().prefix(3).map { ":\($0)" }.joined(separator: " ")
            let font = Font.system(size: 9.5, weight: .medium, design: .monospaced)
            ctx.draw(Text(left).font(font).foregroundColor(muted), at: CGPoint(x: pts.0.x + 6, y: pts.0.y - 8), anchor: .leading)
            ctx.draw(Text(dports + " " + f0.ev.proto).font(font).foregroundColor(exitColor(exits.first { $0.iface == f0.iface }).opacity(0.85)),
                     at: CGPoint(x: pts.3.x - 6, y: pts.3.y - 9), anchor: .trailing)
        }

        // 앱 칸
        for a in visibleApps {
            guard let p = L.app[a] else { continue }
            let rect = CGRect(x: p.x - L.appSize.width / 2, y: p.y - L.appSize.height / 2, width: L.appSize.width, height: L.appSize.height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(panel))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(lineC), lineWidth: 1)
            if let icon = scene.icons[a] {
                ctx.draw(Image(nsImage: icon), in: CGRect(x: rect.minX + 6, y: p.y - 9, width: 18, height: 18))
                label(a, CGPoint(x: rect.minX + 30, y: p.y), fg, .system(size: 12, weight: .medium), anchor: .leading)
            } else {
                label(a, p, fg, .system(size: 12, weight: .medium))
            }
        }
        if visibleApps.isEmpty {
            label("연결을 기다리는 중", CGPoint(x: size.width * 0.11, y: size.height / 2), muted, .caption)
        }

        // 규칙 칸
        for (i, r) in rules.enumerated() {
            guard let p = L.rule[r.id] else { continue }
            let w = L.ruleSize.width, h = L.ruleSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            let dim = dimmed(rule: r.id, iface: r.chosenIface ?? "block")
            let col: Color = r.decision == "route" ? exitColor(exits.first { $0.iface == r.chosenIface }) : r.decision == "block" ? blockC : muted
            var c = ctx
            c.opacity = dim ? 0.35 : 1
            c.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(panel))
            c.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(focusRule == r.id ? col : lineC), lineWidth: focusRule == r.id ? 1.6 : 1)
            let pos = (m.status?.rules.firstIndex { $0.id == r.id } ?? i) + 1
            c.draw(Text("#\(pos)").font(.system(size: 10, design: .monospaced)).foregroundColor(muted), at: CGPoint(x: rect.minX + 8, y: p.y), anchor: .leading)
            c.draw(Text(r.title).font(.system(size: h < 26 ? 11 : 12, weight: .semibold)).foregroundColor(fg), at: CGPoint(x: rect.minX + 34, y: p.y - (h >= 30 ? 6 : 0)), anchor: .leading)
            if h >= 30 {
                c.draw(Text(r.targets.map(\.target).joined(separator: ", ")).font(.system(size: 9.5, design: .monospaced)).foregroundColor(muted),
                       at: CGPoint(x: rect.minX + 34, y: p.y + 8), anchor: .leading)
            }
            let n = scene.count("r:\(r.id)")
            if n > 0 { c.draw(Text("\(n)").font(.system(size: 10, design: .monospaced)).foregroundColor(muted), at: CGPoint(x: rect.maxX - 8, y: p.y), anchor: .trailing) }
            if r.decision == "skip" || r.decision == "system" || r.decision == "next" {
                c.draw(Text("적용 안 함").font(.system(size: 9)).foregroundColor(muted), at: CGPoint(x: rect.maxX + 6, y: p.y), anchor: .leading)
            }
        }

        // 출구 칸 + 차단 벽
        for e in visibleExits {
            guard let p = L.exit[e.iface] else { continue }
            let w = L.nodeSize.width, h = L.nodeSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            let col = exitColor(e)
            var c = ctx
            c.opacity = dimmed(rule: nil, iface: e.iface) ? 0.35 : 1
            let down = e.up && e.healthy == false
            c.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(e.up ? col.opacity(0.12) : stage))
            c.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(down ? Color.orange : col.opacity(e.up ? 0.9 : 0.5)),
                     style: StrokeStyle(lineWidth: 1.2, dash: e.up ? [] : [4, 4]))
            c.draw(Text(e.label).font(.system(size: 12.5, weight: .semibold)).foregroundColor(e.up ? col : muted), at: CGPoint(x: rect.minX + 10, y: p.y - 7), anchor: .leading)
            c.draw(Text(e.up ? (down ? "\(e.iface) · 응답 없음" : e.iface) : "\(e.iface) · 연결 안 됨").font(.system(size: 10, design: .monospaced)).foregroundColor(down ? .orange : muted),
                   at: CGPoint(x: rect.minX + 10, y: p.y + 9), anchor: .leading)
            let n = scene.count("x:\(e.iface)")
            if n > 0 { c.draw(Text("\(n)").font(.system(size: 10, design: .monospaced)).foregroundColor(muted), at: CGPoint(x: rect.maxX - 8, y: p.y - 7), anchor: .trailing) }
        }
        do {
            let w = L.nodeSize.width, h = L.nodeSize.height, p = L.wall
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            var c = ctx
            c.opacity = dimmed(rule: nil, iface: "block") ? 0.35 : 1
            c.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(blockC.opacity(0.1)))
            var hatch = Path()
            var x = rect.minX - h
            while x < rect.maxX { hatch.move(to: CGPoint(x: x, y: rect.maxY)); hatch.addLine(to: CGPoint(x: x + h, y: rect.minY)); x += 9 }
            c.clip(to: Path(roundedRect: rect, cornerRadius: 6))
            c.stroke(hatch, with: .color(blockC.opacity(0.22)), lineWidth: 1)
            c.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(blockC), lineWidth: 1.2)
            c.draw(Text("차단 (pf)").font(.system(size: 12.5, weight: .semibold)).foregroundColor(blockC), at: p)
            let n = scene.count("x:block")
            if n > 0 { c.draw(Text("\(n)").font(.system(size: 10, design: .monospaced)).foregroundColor(muted), at: CGPoint(x: rect.maxX - 8, y: rect.minY + 10), anchor: .trailing) }
        }

        if scene.reduceMotion {
            label("동작 줄이기가 켜져 있어 캡슐 대신 전선 밝기와 숫자로 보여 줘요", CGPoint(x: size.width / 2, y: size.height - 10), muted, .caption)
        }
    }

    /// 앞 층 (매 프레임): 규칙 칸 반짝임, 캡슐, 파편
    private func drawFront(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = layout(size)
        let scene = stream.scene
        // 출구가 바뀐 규칙 옆에 잠깐 "Wi-Fi(en0) → VPN:pass(utun4)"
        for (id, n) in scene.notes {
            guard let p = L.rule[id] else { continue }
            let t = now.timeIntervalSince(n.t0)
            let a = t < 0.25 ? t / 0.25 : max(0, min(1, (RouteScene.noteDuration - t) / 0.7))
            let r = rules.first { $0.id == id }
            let col: Color = r.map { targetKey($0) == "block" ? blockC : targetKey($0) == "none" ? muted : exitColor(exits.first { $0.iface == r?.chosenIface }) } ?? fg
            let text = ctx.resolve(Text(n.text).font(.system(size: 11, weight: .semibold)).foregroundColor(col))
            let sz = text.measure(in: CGSize(width: 400, height: 30))
            let at = CGPoint(x: p.x + L.ruleSize.width / 2 + 12, y: p.y - L.ruleSize.height / 2 - 4)
            var g = ctx
            g.opacity = a
            g.fill(Path(roundedRect: CGRect(x: at.x - 6, y: at.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6), cornerRadius: 6), with: .color(stage.opacity(0.92)))
            g.stroke(Path(roundedRect: CGRect(x: at.x - 6, y: at.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6), cornerRadius: 6), with: .color(col.opacity(0.7)), lineWidth: 1)
            g.draw(text, at: at, anchor: .leading)
        }
        for key in visibleGroups {
            guard let p = L.rule[key], let f = scene.flash["r:\(key)"], f > 0 else { continue }
            let rect = CGRect(x: p.x - L.ruleSize.width / 2, y: p.y - L.ruleSize.height / 2, width: L.ruleSize.width, height: L.ruleSize.height)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(fg.opacity(f * 0.6)), lineWidth: 1.2)
        }
        for r in rules {
            guard let p = L.rule[r.id], let f = scene.flash["r:\(r.id)"], f > 0 else { continue }
            let col: Color = r.decision == "route" ? exitColor(exits.first { $0.iface == r.chosenIface }) : r.decision == "block" ? blockC : muted
            let rect = CGRect(x: p.x - L.ruleSize.width / 2, y: p.y - L.ruleSize.height / 2, width: L.ruleSize.width, height: L.ruleSize.height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(col.opacity(f * 0.28)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(col.opacity(f)), lineWidth: 1.4)
        }
        // 캡슐
        for i in scene.caps.indices {
            let cap = scene.caps[i]
            if cap.dir != 0 {
                // 패킷: 길을 따라 나가거나(앱 → 출구) 들어온다(출구 → 앱)
                guard let pts = bundlePoints(app: cap.app, slot: cap.slot, iface: cap.ev.iface, L) else { continue }
                let el = now.timeIntervalSince(cap.t0)
                if el < 0 { scene.caps[i].pos = CGPoint(x: -100, y: -100); continue }   // 아직 출발 전 (차례로 보낸다)
                let t = min(1, el / RouteScene.flowDuration)
                let k = cap.dir > 0 ? t : 1 - t
                let p: CGPoint
                if k < 0.4 { p = cubic(pts.0, pts.1, k / 0.4) }
                else if k < 0.46 { p = CGPoint(x: pts.1.x + (pts.2.x - pts.1.x) * (k - 0.4) / 0.06, y: pts.1.y) }
                else { p = cubic(pts.2, pts.3, (k - 0.46) / 0.54) }
                scene.caps[i].pos = p
                let col = exitColor(exits.first { $0.iface == cap.ev.iface })
                let dim = dimmed(rule: cap.slot, iface: cap.ev.iface)
                var g = ctx
                g.opacity = dim ? 0.12 : (cap.ev.outside == true ? 0.7 : 1)
                if cap.dir > 0 {
                    if !dim { g.fill(Path(roundedRect: CGRect(x: p.x - 12, y: p.y - 5.5, width: 24, height: 11), cornerRadius: 5.5), with: .color(col.opacity(0.22))) }
                    g.fill(Path(roundedRect: CGRect(x: p.x - 7, y: p.y - 2.5, width: 14, height: 5), cornerRadius: 2.5), with: .color(col))
                } else {
                    // 들어오는 패킷: 작고 밝은 알
                    if !dim { g.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(fg.opacity(0.18))) }
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(fg.opacity(0.9)))
                    g.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(col), lineWidth: 1)
                }
                continue
            }
            guard let (a, r, end) = endpoints(cap, L) else { continue }
            let k = min(1, now.timeIntervalSince(cap.t0) / RouteScene.duration)
            let aR = CGPoint(x: a.x + L.appSize.width / 2, y: a.y)
            let rL = CGPoint(x: r.x - L.ruleSize.width / 2, y: r.y), rR = CGPoint(x: r.x + L.ruleSize.width / 2, y: r.y)
            let p: CGPoint
            if k < 0.4 { p = cubic(aR, rL, k / 0.4) }
            else if k < 0.46 { p = CGPoint(x: rL.x + (rR.x - rL.x) * (k - 0.4) / 0.06, y: r.y) }   // 규칙 칸을 가로지른다
            else { p = cubic(rR, end, (k - 0.46) / 0.54) }
            scene.caps[i].pos = p
            let ex = exits.first { $0.iface == cap.ev.iface }
            let col: Color = k < 0.43 ? (cap.ev.outside == true ? muted : fg)
                : (cap.ev.act == "block" ? blockC : cap.ev.outside == true ? exitColor(ex).opacity(0.6) : exitColor(ex))
            let dim = dimmed(rule: cap.slot, iface: cap.ev.act == "block" ? "block" : cap.ev.iface)
            var g = ctx
            g.opacity = dim ? 0.15 : (cap.replay ? 0.75 : 1)
            if !dim { g.fill(Path(roundedRect: CGRect(x: p.x - 13, y: p.y - 6, width: 26, height: 12), cornerRadius: 6), with: .color(col.opacity(0.22))) }   // 빛
            g.fill(Path(roundedRect: CGRect(x: p.x - 8, y: p.y - 3, width: 16, height: 6), cornerRadius: 3), with: .color(col))
            if cap.n > 1 && !dim { ctx.draw(Text("×\(cap.n)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(fg), at: CGPoint(x: p.x + 11, y: p.y - 9), anchor: .leading) }
        }
        for s in scene.sparks {
            ctx.fill(Path(ellipseIn: CGRect(x: s.p.x - s.r, y: s.p.y - s.r, width: s.r * 2, height: s.r * 2)), with: .color(blockC.opacity(max(0, s.life))))
        }
    }

    // MARK: 조작

    private func nearestCap(_ p: CGPoint) -> RouteScene.Cap? {
        stream.scene.caps.min { hypot($0.pos.x - p.x, $0.pos.y - p.y) < hypot($1.pos.x - p.x, $1.pos.y - p.y) }
            .flatMap { hypot($0.pos.x - p.x, $0.pos.y - p.y) < 14 ? $0 : nil }
    }

    /// 앱·규칙·출구 칸을 두 번 누르면 그것만 본다. 같은 칸을 다시 두 번 누르면 전체로.
    private func doubleTap(_ p: CGPoint, size: CGSize) {
        let L = layout(size)
        func toggle(_ z: Zoom) { setZoom(zoom == z ? nil : z) }
        if let a = L.app.first(where: { abs($0.value.x - p.x) < L.appSize.width / 2 && abs($0.value.y - p.y) < L.appSize.height / 2 }) {
            toggle(.app(a.key)); return
        }
        if let r = L.rule.first(where: { abs($0.value.x - p.x) < L.ruleSize.width / 2 && abs($0.value.y - p.y) < L.ruleSize.height / 2 }) {
            toggle(.rule(r.key)); return
        }
        if let e = L.exit.first(where: { abs($0.value.x - p.x) < L.nodeSize.width / 2 && abs($0.value.y - p.y) < L.nodeSize.height / 2 }) {
            toggle(.exit(e.key)); return
        }
        if abs(L.wall.x - p.x) < L.nodeSize.width / 2 && abs(L.wall.y - p.y) < L.nodeSize.height / 2 { toggle(.exit("block")) }
    }

    private func tap(_ p: CGPoint, size: CGSize) {
        let L = layout(size)
        if let r = L.rule.first(where: { abs($0.value.x - p.x) < L.ruleSize.width / 2 && abs($0.value.y - p.y) < L.ruleSize.height / 2 }) {
            focusRule = focusRule == r.key ? nil : r.key; focusExit = nil; return
        }
        if let e = L.exit.first(where: { abs($0.value.x - p.x) < L.nodeSize.width / 2 && abs($0.value.y - p.y) < L.nodeSize.height / 2 }) {
            focusExit = focusExit == e.key ? nil : e.key; focusRule = nil; return
        }
        if abs(L.wall.x - p.x) < L.nodeSize.width / 2 && abs(L.wall.y - p.y) < L.nodeSize.height / 2 {
            focusExit = focusExit == "block" ? nil : "block"; focusRule = nil; return
        }
        focusRule = nil; focusExit = nil
    }

    @ViewBuilder private func tooltip(width: CGFloat) -> some View {
        if let (cap, p) = hover {
            VStack(alignment: .leading, spacing: 2) {
                tipRow("앱", cap.app + (cap.n > 1 ? " ×\(cap.n)" : ""))
                tipRow("주소", "\(hostName(cap.ev)):\(cap.ev.dport) \(cap.ev.proto)" + (hostName(cap.ev) == cap.ev.dst ? "" : " · \(cap.ev.dst)"))
                tipRow("규칙", ruleText(cap.ev))
                tipRow("결과", resultText(cap.ev))
                if !cap.info.isEmpty { tipRow("패킷", cap.info) }
                tipRow("포트", "\(cap.ev.src):\(cap.ev.sport) → \(cap.ev.dst):\(cap.ev.dport)")
                tipRow("시각", timeString(cap.ev.t))
            }
            .font(.system(size: 11.5))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(stage.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lineC))
            .foregroundStyle(fg)
            .offset(x: min(p.x + 14, width - 300), y: max(4, p.y - 10))
            .allowsHitTesting(false)
        }
    }

    private func tipRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).foregroundStyle(muted).frame(width: 30, alignment: .leading)
            Text(v).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 글

    private func hostName(_ e: ConnEvent) -> String {
        if e.outside == true { return names.name(e.dst) ?? e.dst }      // 역방향 조회 이름, 없으면 IP
        let r = m.status?.rules.first { $0.id == e.rule }
        return r?.targets.first { t in t.target == e.dst || t.addresses.contains { $0.ip == e.dst } }?.target ?? e.dst
    }
    private func ruleText(_ e: ConnEvent) -> String {
        if e.outside == true { return "(규칙 없음 · \(stream.scene.slot(for: e).dropFirst()))" }
        guard let s = m.status, let i = s.rules.firstIndex(where: { $0.id == e.rule }) else { return "?" }
        return "#\(i + 1) \(s.rules[i].title)"
    }
    private func resultText(_ e: ConnEvent) -> String {
        let ex = exits.first { $0.iface == e.iface }
        if e.outside == true { return "→ 평소 경로 \(ex?.label ?? e.iface)(\(e.iface))" }
        if e.act == "pass" { return "→ \(ex?.label ?? e.iface)(\(e.iface))" }
        if let a = e.allow, a != e.iface { return "막힘 · \(e.iface)로 나가려 함 (이 규칙은 \(a)만)" }
        return "막힘 · 쓸 수 있는 출구 없음"
    }
    private func timeString(_ t: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t) / 1000))
    }

    // MARK: 타임라인 (최근 10분, 되감기)

    private var timeline: some View {
        let nowMs = Double(Date().timeIntervalSince1970 * 1000)
        let span = EventStream.keep * 1000
        let startMs = nowMs - span
        let bins = 60                                           // 10초 칸
        var pass = [Int](repeating: 0, count: bins), block = pass, out = pass
        let sc = stream.scene
        for e in stream.history where e.kind == nil && (zoom.map({ $0.matches(e, app: RouteScene.appLabel(e), slot: sc.slot(for: e)) }) ?? true) {
            let i = Int((Double(e.t) - startMs) / span * Double(bins))
            guard (0..<bins).contains(i) else { continue }
            if e.outside == true { out[i] += 1 } else if e.act == "block" { block[i] += 1 } else { pass[i] += 1 }
        }
        let peak = max(1, (0..<bins).map { pass[$0] + block[$0] + out[$0] }.max() ?? 1)
        _ = stream.historyStamp                                 // 기록이 바뀌면 다시 그린다
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("최근 10분").font(.caption2.bold()).foregroundStyle(muted)
                Text(cursor.map { timeString(Int($0)) } ?? "끌어서 시각 고르기").font(.caption2.monospaced()).foregroundStyle(cursor == nil ? muted : fg)
            }
            .frame(width: 96, alignment: .leading)
            GeometryReader { g in
                Canvas { ctx, size in
                    let bw = size.width / CGFloat(bins)
                    for i in 0..<bins {
                        var y = size.height
                        for (n, c) in [(pass[i], Color.teal), (out[i], muted), (block[i], blockC)] where n > 0 {
                            let h = CGFloat(n) / CGFloat(peak) * (size.height - 4)
                            ctx.fill(Path(CGRect(x: CGFloat(i) * bw + 1, y: y - h, width: bw - 2, height: h)), with: .color(c.opacity(0.75)))
                            y -= h
                        }
                    }
                    func xFor(_ t: Double) -> CGFloat { CGFloat((t - startMs) / span) * size.width }
                    if let c = cursor {
                        let x = xFor(c)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(fg), lineWidth: 1.5)
                    }
                    if let rc = stream.replayCursor {
                        let x = xFor(Double(rc))
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.orange), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = min(1, max(0, v.location.x / g.size.width))
                    cursor = startMs + Double(f) * span
                })
            }
            .frame(height: 34)
            Picker("", selection: $speed) {
                Text("1×").tag(1.0); Text("4×").tag(4.0); Text("16×").tag(16.0)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { if let c = cursor { stream.replay(from: Int(c), speed: speed) } } label: { Label("여기서부터 다시 보기", systemImage: "gobackward") }
                .disabled(cursor == nil)
            Button { stream.goLive(); cursor = nil } label: { Label("실시간", systemImage: "dot.radiowaves.left.and.right") }
                .disabled(!stream.replaying && cursor == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(panel)
        .environment(\.colorScheme, .dark)
    }

    // MARK: 최근 연결

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("최근 연결").font(.caption.bold()).foregroundStyle(muted)
                Spacer()
                Text("줄을 누르면 그 길을 다시 그려요").font(.caption2).foregroundStyle(muted)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(stream.recent.filter { e in zoom.map { $0.matches(e, app: RouteScene.appLabel(e), slot: stream.scene.slot(for: e)) } ?? true }.prefix(100).enumerated()), id: \.offset) { _, e in
                        Button { stream.scene.ingest(e, replay: true); stream.animating = true } label: { recentRow(e) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
            .frame(height: 150)
        }
        .background(panel)
    }

    private func recentRow(_ e: ConnEvent) -> some View {
        let ex = exits.first { $0.iface == e.iface }
        let c: Color = e.act == "block" ? blockC : exitColor(ex)
        return HStack(spacing: 10) {
            Text(timeString(e.t)).foregroundStyle(muted).frame(width: 62, alignment: .leading)
            Text(RouteScene.appLabel(e)).foregroundStyle(fg).frame(width: 110, alignment: .leading).lineLimit(1)
            Text("\(hostName(e)):\(e.dport) \(e.proto)").foregroundStyle(fg).frame(width: 230, alignment: .leading).lineLimit(1)
            Text(ruleText(e)).foregroundStyle(muted).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(e.act == "block" ? "✕ " + resultText(e) : resultText(e)).foregroundStyle(c).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timeString(e.t)) \(RouteScene.appLabel(e)) \(hostName(e)):\(e.dport) \(ruleText(e)) \(resultText(e))")
    }
}
