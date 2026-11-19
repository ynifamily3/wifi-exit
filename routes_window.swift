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
        var row = ""                             // 흐름도 오른쪽의 목적지 줄 (RouteScene.row(for:))
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
    // w:목적지 줄, ax:앱|출구(앱 → 출구 선), wx:줄|출구(출구 → 목적지 선), b:앱|줄|출구(연결 길)
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
                                      row: scene.row(for: e), first: e.t, last: e.t)
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
                for k in ["a:\(d.app)", "d:\(key)", "r:\(d.slot)", "x:\(d.iface)", "w:\(d.row)", "ax:\(d.app)|\(d.iface)",
                          "wx:\(d.row)|\(d.iface)", "b:\(d.app)|\(d.row)|\(d.iface)"] {
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
        let liveRows = Set(dests.values.filter { !$0.live.isEmpty }.map(\.row))
        if scene.pruneGroups(olderThan: 90, keep: liveRows) { animating = true }
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

    /// 규칙을 처음 받거나 바뀌면 규칙 대상 표를 새로 하고, 이미 본 연결의 목적지 줄을 다시 맞춘다
    /// (규칙보다 연결이 먼저 오면 모두 "그 밖의 주소"로 갔다)
    func setRules(_ rules: [RuleStatus]) {
        scene.setRules(rules)
        for (k, f) in scene.flows where f.ev.outside != true {
            let r = scene.row(rule: f.ev.rule, dst: f.ev.dst)
            if r != f.row { scene.flows[k]?.row = r }
        }
        for (k, d) in dests where !d.outside {
            let r = scene.row(rule: d.rule, dst: d.dst)
            if r != d.row { dests[k]?.row = r }
        }
        animating = true
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
        var row = ""                     // 닿는 목적지 줄
        var dir = 0                      // 0 = 막힌 연결(규칙까지 가서 부서짐), 1 = 나가는 패킷, -1 = 들어오는 패킷
        var info = ""                    // 마우스를 올렸을 때 덧붙일 말 ("나감 3패킷 · 4.1KB")
    }

    /// 수립된 연결 하나. 같은 (앱, 칸, 출구)의 연결들은 길 하나를 같이 쓴다.
    struct Flow {
        var key: String
        var app: String
        var slot: String
        var row: String                      // 흐름도 오른쪽의 목적지 줄
        var iface: String
        var ev: ConnEvent
        var opened: Date
        var closedAt: Date?
        var bundle: String { "\(app)|\(row)|\(iface)" }
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

    /// 같은 (앱, 목적지 줄, 출구)를 쓰는 연결들 → 길 하나
    var bundles: [String: [Flow]] { Dictionary(grouping: flows.values, by: \.bundle) }

    func saveLiveFlows() { savedFlows = flows; flows.removeAll(); pending.removeAll() }
    func restoreLiveFlows() { if let s = savedFlows { flows = s }; savedFlows = nil; pending.removeAll() }

    /// 패킷 수 → 보낼 캡슐 수. 한 개라도 있으면 1개, 많아도 4개까지 (로그 눈금).
    static func sample(_ n: Int) -> Int { n <= 0 ? 0 : min(4, 1 + Int(log2(Double(n)))) }

    static func bytesText(_ b: Int) -> String { b >= 1_048_576 ? String(format: "%.1fMB", Double(b) / 1_048_576) : b >= 1024 ? String(format: "%.1fKB", Double(b) / 1024) : "\(b)B" }
    var sparks: [Spark] = []
    var heat: [String: Double] = [:]          // "r:<규칙>" / "a:<앱>|<규칙>" → 0…1.5
    var hits: [(Date, String)] = []           // 최근 60초 지나간 것 (규칙·출구·줄 숫자)
    var blockPairs: [String: Date] = [:]      // "앱|줄" → 마지막으로 막힌 때 (막힌 길 강조용)
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
        let toRow = outsideGroups.contains(to) ? to : "~+"
        for (k, f) in flows where f.slot == from { flows[k]?.slot = to; flows[k]?.row = f.row == from ? toRow : f.row }
        for (k, v) in heat where k.hasPrefix("o:\(from)|") { heat[k] = nil; heat["o:\(to)|" + k.split(separator: "|").last!] = v }
        for (k, v) in flash where k == "r:\(from)" { flash[k] = nil; flash["r:\(to)"] = v }
        hits = hits.map { $0.1 == "r:\(from)" ? ($0.0, "r:\(to)") : $0 }
    }

    /// 사건이 지나갈 칸
    func slot(for e: ConnEvent) -> String {
        guard e.outside == true else { return e.rule ?? "?" }
        return "~" + (nameFor(e.dst).map(Self.registrable) ?? e.dst)
    }

    // MARK: 목적지 줄
    // 오른쪽 기둥은 규칙마다 묶음 하나, 묶음 안에 대상(도메인·IP·대역)마다 줄 하나. 규칙 밖 연결은 "규칙 없음" 묶음에
    // 목적지(등록 도메인, 없으면 IP)마다 줄 하나. 줄 열쇠: "t:<규칙>|<대상>", 넘친 대상 "t:<규칙>|+", 규칙 밖 "~<목적지>", 넘친 목적지 "~+"
    struct RuleTargets { var targets: [(target: String, kind: TargetKind, ips: Set<String>)] }
    var ruleTargets: [String: RuleTargets] = [:]
    static let targetCap = 5                    // 규칙 묶음마다 보여 줄 대상 줄 (나머지는 "그 밖의 대상" 한 줄)

    func setRules(_ rules: [RuleStatus]) {
        var out: [String: RuleTargets] = [:]
        for r in rules { out[r.id] = RuleTargets(targets: r.targets.map { ($0.target, $0.kind, Set($0.addresses.map(\.ip))) }) }
        ruleTargets = out
    }

    /// 사건이 닿는 목적지 줄
    func row(for e: ConnEvent) -> String {
        if e.outside == true {
            let s = slot(for: e)
            return outsideGroups.contains(s) || outsideGroups.count < Self.maxGroups ? s : "~+"
        }
        return row(rule: e.rule, dst: e.dst)
    }

    /// 규칙 대상 줄: 그 규칙의 대상 중 이 주소를 맡은 것 (도메인은 풀린 주소, 대역은 포함)
    func row(rule: String?, dst: String) -> String {
        guard let id = rule else { return "t:?|+" }
        guard let ts = ruleTargets[id]?.targets,
              let i = ts.firstIndex(where: { $0.ips.contains(dst) || ($0.kind == .cidr && targetCovered(dst, by: $0.target)) })
        else { return "t:\(id)|+" }
        return i < Self.targetCap ? "t:\(id)|\(ts[i].target)" : "t:\(id)|+"
    }

    /// 줄 열쇠 → 묶음 열쇠 (규칙 id, 규칙 밖이면 "~")
    static func group(ofRow r: String) -> String {
        if r.hasPrefix("~") { return "~" }
        return String(r.dropFirst(2).prefix { $0 != "|" })
    }
    /// 줄 열쇠 → 칸(slot): 규칙 id, 또는 규칙 밖 "~목적지"
    static func slot(ofRow r: String) -> String { r.hasPrefix("~") ? r : group(ofRow: r) }

    /// 3분(또는 age) 넘게 연결이 없는 규칙 밖 목적지 줄을 뺀다 (자리는 다음 정리 때 메운다)
    func pruneGroups(olderThan age: TimeInterval, keep: Set<String>, now: Date = Date()) -> Bool {
        let stale = outsideGroups.filter { !keep.contains($0) && now.timeIntervalSince(groupSeen[$0] ?? .distantPast) > age }
        guard !stale.isEmpty else { return false }
        outsideGroups.removeAll { stale.contains($0) }
        for g in stale { groupExits[g] = nil }
        moving = true
        return true
    }

    // MARK: 붙박이 자리
    // 칸은 한 번 놓이면 그 자리에 머문다. 새 앱은 이어진 출구들의 높이 근처 빈자리에 들어가고, 다른 칸은 움직이지 않는다.
    // 빠진 칸의 빈자리와 어긋난 순서는 마우스를 올리지 않은 조용한 때에 한꺼번에 정리한다 (arrangeGap 마다 한 번까지).
    var appY: [String: CGFloat] = [:]
    var exitY: [String: CGFloat] = [:]          // 인터페이스(또는 "block") → 높이
    var appExits: [String: [String: Date]] = [:] // 앱 → 쓴 출구(또는 "block") → 마지막으로 본 때
    var lastArrange = Date.distantPast
    var arrangedKey = ""                        // 정리할 때의 보이는 출구·묶음 (바뀌면 출구 자리를 바로 다시 잡는다)
    var interacting = false                     // 마우스를 올렸거나 팝오버가 열려 있으면 정리하지 않는다
    static let arrangeGap = 8.0

    /// 칸들을 바라는 높이(이어진 칸들의 평균) 순으로 세우고, 간격을 지키며 바라는 높이에서 가장 덜 벗어나게 둔다:
    /// 겹치는 이웃끼리 덩어리로 묶어 덩어리 가운데를 평균에 맞춘다. keepOrder 면 주어진 순서를 바꾸지 않는다.
    static func place(_ ids: [String], want: [String: CGFloat], gap: CGFloat, top: CGFloat, keepOrder: Bool = false,
                      current: [String: CGFloat] = [:]) -> [String: CGFloat] {
        var order = ids
        if !keepOrder {
            // 바라는 높이가 반 칸 안쪽으로 비슷하면 지금 순서를 지킨다 (칸이 왔다 갔다 흔들리지 않게)
            let band = gap / 2
            order = ids.enumerated().sorted { a, b in
                let wa = want[a.element].map { ($0 / band).rounded(.down) } ?? .greatestFiniteMagnitude
                let wb = want[b.element].map { ($0 / band).rounded(.down) } ?? .greatestFiniteMagnitude
                if wa != wb { return wa < wb }
                let ca = current[a.element] ?? .greatestFiniteMagnitude, cb = current[b.element] ?? .greatestFiniteMagnitude
                return ca != cb ? ca < cb : a.offset < b.offset
            }.map(\.element)
        }
        var clusters: [(ids: [String], top: CGFloat)] = []
        for id in order {
            let fallback = clusters.last.map { $0.top + CGFloat($0.ids.count) * gap } ?? top
            var c = (ids: [id], top: want[id] ?? fallback)
            while let last = clusters.last, last.top + CGFloat(last.ids.count) * gap > c.top {
                clusters.removeLast()
                let merged = last.ids + c.ids
                let tops = merged.enumerated().map { (want[$0.element] ?? (last.top + CGFloat($0.offset) * gap)) - CGFloat($0.offset) * gap }
                c = (ids: merged, top: tops.reduce(0, +) / CGFloat(tops.count))
            }
            clusters.append(c)
        }
        var out: [String: CGFloat] = [:]
        var floor = top
        for c in clusters {
            let t = max(c.top, floor)
            for (i, id) in c.ids.enumerated() { out[id] = t + CGFloat(i) * gap }
            floor = t + CGFloat(c.ids.count) * gap
        }
        return out
    }

    /// 앱이 바라는 높이: 최근 1분에 쓴 출구들의 높이 평균 (없으면 지금까지 쓴 출구 전부)
    func appWant(_ app: String, now: Date = Date()) -> CGFloat? {
        let used = appExits[app] ?? [:]
        let recent = used.filter { now.timeIntervalSince($0.value) < 60 }.map(\.key)
        let ys = (recent.isEmpty ? Array(used.keys) : recent).compactMap { exitY[$0] }
        return ys.isEmpty ? nil : ys.reduce(0, +) / CGFloat(ys.count)
    }

    /// 보이는 칸에 자리를 준다. exitWant: 출구마다 바라는 높이 (이어진 목적지 줄들의 평균), exits: 바라는 높이가 같을 때의 순서
    var arrangedZoom = ""
    func arrange(apps: [String], exits: [String], exitWant: [String: CGFloat], key: String, zoomKey: String, top: CGFloat,
                 appGap: CGFloat, exitGap: CGFloat, now: Date = Date()) {
        let quiet = !interacting && now.timeIntervalSince(lastArrange) >= Self.arrangeGap
        let exitsChanged = key != arrangedKey || exits.contains { exitY[$0] == nil }
        if exitsChanged || quiet {
            // 출구도 이어진 묶음의 높이 순으로 (규칙 순서와 출구 순서가 달라 선이 엇갈리지 않게). 이어진 것이 없는 출구는 아래로
            let next = Self.place(exits, want: exitWant, gap: exitGap, top: top, current: exitY)
            if next.contains(where: { abs((exitY[$0.key] ?? -999) - $0.value) > 1 }) { exitY = next; moving = true }
            arrangedKey = key
        }
        // 빠진 앱의 자리는 비워 둔다 (다른 칸을 당기지 않는다)
        appY = appY.filter { apps.contains($0.key) }
        let zoomChanged = zoomKey != arrangedZoom
        if zoomChanged || quiet {
            arrangedZoom = zoomKey
            let want = Dictionary(uniqueKeysWithValues: apps.compactMap { a in appWant(a, now: now).map { (a, $0) } })
            let next = Self.place(apps, want: want, gap: appGap, top: top, current: appY)
            if next.contains(where: { abs((appY[$0.key] ?? -999) - $0.value) > 1 }) { appY = next; moving = true }
            lastArrange = now
            return
        }
        // 새 앱: 바라는 높이에서 가장 가까운 빈자리 (위아래로 번갈아 찾는다)
        for a in apps where appY[a] == nil {
            let w = max(top, appWant(a, now: now) ?? (appY.values.max().map { $0 + appGap } ?? top))
            var y = w
            for i in 0..<400 {
                let d = CGFloat((i + 1) / 2) * 4 * (i % 2 == 0 ? 1 : -1)
                let cand = w + d
                if cand >= top, !appY.values.contains(where: { abs($0 - cand) < appGap - 0.5 }) { y = cand; break }
            }
            appY[a] = y
            moving = true
        }
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
            // 앱 칸은 밀어내지 않는다: 오래 조용한 앱만 pruneApps 가 뺀다 (예전에는 8번째 앱이 오면 가장 오래된 앱이 빠져 칸이 자꾸 바뀌었다)
            apps.append(app)
            if !reduceMotion { appeared["a:" + app] = Date(); moving = true }
        }
        appExits[app, default: [:]][e.act == "block" ? "block" : e.iface] = Date()
        let slot = slot(for: e)
        let row = row(for: e)
        if e.outside == true {
            groupSeen[slot] = Date()
            groupLatest[slot] = nameFor(e.dst) ?? e.dst
            var ips = groupIPs[slot] ?? []
            if !ips.contains(e.dst) { ips.append(e.dst); if ips.count > 20 { ips.removeFirst() } }
            groupIPs[slot] = ips
            // 목적지 줄도 밀어내지 않는다: 자리가 차면 "그 밖의 목적지" 한 줄로 모으고, 조용한 줄은 pruneGroups 가 뺀다
            if !outsideGroups.contains(slot), outsideGroups.count < Self.maxGroups { outsideGroups.append(slot) }
        }
        // 수립된 연결 = 길을 만든다 (캡슐은 패킷이 오갈 때)
        if e.act == "pass" {
            if flows[e.flowKey]?.closedAt != nil { return }      // 이미 닫힌 연결에 늦게 온 열림
            let f = Flow(key: e.flowKey, app: app, slot: slot, row: row, iface: e.iface, ev: e, opened: Date(), closedAt: nil)
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
            var c = Cap(ev: e, app: app, t0: Date()); c.slot = slot; c.row = row; land(c)
            if e.act == "block" { addPulse("blk:\(app)|\(row)", dir: 1) }
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
            let nf = Flow(key: e.flowKey, app: Self.appLabel(e), slot: slot(for: e), row: row(for: e), iface: e.iface, ev: e, opened: Date(), closedAt: nil)
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
        let now0 = Date()
        if c.ev.outside == true {
            let k = "o:\(rule)|\(c.ev.iface)"
            heat[k] = min(1.5, (heat[k] ?? 0) + 0.5)
            groupExits[rule, default: []].insert(c.ev.iface)
        }
        heat["r:\(rule)"] = min(1.5, (heat["r:\(rule)"] ?? 0) + 0.5)
        heat["a:\(c.app)|\(rule)"] = min(1.5, (heat["a:\(c.app)|\(rule)"] ?? 0) + 0.6)
        if c.ev.act == "block" {
            let row = c.row.isEmpty ? row(for: c.ev) : c.row
            heat["ab:\(c.app)"] = min(1.5, (heat["ab:\(c.app)"] ?? 0) + 0.6)       // 앱 → 막음
            heat["wb:\(row)"] = min(1.5, (heat["wb:\(row)"] ?? 0) + 0.6)            // 막음 → 목적지 줄
            hits.append((now0, "w:\(row)"))
            blockPairs["\(c.app)|\(row)"] = now0
        }
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
        if !blockPairs.isEmpty { blockPairs = blockPairs.filter { now.timeIntervalSince($0.value) < 60 } }
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

/// 흐름도에서 강조할 경로: 앱·목적지 줄·규칙 묶음·출구 중 정한 것만 맞춰 본다 (nil = 아무거나)
struct PathFocus: Equatable {
    var app: String? = nil
    var row: String? = nil
    var group: String? = nil          // 규칙 id, 또는 규칙 밖 "~"
    var iface: String? = nil          // 출구 인터페이스, 또는 "block"
    func matches(app a: String, row r: String, iface x: String) -> Bool {
        (app == nil || app == a) && (row == nil || row == r) && (group == nil || group == RouteScene.group(ofRow: r)) && (iface == nil || iface == x)
    }
}

/// 강조한 경로가 지나는 칸과 선
struct FocusSets {
    var nodes = Set<String>()         // "a:앱", "x:출구", "w:줄", "g:묶음"
    var appExit = Set<String>()       // "앱|출구"
    var exitRow = Set<String>()       // "줄|출구"
}

/// 오른쪽 기둥의 목적지 줄 하나
struct DiagramRow {
    let key: String                   // RouteScene.row(for:) 와 같은 열쇠
    let slot: String                  // 규칙 id, 또는 규칙 밖 "~목적지"
    let title: String
    let sub: String
    let ips: [String]                 // 나라 표시·규칙 만들기에 쓰는 주소
    var more = false                  // "그 밖의 …" 줄
}
/// 규칙 하나(또는 규칙 밖)의 묶음
struct DiagramGroup {
    let key: String                   // 규칙 id, 또는 "~"
    let rule: RuleStatus?
    let rows: [DiagramRow]
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


/// 흐름도 배치 (위에서부터 쌓는다: 칸이 늘거나 줄어도 위쪽 칸은 움직이지 않는다)
/// 왼쪽 앱, 가운데 출구(막음 포함), 오른쪽 규칙 묶음 안의 목적지 줄. 앱·출구 높이는 RouteScene 의 붙박이 자리에서 온다.
struct RouteLayout {
    var app: [String: CGPoint] = [:]
    var exit: [String: CGPoint] = [:]       // 인터페이스 → 가운데
    var wall = CGPoint.zero                 // 막음
    var row: [String: CGPoint] = [:]        // 목적지 줄 → 가운데
    var group: [String: CGRect] = [:]       // 묶음 → 점선 테두리
    var appSize = CGSize(width: 150, height: 30)
    var nodeSize = CGSize(width: 180, height: 44)
    var rowSize = CGSize(width: 320, height: 36)
    var height: CGFloat = 0                 // 필요한 그림 높이
    static let top: CGFloat = 70
    static let padTop: CGFloat = 16, padX: CGFloat = 10, padBottom: CGFloat = 10, rowGap: CGFloat = 8, groupGap: CGFloat = 22
    static let appGap: CGFloat = 44, exitGap: CGFloat = 62

    func appRight(_ a: String) -> CGPoint? { app[a].map { CGPoint(x: $0.x + appSize.width / 2, y: $0.y) } }
    func exitLeft(_ x: String) -> CGPoint? { (x == "block" ? wall : exit[x]).map { CGPoint(x: $0.x - nodeSize.width / 2, y: $0.y) } }
    func exitRight(_ x: String) -> CGPoint? { (x == "block" ? wall : exit[x]).map { CGPoint(x: $0.x + nodeSize.width / 2, y: $0.y) } }
    func rowLeft(_ r: String) -> CGPoint? { row[r].map { CGPoint(x: $0.x - rowSize.width / 2, y: $0.y) } }
    func rowRect(_ r: String) -> CGRect? { row[r].map { CGRect(x: $0.x - rowSize.width / 2, y: $0.y - rowSize.height / 2, width: rowSize.width, height: rowSize.height) } }
    func nodeRect(_ c: CGPoint) -> CGRect { CGRect(x: c.x - nodeSize.width / 2, y: c.y - nodeSize.height / 2, width: nodeSize.width, height: nodeSize.height) }
    func appRect(_ c: CGPoint) -> CGRect { CGRect(x: c.x - appSize.width / 2, y: c.y - appSize.height / 2, width: appSize.width, height: appSize.height) }
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
    @State private var quick: QuickPop?             // 앱·목적지를 눌러 연 빠른 규칙 팝오버
    @AppStorage("routesZoom") private var userZoom = 1.0   // − + 단추·핀치로 고른 배율 (창 너비에 맞춘 배율에 곱한다)
    @State private var pinchBase: Double?
    private static let zoomRange = 0.5 ... 2.0

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
    /// 빠른 규칙 팝오버가 열린 앱 (그 칸에 링을 두른다)
    private var quickApp: String? { if case .app(let a)? = quick?.kind { return a }; return nil }

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
            stream.setRules(m.status?.rules ?? [])
            stream.start()
        }
        .onDisappear { stream.stop() }      // 창을 닫으면 엔진이 pf 기록을 끈다
        .onChange(of: paused) { stream.scene.paused = paused }
        .onChange(of: targetSignature) { _, now in targetsChanged(now) }
        .onChange(of: m.status?.generatedAt) { stream.refreshSamplerContext() }
        .onAppear { lastTargets = targetSignature }
        .onChange(of: selection) { _, sel in applySelection(sel) }
        .onChange(of: groupBy) { selection = nil }
        .onChange(of: quick?.id) { stream.scene.interacting = quick != nil || hoverPath != nil; stream.nodesSettled(true) }
        .onChange(of: m.status?.rules) { stream.setRules(m.status?.rules ?? []) }
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
            let fit = min(1, max(Self.minScale, geo.size.width / Self.minDiagramWidth))
            let scale = fit * CGFloat(userZoom)
            let innerW = max(geo.size.width / scale, Self.minDiagramWidth)
            let innerH = max(geo.size.height / scale, layout(CGSize(width: innerW, height: 0)).height)
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
                        stream.scene.interacting = true
                    case .ended:
                        hoverNode = nil; hoverTip = nil
                        if hoverPath != nil { hoverPath = nil; stream.scene.nodeFading = true; stream.nodesSettled(true) }
                        stream.scene.interacting = quick != nil
                    }
                }
                .onTapGesture(count: 2, coordinateSpace: .local) { p in doubleTap(p, size: size) }
                .onTapGesture(coordinateSpace: .local) { p in tap(p, size: size) }
                .overlay(alignment: .topLeading) { hoverTipView(width: innerW, scale: scale) }
                .frame(width: innerW, height: innerH)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: innerW * scale, height: innerH * scale, alignment: .topLeading)
                .popover(item: $quick, attachmentAnchor: .rect(.rect(scaled(quick?.anchor ?? .zero, scale))),
                         arrowEdge: quick?.edge ?? .trailing) { q in quickContent(q) }
            }
            .scrollDisabled(innerW * scale <= geo.size.width + 0.5 && innerH * scale <= geo.size.height + 0.5)
            .overlay(alignment: .top) { zoomChip.padding(.top, 10) }
            // 범례와 배율 단추는 그림 위에 떠 있다 (스크롤해도 제자리, 줄여도 글자 크기 그대로)
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    legend
                    Spacer(minLength: 12)
                    zoomControls(scale: scale)
                }
                .padding(14)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if pinchBase == nil { pinchBase = userZoom }
                        setZoomLevel((pinchBase ?? 1) * v.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
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

    // MARK: 빠른 규칙 (앱·목적지를 누르면)

    private func scaled(_ r: CGRect, _ k: CGFloat) -> CGRect { CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }

    /// 규칙 밖 목적지 줄 → 규칙 초안: 그 목적지로 간 IPv4 들, 이름은 목적지
    private func quickSeed(_ row: DiagramRow) -> QuickRuleSeed {
        let ips = (stream.scene.groupIPs[row.key] ?? row.ips).filter { Target.isIPv4($0) }
        let ds = stream.dests.values.filter { $0.row == row.key && !$0.blocked }
        let live = ds.reduce(0) { $0 + $1.live.count }
        let iface = ds.first { !$0.live.isEmpty }?.iface ?? ds.first?.iface
        let apps = Array(Set(ds.map(\.app))).sorted()
        var ctx = iface.map { "지금 \(exitName($0))로 나가요" } ?? "평소 경로로 나가요"
        if !apps.isEmpty { ctx += " · " + apps.prefix(2).joined(separator: ", ") + (live > 0 ? " 연결 \(live)개" : "") }
        let items = ips.map { QuickItem(id: $0, sub: names.name($0) ?? "", cc: GeoIP.shared.country($0)) }
        return QuickRuleSeed(title: row.title, context: ctx, items: items, name: row.title, reverseNamed: !Target.isIPv4(row.title))
    }

    /// 앱이 최근 10분에 간 곳: 목적지 줄마다 하나 (넘친 목적지는 IP 마다). 규칙이 맡은 곳은 그 규칙 이름을 붙여 고를 수 없게
    private func quickAppRows(_ app: String) -> [QuickAppRow] {
        var rows: [String: (title: String, ips: Set<String>, iface: String, live: Int, ruled: String?)] = [:]
        for d in stream.dests.values where d.app == app && !d.blocked {
            let key = d.row == "~+" || d.row.isEmpty ? "ip:" + d.dst : d.row
            let ruled: String? = d.outside ? nil : (m.status?.rules.first { $0.id == d.slot }?.title ?? d.slot)
            let title = key.hasPrefix("ip:") ? d.dst : rowTitle(d.row)
            var r = rows[key] ?? (title, [], d.iface, 0, ruled)
            r.ips.insert(d.dst); r.live += d.live.count
            if !d.live.isEmpty { r.iface = d.iface }
            rows[key] = r
        }
        return rows.map { k, r in
            let ips = r.ips.sorted()
            let sub = (ips.count == 1 ? ips[0] : "IP \(ips.count)개") + " · " + exitName(r.iface)
            return QuickAppRow(id: k, title: r.title, sub: sub, cc: ips.first.flatMap { GeoIP.shared.country($0) }, ips: ips, ruled: r.ruled)
        }
        .sorted { a, b in
            if (a.ruled == nil) != (b.ruled == nil) { return a.ruled == nil }
            let la = rows[a.id]?.live ?? 0, lb = rows[b.id]?.live ?? 0
            return la != lb ? la > lb : a.title < b.title
        }
    }

    /// 앱 묶음(.app) 경로 (앱별 스플리팅에 넣을 수 있는지)
    private func appBundle(_ app: String) -> URL? {
        stream.dests.values.first { $0.app == app && ($0.exe ?? "").hasSuffix(".app") }.flatMap { $0.exe }.map { URL(fileURLWithPath: $0) }
    }

    /// 빠른 규칙을 엔진에 넣는다 (규칙 창과 같은 add 명령). 실패하면 까닭을 돌려준다
    private func saveQuick(_ rule: Rule) async -> String? {
        await m.saveRule(rule, isNew: true, draftKey: "quick")
        if let msg = m.message { return msg }
        quick = nil
        return nil
    }

    @ViewBuilder private func quickContent(_ q: QuickPop) -> some View {
        switch q.kind {
        case .rule(let seed):
            QuickRuleForm(seed: seed, candidates: exitCandidates(), save: { await saveQuick($0) },
                          more: { d in
                              quick = nil
                              m.drafts["new"] = d; m.windowSelection = "new"
                              NSApp.activate(); openWindow(id: "rules")
                          },
                          cancel: { quick = nil })
        case .app(let a):
            let live = stream.liveCount { $0.app == a && !$0.blocked }
            let ifaces = Set(stream.dests.values.filter { $0.app == a && !$0.live.isEmpty }.map(\.iface)).sorted()
            QuickAppMenu(app: a, icon: stream.scene.icons[a],
                         context: "연결 \(live)개" + (ifaces.isEmpty ? "" : " · " + ifaces.map(exitName).joined(separator: ", ")),
                         rows: quickAppRows(a), canSplit: appBundle(a) != nil,
                         makeRule: { rows in
                             let items = rows.flatMap { r in r.ips.filter { Target.isIPv4($0) }.map { QuickItem(id: $0, sub: r.title, cc: GeoIP.shared.country($0)) } }
                             let title = rows.count == 1 ? rows[0].title : "\(a)이(가) 간 \(rows.count)곳"
                             quick?.kind = .rule(QuickRuleSeed(title: title, context: "\(a)의 연결에서", items: items,
                                                               name: rows.count == 1 ? rows[0].title : a, reverseNamed: rows.contains { !Target.isIPv4($0.title) }))
                         },
                         split: {
                             quick = nil
                             AppModel.shared.pendingSplitApp = appBundle(a)
                             AppWindows.open("app-rules")
                         },
                         zoom: { quick = nil; setZoom(.app(a)) })
        }
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
    // 왼쪽 앱 → 가운데 출구(막음 포함) → 오른쪽 규칙 묶음 안의 목적지 줄. 선 색은 나간 출구, 굵기는 최근 6초 오간 양.

    /// 그릴 때 쓰는 배치: 칸이 목표 자리로 0.3초쯤에 걸쳐 부드럽게 옮겨 간다 (한 프레임에 한 번만 나아간다)
    private func animatedLayout(_ size: CGSize, now: Date) -> RouteLayout {
        var L = layout(size)
        let sc = stream.scene
        if sc.reduceMotion { return L }
        if sc.layoutSize.width != size.width {
            // 창 너비를 바꾸는 중에는 따라가지 않고 바로 맞춘다 (매 프레임 칸 전체를 다시 그려 버벅였다)
            sc.layoutSize = size
            for (a, p) in L.app { sc.shown["a:" + a] = p }
            for (x, p) in L.exit { sc.shown["x:" + x] = p }
            for (r, p) in L.row { sc.shown["w:" + r] = p }
            for (g, r) in L.group { sc.shown["g:" + g] = r.origin }
            sc.shown["x:block"] = L.wall
            sc.layoutT = now
            return L
        }
        let dt = min(0.1, max(0, now.timeIntervalSince(sc.layoutT)))
        if now > sc.layoutT { sc.layoutT = now }
        let k = 1 - exp(-dt * 11)
        var unsettled = false
        func ease(_ key: String, _ target: CGPoint) -> CGPoint {
            guard let cur = sc.shown[key] else { sc.shown[key] = target; return target }
            let next = CGPoint(x: cur.x + (target.x - cur.x) * k, y: cur.y + (target.y - cur.y) * k)
            if hypot(next.x - target.x, next.y - target.y) < 0.4 { sc.shown[key] = target; return target }
            sc.shown[key] = next; unsettled = true
            return next
        }
        for (a, p) in L.app { L.app[a] = ease("a:" + a, p) }
        for (x, p) in L.exit { L.exit[x] = ease("x:" + x, p) }
        L.wall = ease("x:block", L.wall)
        for (r, p) in L.row { L.row[r] = ease("w:" + r, p) }
        for (g, r) in L.group { L.group[g] = CGRect(origin: ease("g:" + g, r.origin), size: r.size) }
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

    /// 오른쪽 기둥: 규칙마다 묶음 (대상 줄 + 넘친 대상), 맨 아래 규칙 밖 묶음 (목적지 줄 + 넘친 목적지)
    private var diagramGroups: [DiagramGroup] {
        let scene = stream.scene
        var used = Set(scene.flows.values.map(\.row))
        for k in scene.heat.keys where k.hasPrefix("wb:") { used.insert(String(k.dropFirst(3))) }
        var out: [DiagramGroup] = []
        for r in rules {
            var rows: [DiagramRow] = r.targets.prefix(RouteScene.targetCap).map { t in
                DiagramRow(key: "t:\(r.id)|\(t.target)", slot: r.id, title: t.target, sub: targetSub(t), ips: t.addresses.map(\.ip))
            }
            let extra = r.targets.count - RouteScene.targetCap
            let plus = "t:\(r.id)|+"
            if extra > 0 || used.contains(plus) {
                let names = r.targets.dropFirst(RouteScene.targetCap).prefix(3).map(\.target).joined(separator: ", ")
                rows.append(DiagramRow(key: plus, slot: r.id, title: extra > 0 ? "그 밖의 대상 \(extra)개" : "그 밖의 주소",
                                       sub: extra > 0 ? names : "대상 목록에 없던 주소", ips: [], more: true))
            }
            out.append(DiagramGroup(key: r.id, rule: r, rows: rows))
        }
        var outside: [DiagramRow] = visibleGroups.map { g in
            DiagramRow(key: g, slot: g, title: String(g.dropFirst()), sub: groupSub(g), ips: scene.groupIPs[g] ?? [])
        }
        var zoomedToRule = false
        if case .rule? = zoom { zoomedToRule = true }
        if used.contains("~+") && !zoomedToRule {
            outside.append(DiagramRow(key: "~+", slot: "~+", title: "그 밖의 목적지", sub: "자리가 차서 한데 모았어요", ips: [], more: true))
        }
        if !outside.isEmpty { out.append(DiagramGroup(key: "~", rule: nil, rows: outside)) }
        return out
    }

    private func targetSub(_ t: TargetStatus) -> String {
        switch t.kind {
        case .domain:
            let ips = t.addresses.map(\.ip)
            if ips.isEmpty { return "아직 못 풀었어요" }
            return ips.count == 1 ? ips[0] : "\(ips[0]) 외 \(ips.count - 1)개"
        case .cidr: return "대역"
        case .ip: return t.addresses.first?.owner.map { "앞 규칙(\($0))이 맡음" } ?? "IP"
        }
    }

    private func groupSub(_ g: String) -> String {
        let name = String(g.dropFirst())
        if let latest = stream.scene.groupLatest[g], latest != name { return latest }
        if Target.isIPv4(name) { return "이름 없음" }
        let ips = stream.scene.groupIPs[g] ?? []
        return ips.count == 1 ? ips[0] : ips.isEmpty ? "규칙 없음" : "IP \(ips.count)개"
    }

    /// 줄의 나라 (서버가 있는 곳). 대역이면 첫 주소로 본다
    private func rowCountry(_ row: DiagramRow) -> String? {
        guard let ip = row.ips.first else { return nil }
        return GeoIP.shared.country(String(ip.split(separator: "/")[0]))
    }

    private func layout(_ size: CGSize) -> RouteLayout {
        var L = RouteLayout()
        let w = size.width
        L.appSize = CGSize(width: min(160, max(124, w * 0.15)), height: 30)
        L.nodeSize = CGSize(width: min(196, max(164, w * 0.18)), height: 44)
        let ax = 22 + L.appSize.width / 2
        let ex = max(ax + L.appSize.width / 2 + 80 + L.nodeSize.width / 2, w * 0.40)
        let gx = ex + L.nodeSize.width / 2 + max(70, w * 0.08)
        let gw = max(250, w - 22 - gx)
        L.rowSize = CGSize(width: gw - 2 * RouteLayout.padX, height: 36)
        var y = RouteLayout.top
        let groups = diagramGroups
        for g in groups {
            let n = CGFloat(g.rows.count)
            let h = RouteLayout.padTop + n * L.rowSize.height + max(0, n - 1) * RouteLayout.rowGap + RouteLayout.padBottom
            L.group[g.key] = CGRect(x: gx, y: y, width: gw, height: h)
            for (i, r) in g.rows.enumerated() {
                let cy = y + RouteLayout.padTop + CGFloat(i) * (L.rowSize.height + RouteLayout.rowGap) + L.rowSize.height / 2
                L.row[r.key] = CGPoint(x: gx + gw / 2, y: cy)
            }
            y += h + RouteLayout.groupGap
        }
        // 출구가 바라는 높이: 그 출구로 보내는 규칙 묶음의 가운데 + 지금 그 출구로 열린 연결이 닿는 줄들의 평균
        var wants: [String: [CGFloat]] = [:]
        for r in rules {
            guard let gr = L.group[r.id] else { continue }
            if r.decision == "route", let i = r.chosenIface { wants[i, default: []].append(gr.midY) }
            if r.decision == "block" { wants["block", default: []].append(gr.midY) }
        }
        for f in stream.scene.flows.values where f.closedAt == nil {
            if let ry = L.row[f.row]?.y { wants[f.iface, default: []].append(ry) }
        }
        for k in stream.scene.heat.keys where k.hasPrefix("wb:") {
            if let ry = L.row[String(k.dropFirst(3))]?.y { wants["block", default: []].append(ry) }
        }
        let exitWant = wants.mapValues { $0.reduce(0, +) / CGFloat($0.count) }
        let order = visibleExits.map(\.iface) + ["block"]
        let top = RouteLayout.top + L.nodeSize.height / 2
        let key = order.joined(separator: ",") + "/" + groups.map(\.key).joined(separator: ",")
        stream.scene.arrange(apps: visibleApps, exits: order, exitWant: exitWant, key: key, zoomKey: zoom.map { "\($0)" } ?? "",
                             top: top, appGap: RouteLayout.appGap, exitGap: RouteLayout.exitGap)
        var bottom = y
        for (i, x) in order.enumerated() {
            let cy = stream.scene.exitY[x] ?? top + CGFloat(i) * RouteLayout.exitGap
            if x == "block" { L.wall = CGPoint(x: ex, y: cy) } else { L.exit[x] = CGPoint(x: ex, y: cy) }
            bottom = max(bottom, cy + L.nodeSize.height)
        }
        for a in visibleApps {
            let cy = stream.scene.appY[a] ?? top
            L.app[a] = CGPoint(x: ax, y: cy)
            bottom = max(bottom, cy + L.appSize.height)
        }
        L.height = bottom + 48
        return L
    }

    /// 길 하나: 앱 → 출구 → 목적지 줄 (출구 칸은 가로지른다). 줄이 안 보이면 출구까지만
    private func routePath(app: String, row: String, iface: String, _ L: RouteLayout) -> (path: Path, start: CGPoint, end: CGPoint)? {
        guard let a = L.appRight(app), let b = L.exitLeft(iface) else { return nil }
        var p = wirePath(a, b)
        guard let c = L.exitRight(iface), let d = L.rowLeft(row) else { return (p, a, b) }
        p.addLine(to: c)
        p.addPath(wirePath(c, d))
        return (p, a, d)
    }

    /// 핑: 경로를 따라 흐르는 빛줄기, 끝에 닿으면 연결점에서 원이 한 번 퍼진다
    private func drawPulses(_ ctx: inout GraphicsContext, _ L: RouteLayout, now: Date, rings: Bool, focus fs: FocusSets?) {
        for p in stream.scene.pulses {
            let t = now.timeIntervalSince(p.t0) / RouteScene.pulseDuration
            guard t >= 0, t <= 1 else { continue }
            // "b:앱|줄|출구" (데이터가 오감) · "blk:앱|줄" (막힘)
            let block = p.key.hasPrefix("blk:")
            let body = p.key.dropFirst(block ? 4 : 2)
            guard let i = body.firstIndex(of: "|") else { continue }
            let app = String(body[..<i])
            var row = String(body[body.index(after: i)...]), iface = "block"
            if !block {
                guard let j = row.lastIndex(of: "|") else { continue }
                iface = String(row[row.index(after: j)...]); row = String(row[..<j])
            }
            guard let r = routePath(app: app, row: row, iface: iface, L) else { continue }
            let color = block ? blockC : exitColor(exits.first { $0.iface == iface })
            let width: CGFloat = block ? 1.6 : 1.4 + CGFloat(stream.scene.smoothV["ax:\(app)|\(iface)"] ?? 0) * 4
            let away = fade("ld:p:" + p.key, fs.map { !$0.appExit.contains(app + "|" + iface) } ?? false)
            guard away < 0.98 else { continue }
            let end = p.dir > 0 ? r.end : r.start
            let e = easeInOut(min(1, t / 0.8))                     // 0.8 동안 흐르고, 남은 0.2 동안 도착점에서 퍼진다
            let pos = p.dir > 0 ? e : 1 - e
            let fadeIn = sin(.pi * min(1, t / 0.8))
            if !rings {
                let seg = r.path.trimmedPath(from: max(0, pos - 0.07), to: min(1, pos + 0.01))
                var g = ctx
                g.opacity = fadeIn * (1 - away)
                g.stroke(seg, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
                g.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: width + 1.5, lineCap: .round))
                g.stroke(seg, with: .color(.white.opacity(dark ? 0.55 : 0.8)), style: StrokeStyle(lineWidth: max(1, width * 0.45), lineCap: .round))
            }
            if rings, t > 0.72 {
                let k = easeOut((t - 0.72) / 0.28)
                let rr = 4 + 9 * k
                var g = ctx
                g.opacity = 1 - away
                g.stroke(Path(ellipseIn: CGRect(x: end.x - rr, y: end.y - rr, width: 2 * rr, height: 2 * rr)),
                         with: .color(color.opacity(0.55 * (1 - k))), lineWidth: 1.5)
            }
        }
    }

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

    // MARK: 강조

    /// 지금 강조할 경로: 마우스를 올린 것, 없으면 눌러 둔 규칙·출구
    private var activeFocus: PathFocus? {
        if let h = hoverPath { return h }
        if let r = focusRule { return r.hasPrefix("~") ? PathFocus(row: r) : PathFocus(group: r) }
        if let x = focusExit { return PathFocus(iface: x) }
        return nil
    }

    /// 강조한 경로가 지나는 칸과 선
    private func focusSets(_ f: PathFocus, groups: [DiagramGroup]) -> FocusSets {
        var s = FocusSets()
        let scene = stream.scene
        func add(_ app: String, _ row: String, _ iface: String) {
            s.nodes.formUnion(["a:" + app, "x:" + iface, "w:" + row, "g:" + RouteScene.group(ofRow: row)])
            s.appExit.insert(app + "|" + iface)
            s.exitRow.insert(row + "|" + iface)
        }
        for fl in scene.flows.values where f.matches(app: fl.app, row: fl.row, iface: fl.iface) { add(fl.app, fl.row, fl.iface) }
        let now = Date()
        for (k, t) in scene.blockPairs where now.timeIntervalSince(t) < 60 {
            guard let i = k.firstIndex(of: "|") else { continue }
            let app = String(k[..<i]), row = String(k[k.index(after: i)...])
            if f.matches(app: app, row: row, iface: "block") { add(app, row, "block") }
        }
        // 연결이 없어도: 그 출구로 보내는(또는 막는) 규칙 묶음
        if f.app == nil && f.row == nil {
            for r in rules {
                let x: String? = r.decision == "route" ? r.chosenIface : r.decision == "block" ? "block" : nil
                guard let x, f.iface == nil || f.iface == x, f.group == nil || f.group == r.id else { continue }
                s.nodes.formUnion(["g:" + r.id, "x:" + x])
                for row in groups.first(where: { $0.key == r.id })?.rows ?? [] {
                    s.nodes.insert("w:" + row.key)
                    if x == "block" { s.exitRow.insert(row.key + "|block") }
                }
            }
        }
        if let a = f.app { s.nodes.insert("a:" + a) }
        if let r = f.row { s.nodes.formUnion(["w:" + r, "g:" + RouteScene.group(ofRow: r)]) }
        if let g = f.group { s.nodes.insert("g:" + g) }
        if let x = f.iface { s.nodes.insert("x:" + x) }
        return s
    }

    private func rowTitle(_ key: String) -> String {
        for g in diagramGroups { if let r = g.rows.first(where: { $0.key == key }) { return r.title } }
        return key.hasPrefix("~") ? String(key.dropFirst()) : key
    }

    private func countryName(_ cc: String) -> String {
        Locale(identifier: "ko").localizedString(forRegionCode: cc) ?? cc
    }

    private func hitLine(_ path: Path, _ p: CGPoint) -> Bool {
        path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round)).contains(p)
    }

    /// 점 p 에서 강조할 경로와 설명. 순서: 트래픽 막대 → 칸 → 묶음 제목 → 선
    private func hoverTarget(_ p: CGPoint, size: CGSize) -> (PathFocus?, String?) {
        let L = layout(size)
        for a in visibleApps {
            guard let c = L.app[a] else { continue }
            let r = L.appRect(c)
            guard r.contains(p) else { continue }
            if meterRect(r, inset: 10).insetBy(dx: -3, dy: -3).contains(p) { return (PathFocus(app: a), meterTip("a:\(a)", title: a)) }
            return (PathFocus(app: a), "\(a)\n누르면 간 곳으로 규칙 만들기")
        }
        for e in visibleExits {
            guard let c = L.exit[e.iface] else { continue }
            let r = L.nodeRect(c)
            guard r.contains(p) else { continue }
            if meterRect(r).insetBy(dx: -3, dy: -3).contains(p) { return (PathFocus(iface: e.iface), meterTip("x:\(e.iface)", title: exitName(e.iface))) }
            return (PathFocus(iface: e.iface), nil)
        }
        if L.nodeRect(L.wall).contains(p) { return (PathFocus(iface: "block"), nil) }
        for g in diagramGroups {
            for row in g.rows {
                guard let r = L.rowRect(row.key), r.contains(p) else { continue }
                if !row.more, meterRect(r).insetBy(dx: -3, dy: -3).contains(p) {
                    return (PathFocus(row: row.key), meterTip("w:\(row.key)", title: row.title))
                }
                var lines = [row.title]
                if let cc = rowCountry(row) { lines.append("서버: \(countryName(cc))(\(cc))") }
                if g.rule == nil && !row.more { lines.append("누르면 이 목적지로 규칙 만들기") }
                return (PathFocus(row: row.key), row.more ? nil : lines.joined(separator: "\n"))
            }
            if let gr = L.group[g.key], CGRect(x: gr.minX, y: gr.minY - 10, width: gr.width, height: 20).contains(p) {
                return (PathFocus(group: g.key), g.rule.map { "\($0.title)\n\($0.reason)" })
            }
        }
        // 선: 앱 → 출구, 출구 → 목적지 줄
        var seen = Set<String>()
        for f in stream.scene.flows.values {
            let ax = "ax:" + f.app + "|" + f.iface
            if seen.insert(ax).inserted, let a = L.appRight(f.app), let b = L.exitLeft(f.iface), hitLine(wirePath(a, b), p) {
                let live = stream.liveCount { $0.app == f.app && $0.iface == f.iface && !$0.blocked }
                return (PathFocus(app: f.app, iface: f.iface),
                        "\(f.app) → \(exitName(f.iface))\n연결 \(live) · 최근 6초 \(RouteScene.bytesText(stream.recent(ax)))")
            }
            let wx = "wx:" + f.row + "|" + f.iface
            if seen.insert(wx).inserted, let a = L.exitRight(f.iface), let b = L.rowLeft(f.row), hitLine(wirePath(a, b), p) {
                let live = stream.liveCount { $0.row == f.row && $0.iface == f.iface && !$0.blocked }
                return (PathFocus(row: f.row, iface: f.iface),
                        "\(exitName(f.iface)) → \(rowTitle(f.row))\n연결 \(live) · 최근 6초 \(RouteScene.bytesText(stream.recent(wx)))")
            }
        }
        return (nil, nil)
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
            HStack(spacing: 4) {
                Text("KR").font(.system(size: 8.5, weight: .semibold).monospaced())
                    .padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(muted.opacity(0.5), lineWidth: 0.7))
                Text("서버 나라 (IP Geolocation by DB-IP)")
            }
        }
        .font(.system(size: 10)).foregroundStyle(muted)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .modifier(Floating(dark: dark, fill: cardC, light: lightShade, shade: darkShade))
        .allowsHitTesting(false)
    }

    private func setZoomLevel(_ z: Double) {
        let v = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, (z * 20).rounded() / 20))
        if v != userZoom { userZoom = v }
    }

    /// 오른쪽 아래 배율: − 지금 배율 +. 가운데 숫자를 누르면 창에 맞춘 크기로 (⌘0)
    private func zoomControls(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { setZoomLevel(userZoom - 0.1) } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(userZoom <= Self.zoomRange.lowerBound)
            .help("줄이기 (⌘−)")
            .accessibilityLabel("줄이기")
            Button { setZoomLevel(1) } label: {
                Text("\(Int((scale * 100).rounded()))%").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40).frame(height: 26).contentShape(Rectangle())
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("창에 맞추기 (⌘0)")
            Button { setZoomLevel(userZoom + 0.1) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(userZoom >= Self.zoomRange.upperBound)
            .help("키우기 (⌘+)")
            .accessibilityLabel("키우기")
        }
        .buttonStyle(.plain)
        .foregroundStyle(fg.opacity(0.8))
        .padding(.horizontal, 3)
        .modifier(Floating(dark: dark, fill: cardC, light: lightShade, shade: darkShade))
    }

    private func nodeAt(_ p: CGPoint, size: CGSize) -> String? {
        let L = layout(size)
        for (a, c) in L.app where L.appRect(c).contains(p) { return "a:" + a }
        for (i, c) in L.exit where L.nodeRect(c).contains(p) { return "x:" + i }
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

    /// 뒤 층 (매 프레임): 장면을 한 걸음 움직이고 선을 그린다
    private func drawBack(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = animatedLayout(size, now: now)
        let scene = stream.scene
        scene.easing = false
        scene.step(now: now) { _ in nil }
        let groups = diagramGroups
        let fs = activeFocus.map { focusSets($0, groups: groups) }
        let hovering = hoverPath != nil
        func state(_ set: Set<String>?, _ k: String) -> (dim: Bool, hot: Bool) {
            guard let set else { return (false, false) }
            let c = set.contains(k)
            return (!c, c && hovering)
        }
        // 막는 규칙의 목적지: 막음 → 줄. 늘 옅은 점선, 막을 때마다 잠깐 진해진다
        var blockRows = Set<String>()
        for g in groups where g.rule?.decision == "block" { for r in g.rows { blockRows.insert(r.key) } }
        for k in scene.heat.keys where k.hasPrefix("wb:") { blockRows.insert(String(k.dropFirst(3))) }
        for row in blockRows.sorted() {
            guard let a = L.exitRight("block"), let b = L.rowLeft(row) else { continue }
            let h = scene.heat["wb:" + row] ?? 0
            let st = state(fs?.exitRow, row + "|block")
            let fd = fade("ld:wb:" + row, st.dim), fh = fade("lh:wb:" + row, st.hot)
            strokeLine(&ctx, wirePath(a, b), color: blockC, opacity: lerp(lerp(0.22 + h * 0.45, 0.9, fh), 0.05, fd),
                       width: 1.1 + min(1.5, CGFloat(h)) + CGFloat(fh) * 0.8, dash: [4, 4])
        }
        // 앱 → 막음: 막힌 시도마다 잠깐
        for (k, h) in scene.heat where k.hasPrefix("ab:") {
            let app = String(k.dropFirst(3))
            guard let a = L.appRight(app), let b = L.exitLeft("block") else { continue }
            let st = state(fs?.appExit, app + "|block")
            let fd = fade("ld:ab:" + app, st.dim), fh = fade("lh:ab:" + app, st.hot)
            strokeLine(&ctx, wirePath(a, b), color: blockC, opacity: lerp(lerp(0.15 + h * 0.5, 0.9, fh), 0.04, fd),
                       width: 1.1 + min(1.5, CGFloat(h)) + CGFloat(fh) * 0.8, dash: [4, 4])
        }
        // 열린 연결: 앱 → 출구, 출구 → 목적지 줄 (같은 쌍은 선 하나). 생길 때 그려지고, 오가면 굵어지고, 닫히면 흐려진다
        struct Seg { var live = 0; var opened = Date.distantFuture; var closed = Date.distantPast }
        var ax: [String: Seg] = [:], wx: [String: Seg] = [:]
        for f in scene.flows.values {
            let o = scene.bundleOpened[f.bundle] ?? f.opened
            for (isAX, key) in [(true, f.app + "|" + f.iface), (false, f.row + "|" + f.iface)] {
                var sg = (isAX ? ax[key] : wx[key]) ?? Seg()
                if let c = f.closedAt { sg.closed = max(sg.closed, c) } else { sg.live += 1 }
                sg.opened = min(sg.opened, o)
                if isAX { ax[key] = sg } else { wx[key] = sg }
            }
        }
        func drawSeg(_ path: Path, _ sg: Seg, meter: String, iface: String, st: (dim: Bool, hot: Bool)) {
            var alpha = 1.0
            if sg.live == 0 { alpha = 1 - easeOut(now.timeIntervalSince(sg.closed) / RouteScene.closeFade) }
            let grow = easeOut(now.timeIntervalSince(sg.opened) / RouteScene.openDuration)
            alpha *= 0.3 + 0.7 * grow
            let v = scene.smooth(meter, norm(stream.recent(meter)))
            let fd = fade("ld:" + meter, st.dim), fh = fade("lh:" + meter, st.hot)
            let op = lerp(lerp((sg.live == 0 ? 0.3 : 0.6) + v * 0.3, 1, fh), 0.07, fd) * alpha
            strokeLine(&ctx, path.trimmedPath(from: 0, to: grow), color: exitColor(exits.first { $0.iface == iface }),
                       opacity: op, width: 1.4 + CGFloat(v) * 4 + CGFloat(fh) * 1.2)
        }
        for (k, sg) in ax {
            guard let i = k.lastIndex(of: "|") else { continue }
            let app = String(k[..<i]), iface = String(k[k.index(after: i)...])
            guard let a = L.appRight(app), let b = L.exitLeft(iface) else { continue }
            drawSeg(wirePath(a, b), sg, meter: "ax:" + k, iface: iface, st: state(fs?.appExit, k))
        }
        for (k, sg) in wx {
            guard let i = k.lastIndex(of: "|") else { continue }
            let row = String(k[..<i]), iface = String(k[k.index(after: i)...])
            guard let a = L.exitRight(iface), let b = L.rowLeft(row) else { continue }
            drawSeg(wirePath(a, b), sg, meter: "wx:" + k, iface: iface, st: state(fs?.exitRow, k))
        }
        drawPulses(&ctx, L, now: now, rings: false, focus: fs)
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

    /// 규칙이 보내는 곳 (묶음 오른쪽 위에 적는다)
    private func routeText(_ r: RuleStatus) -> (text: String, color: Color, dot: Bool) {
        switch r.decision {
        case "route":
            let col = exitColor(exits.first { $0.iface == r.chosenIface })
            let chosen = r.chosenExit.map(Exits.label) ?? exitName(r.chosenIface ?? "")
            if r.exits.count > 1, let i = r.exits.firstIndex(of: r.chosenExit ?? "") { return ("\(r.exitsText) · \(i + 1)순위", col, true) }
            return (chosen, col, true)
        case "block": return (r.exits.isEmpty ? "막기" : "출구 없음 · 막는 중", blockC, true)
        case "skip": return ("쉼 · " + (r.when.flatMap { try? Condition.parse($0) }.map(\.short) ?? "조건 안 맞음"), muted, false)
        case "next": return ("쉼 · 출구 없어 다음 규칙으로", muted, false)
        case "system": return ("쉼 · 출구 없어 평소 경로로", muted, false)
        default: return (r.decision, muted, false)
        }
    }

    /// 규칙 묶음: 희미한 점선 테두리, 위 테두리에 ─ 번호 이름 ──── ● 출구 ─ 처럼 글자가 걸친다.
    /// 글자 뒤에 바탕을 깔지 않고 테두리를 글자 자리만큼 끊는다 (점 무늬가 그대로 비치게)
    private func drawGroupFrame(_ c: inout GraphicsContext, _ g: DiagramGroup, _ gr: CGRect) {
        var left: Text, right: Text
        if let r = g.rule {
            let pos = (m.status?.rules.firstIndex { $0.id == r.id } ?? 0) + 1
            left = Text("\(pos)  ").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundColor(muted)
                + Text(TextFit.fit(r.title, 11.5, .semibold, false, gr.width * 0.45, .tail)).font(.system(size: 11.5, weight: .semibold)).foregroundColor(fg.opacity(0.78))
            let rt = routeText(r)
            right = (rt.dot ? Text("● ").font(.system(size: 8)).foregroundColor(rt.color) : Text(""))
                + Text(TextFit.fit(rt.text, 10.5, .medium, false, gr.width * 0.42, .tail)).font(.system(size: 10.5, weight: .medium)).foregroundColor(rt.color)
        } else {
            left = Text(Image(systemName: "questionmark.circle")).font(.system(size: 10.5)).foregroundColor(muted)
                + Text("  규칙 없음").font(.system(size: 11.5, weight: .semibold)).foregroundColor(fg.opacity(0.78))
            right = Text("평소 경로").font(.system(size: 10.5, weight: .medium)).foregroundColor(muted)
        }
        let lt = c.resolve(left), rt = c.resolve(right)
        let lw = lt.measure(in: CGSize(width: gr.width, height: 30)).width, rw = rt.measure(in: CGSize(width: gr.width, height: 30)).width
        let lx = gr.minX + 14, rx = gr.maxX - 14
        var b = c
        var clip = Path(gr.insetBy(dx: -4, dy: -4))
        clip.addRect(CGRect(x: lx - 6, y: gr.minY - 3, width: lw + 12, height: 6))
        clip.addRect(CGRect(x: rx - rw - 6, y: gr.minY - 3, width: rw + 12, height: 6))
        b.clip(to: clip, style: FillStyle(eoFill: true))
        b.stroke(Path(roundedRect: gr, cornerRadius: 12, style: .continuous), with: .color(muted.opacity(dark ? 0.34 : 0.4)),
                 style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        c.draw(lt, at: CGPoint(x: lx, y: gr.minY), anchor: .leading)
        c.draw(rt, at: CGPoint(x: rx, y: gr.minY), anchor: .trailing)
    }

    /// 가운데 층 (상태가 바뀔 때만): 칸과 글자. 매 프레임 글자를 다시 그리지 않아 CPU 를 아낀다
    private func drawNodes(_ ctx: inout GraphicsContext, size: CGSize, now: Date = Date()) {
        let L = animatedLayout(size, now: now)
        let fit = TextFit.fit
        let scene = stream.scene
        let groups = diagramGroups
        let fs = activeFocus.map { focusSets($0, groups: groups) }
        scene.nodeFading = false
        func label(_ s: String, _ p: CGPoint, _ c: Color, _ font: Font, anchor: UnitPoint = .center) {
            ctx.draw(Text(s).font(font).foregroundColor(c), at: p, anchor: anchor)
        }
        /// 강조한 경로 밖의 칸은 흐리게
        func off(_ key: String) -> Bool { fs.map { !$0.nodes.contains(key) } ?? false }
        /// 흐림 정도 0…1 을 부드럽게 (바뀌는 동안 칸 층을 매 프레임 다시 그린다)
        func dimAmt(_ key: String) -> Double {
            let on = off(key)
            let v = fade("nd:" + key, on)
            if v != (on ? 1 : 0) { scene.nodeFading = true }
            return v
        }
        // 칼럼 머리글: 이름 + 개수, 밑에 칸 너비만큼 짧은 선
        func header(_ title: String, _ n: Int, x: CGFloat, width: CGFloat) {
            let t = Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(fg.opacity(0.7))
                + Text("  \(n)").font(.system(size: 11).monospacedDigit()).foregroundColor(muted)
            ctx.draw(t, at: CGPoint(x: x - width / 2 + 2, y: RouteLayout.top - 40), anchor: .leading)
            ctx.fill(Path(CGRect(x: x - width / 2, y: RouteLayout.top - 29, width: width, height: 1)), with: .color(lineC.opacity(dark ? 0.9 : 0.8)))
        }
        header("앱", visibleApps.count, x: 22 + L.appSize.width / 2, width: L.appSize.width)
        header("출구", visibleExits.count, x: L.wall.x, width: L.nodeSize.width)
        if let any = L.group.values.first {
            header("목적지 · 규칙별로 묶음", groups.reduce(0) { $0 + $1.rows.filter { !$0.more }.count }, x: any.midX, width: any.width)
        }

        // 오른쪽: 규칙 묶음과 목적지 줄
        for g in groups {
            guard let gr = L.group[g.key] else { continue }
            let resting = g.rule.map { ["skip", "system", "next"].contains($0.decision) } ?? false
            var c = ctx
            c.opacity = lerp(resting ? 0.62 : 1, NodeToken.dimmed, dimAmt("g:" + g.key))
            drawGroupFrame(&c, g, gr)
            let blockRule = g.rule?.decision == "block"
            for row in g.rows {
                guard let rect = L.rowRect(row.key) else { continue }
                let n = stream.liveCount { $0.row == row.key && !$0.blocked }
                var rc = c
                rc.opacity = c.opacity * lerp(1, NodeToken.dimmed, dimAmt("w:" + row.key))
                let st: NodeState = n > 0 ? .active : .resting
                let tint: Color? = blockRule ? blockC : stream.dests.values.first { $0.row == row.key && !$0.blocked && !$0.live.isEmpty }
                    .map { d in exitColor(exits.first { $0.iface == d.iface }) }
                drawCard(&rc, rect, shape: blockRule ? .wall : .rule, tint: n > 0 || blockRule ? tint : nil, state: blockRule ? .idle : st,
                         selected: focusRule == row.key)
                let blocks = scene.count("w:" + row.key)
                let cc = row.more ? nil : rowCountry(row)
                var right = rect.maxX - NodeToken.inset
                if !row.more && !blockRule {
                    drawMeter(&rc, key: "w:\(row.key)", in: CGRect(x: right - NodeToken.meter.width, y: rect.midY - NodeToken.meter.height / 2,
                                                              width: NodeToken.meter.width, height: NodeToken.meter.height))
                    right -= NodeToken.meter.width + 6
                }
                let countText = blockRule || blocks > 0 && n == 0 ? (blocks > 0 ? "막힘 \(blocks)" : "") : n > 0 ? "\(n)" : ""
                if !countText.isEmpty {
                    let t = rc.resolve(Text(countText).font(NodeToken.digits).foregroundColor(blockRule || n == 0 ? blockC.opacity(0.9) : muted))
                    rc.draw(t, at: CGPoint(x: right, y: rect.midY), anchor: .trailing)
                    right -= t.measure(in: CGSize(width: 80, height: 20)).width + 8
                }
                if let cc {
                    let t = rc.resolve(Text(cc).font(.system(size: 9, weight: .semibold).monospaced()).foregroundColor(muted))
                    let sz = t.measure(in: CGSize(width: 40, height: 20))
                    let box = CGRect(x: right - sz.width - 8, y: rect.midY - sz.height / 2 - 2, width: sz.width + 8, height: sz.height + 4)
                    rc.stroke(Path(roundedRect: box, cornerRadius: 3.5), with: .color(muted.opacity(0.4)), lineWidth: 0.8)
                    rc.draw(t, at: CGPoint(x: box.midX, y: box.midY))
                    right = box.minX - 8
                }
                let room = right - (rect.minX + 12)
                let titleC: Color = blockRule ? blockC : row.more || n == 0 ? fg.opacity(0.6) : fg.opacity(0.9)
                rc.draw(Text(fit(row.title, 12, .semibold, false, room, .middle)).font(.system(size: 12, weight: .semibold)).foregroundColor(titleC),
                        at: CGPoint(x: rect.minX + 12, y: rect.midY - 7), anchor: .leading)
                rc.draw(Text(fit(row.sub, 10, .regular, false, room, .middle)).font(NodeToken.sub).foregroundColor(muted),
                        at: CGPoint(x: rect.minX + 12, y: rect.midY + 8), anchor: .leading)
                drawPort(&rc, CGPoint(x: rect.minX, y: rect.midY), color: blockRule ? blockC.opacity(0.8) : tint ?? lineC,
                         filled: fs != nil && !off("w:" + row.key) && (n > 0 || blockRule))
            }
        }

        // 왼쪽: 앱 칸 (출발, 알약)
        for a in visibleApps {
            guard let p = L.app[a] else { continue }
            let rect = L.appRect(p)
            let live = stream.liveCount { $0.app == a && !$0.blocked }
            var selected = false
            if case .app(let z)? = zoom { selected = z == a }
            var c = ctx
            // 나타날 때: 왼쪽에서 살짝 미끄러지며 짙어진다
            let ap = scene.appeared["a:" + a].map { easeOut(now.timeIntervalSince($0) / RouteScene.appearDuration) } ?? 1
            c.opacity = (1 - 0.6 * dimAmt("a:" + a)) * ap
            c.translateBy(x: -10 * (1 - ap), y: 0)
            drawCard(&c, rect, shape: .app, tint: nil, state: live > 0 ? .active : .idle, selected: selected || quickApp == a)
            let room = rect.width - 32 - 10 - NodeToken.meter.width - 6
            if let icon = scene.icons[a] {
                c.draw(Image(nsImage: icon), in: CGRect(x: rect.minX + 9, y: p.y - 9, width: 18, height: 18))
                c.draw(Text(fit(a, 12, .medium, false, room, .tail)).font(NodeToken.appTitle).foregroundColor(fg), at: CGPoint(x: rect.minX + 32, y: p.y), anchor: .leading)
            } else {
                c.draw(Text(fit(a, 12, .medium, false, room + 22, .tail)).font(NodeToken.appTitle).foregroundColor(fg), at: CGPoint(x: rect.minX + 12, y: p.y), anchor: .leading)
            }
            drawTrail(&c, rect, meter: "a:\(a)", count: 0, inset: 10)
            let appC = stream.dests.values.first { $0.app == a && !$0.blocked && !$0.live.isEmpty }.map { d in exitColor(exits.first { $0.iface == d.iface }) }
            drawPort(&c, CGPoint(x: rect.maxX, y: p.y), color: appC ?? (live > 0 ? fg.opacity(0.4) : lineC), filled: fs != nil && !off("a:" + a))
        }
        // 빠진 앱 칸: 그 자리에서 흐려지며 사라진다
        for (a, lv) in scene.leaving {
            let k = easeOut(now.timeIntervalSince(lv.t0) / RouteScene.leaveDuration)
            let rect = L.appRect(lv.at)
            var c = ctx
            c.opacity = 1 - k
            drawCard(&c, rect, shape: .app, tint: nil, state: .idle, selected: false)
            if let icon = scene.icons[a] { c.draw(Image(nsImage: icon), in: CGRect(x: rect.minX + 9, y: lv.at.y - 9, width: 18, height: 18)) }
            c.draw(Text(a).font(NodeToken.appTitle).foregroundColor(fg), at: CGPoint(x: rect.minX + 32, y: lv.at.y), anchor: .leading)
        }
        if visibleApps.isEmpty && !showsEmptyCard {
            label("연결을 기다리는 중", CGPoint(x: 22 + L.appSize.width / 2, y: RouteLayout.top + 30), muted, .caption)
        }

        // 가운데: 출구 칸 (출구 색 바탕, 양옆에 연결점)
        for e in visibleExits {
            guard let p = L.exit[e.iface] else { continue }
            let rect = L.nodeRect(p)
            let col = exitColor(e)
            let down = e.up && e.healthy == false
            let n = stream.liveCount { $0.iface == e.iface && !$0.blocked }
            var c = ctx
            c.opacity = lerp(1, NodeToken.dimmed, dimAmt("x:" + e.iface))
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
            let hot = fs != nil && !off("x:" + e.iface) && e.up
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: e.up ? col.opacity(0.8) : lineC, filled: hot)
            drawPort(&c, CGPoint(x: rect.maxX, y: p.y), color: e.up ? col.opacity(0.8) : lineC, filled: hot)
        }
        // 막음: 출구와 같은 자리, 산호색 점선. 숫자는 최근 60초 동안 막은 횟수
        do {
            let p = L.wall
            let rect = L.nodeRect(p)
            var c = ctx
            c.opacity = lerp(1, NodeToken.dimmed, dimAmt("x:block"))
            drawCard(&c, rect, shape: .wall, tint: blockC, state: .idle, selected: focusExit == "block")
            c.draw(Text(Image(systemName: "nosign")).font(.system(size: 13, weight: .medium)).foregroundColor(blockC), at: CGPoint(x: rect.minX + 19, y: p.y))
            c.draw(Text("막음").font(NodeToken.title).foregroundColor(fg), at: CGPoint(x: rect.minX + 36, y: p.y - 7), anchor: .leading)
            c.draw(Text("최근 60초").font(NodeToken.sub).foregroundColor(muted), at: CGPoint(x: rect.minX + 36, y: p.y + 9), anchor: .leading)
            drawTrail(&c, rect, meter: nil, count: scene.count("x:block"))
            let hot = fs != nil && !off("x:block")
            drawPort(&c, CGPoint(x: rect.minX, y: p.y), color: blockC.opacity(0.8), filled: hot)
            drawPort(&c, CGPoint(x: rect.maxX, y: p.y), color: blockC.opacity(0.8), filled: hot)
        }
    }

    /// 앞 층 (매 프레임): 핑이 닿을 때 퍼지는 원, 규칙의 출구가 바뀌었을 때 잠깐 뜨는 글
    private func drawFront(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let L = animatedLayout(size, now: now)
        let fs = activeFocus.map { focusSets($0, groups: diagramGroups) }
        drawPulses(&ctx, L, now: now, rings: true, focus: fs)
        let scene = stream.scene
        // 출구가 바뀐 규칙: 묶음 오른쪽 위에 잠깐 "Wi-Fi(en0) → VPN:pass(utun4)"
        for (id, n) in scene.notes {
            guard let gr = L.group[id] else { continue }
            let t = now.timeIntervalSince(n.t0)
            let a = t < 0.25 ? t / 0.25 : max(0, min(1, (RouteScene.noteDuration - t) / 0.7))
            let r = rules.first { $0.id == id }
            let col: Color = r.map { targetKey($0) == "block" ? blockC : targetKey($0) == "none" ? muted : exitColor(exits.first { $0.iface == r?.chosenIface }) } ?? fg
            let text = ctx.resolve(Text(n.text).font(.system(size: 11, weight: .semibold)).foregroundColor(col))
            let sz = text.measure(in: CGSize(width: 400, height: 30))
            let box = CGRect(x: gr.maxX - sz.width - 12, y: gr.minY - sz.height - 16, width: sz.width + 12, height: sz.height + 6)
            var g = ctx
            g.opacity = a
            g.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(stage.opacity(0.92)))
            g.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(col.opacity(0.7)), lineWidth: 1)
            g.draw(text, at: CGPoint(x: box.midX, y: box.midY))
        }
        for s in scene.sparks {
            ctx.fill(Path(ellipseIn: CGRect(x: s.p.x - s.r, y: s.p.y - s.r, width: s.r * 2, height: s.r * 2)), with: .color(blockC.opacity(max(0, s.life))))
        }
    }

    // MARK: 조작

    private enum Hit { case app(String, CGRect), exit(String, CGRect), row(DiagramRow, DiagramGroup, CGRect), group(DiagramGroup), none }

    private func hitTest(_ p: CGPoint, size: CGSize) -> Hit {
        let L = layout(size)
        for (a, c) in L.app where L.appRect(c).contains(p) { return .app(a, L.appRect(c)) }
        for (x, c) in L.exit where L.nodeRect(c).contains(p) { return .exit(x, L.nodeRect(c)) }
        if L.nodeRect(L.wall).contains(p) { return .exit("block", L.nodeRect(L.wall)) }
        for g in diagramGroups {
            for row in g.rows { if let r = L.rowRect(row.key), r.contains(p) { return .row(row, g, r) } }
            if let gr = L.group[g.key], gr.insetBy(dx: 0, dy: -10).contains(p) { return .group(g) }
        }
        return .none
    }

    /// 두 번 누르면 그것만 본다. 같은 칸을 다시 두 번 누르면 전체로.
    private func doubleTap(_ p: CGPoint, size: CGSize) {
        func toggle(_ z: Zoom) { quick = nil; setZoom(zoom == z ? nil : z) }
        switch hitTest(p, size: size) {
        case .app(let a, _): toggle(.app(a))
        case .exit(let x, _): toggle(.exit(x))
        case .row(let row, _, _): if row.slot != "~+" { toggle(.rule(row.slot)) }
        case .group(let g): if g.rule != nil { toggle(.rule(g.key)) }
        case .none: break
        }
    }

    /// 앱을 누르면 간 곳으로 규칙 만들기, 규칙 밖 목적지를 누르면 그 자리에서 규칙 만들기, 규칙·출구는 강조
    private func tap(_ p: CGPoint, size: CGSize) {
        switch hitTest(p, size: size) {
        case .app(let a, let r):
            quick = QuickPop(kind: .app(a), anchor: r, edge: .trailing)
        case .row(let row, let g, let r):
            if g.rule == nil && !row.more {
                quick = QuickPop(kind: .rule(quickSeed(row)), anchor: r, edge: .leading)
            } else {
                focusRule = focusRule == row.slot ? nil : row.slot; focusExit = nil
            }
        case .group(let g):
            if g.rule != nil { focusRule = focusRule == g.key ? nil : g.key; focusExit = nil }
        case .exit(let x, _):
            focusExit = focusExit == x ? nil : x; focusRule = nil
        case .none:
            focusRule = nil; focusExit = nil
            if zoom != nil || selection != nil { showAll() }       // 빈 곳을 누르면 전체로
        }
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

/// 흐름도 위에 떠 있는 판 (범례·배율 단추): 칸과 같은 바탕에 바깥 그림자 두 개와 옅은 테두리
struct Floating: ViewModifier {
    let dark: Bool
    let fill: Color, light: Color, shade: Color
    func body(content: Content) -> some View {
        content.background(
            Capsule().fill(fill)
                .shadow(color: light.opacity(dark ? 0.9 : 0.95), radius: 8, x: -3, y: -3)
                .shadow(color: shade.opacity(dark ? 1 : 0.9), radius: 10, x: 3.5, y: 5)
        )
        .overlay(Capsule().strokeBorder((dark ? Color.white : .black).opacity(dark ? 0.08 : 0.05)))
    }
}
