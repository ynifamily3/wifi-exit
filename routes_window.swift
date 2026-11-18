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
    @Published var nodesMoving = false           // 칸이 나타나거나 자리를 옮기는 동안만 칸 층을 매 프레임 다시 그린다
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
    #if DEBUG
    private var sampleEvents: DevSampleEvents?   // ./dev.sh --sample: 엔진 대신 가짜 연결
    #endif

    // MARK: 모아 보기 (연결 목록·트래픽 막대·인스펙터)

    /// 앱 + 목적지 + 포트 + 통과/막힘 하나. 최근 10분 것만 둔다.
    struct DestStat: Identifiable {
        let id: String
        let app: String, exe: String?, dst: String, dport: Int, proto: String
        let rule: String?, slot: String, iface: String, blocked: Bool, outside: Bool
        var opens = 0, bytesOut = 0, bytesIn = 0
        var first: Int, last: Int
        var live = Set<String>()                 // 지금 열려 있는 연결 (flowKey)
    }
    struct Bin { var out = 0, inn = 0, blocked = 0 }
    @Published private(set) var statsStamp = 0   // 1초에 한 번만 올려 목록·막대를 다시 그린다
    private(set) var dests: [String: DestStat] = [:]
    private(set) var bins: [Int: Bin] = [:]      // 10초 칸 (t / 10_000)
    private var flowStat: [String: String] = [:]
    // 작은 트래픽 칸 (Little Snitch 처럼): 키마다 최근 12초를 2초 칸 6개로. 키 = a:앱, d:목적지, r:규칙, x:출구,
    // re:규칙|출구(규칙 → 출구 선), b:앱|규칙|출구(연결 길)
    static let meterSlotMs = 2000, meterSlots = 6
    private(set) var meters: [String: [Int: Bin]] = [:]
    private(set) var meterPeak = 2048           // 칸 하나의 최댓값 (막대 높이 기준)
    private(set) var recentPeak = 6144          // 최근 6초 합의 최댓값 (선 굵기 기준)
    func meter(_ key: String) -> [Bin] {
        let now = Int(Date().timeIntervalSince1970 * 1000) / Self.meterSlotMs
        let m = meters[key] ?? [:]
        return (0..<Self.meterSlots).map { m[now - Self.meterSlots + 1 + $0] ?? Bin() }
    }
    /// 최근 6초에 오간 양 (보냄 + 받음)
    func recent(_ key: String) -> Int { meter(key).suffix(3).reduce(0) { $0 + $1.out + $1.inn } }
    /// 지금 열린 연결 수
    func liveCount(_ match: (DestStat) -> Bool) -> Int { dests.values.reduce(0) { $0 + (match($1) ? $1.live.count : 0) } }
    private var statsDirty = false
    private var statsTimer: Timer?

    private func tally(_ e: ConnEvent) {
        let app = RouteScene.appLabel(e)
        let bin = e.t / 10_000
        func stat(_ act: String) -> String {
            let key = "\(app)|\(e.dst)|\(e.dport)|\(act)"
            if dests[key] == nil {
                dests[key] = DestStat(id: key, app: app, exe: e.exe, dst: e.dst, dport: e.dport, proto: e.proto, rule: e.rule,
                                      slot: scene.slot(for: e), iface: e.iface, blocked: act == "block", outside: e.outside == true,
                                      first: e.t, last: e.t)
            }
            return key
        }
        switch e.kind {
        case nil:
            let key = stat(e.act)
            let prev = dests[key]?.last ?? e.t
            dests[key]?.opens += 1
            dests[key]?.last = max(prev, e.t)
            if e.act == "pass" { dests[key]?.live.insert(e.flowKey); flowStat[e.flowKey] = key }
            else { bins[bin, default: Bin()].blocked += 1 }
        case "traffic":
            let key = flowStat[e.flowKey] ?? stat("pass")
            flowStat[e.flowKey] = key
            dests[key]?.bytesOut += e.bout ?? 0
            dests[key]?.bytesIn += e.bin ?? 0
            dests[key]?.last = e.t
            if let d = dests[key] {
                let slot = e.t / Self.meterSlotMs
                for k in ["a:\(d.app)", "d:\(key)", "r:\(d.slot)", "x:\(d.iface)", "re:\(d.slot)|\(d.iface)", "b:\(d.app)|\(d.slot)|\(d.iface)"] {
                    meters[k, default: [:]][slot, default: Bin()].out += e.bout ?? 0
                    meters[k, default: [:]][slot, default: Bin()].inn += e.bin ?? 0
                }
            }
            bins[bin, default: Bin()].out += e.bout ?? 0
            bins[bin, default: Bin()].inn += e.bin ?? 0
        case "close":
            if let key = flowStat.removeValue(forKey: e.flowKey) { dests[key]?.live.remove(e.flowKey); dests[key]?.last = e.t }
        default:
            break
        }
        statsDirty = true
    }

    private func publishStats() {
        // 3분 넘게 연결이 없는 앱 칸은 흐려지며 뺀다 (예전에는 7개가 넘어야만 빠져서 지난 앱이 계속 남았다)
        let liveApps = Set(dests.values.filter { !$0.live.isEmpty }.map(\.app))
        if scene.pruneApps(olderThan: 180, keep: liveApps) { animating = true }
        if !meters.isEmpty { statsDirty = true }      // 트래픽 칸은 조용해져도 1초마다 한 칸씩 흘러가야 한다
        guard statsDirty else { return }
        statsDirty = false
        let cut = Int((Date().timeIntervalSince1970 - Self.keep) * 1000)
        dests = dests.filter { $0.value.last >= cut || !$0.value.live.isEmpty }
        bins = bins.filter { $0.key >= cut / 10_000 }
        let oldest = Int(Date().timeIntervalSince1970 * 1000) / Self.meterSlotMs - Self.meterSlots
        meters = meters.compactMapValues { m in let k = m.filter { $0.key > oldest }; return k.isEmpty ? nil : k }
        meterPeak = max(2048, meters.values.flatMap { $0.values.map { max($0.out, $0.inn) } }.max() ?? 0)
        recentPeak = max(6144, meters.keys.map(recent).max() ?? 0)
        statsStamp &+= 1
    }

    func start() {
        wanted = true
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishStats() }
        }
        refreshSamplerContext()
        sampler.onEvents = { [weak self] evs in MainActor.assumeIsolated { evs.forEach { self?.deliver($0) } } }   // 메인 큐에서 불린다
        connect()
        if allTraffic { sampler.start() }
    }

    func stop() {
        wanted = false
        statsTimer?.invalidate(); statsTimer = nil
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
        tally(e)
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
        #if DEBUG
        if DevSample.on {
            if sampleEvents == nil { sampleEvents = DevSampleEvents { [weak self] e in self?.deliver(e) } }
            sampleEvents?.start()
            connected = true; problem = nil
            return
        }
        #endif
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
        #if DEBUG
        sampleEvents?.stop()
        #endif
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
    func nodesSettled(_ moving: Bool) {
        if nodesMoving != moving { nodesMoving = moving }
        if moving && !animating { animating = true }
    }
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
    static let openDuration = 0.6             // 길이 그려지는 시간
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
    // 핑: 데이터가 오가면 경로를 따라 빛줄기 하나가 흐르고, 도착점에서 원이 한 번 퍼진다 (경로마다 pulseGap 에 한 번까지)
    struct Pulse { var key: String; var t0: Date; var dir: Int }
    var pulses: [Pulse] = []
    private var lastPulse: [String: Date] = [:]
    static let pulseDuration = 1.3
    static let pulseGap = 1.6
    var capsules = false                       // 예전의 패킷 캡슐 (지금은 쓰지 않는다)
    // 칸이 나타나고 사라지고 자리를 옮기는 움직임
    var appeared: [String: Date] = [:]         // "a:앱" → 나타난 때
    var leaving: [String: (t0: Date, at: CGPoint)] = [:]   // 앱 칸이 밀려나 흐려지는 중
    var shown: [String: CGPoint] = [:]         // 칸마다 지금 그려진 자리 (목표 자리로 부드럽게 따라간다)
    var layoutT = Date.distantPast
    var smoothV: [String: Double] = [:]        // 선 굵기·진하기 (목표 값으로 부드럽게 따라간다)
    var frameDT = 0.0
    var easing = false                         // 지난 프레임에 아직 따라가는 중인 값이 있었나
    var nodeFading = false                     // 칸이 흐려지거나 돌아오는 중 (마우스 올림)
    var layoutSize = CGSize.zero
    var moving = false { didSet { if moving != oldValue { let m = moving; DispatchQueue.main.async { [weak self] in self?.onMoving?(m) } } } }
    var onMoving: ((Bool) -> Void)?
    static let appearDuration = 0.35
    static let leaveDuration = 0.3

    /// 오래 조용한 앱 칸을 뺀다. 뺀 것이 있으면 true
    func pruneApps(olderThan age: TimeInterval, keep: Set<String>, now: Date = Date()) -> Bool {
        let stale = apps.filter { !keep.contains($0) && now.timeIntervalSince(appSeen[$0] ?? .distantPast) > age }
        guard !stale.isEmpty else { return false }
        for a in stale {
            apps.removeAll { $0 == a }
            if !reduceMotion, let at = shown["a:" + a] { leaving[a] = (now, at) }
            shown["a:" + a] = nil
        }
        moving = true
        return true
    }

    func addPulse(_ key: String, dir: Int, now: Date = Date()) {
        guard !reduceMotion, !paused else { return }
        if let l = lastPulse[key], now.timeIntervalSince(l) < Self.pulseGap { return }
        lastPulse[key] = now
        pulses.append(Pulse(key: key, t0: now, dir: dir))
    }

    /// 값을 목표로 부드럽게 (지수 감쇠). 아직 멀면 easing 을 켜 다음 프레임도 그리게 한다
    func smooth(_ key: String, _ target: Double, rate: Double = 5) -> Double {
        guard !reduceMotion else { return target }
        let cur = smoothV[key] ?? target
        let next = cur + (target - cur) * (1 - exp(-frameDT * rate))
        if abs(next - target) > 0.004 { easing = true; smoothV[key] = next; return next }
        smoothV[key] = target
        return target
    }

    var morphs: [String: (from: String, to: String, t0: Date)] = [:]     // 규칙 → 전선이 옮겨 가는 중 (출구 키)
    var notes: [String: (text: String, t0: Date)] = [:]                  // 규칙 옆에 잠깐 뜨는 "Wi-Fi → VPN"
    static let morphDuration = 0.9
    static let noteDuration = 2.8

    var idle: Bool {
        caps.isEmpty && sparks.isEmpty && heat.isEmpty && flash.isEmpty && morphs.isEmpty && notes.isEmpty && bundleHeat.isEmpty && pending.isEmpty
            && pulses.isEmpty && leaving.isEmpty && !easing && !moving
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
                if !reduceMotion, let at = shown["a:" + oldest] { leaving[oldest] = (Date(), at) }
                shown["a:" + oldest] = nil
            }
            apps.append(app)
            if !reduceMotion { appeared["a:" + app] = Date(); moving = true }
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
        if reduceMotion || !capsules {
            var c = Cap(ev: e, app: app, t0: Date()); c.slot = slot; land(c)
            if e.act == "block" { addPulse("blk:" + slot, dir: 1) }
            return
        }
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
            addPulse("b:" + b, dir: p.bout >= p.bin ? 1 : -1, now: now)
            if reduceMotion || !capsules { continue }
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
        frameDT = dt
        if paused { return }
        flushTraffic(now)
        pulses.removeAll { now.timeIntervalSince($0.t0) > Self.pulseDuration }
        leaving = leaving.filter { now.timeIntervalSince($0.value.t0) < Self.leaveDuration }
        appeared = appeared.filter { now.timeIntervalSince($0.value) < Self.appearDuration }
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
/// 목록 줄의 작은 트래픽 칸: 2초 칸 6개, 칸마다 위는 보냄, 아래는 받음 (Little Snitch 의 줄 옆 막대처럼)
struct MiniMeter: View {
    let bins: [EventStream.Bin]
    let peak: Int
    let sent: Color, recv: Color, track: Color

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 1.5, cw = (size.width - gap * CGFloat(max(1, bins.count - 1))) / CGFloat(max(1, bins.count)), half = (size.height - 1) / 2
            for (i, b) in bins.enumerated() {
                let x = CGFloat(i) * (cw + gap)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: cw, height: half), cornerRadius: 0.8), with: .color(track))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: half + 1, width: cw, height: half), cornerRadius: 0.8), with: .color(track))
                if b.out > 0 {
                    let h = max(1.5, half * CGFloat(min(1, Double(b.out) / Double(max(1, peak))).squareRoot()))
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: half - h, width: cw, height: h), cornerRadius: 0.8), with: .color(sent))
                }
                if b.inn > 0 {
                    let h = max(1.5, half * CGFloat(min(1, Double(b.inn) / Double(max(1, peak))).squareRoot()))
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: half + 1, width: cw, height: h), cornerRadius: 0.8), with: .color(recv))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 흐름도에서 강조할 경로: 앱·규칙·출구 중 정한 것만 맞춰 본다 (nil = 아무거나)
struct PathFocus: Equatable {
    var app: String? = nil
    var rule: String? = nil
    var iface: String? = nil
    /// 선(또는 칸)이 이 경로에 속하는지. 선 쪽의 nil 은 그 칸을 거치지 않는 선이라 따지지 않는다
    func matches(app a: String?, rule r: String?, iface x: String?) -> Bool {
        (app == nil || a == nil || app == a) && (rule == nil || r == nil || rule == r) && (iface == nil || x == nil || iface == x)
    }
}

/// 연결 목록을 묶는 방식
enum GroupBy: String { case app, exit, rule }

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
        // 칸 사이를 72pt 까지만 벌리고 가운데로 모은다 (칸이 적을 때 창 끝까지 흩어지지 않게)
        func ys(_ n: Int) -> [CGFloat] {
            let k = CGFloat(max(n, 1)), step = min(72, (bottom - top) / k)
            let start = top + ((bottom - top) - step * k) / 2
            return (0..<max(n, 1)).map { start + step * (CGFloat($0) + 0.5) }
        }
        let ax = max(76, size.width * 0.1), rx = size.width * 0.47, ex = size.width - max(96, size.width * 0.12)
        for (a, y) in zip(apps, ys(apps.count)) { app[a] = CGPoint(x: ax, y: y) }
        let slots = rules.count + outside.count
        let rh = min(36, (bottom - top) / CGFloat(max(slots, 1)) - 4)
        ruleSize = CGSize(width: min(264, size.width * 0.29), height: max(20, rh))
        let rys = ys(slots)
        for (r, y) in zip(rules, rys) { rule[r.id] = CGPoint(x: rx, y: y) }
        for (k, y) in zip(outside, rys.dropFirst(rules.count)) { rule[k] = CGPoint(x: rx, y: y) }
        let col = ys(exits.count + 1)
        for (e, y) in zip(exits, col) { exit[e.iface] = CGPoint(x: ex, y: y) }
        wall = CGPoint(x: ex, y: col.last ?? bottom)
        nodeSize = CGSize(width: min(200, max(176, size.width * 0.21)), height: 44)
        appSize = CGSize(width: min(150, max(120, size.width * 0.16)), height: 30)
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
    @State private var hoverNode: String?
    @State private var hoverPath: PathFocus?       // 마우스를 올린 경로: 그 경로만 진하게, 나머지는 흐리게
    @State private var hoverTip: (text: String, at: CGPoint)?          // 마우스가 올라간 칸: "a:<앱>" | "x:<인터페이스>". 그 칸의 포트만 쓴다
    @State private var focusRule: String?
    @State private var focusExit: String?
    @State private var zoom: Zoom?                // 하나만 보기 (더블클릭 또는 머리의 "보기" 메뉴)
    @State private var lastTargets: [String: String] = [:]

    @Environment(\.colorScheme) private var scheme
    @AppStorage("routesAlwaysDark") private var alwaysDark = false
    @State private var selection: String?          // 연결 목록에서 고른 줄 (MonitorNode.id)
    @State private var search = ""
    @AppStorage("routesGroupBy") private var groupBy: GroupBy = .app
    @AppStorage("routesInspector") private var showInspector = true

    /// 시스템 테마를 따른다. "늘 어둡게"를 켜면 빛나는 캡슐이 잘 보이는 어두운 화면.
    private var dark: Bool { alwaysDark || scheme == .dark }
    // 뉴모피즘 팔레트: 아주 연한 푸른 회색 바탕, 진한 남회색 글자. 그림자는 바탕에서 15% 밝게·어둡게 뽑는다
    private var stage: Color { dark ? Color(red: 0.092, green: 0.1, blue: 0.118) : Color(red: 0.965, green: 0.966, blue: 0.97) }
    /// 칸 바탕: 밝은 모양은 바탕보다 한 단계 하얗게 (솟은 판이 빛을 받는 느낌)
    private var cardC: Color { dark ? Color(red: 0.13, green: 0.14, blue: 0.162) : Color(red: 0.985, green: 0.985, blue: 0.988) }
    private var panel: Color { stage }
    private var lineC: Color { dark ? Color(red: 0.2, green: 0.215, blue: 0.245) : Color(red: 0.8, green: 0.81, blue: 0.83) }
    private var fg: Color { dark ? Color(red: 0.82, green: 0.84, blue: 0.87) : Color(red: 0.2, green: 0.22, blue: 0.26) }
    private var muted: Color { dark ? Color(red: 0.5, green: 0.53, blue: 0.58) : Color(red: 0.47, green: 0.49, blue: 0.53) }
    /// 응답 없음: 차분한 황토색 (팝업의 호박색보다 눌린 톤)
    private var warnC: Color { dark ? Color(red: 0.78, green: 0.64, blue: 0.40) : Color(red: 0.58, green: 0.43, blue: 0.18) }
    /// 바탕보다 밝은·어두운 그림자 (검정·흰색이 아니라 바탕에서 나온 색)
    private var lightShade: Color { dark ? Color(red: 0.135, green: 0.145, blue: 0.168) : .white }
    private var darkShade: Color { dark ? Color(red: 0.035, green: 0.04, blue: 0.05) : Color(red: 0.82, green: 0.83, blue: 0.855) }

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
    private func zoomLabel(_ z: Zoom) -> String {
        switch z {
        case .app(let a): return a
        case .rule(let r):
            if r.hasPrefix("~") { return "(규칙 없음) \(r.dropFirst())" }
            return m.status?.rules.first { $0.id == r }?.title ?? r
        case .exit(let x): return x == "block" ? "막힌 연결" : "\(exits.first { $0.iface == x }?.label ?? x)(\(x))"
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
        case "block": return "막음"
        case "none": return "쉼"
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
    private var statusLine: String {
        stream.replaying ? "되감기 중 · \(stream.replayCursor.map(timeString) ?? "")"
            : stream.connected ? "보는 중 · 최근 1분 \(stream.scene.hits.filter { $0.1.hasPrefix("x:") }.count)건"
            : (stream.problem ?? "엔진에 붙는 중…")
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                connectionList
                Divider()
                trafficChart
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            diagram
        }
        .inspector(isPresented: $showInspector) {
            inspectorPane.inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .frame(minWidth: 1060, minHeight: 600)
        .onExitCommand { if zoom != nil || selection != nil { showAll() } }
        .onAppear {
            stream.names = names
            let nm = names
            stream.scene.nameFor = { [weak nm] ip in MainActor.assumeIsolated { nm?.name(ip) } }
            let sc = stream.scene, st2 = stream
            names.onResolved = { [weak st2] ip, name in sc.nameArrived(ip: ip, name: name); st2?.animating = true }
            sc.onFlowsChanged = { [weak st2] in st2?.flowStamp &+= 1 }
            let model = m
            stream.statusProvider = { [weak model] in model?.status }
            // 차분하게: 패킷마다 날아가는 캡슐 없이 선의 굵기·밝기와 숫자로만 보여 준다 (Little Snitch 처럼)
            stream.scene.reduceMotion = reduceMotion      // 시스템 "동작 줄이기"면 핑·이동 애니메이션 없이
            stream.scene.capsules = false
            stream.scene.onMoving = { [weak st2] m in st2?.nodesSettled(m) }
            let st = stream
            stream.scene.onIdle = { [weak st] in st?.sceneWentIdle() }
            stream.start()
        }
        .onDisappear { stream.stop() }      // 창을 닫으면 엔진이 pf 기록을 끈다
        .onChange(of: paused) { stream.scene.paused = paused }
        .onChange(of: targetSignature) { _, now in targetsChanged(now) }
        .onChange(of: m.status?.generatedAt) { stream.refreshSamplerContext() }
        .onAppear { lastTargets = targetSignature }
        .onChange(of: selection) { _, sel in applySelection(sel) }
        .onChange(of: groupBy) { selection = nil }
        .navigationTitle("라우팅 보기")
        .navigationSubtitle(statusLine)
        .toolbar { toolbarContent }
        .preferredColorScheme(alwaysDark ? .dark : nil)
    }

    /// 가운데: 앱 → 규칙 → 출구 흐름도. 목록에서 고른 것만 진하게 그린다.
    /// 흐름도는 이 너비보다 좁게 배치하지 않는다. 공간이 좁으면 비율 그대로 줄이고(70%까지), 더 좁으면 가로로 스크롤한다
    private static let minDiagramWidth: CGFloat = 680
    private static let minScale: CGFloat = 0.7

    private var diagram: some View {
        GeometryReader { geo in
            let scale = min(1, max(Self.minScale, geo.size.width / Self.minDiagramWidth))
            let innerW = max(geo.size.width / scale, Self.minDiagramWidth)
            let innerH = max(geo.size.height / scale, stageNeeded)
            let size = CGSize(width: innerW, height: innerH)
            ScrollView([.vertical, .horizontal]) {
                ZStack {
                    Canvas { ctx, size in drawGrid(&ctx, size: size) }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || !stream.animating)) { tl in
                        Canvas { ctx, size in drawBack(&ctx, size: size, now: tl.date) }
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !stream.nodesMoving)) { tl in
                        Canvas { ctx, size in drawNodes(&ctx, size: size, now: tl.date) }
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || !stream.animating)) { tl in
                        Canvas { ctx, size in drawFront(&ctx, size: size, now: tl.date) }
                    }
                }
                .background(stage)
                // 아래 손짓들은 줄이기 전의 좌표로 받는다 (scaleEffect 앞에 둔다)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let n = nodeAt(p, size: size)
                        if n != hoverNode { hoverNode = n }
                        let (focus, tip) = hoverTarget(p, size: size)
                        if focus != hoverPath { hoverPath = focus; stream.scene.nodeFading = true; stream.nodesSettled(true) }
                        hoverTip = tip.map { ($0, p) }
                    case .ended:
                        hoverNode = nil; hoverTip = nil
                        if hoverPath != nil { hoverPath = nil; stream.scene.nodeFading = true; stream.nodesSettled(true) }
                    }
                }
                .onTapGesture(count: 2, coordinateSpace: .local) { p in doubleTap(p, size: size) }
                .onTapGesture(coordinateSpace: .local) { p in tap(p, size: size) }
                .overlay(alignment: .topLeading) { hoverTipView(width: innerW, scale: scale) }
                .overlay(alignment: .bottomLeading) { legend.padding(14) }
                .frame(width: innerW, height: innerH)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: innerW * scale, height: innerH * scale, alignment: .topLeading)
            }
            .scrollDisabled(innerW * scale <= geo.size.width + 0.5 && innerH * scale <= geo.size.height + 0.5)
            .overlay(alignment: .top) { zoomChip.padding(.top, 10) }
            .overlay { emptyState }
        }
        .background(stage)
    }

    /// 규칙이 없고 "규칙 대상만"이면 그릴 것이 없다. 빈 화면 대신 까닭과 할 일을 보여 준다
    private var showsEmptyCard: Bool { allRules.isEmpty && !stream.allTraffic && stream.scene.outsideGroups.isEmpty }

    @ViewBuilder private var emptyState: some View {
        if showsEmptyCard {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26, weight: .light)).foregroundStyle(muted)
                Text("켜진 규칙이 없어요").font(.system(size: 15, weight: .semibold)).foregroundStyle(fg)
                Text("규칙을 추가하거나 모든 연결을 켜면 여기에 그려져요")
                    .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("규칙 추가…") { m.windowSelection = "new"; NSApp.activate(); openWindow(id: "rules") }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                    Button("모든 연결 보기") { stream.setAllTraffic(true) }
                        .controlSize(.regular)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color(red: 0.13, green: 0.14, blue: 0.162) : Color(red: 0.985, green: 0.985, blue: 0.988))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.08), radius: 12, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((dark ? Color.white : .black).opacity(0.06)))
        }
    }

    /// 하나만 보는 중일 때 흐름도 위에 뜨는 띠: 무엇을 보는지 + 전체로 돌아가기 (Esc·빈 곳 클릭도 같다)
    @ViewBuilder private var zoomChip: some View {
        if let z = zoom {
            HStack(spacing: 8) {
                Image(systemName: "scope").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                Text(zoomTitle(z)).font(.system(size: 12, weight: .medium)).foregroundStyle(fg).lineLimit(1).truncationMode(.middle)
                Button { showAll() } label: {
                    Text("전체 보기").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(fg.opacity(0.08)))
                }
                .buttonStyle(.plain).foregroundStyle(fg)
                .help("전체 보기 (esc)")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
            .background(Capsule().fill(dark ? Color(red: 0.16, green: 0.17, blue: 0.2) : .white)
                .shadow(color: .black.opacity(dark ? 0.45 : 0.1), radius: 8, y: 2))
            .overlay(Capsule().strokeBorder((dark ? Color.white : .black).opacity(0.08)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func zoomTitle(_ z: Zoom) -> String {
        if let sel = selection, sel.hasPrefix("d:"), let d = stream.dests[String(sel.dropFirst(2))] {
            return "\(d.app) → \(hostOf(d)):\(d.dport)만 보는 중"
        }
        return "\(zoomLabel(z))만 보는 중"
    }

    private func showAll() {
        withAnimation(.easeOut(duration: 0.2)) {
            selection = nil
            setZoom(nil)
        }
    }

    /// 목록에서 고른 줄을 흐름도에 비춘다: 앱은 그 앱만, 목적지는 그 앱 + 그 규칙 강조, 출구·규칙 묶음은 그것만.
    private func applySelection(_ sel: String?) {
        guard let sel else { setZoom(nil); return }
        let body = String(sel.drop { $0 != ":" }.dropFirst())
        switch sel.prefix(while: { $0 != ":" }) {
        case "a": setZoom(.app(body))
        case "d": if let d = stream.dests[body] { setZoom(.app(d.app)); focusRule = d.slot }
        case "x": setZoom(.exit(body))
        case "xa": let p = body.split(separator: "|", maxSplits: 1).map(String.init); if p.count == 2 { setZoom(.app(p[1])); focusExit = p[0] }
        case "r": setZoom(.rule(body))
        case "ra": let p = body.split(separator: "|", maxSplits: 1).map(String.init); if p.count == 2 { setZoom(.app(p[1])); focusRule = p[0] }
        default: setZoom(nil)
        }
    }

    /// 규칙 밖 칸에서 새 규칙 초안을 만든다 (그 칸으로 간 IPv4 들, 메모는 도메인).
    private func makeRule(from key: String) {
        var d = RuleDraft(nil)
        d.targets = (stream.scene.groupIPs[key] ?? []).compactMap { Target.parse($0)?.0 }.prefix(10).map { $0 }
        d.name = String(key.dropFirst())
        m.drafts["new"] = d
        m.windowSelection = "new"
        NSApp.activate()
        openWindow(id: "rules")
    }

    // MARK: 머리

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let f = focusRule, f.hasPrefix("~") {
                Button { makeRule(from: f) } label: { Label("이 목적지로 규칙 만들기", systemImage: "plus.circle") }
                    .help("이 목적지로 간 IP들로 새 규칙 초안을 만들어요")
            }
            Picker("범위", selection: Binding(get: { stream.allTraffic }, set: { stream.setAllTraffic($0) })) {
                Text("규칙 대상만").tag(false)
                Text("모든 연결").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("모든 연결: 규칙에 없는 연결도 보여요")
            Menu {
                Picker("묶기", selection: $groupBy) {
                    Text("앱 → 목적지").tag(GroupBy.app)
                    Text("출구 → 앱").tag(GroupBy.exit)
                    Text("규칙 → 앱").tag(GroupBy.rule)
                }
                .pickerStyle(.inline)
            } label: { Label("묶기", systemImage: "list.bullet.indent") }
            .help("목록 묶기")
            Toggle(isOn: $paused) { Label("기록 멈춤", systemImage: "pause.fill") }
                .help("화면 기록만 멈춰요. 규칙 적용은 계속돼요")
            Toggle(isOn: $alwaysDark) { Label("늘 어둡게", systemImage: "moon") }
                .help("늘 어두운 화면으로")
            Button { NSApp.activate(); openWindow(id: "rules") } label: { Label("규칙 편집", systemImage: "list.bullet.rectangle") }
                .help("규칙 편집")
            Button { showInspector.toggle() } label: { Label("인스펙터", systemImage: "sidebar.right") }
                .help("인스펙터 보기")
        }
    }

    // MARK: 그리기

    /// 그릴 때 쓰는 배치: 칸이 목표 자리로 0.3초쯤에 걸쳐 부드럽게 옮겨 간다 (한 프레임에 한 번만 나아간다)
    private func animatedLayout(_ size: CGSize, now: Date) -> RouteLayout {
        var L = layout(size)
        let sc = stream.scene
        if sc.reduceMotion { return L }
        if sc.layoutSize != size {
            // 창 크기를 바꾸는 중에는 따라가지 않고 바로 맞춘다 (매 프레임 칸 전체를 다시 그려 버벅였다)
            sc.layoutSize = size
            for (a, p) in L.app { sc.shown["a:" + a] = p }
            for (r, p) in L.rule { sc.shown["r:" + r] = p }
            for (x, p) in L.exit { sc.shown["x:" + x] = p }
            sc.shown["x:block"] = L.wall
            sc.layoutT = now
            return L
        }
        let dt = min(0.1, max(0, now.timeIntervalSince(sc.layoutT)))
        if now > sc.layoutT { sc.layoutT = now }
        let k = 1 - exp(-dt * 13)
        var unsettled = false
        func ease(_ key: String, _ target: CGPoint) -> CGPoint {
            guard let cur = sc.shown[key] else { sc.shown[key] = target; return target }
            let next = CGPoint(x: cur.x + (target.x - cur.x) * k, y: cur.y + (target.y - cur.y) * k)
            if hypot(next.x - target.x, next.y - target.y) < 0.4 { sc.shown[key] = target; return target }
            sc.shown[key] = next; unsettled = true
            return next
        }
        for (a, p) in L.app { L.app[a] = ease("a:" + a, p) }
        for (r, p) in L.rule { L.rule[r] = ease("r:" + r, p) }
        for (x, p) in L.exit { L.exit[x] = ease("x:" + x, p) }
        L.wall = ease("x:block", L.wall)
        sc.moving = unsettled || !sc.appeared.isEmpty || !sc.leaving.isEmpty || sc.nodeFading
        return L
    }

    /// 강조·흐림이 바뀔 때 0.2초쯤에 걸쳐 부드럽게 (켜짐 = 1)
    private func fade(_ key: String, _ on: Bool) -> Double { stream.scene.smooth("f:" + key, on ? 1 : 0, rate: 14) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// 배경 점 한 칸 (14pt) 무늬. 한 번 그려 두고 타일로 깐다 (점 수천 개를 매번 그리면 창 크기를 바꿀 때 버벅였다)
    private static var tiles: [Bool: Image] = [:]
    private func dotTile() -> Image {
        if let t = Self.tiles[dark] { return t }
        let isDark = dark
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            (isDark ? NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 0.06) : NSColor(srgbRed: 0.2, green: 0.22, blue: 0.26, alpha: 0.075)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 7 - 0.9, y: 7 - 0.9, width: 1.8, height: 1.8)).fill()
            return true
        }
        let t = Image(nsImage: img)
        Self.tiles[isDark] = t
        return t
    }

    private func easeOut(_ t: Double) -> Double { let u = 1 - min(1, max(0, t)); return 1 - u * u * u }
    private func easeInOut(_ t: Double) -> Double { let x = min(1, max(0, t)); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    /// 핑: 경로를 따라 흐르는 빛줄기, 끝에 닿으면 연결점에서 원이 한 번 퍼진다
    /// rings: false = 빛줄기만 (칸 아래 층에 그려 칸 글자를 가로지르지 않게), true = 도착점의 원만 (칸 위 층)
    private func drawPulses(_ ctx: inout GraphicsContext, _ L: RouteLayout, now: Date, rings: Bool) {
        for p in stream.scene.pulses {
            let t = now.timeIntervalSince(p.t0) / RouteScene.pulseDuration
            guard t >= 0, t <= 1 else { continue }
            var path: Path?, color = fg, width: CGFloat = 2, end = CGPoint.zero
            var focus = (app: String?.none, rule: String?.none, iface: String?.none)
            if p.key.hasPrefix("b:") {
                let parts = p.key.dropFirst(2).split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count == 3, let pts = bundlePoints(app: parts[0], slot: parts[1], iface: parts[2], L) else { continue }
                path = bundlePath(pts); end = p.dir > 0 ? pts.3 : pts.0
                color = exitColor(exits.first { $0.iface == parts[2] })
                width = 1.4 + CGFloat(stream.scene.smoothV["b:" + p.key.dropFirst(2)] ?? 0) * 4
                focus = (parts[0], parts[1], parts[2])
            } else if p.key.hasPrefix("blk:"), let rp = L.rule[String(p.key.dropFirst(4))] {
                end = CGPoint(x: L.wall.x - L.nodeSize.width / 2, y: L.wall.y)
                path = wirePath(CGPoint(x: rp.x + L.ruleSize.width / 2, y: rp.y), end); color = blockC; width = 1.6
                focus = (nil, String(p.key.dropFirst(4)), "block")
            }
            let away = fade("ld:p:" + p.key, lineDim(app: focus.app, rule: focus.rule, iface: focus.iface))
            guard let path, away < 0.98 else { continue }
            let e = easeInOut(min(1, t / 0.8))                     // 0.8 동안 흐르고, 남은 0.2 동안 도착점에서 퍼진다
            let pos = p.dir > 0 ? e : 1 - e
            let fade = sin(.pi * min(1, t / 0.8))
            if !rings {
            let seg = path.trimmedPath(from: max(0, pos - 0.07), to: min(1, pos + 0.01))
            var g = ctx
            g.opacity = fade * (1 - away)
            g.stroke(seg, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
            g.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: width + 1.5, lineCap: .round))
            g.stroke(seg, with: .color(.white.opacity(dark ? 0.55 : 0.8)), style: StrokeStyle(lineWidth: max(1, width * 0.45), lineCap: .round))
            }
            if rings, t > 0.72 {
                let k = easeOut((t - 0.72) / 0.28)
                let r = 4 + 9 * k
                ctx.stroke(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(color.opacity(0.55 * (1 - k))), lineWidth: 1.5)
            }
        }
    }

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

    /// 점이 올라간 앱 칸·출구 칸
    // MARK: 마우스 올림: 경로 강조·설명

    /// 칸의 트래픽 막대 자리 (그리기와 같은 계산)
    private func meterRect(_ rect: CGRect, inset: CGFloat = NodeToken.inset) -> CGRect {
        CGRect(x: rect.maxX - inset - NodeToken.meter.width, y: rect.midY - NodeToken.meter.height / 2,
               width: NodeToken.meter.width, height: NodeToken.meter.height)
    }

    private func meterTip(_ key: String, title: String) -> String {
        let bins = stream.meter(key)
        let out = bins.reduce(0) { $0 + $1.out }, inn = bins.reduce(0) { $0 + $1.inn }
        return "\(title) · 최근 12초\n보냄 \(RouteScene.bytesText(out)) · 받음 \(RouteScene.bytesText(inn))\n막대 한 칸 = 2초 (위 보냄, 아래 받음)"
    }

    private func exitName(_ iface: String) -> String {
        iface == "block" ? "막음" : exits.first { $0.iface == iface }.map { "\($0.label)(\(iface))" } ?? iface
    }

    /// 점 p 에서 강조할 경로와 설명. 순서: 트래픽 막대 → 칸 → 선
    private func hoverTarget(_ p: CGPoint, size: CGSize) -> (PathFocus?, String?) {
        let L = layout(size)
        func inside(_ c: CGPoint, _ s: CGSize) -> Bool { abs(p.x - c.x) <= s.width / 2 && abs(p.y - c.y) <= s.height / 2 }
        func box(_ c: CGPoint, _ s: CGSize) -> CGRect { CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height) }
        for a in visibleApps {
            guard let c = L.app[a], inside(c, L.appSize) else { continue }
            if meterRect(box(c, L.appSize), inset: 10).insetBy(dx: -3, dy: -3).contains(p) { return (PathFocus(app: a), meterTip("a:\(a)", title: a)) }
            return (PathFocus(app: a), nil)
        }
        for r in rules {
            guard let c = L.rule[r.id], inside(c, L.ruleSize) else { continue }
            if r.decision != "block", meterRect(box(c, L.ruleSize)).insetBy(dx: -3, dy: -3).contains(p) { return (PathFocus(rule: r.id), meterTip("r:\(r.id)", title: r.title)) }
            return (PathFocus(rule: r.id), nil)
        }
        for e in visibleExits {
            guard let c = L.exit[e.iface], inside(c, L.nodeSize) else { continue }
            if meterRect(box(c, L.nodeSize)).insetBy(dx: -3, dy: -3).contains(p) { return (PathFocus(iface: e.iface), meterTip("x:\(e.iface)", title: exitName(e.iface))) }
            return (PathFocus(iface: e.iface), nil)
        }
        if inside(L.wall, L.nodeSize) { return (PathFocus(iface: "block"), nil) }
        // 선: 연결 길(앱 → 규칙 → 출구) 먼저, 그다음 규칙 → 출구
        for (b, fs) in stream.scene.bundles {
            guard let f0 = fs.first, let pts = bundlePoints(app: f0.app, slot: f0.slot, iface: f0.iface, L) else { continue }
            if bundlePath(pts).strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round)).contains(p) {
                let live = fs.filter { $0.closedAt == nil }.count
                let title = m.status?.rules.first { $0.id == f0.slot }?.title ?? String(f0.slot.dropFirst())
                return (PathFocus(app: f0.app, rule: f0.slot, iface: f0.iface),
                        "\(f0.app) → \(title) → \(exitName(f0.iface))\n연결 \(live) · 최근 6초 \(RouteScene.bytesText(stream.recent("b:\(b)")))")
            }
        }
        for r in rules {
            let key = targetKey(r)
            guard key != "none", let rp = L.rule[r.id] else { continue }
            let from = CGPoint(x: rp.x + L.ruleSize.width / 2, y: rp.y)
            let end = key == "block" ? CGPoint(x: L.wall.x - L.nodeSize.width / 2, y: L.wall.y) : L.exit[key].map { CGPoint(x: $0.x - L.nodeSize.width / 2, y: $0.y) }
            guard let end, wirePath(from, end).strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round)).contains(p) else { continue }
            let live = stream.liveCount { $0.slot == r.id && !$0.blocked }
            return (PathFocus(rule: r.id, iface: key), "\(r.title) → \(exitName(key))\n" + (key == "block" ? "쓸 수 있는 출구가 없어 막는 중" : "연결 \(live) · 최근 6초 \(RouteScene.bytesText(stream.recent("re:\(r.id)|\(key)")))"))
        }
        return (nil, nil)
    }

    /// 강조한 경로가 지나는 칸들 ("a:앱", "r:규칙", "x:출구")
    private func focusNodes(_ f: PathFocus) -> Set<String> {
        var out = Set<String>()
        if let a = f.app { out.insert("a:" + a) }
        if let r = f.rule { out.insert("r:" + r) }
        if let x = f.iface { out.insert("x:" + x) }
        for (_, fs) in stream.scene.bundles {
            guard let f0 = fs.first, f.matches(app: f0.app, rule: f0.slot, iface: f0.iface) else { continue }
            out.formUnion(["a:" + f0.app, "r:" + f0.slot, "x:" + f0.iface])
        }
        for r in rules where f.app == nil {
            let key = targetKey(r)
            guard key != "none", f.matches(app: nil, rule: r.id, iface: key) else { continue }
            out.formUnion(["r:" + r.id, "x:" + key])
        }
        return out
    }

    @ViewBuilder private func hoverTipView(width: CGFloat, scale: CGFloat) -> some View {
        if let tip = hoverTip {
            Text(tip.text)
                .font(.system(size: 11)).foregroundStyle(fg).lineSpacing(2)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dark ? Color(red: 0.16, green: 0.17, blue: 0.2) : .white)
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.12), radius: 6, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder((dark ? Color.white : .black).opacity(0.08)))
                .fixedSize()
                .scaleEffect(1 / scale, anchor: .topLeading)          // 흐름도를 줄여도 설명 글자는 그대로
                .offset(x: min(tip.at.x + 14, width - 260 / scale), y: tip.at.y + 16)
                .allowsHitTesting(false)
        }
    }

    /// 색의 뜻: 선과 연결점의 색은 늘 "나가는 출구"만 뜻한다. 주의·오류는 아이콘과 글로.
    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(["wifi", "wired", "vpn"], id: \.self) { k in Capsule().fill(Color.exit(k, dark: dark)).frame(width: 10, height: 3) }
                Text("선 색 = 나가는 출구")
            }
            Text("굵기 = 최근 6초 오간 양")
            HStack(spacing: 3) {
                VStack(spacing: 1) { Capsule().fill(sentC).frame(width: 6, height: 3); Capsule().fill(recvC).frame(width: 6, height: 3) }
                Text("최근 12초 보냄·받음")
            }
        }
        .font(.system(size: 10)).foregroundStyle(muted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(stage.opacity(0.9)))
        .allowsHitTesting(false)
    }

    private func nodeAt(_ p: CGPoint, size: CGSize) -> String? {
        let L = layout(size)
        for (a, c) in L.app where abs(p.x - c.x) <= L.appSize.width / 2 && abs(p.y - c.y) <= L.appSize.height / 2 { return "a:" + a }
        for (i, c) in L.exit where abs(p.x - c.x) <= L.nodeSize.width / 2 && abs(p.y - c.y) <= L.nodeSize.height / 2 { return "x:" + i }
        return nil
    }

    /// 보냄(분홍)·받음(파랑): Little Snitch 의 트래픽 색을 톤만 낮춰서
    private var sentC: Color { dark ? Color(red: 0.70, green: 0.55, blue: 0.62) : Color(red: 0.64, green: 0.44, blue: 0.54) }
    private var recvC: Color { dark ? Color(red: 0.50, green: 0.59, blue: 0.73) : Color(red: 0.38, green: 0.49, blue: 0.65) }
    /// 선 굵기·진하기에 쓰는 0…1 (최근 6초 양을 가장 많은 길에 견준 값, 제곱근으로 작은 양도 보이게)
    private func norm(_ v: Int) -> Double { v <= 0 ? 0 : min(1, (Double(v) / Double(stream.recentPeak)).squareRoot()) }

    /// 캔버스에 작은 트래픽 칸을 그린다: 칸마다 위는 보냄, 아래는 받음, 빈 칸은 옅은 회색
    private func drawMeter(_ c: inout GraphicsContext, key: String, in r: CGRect) {
        let bins = stream.meter(key)
        let gap: CGFloat = 1.5, cw = (r.width - gap * CGFloat(bins.count - 1)) / CGFloat(bins.count), half = (r.height - 1) / 2
        let peak = Double(stream.meterPeak)
        for (i, b) in bins.enumerated() {
            let x = r.minX + CGFloat(i) * (cw + gap)
            c.fill(Path(roundedRect: CGRect(x: x, y: r.minY, width: cw, height: half), cornerRadius: 0.8), with: .color(fg.opacity(0.08)))
            c.fill(Path(roundedRect: CGRect(x: x, y: r.minY + half + 1, width: cw, height: half), cornerRadius: 0.8), with: .color(fg.opacity(0.08)))
            if b.out > 0 {
                let h = max(1.5, half * CGFloat(min(1, Double(b.out) / peak).squareRoot()))
                c.fill(Path(roundedRect: CGRect(x: x, y: r.minY + half - h, width: cw, height: h), cornerRadius: 0.8), with: .color(sentC))
            }
            if b.inn > 0 {
                let h = max(1.5, half * CGFloat(min(1, Double(b.inn) / peak).squareRoot()))
                c.fill(Path(roundedRect: CGRect(x: x, y: r.minY + half + 1, width: cw, height: h), cornerRadius: 0.8), with: .color(recvC))
            }
        }
    }

    private func exitColor(_ e: ExitInfo?) -> Color { e.map { Color.exit($0.name, dark: dark) } ?? muted }
    private var blockC: Color { Color.exit("block", dark: dark) }

    private func dimmed(rule: String?, iface: String?) -> Bool {
        if let f = focusRule, f != rule { return true }
        if let f = focusExit, f != iface { return true }
        return false
    }
    /// 선: 클릭 강조 또는 마우스 올린 경로 밖이면 흐리게
    private func lineDim(app: String?, rule: String?, iface: String?) -> Bool {
        dimmed(rule: rule, iface: iface) || (hoverPath.map { !$0.matches(app: app, rule: rule, iface: iface) } ?? false)
    }
    private func lineHot(app: String?, rule: String?, iface: String?) -> Bool {
        hoverPath?.matches(app: app, rule: rule, iface: iface) ?? false
    }

    /// 뒤 층 (매 프레임): 장면을 한 걸음 움직이고 전선을 그린다
    private func drawBack(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = animatedLayout(size, now: now)
        stream.scene.easing = false
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
            let dim = lineDim(app: nil, rule: r.id, iface: key == "none" ? nil : key)
            let hot = lineHot(app: nil, rule: r.id, iface: key)
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
            let fd = fade("ld:re:\(r.id)", dim), fh = fade("lh:re:\(r.id)", hot)
            if key == "block" {
                // 막힌 연결은 오간 양이 없으니 시도할 때마다 잠깐 진해진다
                let op = lerp(lerp(0.16 + h * 0.5, 0.9, fh), 0.06, fd)
                strokeLine(&ctx, wirePath(from, end), color: col, opacity: op, width: 1.2 + min(2, h * 1.5) + CGFloat(fh))
            } else {
                let v = scene.smooth("re:\(r.id)|\(key)", norm(stream.recent("re:\(r.id)|\(key)")))
                let live = scene.smooth("rl:\(r.id)", stream.liveCount { $0.slot == r.id && !$0.blocked } > 0 ? 1 : 0)
                let op = lerp(lerp(0.16 + live * 0.34 + v * 0.4, 0.95, fh), 0.06, fd)
                strokeLine(&ctx, wirePath(from, end), color: col, opacity: op, width: 1.2 + v * 4 + CGFloat(fh))
            }
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
            // 생길 때: 감속하며 그려지고 함께 짙어진다. 닫힐 때: 서서히 흐려진다
            var alpha = 1.0
            if live.isEmpty, let last = fs.compactMap(\.closedAt).max() { alpha = 1 - easeOut(now.timeIntervalSince(last) / RouteScene.closeFade) }
            let grow = easeOut(now.timeIntervalSince(scene.bundleOpened[b] ?? .distantPast) / RouteScene.openDuration)
            alpha *= 0.3 + 0.7 * grow
            let v = scene.smooth("b:\(b)", norm(stream.recent("b:\(b)")))
            let col = exitColor(exits.first { $0.iface == f0.iface })
            let fd = fade("ld:b:\(b)", lineDim(app: f0.app, rule: f0.slot, iface: f0.iface))
            let fh = fade("lh:b:\(b)", lineHot(app: f0.app, rule: f0.slot, iface: f0.iface))
            let path = bundlePath(pts).trimmedPath(from: 0, to: grow)
            strokeLine(&ctx, path, color: col, opacity: lerp(lerp((live.isEmpty ? 0.3 : 0.6) + v * 0.3, 1, fh), 0.07, fd) * alpha,
                       width: 1.4 + v * 4 + CGFloat(fh) * 1.2, dash: f0.ev.outside == true ? [6, 3] : [])
        }
        // 전선: 앱 → 규칙 (열린 길이 없는 것만: 막힌 시도나 방금 닫힌 연결)
        let openPairs = Set(scene.bundles.keys.map { $0.split(separator: "|").prefix(2).joined(separator: "|") })
        for (k, v) in scene.heat where k.hasPrefix("a:") {
            let parts = k.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !openPairs.contains("\(parts[0])|\(parts[1])"), let ap = L.app[parts[0]], let rp = L.rule[parts[1]] else { continue }
            let from = CGPoint(x: ap.x + L.appSize.width / 2, y: ap.y), to = CGPoint(x: rp.x - L.ruleSize.width / 2, y: rp.y)
            let fd = fade("ld:a:\(k)", lineDim(app: parts[0], rule: parts[1], iface: nil))
            strokeLine(&ctx, wirePath(from, to), color: fg, opacity: lerp(0.05 + v * 0.3, 0.03, fd), width: 1 + v * 1.5)
        }
        drawPulses(&ctx, L, now: now, rings: false)

    }

    // MARK: 칸 디자인 토큰
    //   종류마다 모양: 앱(출발) = 알약, 규칙(판단) = 모서리 8 + 번호 동그라미에 보내는 곳 색, 출구(도착) = 모서리 10 + 출구 색 바탕,
    //   막음·규칙 없음 = 점선. 상태마다 테두리: 쉼 1pt 옅게, 사용 중 1.5pt 진하게, 쉬는 규칙 점선 + 흐림,
    //   응답 없음 호박색, 지금 없음 점선, 고름 2pt 링. 선은 칸 옆구리의 연결점에서 끝난다.

    enum NodeToken {
        static let ruleRadius: CGFloat = 8
        static let exitRadius: CGFloat = 10
        static let inset: CGFloat = 8
        static let meter = CGSize(width: 26, height: 16)
        static let port: CGFloat = 3.5
        static let idleLine: CGFloat = 1
        static let activeLine: CGFloat = 1.5
        static let ring: CGFloat = 2
        static let dimmed: Double = 0.35
        static let resting: Double = 0.8
        static let title = Font.system(size: 12.5, weight: .semibold)
        static let appTitle = Font.system(size: 12, weight: .medium)
        static let sub = Font.system(size: 10)
        static let digits = Font.system(size: 10).monospacedDigit()
    }
    enum NodeShape { case app, rule, exit, outside, wall }
    enum NodeState { case idle, active, resting, warn, absent }

    /// 칸 하나 (뉴모피즘): 배경과 같은 색의 판이 바깥 그림자 두 개(위왼쪽 흰 빛, 아래오른쪽 그림자)로 솟는다.
    /// 쓰는 중이면 더 높이 솟고 출구 색 테두리, 쉬는 칸은 옅은 1pt 테두리, 쉬는 규칙·지금 없음은 그림자 없이 점선.
    private func drawCard(_ c: inout GraphicsContext, _ rect: CGRect, shape: NodeShape, tint: Color?, state: NodeState, selected: Bool) {
        let radius: CGFloat = shape == .app ? rect.height / 2 : (shape == .rule || shape == .outside) ? NodeToken.ruleRadius : NodeToken.exitRadius
        let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let flat = state == .resting || state == .absent || shape == .outside
        if !flat {
            // 바깥 그림자 두 개: 위왼쪽 흰 빛 + 아래오른쪽 어두운 그림자. 쓰는 중이면 더 높이 솟는다
            let lift: CGFloat = state == .active ? 1.6 : 1
            var hi = c
            hi.addFilter(.shadow(color: lightShade.opacity(dark ? 1 : 0.95), radius: 7 * lift, x: -3 * lift, y: -3 * lift, options: .shadowOnly))
            hi.fill(path, with: .color(stage))
            // 상태는 그림자 색으로: 쓰는 출구는 출구 색, 응답 없음은 호박색, 그 밖은 회색 그림자
            // 색 그림자는 은은하게: 어두운 모양에서는 바닥 그림자에 출구 색을 아주 조금만 비친다 (빛나 보이지 않게)
            let shadowC: Color = state == .warn ? (dark ? warnC.opacity(0.16) : warnC.opacity(0.3))
                : (state == .active && tint != nil) ? (dark ? tint!.opacity(0.14) : tint!.opacity(0.32))
                : darkShade.opacity(state == .active ? 1 : 0.85)
            if dark && (state == .warn || (state == .active && tint != nil)) {
                var base = c
                base.addFilter(.shadow(color: darkShade, radius: 8 * lift, x: 3.5 * lift, y: 4 * lift, options: .shadowOnly))
                base.fill(path, with: .color(stage))
            }
            var lo = c
            lo.addFilter(.shadow(color: shadowC, radius: 8 * lift, x: 3.5 * lift, y: 4 * lift, options: .shadowOnly))
            lo.fill(path, with: .color(stage))
        }
        // 5% 얼음 유리: 바탕을 조금 비치게 하고, 밑의 점 무늬를 흐리게 번져 보이게 한 뒤 흰 빛 5%
        c.fill(path, with: .color(cardC.opacity(0.94)))
        var frost = c
        frost.opacity = 0.7
        frost.fill(path, with: .tiledImage(dotTile()))
        c.fill(path, with: .color(.white.opacity(dark ? 0.035 : 0.05)))
        if let tint { c.fill(path, with: .color(tint.opacity(dark ? 0.12 : 0.07))) }
        let dashed = shape == .outside || shape == .wall || state == .absent || state == .resting
        let line: Color
        switch state {
        case .warn: line = warnC
        case .active: line = tint.map { $0.opacity(0.8) } ?? fg.opacity(0.4)
        default: line = tint.map { $0.opacity(0.45) } ?? muted.opacity(0.55)
        }
        // 테두리: 평평한 칸은 점선, 솟은 칸은 아주 옅은 1pt 한 색 (어두운 모양에서는 그림자가 잘 안 보여 이 선이 가장자리를 잡는다)
        if dashed { c.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: NodeToken.idleLine, dash: [4, 3])) }
        else { c.stroke(path, with: .color((dark ? Color.white : .black).opacity(dark ? 0.08 : 0.045)), lineWidth: 1) }
        if selected {
            c.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: radius + 3, style: .continuous),
                     with: .color(fg.opacity(0.8)), lineWidth: NodeToken.ring)
        }
    }

    /// 배경: 점 무늬 (Cloudflare 처럼). 지금 쓰는 출구 둘레의 점은 그 출구 색으로 옅게 물든다
    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        _ = stream.statsStamp
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(dotTile()))
        let step: CGFloat = 14, r: CGFloat = 1.15, reach: CGFloat = 100
        let L = layout(size)
        for e in visibleExits {
            guard let p = L.exit[e.iface], stream.liveCount({ $0.iface == e.iface && !$0.blocked }) > 0 else { continue }
            var levels: [Int: Path] = [:]
            var y = ((p.y - reach) / step).rounded(.down) * step + step / 2
            while y <= p.y + reach {
                var x = ((p.x - reach) / step).rounded(.down) * step + step / 2
                while x <= p.x + reach {
                    let d = hypot(x - p.x, y - p.y), level = Int((1 - d / reach) * 4)
                    if d < reach, level > 0 { levels[level, default: Path()].addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
                    x += step
                }
                y += step
            }
            for (lv, path) in levels { ctx.fill(path, with: .color(exitColor(e).opacity(0.05 + 0.06 * Double(lv)))) }
        }
    }

    /// 선이 꽂히는 연결점: 칸 테두리 위에 그려 선 끝을 덮는다
    /// filled: 강조한 경로의 출발·도착점은 선 색으로 채우고 조금 키운다
    private func drawPort(_ c: inout GraphicsContext, _ p: CGPoint, color: Color, filled: Bool = false) {
        let r = NodeToken.port + (filled ? 1 : 0)
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        c.fill(Path(ellipseIn: rect), with: .color(filled ? color : stage))
        c.stroke(Path(ellipseIn: rect), with: .color(filled ? stage : color), lineWidth: filled ? 1.5 : 1.2)
    }

    /// 오른쪽 끝: 트래픽 칸, 그 왼쪽에 숫자
    private func drawTrail(_ c: inout GraphicsContext, _ rect: CGRect, meter key: String?, count n: Int, inset: CGFloat = NodeToken.inset) {
        let mw = NodeToken.meter.width
        if let key { drawMeter(&c, key: key, in: CGRect(x: rect.maxX - inset - mw, y: rect.midY - NodeToken.meter.height / 2, width: mw, height: NodeToken.meter.height)) }
        if n > 0 {
            c.draw(Text("\(n)").font(NodeToken.digits).foregroundColor(muted),
                   at: CGPoint(x: rect.maxX - inset - (key == nil ? 0 : mw + 6), y: rect.midY), anchor: .trailing)
        }
    }

    /// 간선: 단색 선 하나. 굵기 = 최근 오간 양, 진하기 = 지금 열린 연결이 있나
    private func strokeLine(_ ctx: inout GraphicsContext, _ path: Path, color: Color, opacity: Double, width: CGFloat, dash: [CGFloat] = []) {
        guard opacity > 0.01 else { return }
        ctx.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    /// 가운데 층 (상태가 바뀔 때만): 칸과 글자. 매 프레임 글자를 다시 그리지 않아 CPU 를 아낀다
    private func drawNodes(_ ctx: inout GraphicsContext, size: CGSize, now: Date = Date()) {
        let L = animatedLayout(size, now: now)
        let fit = TextFit.fit
        let scene = stream.scene
        func label(_ s: String, _ p: CGPoint, _ c: Color, _ font: Font, anchor: UnitPoint = .center) {
            ctx.draw(Text(s).font(font).foregroundColor(c), at: p, anchor: anchor)
        }
        let onPath = hoverPath.map(focusNodes)
        scene.nodeFading = false
        /// 마우스 올린 경로 밖의 칸은 흐리게
        func off(_ key: String) -> Bool { onPath.map { !$0.contains(key) } ?? false }
        /// 흐림 정도 0…1 을 부드럽게 (바뀌는 동안 칸 층을 매 프레임 다시 그린다)
        func dimAmt(_ key: String, _ on: Bool) -> Double {
            let v = fade("nd:" + key, on)
            if v != (on ? 1 : 0) { scene.nodeFading = true }
            return v
        }
        // 칼럼 머리글: 이름 + 개수, 밑에 칸 너비만큼 짧은 선 (선이 지나는 빈 곳에는 긋지 않는다)
        // 칸들이 가운데로 모이므로 머리글은 맨 위 칸 바로 위에 둔다
        var tops: [CGFloat] = [L.wall.y - L.nodeSize.height / 2]
        tops += L.app.values.map { $0.y - L.appSize.height / 2 }
        tops += L.rule.values.map { $0.y - L.ruleSize.height / 2 }
        tops += L.exit.values.map { $0.y - L.nodeSize.height / 2 }
        let topY: CGFloat = max(30, tops.min() ?? 30)
        func header(_ title: String, _ n: Int, x: CGFloat, width: CGFloat) {
            let t = Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(fg.opacity(0.7))
                + Text("  \(n)").font(.system(size: 11).monospacedDigit()).foregroundColor(muted)
            ctx.draw(t, at: CGPoint(x: x - width / 2 + 2, y: topY - 24), anchor: .leading)
            ctx.fill(Path(CGRect(x: x - width / 2, y: topY - 13, width: width, height: 1)), with: .color(lineC.opacity(dark ? 0.9 : 0.8)))
        }
        header("앱", visibleApps.count, x: L.app.values.first?.x ?? max(76, size.width * 0.1), width: L.appSize.width)
        header("규칙", rules.count + visibleGroups.count, x: size.width * 0.47, width: L.ruleSize.width)
        header("출구", visibleExits.count, x: L.wall.x, width: L.nodeSize.width)

        // 규칙 밖 칸: 목적지 도메인(없으면 IP)마다 하나. 규칙에 없는 연결이 평소 경로로 나간다
        for key in visibleGroups {
            guard let p = L.rule[key] else { continue }
            let w = L.ruleSize.width, h = L.ruleSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            var c = ctx
            c.opacity = dimmed(rule: key, iface: nil) ? NodeToken.dimmed : 1
            let n = stream.liveCount { $0.slot == key }
            drawCard(&c, rect, shape: .outside, tint: nil, state: n > 0 ? .active : .idle, selected: focusRule == key)
            c.draw(Text(Image(systemName: "questionmark.circle")).font(.system(size: 12)).foregroundColor(muted), at: CGPoint(x: rect.minX + 19, y: p.y))
            let room = w - 34 - NodeToken.inset - NodeToken.meter.width - (n > 0 ? 26 : 8)
            c.draw(Text(fit(String(key.dropFirst()), 12.5, .semibold, false, room, .middle)).font(NodeToken.title).foregroundColor(fg.opacity(0.85)),
                   at: CGPoint(x: rect.minX + 34, y: p.y - (h >= 30 ? 6 : 0)), anchor: .leading)
            if h >= 30 {
                let sub = scene.groupLatest[key].flatMap { $0 == String(key.dropFirst()) ? nil : $0 } ?? "규칙 없음"
                c.draw(Text(fit(sub, 10, .regular, false, room, .middle)).font(NodeToken.sub).foregroundColor(muted), at: CGPoint(x: rect.minX + 34, y: p.y + 8), anchor: .leading)
            }
            drawTrail(&c, rect, meter: "r:\(key)", count: n)
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: lineC)
            drawPort(&c, CGPoint(x: rect.maxX, y: p.y), color: lineC)
        }

        // 길 양 끝의 포트: 앱 쪽은 출발 포트(여럿이면 개수), 출구 쪽은 목적지 포트.
        // 한 앱에서 여러 규칙으로, 여러 규칙에서 한 출구로 길이 갈라지면 끝점이 같으므로 끝점마다 모아 한 번만 쓴다.
        var appEnds: [String: (p: CGPoint, flows: [RouteScene.Flow])] = [:]
        var exitEnds: [String: (p: CGPoint, flows: [RouteScene.Flow])] = [:]
        for (_, fs) in scene.bundles {
            let live = fs.filter { $0.closedAt == nil }
            guard let f0 = live.first, let pts = bundlePoints(app: f0.app, slot: f0.slot, iface: f0.iface, L) else { continue }
            if dimmed(rule: f0.slot, iface: f0.iface) { continue }
            appEnds[f0.app, default: (pts.0, [])].flows += live
            exitEnds[f0.iface, default: (pts.3, [])].flows += live
        }
        // 포트는 선 위를 어지럽히므로 마우스를 올린 칸 것만 쓴다
        let portFont = Font.system(size: 10, weight: .medium).monospacedDigit()
        for (app, end) in appEnds where hoverNode == "a:" + app {
            let sports = Set(end.flows.map(\.ev.sport))
            let left = sports.count == 1 ? ":\(sports.first!)" : "\(end.flows.count)개 연결"
            ctx.draw(Text(left).font(portFont).foregroundColor(muted), at: CGPoint(x: end.p.x + 6, y: end.p.y - 8), anchor: .leading)
        }
        for (iface, end) in exitEnds where hoverNode == "x:" + iface {
            let ds = Array(Set(end.flows.map(\.ev.dport))).sorted()
            var text = ds.prefix(3).map { ":\($0)" }.joined(separator: " ") + (ds.count > 3 ? " +\(ds.count - 3)" : "")
            let protos = Set(end.flows.map(\.ev.proto)).sorted()
            text += " " + protos.joined(separator: "/")
            ctx.draw(Text(text).font(portFont).foregroundColor(exitColor(exits.first { $0.iface == iface }).opacity(0.85)),
                     at: CGPoint(x: end.p.x - 6, y: end.p.y - 9), anchor: .trailing)
        }

        // 앱 칸 (출발): 알약
        for a in visibleApps {
            guard let p = L.app[a] else { continue }
            let rect = CGRect(x: p.x - L.appSize.width / 2, y: p.y - L.appSize.height / 2, width: L.appSize.width, height: L.appSize.height)
            let live = stream.liveCount { $0.app == a && !$0.blocked }
            var selected = false
            if case .app(let z)? = zoom { selected = z == a }
            var ctx = ctx
            // 나타날 때: 왼쪽에서 살짝 미끄러지며 짙어진다
            let ap = scene.appeared["a:" + a].map { easeOut(now.timeIntervalSince($0) / RouteScene.appearDuration) } ?? 1
            ctx.opacity = (1 - 0.6 * dimAmt("a:" + a, off("a:" + a))) * ap
            ctx.translateBy(x: -10 * (1 - ap), y: 0)
            drawCard(&ctx, rect, shape: .app, tint: nil, state: live > 0 ? .active : .idle, selected: selected)
            let room = rect.width - 32 - 10 - NodeToken.meter.width - 6
            if let icon = scene.icons[a] {
                ctx.draw(Image(nsImage: icon), in: CGRect(x: rect.minX + 9, y: p.y - 9, width: 18, height: 18))
                label(fit(a, 12, .medium, false, room, .tail), CGPoint(x: rect.minX + 32, y: p.y), fg, NodeToken.appTitle, anchor: .leading)
            } else {
                label(fit(a, 12, .medium, false, room + 22, .tail), CGPoint(x: rect.minX + 12, y: p.y), fg, NodeToken.appTitle, anchor: .leading)
            }
            drawTrail(&ctx, rect, meter: "a:\(a)", count: 0, inset: 10)
            let appC = stream.dests.values.first { $0.app == a && !$0.blocked && !$0.live.isEmpty }.map { d in exitColor(exits.first { $0.iface == d.iface }) }
            drawPort(&ctx, CGPoint(x: rect.maxX, y: p.y), color: appC ?? (live > 0 ? fg.opacity(0.4) : lineC), filled: onPath != nil && !off("a:" + a))
        }
        // 밀려난 앱 칸: 그 자리에서 흐려지며 사라진다
        for (a, lv) in scene.leaving {
            let k = easeOut(now.timeIntervalSince(lv.t0) / RouteScene.leaveDuration)
            let rect = CGRect(x: lv.at.x - L.appSize.width / 2, y: lv.at.y - L.appSize.height / 2, width: L.appSize.width, height: L.appSize.height)
            var c = ctx
            c.opacity = 1 - k
            drawCard(&c, rect, shape: .app, tint: nil, state: .idle, selected: false)
            if let icon = scene.icons[a] { c.draw(Image(nsImage: icon), in: CGRect(x: rect.minX + 9, y: lv.at.y - 9, width: 18, height: 18)) }
            c.draw(Text(a).font(NodeToken.appTitle).foregroundColor(fg), at: CGPoint(x: rect.minX + 32, y: lv.at.y), anchor: .leading)
        }
        if visibleApps.isEmpty && !showsEmptyCard {
            label("연결을 기다리는 중", CGPoint(x: size.width * 0.11, y: size.height / 2), muted, .caption)
        }

        // 규칙 칸 (판단): 번호 동그라미의 색이 지금 보내는 곳
        for (i, r) in rules.enumerated() {
            guard let p = L.rule[r.id] else { continue }
            let w = L.ruleSize.width, h = L.ruleSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            let resting = r.decision == "skip" || r.decision == "system" || r.decision == "next"
            let routeC = exitColor(exits.first { $0.iface == r.chosenIface })
            let accent: Color? = r.decision == "route" ? routeC : r.decision == "block" ? blockC : nil
            let n = stream.liveCount { $0.slot == r.id && !$0.blocked }
            var c = ctx
            c.opacity = lerp(resting ? NodeToken.resting : 1, NodeToken.dimmed, dimAmt("r:" + r.id, dimmed(rule: r.id, iface: r.chosenIface ?? "block") || off("r:" + r.id)))
            drawCard(&c, rect, shape: .rule, tint: nil, state: resting ? .resting : n > 0 ? .active : .idle, selected: focusRule == r.id)
            // 번호 동그라미가 지금 보내는 곳의 색을 띤다 (출구 색 = 보내는 중, 산호색 = 막는 중, 회색 = 쉼)
            let pos = (m.status?.rules.firstIndex { $0.id == r.id } ?? i) + 1
            let bc = CGPoint(x: rect.minX + 19, y: p.y)
            c.fill(Path(ellipseIn: CGRect(x: bc.x - 9, y: bc.y - 9, width: 18, height: 18)), with: .color((accent ?? fg).opacity(accent == nil ? 0.07 : 0.18)))
            c.draw(Text("\(pos)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(accent ?? muted), at: bc)
            let room = w - 34 - NodeToken.inset - NodeToken.meter.width - (n > 0 ? 26 : 8)
            c.draw(Text(fit(r.title, 12.5, .semibold, false, room, .tail)).font(NodeToken.title).foregroundColor(fg),
                   at: CGPoint(x: rect.minX + 34, y: p.y - (h >= 30 ? 6 : 0)), anchor: .leading)
            if h >= 30 {
                // 쉬는 규칙은 대상 대신 쉬는 까닭을 쓴다 ("쉼 · 01:00–05:00", "쉼 · 다음 규칙으로")
                let why: String? = !resting ? nil : r.decision == "skip"
                    ? "쉼 · " + (r.when.flatMap { try? Condition.parse($0) }.map(\.short) ?? "조건 안 맞음")
                    : r.decision == "next" ? "쉼 · 출구 없어 다음 규칙으로" : "쉼 · 출구 없어 평소 경로로"
                c.draw(Text(fit(why ?? r.targets.map(\.target).joined(separator: ", "), 10, .regular, false, room, .tail)).font(NodeToken.sub).foregroundColor(muted),
                       at: CGPoint(x: rect.minX + 34, y: p.y + 8), anchor: .leading)
            }
            drawTrail(&c, rect, meter: r.decision == "block" ? nil : "r:\(r.id)", count: n)
            let hotRule = onPath != nil && !off("r:" + r.id)
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: accent ?? lineC, filled: hotRule && accent != nil)
            drawPort(&c, CGPoint(x: rect.maxX, y: p.y), color: accent?.opacity(0.8) ?? lineC, filled: hotRule && accent != nil)
        }

        // 출구 칸 (도착): 출구 색 바탕
        for e in visibleExits {
            guard let p = L.exit[e.iface] else { continue }
            let w = L.nodeSize.width, h = L.nodeSize.height
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            let col = exitColor(e)
            let down = e.up && e.healthy == false
            let n = stream.liveCount { $0.iface == e.iface && !$0.blocked }
            var c = ctx
            c.opacity = lerp(1, NodeToken.dimmed, dimAmt("x:" + e.iface, dimmed(rule: nil, iface: e.iface) || off("x:" + e.iface)))
            drawCard(&c, rect, shape: .exit, tint: e.up ? col : nil, state: !e.up ? .absent : down ? .warn : n > 0 ? .active : .idle,
                     selected: focusExit == e.iface)
            c.draw(Text(Image(systemName: Exits.symbol(e.name))).font(.system(size: 13, weight: .medium)).foregroundColor(down ? warnC : e.up ? col : muted),
                   at: CGPoint(x: rect.minX + 19, y: p.y))
            let tx = rect.minX + 36
            let eroom = rect.maxX - tx - NodeToken.inset - NodeToken.meter.width - (n > 0 ? 26 : 8)
            c.draw(Text(fit(e.label, 12.5, .semibold, false, eroom, .tail)).font(NodeToken.title).foregroundColor(e.up ? fg : muted), at: CGPoint(x: tx, y: p.y - 7), anchor: .leading)
            // 주의는 색만이 아니라 아이콘과 글로
            let sub = Text(fit(e.up ? (down ? "\(e.iface) · 응답 없음" : e.iface) : "\(e.iface) · 연결 안 됨", 10, .regular, false, eroom - 14, .tail)).font(NodeToken.sub)
            c.draw(down ? (Text(Image(systemName: "exclamationmark.triangle.fill")).font(.system(size: 9)) + Text(" ") + sub).foregroundColor(warnC)
                        : sub.foregroundColor(muted), at: CGPoint(x: tx, y: p.y + 9), anchor: .leading)
            drawTrail(&c, rect, meter: "x:\(e.iface)", count: n)
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: e.up ? col.opacity(0.8) : lineC, filled: onPath != nil && !off("x:" + e.iface) && e.up)
        }
        // 막음 (도착): 출구와 같은 모양, 산호색 점선. 숫자는 최근 60초 동안 막은 횟수
        do {
            let w = L.nodeSize.width, h = L.nodeSize.height, p = L.wall
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            var c = ctx
            c.opacity = lerp(1, NodeToken.dimmed, dimAmt("x:block", dimmed(rule: nil, iface: "block") || off("x:block")))
            drawCard(&c, rect, shape: .wall, tint: blockC, state: .idle, selected: focusExit == "block")
            c.draw(Text(Image(systemName: "nosign")).font(.system(size: 13, weight: .medium)).foregroundColor(blockC), at: CGPoint(x: rect.minX + 19, y: p.y))
            c.draw(Text("막음").font(NodeToken.title).foregroundColor(fg), at: CGPoint(x: rect.minX + 36, y: p.y - 7), anchor: .leading)
            c.draw(Text("최근 60초").font(NodeToken.sub).foregroundColor(muted), at: CGPoint(x: rect.minX + 36, y: p.y + 9), anchor: .leading)
            drawTrail(&c, rect, meter: nil, count: scene.count("x:block"))
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: blockC.opacity(0.8), filled: onPath != nil && !off("x:block"))
        }
    }

    /// 앞 층 (매 프레임): 규칙 칸 반짝임, 캡슐, 파편
    private func drawFront(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = animatedLayout(size, now: now)
        drawPulses(&ctx, L, now: now, rings: true)
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
        // 칸은 번쩍이지 않는다: 선 굵기·진하기와 칸 안의 트래픽 칸으로만 보여 준다
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
        if zoom != nil || selection != nil { showAll() }       // 빈 곳을 누르면 전체로
    }

    // MARK: 연결 목록 (Little Snitch 의 Connections 처럼: 앱 ▸ 목적지, 줄마다 출구와 오간 양)

    struct MonitorNode: Identifiable {
        enum Kind { case app(String), dest(String), exit(String), rule(String) }
        let id: String
        let title: String
        let kind: Kind
        var bytes = 0
        var live = 0
        var blocked = false
        var exitKey: String? = nil            // 인터페이스 또는 "block": 오른쪽 출구 꼬리표
        var last = 0
        var children: [MonitorNode]? = nil
    }

    private func hostOf(_ d: EventStream.DestStat) -> String {
        if d.outside { return names.name(d.dst) ?? d.dst }
        let r = m.status?.rules.first { $0.id == d.rule }
        return r?.targets.first { t in t.target == d.dst || t.addresses.contains { $0.ip == d.dst } }?.target ?? d.dst
    }
    private func exitTitle(_ key: String) -> String {
        key == "block" ? "막음" : exits.first { $0.iface == key }.map { "\($0.label) · \(key)" } ?? key
    }
    private func ruleTitle(_ slot: String) -> String {
        if slot.hasPrefix("~") { return "규칙 없음 · \(slot.dropFirst())" }
        guard let s = m.status, let i = s.rules.firstIndex(where: { $0.id == slot }) else { return slot }
        return "\(i + 1). \(s.rules[i].title)"
    }

    private var nodes: [MonitorNode] {
        _ = stream.statsStamp
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = stream.dests.values.filter { d in q.isEmpty || [d.app, hostOf(d), d.dst].contains { $0.lowercased().contains(q) } }
        func destNode(_ d: EventStream.DestStat) -> MonitorNode {
            MonitorNode(id: "d:" + d.id, title: "\(hostOf(d)):\(d.dport)", kind: .dest(d.id), bytes: d.bytesOut + d.bytesIn,
                        live: d.live.count, blocked: d.blocked, exitKey: d.blocked ? "block" : d.iface, last: d.last)
        }
        func group(_ id: String, _ title: String, _ kind: MonitorNode.Kind, _ ds: [EventStream.DestStat], exitKey: String? = nil,
                   children: [MonitorNode]?) -> MonitorNode {
            MonitorNode(id: id, title: title, kind: kind, bytes: ds.reduce(0) { $0 + $1.bytesOut + $1.bytesIn },
                        live: ds.reduce(0) { $0 + $1.live.count }, blocked: ds.allSatisfy(\.blocked), exitKey: exitKey,
                        last: ds.map(\.last).max() ?? 0, children: children)
        }
        func appsUnder(_ prefix: String, _ ds: [EventStream.DestStat], exitKey: String?) -> [MonitorNode] {
            Dictionary(grouping: ds, by: \.app).map { app, xs in group("\(prefix)|\(app)", app, .app(app), xs, exitKey: exitKey, children: nil) }
                .sorted(by: Self.stableOrder)
        }
        switch groupBy {
        case .app:
            return Dictionary(grouping: all, by: \.app).map { app, ds in
                group("a:" + app, app, .app(app), ds, children: ds.map(destNode).sorted(by: Self.stableOrder))
            }.sorted(by: Self.stableOrder)
        case .exit:
            return Dictionary(grouping: all, by: { $0.blocked ? "block" : $0.iface }).map { key, ds in
                group("x:" + key, exitTitle(key), .exit(key), ds, exitKey: key, children: appsUnder("xa:" + key, ds, exitKey: key))
            }.sorted { ($0.exitKey == "block" ? 1 : 0, $0.title) < ($1.exitKey == "block" ? 1 : 0, $1.title) }
        case .rule:
            let order = (m.status?.rules ?? []).map(\.id)
            return Dictionary(grouping: all, by: \.slot).map { slot, ds in
                group("r:" + slot, ruleTitle(slot), .rule(slot), ds, children: appsUnder("ra:" + slot, ds, exitKey: nil))
            }.sorted { (order.firstIndex(of: String($0.id.dropFirst(2))) ?? 99) < (order.firstIndex(of: String($1.id.dropFirst(2))) ?? 99) }
        }
    }

    /// 줄 순서는 이름으로 고정한다 (최근 활동 순이면 1초마다 줄이 자리를 바꿔 어지러웠다). 막힌 것만 아래로.
    static func stableOrder(_ a: MonitorNode, _ b: MonitorNode) -> Bool {
        (a.blocked ? 1 : 0, a.title.localizedLowercase) < (b.blocked ? 1 : 0, b.title.localizedLowercase)
    }

    private var connectionList: some View {
        let ns = nodes
        let peak = max(1, ns.map(\.bytes).max() ?? 1)
        return List(ns, children: \.children, selection: $selection) { n in
            nodeRow(n, peak: peak)
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "앱·목적지 검색")
        .overlay {
            if ns.isEmpty {
                ContentUnavailableView(search.isEmpty ? "아직 연결 없음" : "결과 없음", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(search.isEmpty ? (stream.allTraffic ? "새 연결이 생기면 보여요" : "규칙 대상 연결이 생기면 보여요") : ""))
            }
        }
    }

    @ViewBuilder private func nodeRow(_ n: MonitorNode, peak: Int) -> some View {
        HStack(spacing: 7) {
            nodeIcon(n)
            Text(n.title).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(n.blocked ? blockC : Color.primary)
            Spacer(minLength: 4)
            if case .dest = n.kind, let k = n.exitKey { exitTag(k) }
            if !n.blocked {
                // Little Snitch 처럼 줄마다 작은 트래픽 칸 (위 보냄, 아래 받음)
                MiniMeter(bins: stream.meter(meterKey(n)), peak: stream.meterPeak, sent: sentC, recv: recvC, track: Color.primary.opacity(0.08))
                    .frame(width: 26, height: 14)
            }
            Text(n.bytes > 0 ? RouteScene.bytesText(n.bytes) : n.blocked ? "막음" : "")
                .font(.caption.monospacedDigit()).foregroundStyle(n.blocked ? blockC : Color.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .help(n.live > 0 ? "열린 연결 \(n.live)개" : "")
    }

    private func meterKey(_ n: MonitorNode) -> String {
        switch n.kind {
        case .app(let a): return "a:" + a
        case .dest(let k): return "d:" + k
        case .exit(let k): return "x:" + k
        case .rule(let r): return "r:" + r
        }
    }

    @ViewBuilder private func nodeIcon(_ n: MonitorNode) -> some View {
        switch n.kind {
        case .app(let a):
            if let icon = stream.scene.icons[a] { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            else { Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 16) }
        case .dest:
            Image(systemName: n.live > 0 ? "circle.fill" : "circle").font(.system(size: 6)).foregroundStyle(.secondary).frame(width: 16)
        case .exit(let k):
            Image(systemName: k == "block" ? "nosign" : Exits.symbol(exits.first { $0.iface == k }?.name ?? "wifi"))
                .foregroundStyle(k == "block" ? blockC : exitColor(exits.first { $0.iface == k })).frame(width: 16)
        case .rule(let r):
            Image(systemName: r.hasPrefix("~") ? "questionmark.circle" : "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
        }
    }

    /// 점 + 출구 이름 ("● Wi-Fi", "● 막음")
    private func exitTag(_ key: String) -> some View {
        let e = exits.first { $0.iface == key }
        let c = key == "block" ? blockC : exitColor(e)
        return HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(key == "block" ? "막음" : e?.label ?? key).font(.caption).foregroundStyle(key == "block" ? blockC : Color.secondary)
        }
    }

    // MARK: 트래픽 막대 (최근 10분: 보낸 양은 위, 받은 양은 아래, 막힘은 산호색 점. 끌어서 그 시각부터 다시 보기)

    private var trafficChart: some View {
        _ = stream.statsStamp
        let count = 60
        let nowBin = Int(Date().timeIntervalSince1970) / 10
        let data = (0..<count).map { stream.bins[nowBin - count + 1 + $0] ?? EventStream.Bin() }
        let peak = max(1, data.map { max($0.out, $0.inn) }.max() ?? 1)
        let sent = data.reduce(0) { $0 + $1.out }, recv = data.reduce(0) { $0 + $1.inn }
        let nowMs = Double(Date().timeIntervalSince1970 * 1000)
        let span = EventStream.keep * 1000
        let startMs = nowMs - span
        let sentC = self.sentC, recvC = self.recvC
        func pill(_ symbol: String, _ title: String, _ value: Int, _ c: Color) -> some View {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(c)
                Text(title).foregroundStyle(c)
                Spacer(minLength: 4)
                Text(RouteScene.bytesText(value)).foregroundStyle(.primary)
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.opacity(0.14)))
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                pill("arrow.up", "보냄", sent, sentC)
                pill("arrow.down", "받음", recv, recvC)
            }
            GeometryReader { g in
                Canvas { ctx, size in
                    let mid = size.height / 2, bw = size.width / CGFloat(count)
                    for (i, b) in data.enumerated() {
                        let x = CGFloat(i) * bw + 1, w = max(1, bw - 2)
                        // 칸마다 옅은 바탕 (Little Snitch 처럼 빈 시간도 칸으로 보인다)
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height - 6), cornerRadius: 1), with: .color(.primary.opacity(0.05)))
                        if b.out > 0 {
                            let h = max(1.5, CGFloat(b.out) / CGFloat(peak) * (mid - 3))
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - 1 - h, width: w, height: h), cornerRadius: 1), with: .color(sentC))
                        }
                        if b.inn > 0 {
                            let h = max(1.5, CGFloat(b.inn) / CGFloat(peak) * (mid - 3))
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: mid + 1, width: w, height: h), cornerRadius: 1), with: .color(recvC))
                        }
                        if b.blocked > 0 {
                            ctx.fill(Path(ellipseIn: CGRect(x: x + w / 2 - 2, y: size.height - 4, width: 4, height: 4)), with: .color(blockC))
                        }
                    }
                    func xFor(_ t: Double) -> CGFloat { CGFloat((t - startMs) / span) * size.width }
                    if let c = cursor {
                        let x = xFor(c)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.primary), lineWidth: 1.5)
                    }
                    if let rc = stream.replayCursor {
                        let x = xFor(Double(rc))
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(warnC), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    cursor = startMs + Double(min(1, max(0, v.location.x / g.size.width))) * span
                })
            }
            .frame(height: 64)
            .help("끌어서 시각을 고르면 그때부터 다시 볼 수 있어요")
            if cursor != nil || stream.replaying {
                HStack(spacing: 8) {
                    Text(timeString(Int(cursor ?? Double(stream.replayCursor ?? 0)))).font(.caption.monospacedDigit())
                    Spacer()
                    Menu {
                        Picker("빠르기", selection: $speed) { Text("1×").tag(1.0); Text("4×").tag(4.0); Text("16×").tag(16.0) }
                            .pickerStyle(.inline)
                    } label: { Text("\(Int(speed))×").font(.caption.monospacedDigit()) }
                    .menuStyle(.borderlessButton).fixedSize().help("다시 보기 빠르기")
                    Button { if let c = cursor { stream.replay(from: Int(c), speed: speed) } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).disabled(cursor == nil).help("여기서부터 다시 보기")
                    Button { stream.goLive(); cursor = nil } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(.borderless).help("실시간으로")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
    }

    // MARK: 인스펙터 (고른 줄의 규칙·출구·이유·오간 양)

    @ViewBuilder private var inspectorPane: some View {
        let _ = stream.statsStamp
        let sel = selection ?? ""
        let body = String(sel.drop { $0 != ":" }.dropFirst())
        Form {
            switch sel.prefix(while: { $0 != ":" }) {
            case "d":
                if let d = stream.dests[body] { destInspector(d) } else { overviewInspector }
            case "a":
                appInspector(body, stream.dests.values.filter { $0.app == body })
            case "xa", "ra":
                let p = body.split(separator: "|", maxSplits: 1).map(String.init)
                if p.count == 2 {
                    appInspector(p[1], stream.dests.values.filter { $0.app == p[1] && (sel.hasPrefix("xa") ? ($0.blocked ? "block" : $0.iface) == p[0] : $0.slot == p[0]) })
                }
            case "x":
                exitInspector(body)
            case "r":
                ruleInspector(body)
            default:
                overviewInspector
            }
        }
        .formStyle(.grouped)
    }

    private func appIcon(_ app: String, size: CGFloat) -> some View {
        Group {
            if let icon = stream.scene.icons[app] { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }

    private func inspectorHeader(_ title: String, _ subtitle: String, icon: some View) -> some View {
        Section {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func trafficSection(_ ds: [EventStream.DestStat]) -> some View {
        Section("오간 양 · 최근 10분") {
            LabeledContent("열린 연결", value: "\(ds.reduce(0) { $0 + $1.live.count })")
            LabeledContent("보냄", value: RouteScene.bytesText(ds.reduce(0) { $0 + $1.bytesOut }))
            LabeledContent("받음", value: RouteScene.bytesText(ds.reduce(0) { $0 + $1.bytesIn }))
            if let last = ds.map(\.last).max() { LabeledContent("마지막", value: timeString(last)) }
        }
    }

    @ViewBuilder private func destInspector(_ d: EventStream.DestStat) -> some View {
        inspectorHeader(hostOf(d), d.app, icon: appIcon(d.app, size: 32))
        Section {
            LabeledContent("주소", value: "\(d.dst):\(d.dport) \(d.proto)")
            LabeledContent("규칙", value: ruleTitle(d.slot))
            LabeledContent("결과") { exitTag(d.blocked ? "block" : d.iface) }
            if let r = m.status?.rules.first(where: { $0.id == d.rule }), !d.outside {
                LabeledContent("출구 순위", value: r.exitsText)
                if !r.reason.isEmpty { LabeledContent("이유", value: r.reason) }
            }
        }
        trafficSection([d])
        Section {
            if d.outside {
                Button("이 목적지로 규칙 만들기…") { makeRule(from: d.slot) }
            } else if let id = d.rule {
                Button("규칙 편집…") { m.windowSelection = "rule:" + id; NSApp.activate(); openWindow(id: "rules") }
            }
        }
    }

    @ViewBuilder private func appInspector(_ app: String, _ ds: [EventStream.DestStat]) -> some View {
        inspectorHeader(app, ds.first?.exe ?? "", icon: appIcon(app, size: 32))
        trafficSection(ds)
        Section("규칙과 출구") {
            let bySlot = Dictionary(grouping: ds, by: \.slot)
            ForEach(bySlot.keys.sorted(), id: \.self) { slot in
                let xs = bySlot[slot] ?? []
                LabeledContent(ruleTitle(slot)) { exitTag(xs.contains { !$0.blocked } ? (xs.first { !$0.blocked }?.iface ?? "block") : "block") }
            }
        }
    }

    @ViewBuilder private func exitInspector(_ key: String) -> some View {
        let ds = stream.dests.values.filter { ($0.blocked ? "block" : $0.iface) == key }
        if key == "block" {
            inspectorHeader("막음", "쓸 수 있는 출구가 없거나 다른 출구로 나가려던 연결", icon: Image(systemName: "nosign").font(.title2).foregroundStyle(blockC))
        } else {
            let e = exits.first { $0.iface == key }
            inspectorHeader(e?.label ?? key, [key, e?.ip ?? "", e?.healthy == false ? "응답 없음" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: Image(systemName: Exits.symbol(e?.name ?? "wifi")).font(.title2).foregroundStyle(exitColor(e)))
        }
        trafficSection(ds)
        Section("앱") {
            ForEach(Array(Set(ds.map(\.app))).sorted(), id: \.self) { a in
                Label { Text(a) } icon: { appIcon(a, size: 16) }
            }
        }
    }

    @ViewBuilder private func ruleInspector(_ slot: String) -> some View {
        let ds = stream.dests.values.filter { $0.slot == slot }
        if let r = m.status?.rules.first(where: { $0.id == slot }) {
            inspectorHeader(r.title, r.targets.map(\.target).joined(separator: ", "), icon: Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.secondary))
            Section {
                LabeledContent("출구 순위", value: r.exitsText)
                LabeledContent("지금", value: r.nowText)
                if !r.reason.isEmpty { LabeledContent("이유", value: r.reason) }
                Button("규칙 편집…") { m.windowSelection = "rule:" + r.id; NSApp.activate(); openWindow(id: "rules") }
            }
        } else {
            inspectorHeader(ruleTitle(slot), "규칙에 없는 연결", icon: Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary))
            Section { Button("이 목적지로 규칙 만들기…") { makeRule(from: slot) } }
        }
        trafficSection(ds)
    }

    /// 아무것도 고르지 않았을 때: 출구마다 지금 몇 개가 얼마나 나갔는지
    @ViewBuilder private var overviewInspector: some View {
        let all = Array(stream.dests.values)
        inspectorHeader("지금", "최근 10분 · 목록에서 고르면 자세히 보여요", icon: Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.secondary))
        Section("출구") {
            ForEach(exits, id: \.iface) { e in
                let ds = all.filter { !$0.blocked && $0.iface == e.iface }
                LabeledContent {
                    Text(ds.isEmpty ? "—" : "\(ds.reduce(0) { $0 + $1.live.count })개 · \(RouteScene.bytesText(ds.reduce(0) { $0 + $1.bytesOut + $1.bytesIn }))")
                        .monospacedDigit()
                } label: { exitTag(e.iface) }
            }
            let blocked = all.filter(\.blocked)
            LabeledContent { Text(blocked.isEmpty ? "—" : "\(blocked.reduce(0) { $0 + $1.opens })번").monospacedDigit() } label: { exitTag("block") }
        }
    }

    private func timeString(_ t: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t) / 1000))
    }
}


/// 캔버스 글자를 너비에 맞게 줄인다 (줄임표). 매 프레임 그리므로 결과를 기억해 둔다.
@MainActor
enum TextFit {
    enum Mode { case tail, middle }
    private static var cache: [String: String] = [:]

    static func fit(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ mono: Bool, _ maxW: CGFloat, _ mode: Mode) -> String {
        let key = "\(s)|\(size)|\(weight.rawValue)|\(mono)|\(Int(maxW))|\(mode)"
        if let hit = cache[key] { return hit }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        var out = s
        if maxW > 8, width(s) > maxW {
            let chars = Array(s)
            var lo = 0, hi = chars.count               // 남길 글자 수를 이분 탐색
            func make(_ k: Int) -> String {
                switch mode {
                case .tail: return String(chars.prefix(k)) + "…"
                case .middle:
                    let head = (k + 1) / 2, tail = k / 2
                    return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
                }
            }
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if width(make(mid)) <= maxW { lo = mid } else { hi = mid - 1 }
            }
            out = make(lo)
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = out
        return out
    }
}
