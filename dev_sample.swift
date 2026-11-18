// 개발용 표본 상태 (DEBUG 빌드에서만 들어간다 — ./dev.sh --sample).
// root 엔진 없이 팝업·규칙 창을 채워 보려고 WIFIEXIT_SAMPLE 폴더의 status.json · config.json 을 읽는다.
// 규칙 켜기·끄기와 일시정지·재개는 메모리의 표본만 바꾸고, 그 밖의 엔진 명령은 하지 않는다.

#if DEBUG
import Foundation

enum DevSample {
    static let dir: String? = ProcessInfo.processInfo.environment["WIFIEXIT_SAMPLE"].flatMap { $0.isEmpty ? nil : $0 }
    static var on: Bool { dir != nil }

    private static let lock = NSLock()
    private static var loaded = false
    private static var status: EngineStatus?
    private static var config: EngineConfig?
    private static var decisions: [String: String] = [:]   // 규칙을 다시 켤 때 되돌릴 결정

    /// lock 을 잡은 채로 부른다.
    private static func load() {
        guard !loaded, let dir else { return }
        loaded = true
        let decoder = JSONDecoder()
        status = FileManager.default.contents(atPath: dir + "/status.json").flatMap { try? decoder.decode(EngineStatus.self, from: $0) }
        config = FileManager.default.contents(atPath: dir + "/config.json").flatMap { try? decoder.decode(EngineConfig.self, from: $0) }
        if status == nil { FileHandle.standardError.write("표본 상태를 읽지 못했어요: \(dir)/status.json\n".data(using: .utf8)!) }
        for r in status?.rules ?? [] { decisions[r.id] = r.decision == "off" ? "route" : r.decision }
    }

    /// 엔진이 방금 쓴 것처럼 시각을 지금으로 맞춘 표본.
    static func snapshot() -> (EngineStatus?, EngineConfig?) {
        lock.lock(); defer { lock.unlock() }
        load()
        guard var s = status else { return (nil, config) }
        let now = Int(Date().timeIntervalSince1970)
        s.generatedAt = now
        if s.lastApply == 0 { s.lastApply = now - 42 }
        if s.lastResolve == 0 { s.lastResolve = now - 180 }
        return (s, config)
    }

    static func run(_ args: [String]) -> ShellResult {
        lock.lock(); defer { lock.unlock() }
        load()
        guard status != nil else { return ShellResult(code: 1, out: "", err: "표본 상태가 없어요") }
        switch args.first {
        case "on", "off":
            guard args.count == 2, let i = status?.rules.firstIndex(where: { $0.id == args[1] }) else { break }
            let on = args[0] == "on"
            status?.rules[i].enabled = on
            status?.rules[i].decision = on ? decisions[args[1]] ?? "route" : "off"
            if let j = config?.rules.firstIndex(where: { $0.id == args[1] }) { config?.rules[j].enabled = on }
            return ShellResult(code: 0, out: "", err: "")
        case "pause", "resume":
            status?.paused = args[0] == "pause"
            config?.paused = args[0] == "pause"
            return ShellResult(code: 0, out: "", err: "")
        default:
            break
        }
        return ShellResult(code: 1, out: "", err: "표본 상태라 '\(args.joined(separator: " "))'은(는) 하지 않아요")
    }
}

/// 라우팅 보기용 표본 사건 (./dev.sh --sample). 엔진 소켓 대신 표본 규칙의 대상으로 가는 가짜 연결을
/// 열고, 엔진처럼 0.5초마다 오간 양을 보내고, 닫는다. 막는 규칙으로 가는 연결은 막힘 사건 하나로 끝난다.
@MainActor
final class DevSampleEvents {
    private struct Route { let app: String; let exe: String; let rule: String; let dst: [String]; let dport: Int; let iface: String; let block: Bool }
    private struct Flow { var ev: ConnEvent; var age = 0; let life: Int }

    // dev/sample/status.json 의 규칙과 출구에 맞춘 길
    private let routes: [Route] = [
        Route(app: "Safari", exe: "/Applications/Safari.app", rule: "r1", dst: ["192.0.2.10", "192.0.2.11"], dport: 443, iface: "en0", block: false),
        Route(app: "git", exe: "/usr/bin/git", rule: "r1", dst: ["192.0.2.10"], dport: 22, iface: "en0", block: false),
        Route(app: "Slack", exe: "/Applications/Slack.app", rule: "r2", dst: ["203.0.113.20", "203.0.113.21"], dport: 443, iface: "utun4", block: false),
        Route(app: "Dia", exe: "/Applications/Dia.app", rule: "r2", dst: ["203.0.113.40"], dport: 443, iface: "utun4", block: false),
        Route(app: "Finder", exe: "/System/Library/CoreServices/Finder.app", rule: "r3", dst: ["10.20.0.5"], dport: 445, iface: "en7", block: false),
        Route(app: "curl", exe: "/usr/bin/curl", rule: "r4", dst: ["198.51.100.7"], dport: 443, iface: "utun4", block: true),
    ]
    private var flows: [Flow] = []
    private var timer: Timer?
    private let deliver: (ConnEvent) -> Void

    init(deliver: @escaping (ConnEvent) -> Void) { self.deliver = deliver }

    func start() {
        guard timer == nil else { return }
        for _ in 0..<4 { open() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        flows.removeAll()
    }

    private var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func tick() {
        if flows.count < 7, Double.random(in: 0..<1) < 0.3 { open() }
        for i in flows.indices {
            flows[i].age += 1
            guard Double.random(in: 0..<1) < 0.8 else { continue }
            var t = flows[i].ev
            let out = Int.random(in: 1...6), inn = Int.random(in: 1...14)
            t.t = now; t.kind = "traffic"; t.pout = out; t.pin = inn; t.bout = out * 900; t.bin = inn * 1300
            deliver(t)
        }
        for f in flows where f.age >= f.life {
            var c = f.ev
            c.t = now; c.kind = "close"
            deliver(c)
        }
        flows.removeAll { $0.age >= $0.life }
    }

    private func open() {
        guard let r = routes.randomElement(), let dst = r.dst.randomElement() else { return }
        let e = ConnEvent(t: now, act: r.block ? "block" : "pass", iface: r.iface, proto: "tcp",
                          src: r.iface == "utun4" ? "10.124.14.52" : r.iface == "en7" ? "10.10.20.31" : "192.168.0.23",
                          sport: Int.random(in: 49152...65000), dst: dst, dport: r.dport, rule: r.rule,
                          allow: r.block ? nil : r.iface, uid: 501, pid: Int.random(in: 400...9000), app: r.app, exe: r.exe)
        deliver(e)
        if !r.block { flows.append(Flow(ev: e, life: Int.random(in: 8...60))) }
    }
}
#endif
