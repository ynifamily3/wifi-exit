// 앱(app.swift)과 엔진(engine.swift)이 같이 쓰는 경로·설정·상태 모델.

import Foundation

enum Paths {
    static let engine = "/Library/PrivilegedHelperTools/com.miel.WifiExit.engine"
    static let legacyHelper = "/Library/PrivilegedHelperTools/com.miel.WifiExit.helper"
    static let sudoers = "/etc/sudoers.d/wifiexit"     // sudoers.d 는 이름에 '.' 이 있으면 무시하므로 점 없이
    #if WIFI_EXIT_TESTING
    static let dir = NSTemporaryDirectory() + "wifi-exit-tests-\(ProcessInfo.processInfo.processIdentifier)"
    #else
    static let dir = "/Library/Application Support/WifiExit"
    #endif
    static let config = dir + "/config.json"           // root 만 쓴다. 바뀌면 데몬이 곧바로 적용
    static let lock = dir + "/.lock"
    static let stateDir = dir + "/state"               // 엔진이 쓰는 파일. 디렉터리를 나눠 설정 감시에 걸리지 않게 한다
    static let status = stateDir + "/status.json"      // 모두 읽기 가능. 앱·CLI 는 sudo 없이 읽는다
    static let log = stateDir + "/log"
    static let resolved = stateDir + "/resolved.json"
    static let routes = stateDir + "/routes.json"
    static let health = stateDir + "/health.json"              // 출구·규칙 점검 결과 (모두 읽기 가능)
    static let healthOverride = stateDir + "/health-override.json"   // 시험용: 출구를 잠시 실패로 둔다
    static let logging = stateDir + "/logging"                 // 있으면 pf 앵커에 기록(log) 줄을 넣는다 (watch 중)
    static let pfMap = stateDir + "/pfmap.json"                // pf 규칙 번호 → (주소, 규칙 id, 통과/차단)
    static let eventsDir = "/var/run/wifi-exit"
    static let eventsSock = eventsDir + "/events.sock"         // 연결 사건 흐름 (JSON 줄). watch 가 붙어 있는 동안만 기록한다
    static let daemonLabel = "ing.miel.wifi-exit"
    static let daemonPlist = "/Library/LaunchDaemons/ing.miel.wifi-exit.plist"
    static let anchor = "com.apple/wifi-exit"
    #if WIFI_EXIT_TESTING
    static let anchorFile = dir + "/anchor.pf"
    static let resolverDir = dir + "/resolver"
    #else
    static let anchorFile = "/etc/pf.anchors/wifi-exit"
    static let resolverDir = "/etc/resolver"
    #endif
}

// MARK: - 설정 (config.json, v2)

/// 규칙 하나. 위에서부터 보고, 한 주소에는 처음 맞는 규칙 하나만 적용한다.
///   exits: 출구 우선순위 (wifi | wired | tether | vpn:any | vpn:<포털 별칭>). 비어 있으면 "그냥 막기"
///   else:  쓸 수 있는 출구가 없을 때 — block(차단) | system(평소 경로) | next(다음 규칙)
///   when:  조건 (conditions.swift). 안 맞으면 이 규칙은 건너뛰고 다음 규칙으로
struct Rule: Codable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var targets: [String]
    var when: Condition
    var exits: [String]
    var elseAction: String
    var check: String? = nil       // 상태 점검 대상 "host:port": 이 출구로 여기에 닿아야 그 출구를 쓴다

    enum CodingKeys: String, CodingKey { case id, name, enabled, targets, when, exits, elseAction = "else", check }

    init(id: String, name: String, enabled: Bool = true, targets: [String],
         when: Condition = .always, exits: [String] = ["wifi"], elseAction: String = "block", check: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.targets = targets
        self.when = when; self.exits = exits; self.elseAction = elseAction; self.check = check
    }

    /// 화면·CLI 에 보일 이름: 메모가 없으면 첫 대상.
    var isRemaining: Bool { targets.contains(Remaining.target) }
    var title: String { name.isEmpty ? (isRemaining ? "나머지 트래픽" : (targets.first ?? id)) : name }
    var exitsText: String { exits.isEmpty ? "출구 없음" : exits.map(Exits.label).joined(separator: " → ") }
}

/// 상태 점검 대상 "host:port" (host = IPv4 또는 도메인)
enum CheckTarget {
    static func parse(_ s: String) -> (host: String, port: UInt16)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let i = t.lastIndex(of: ":"), let port = UInt16(t[t.index(after: i)...]), port > 0 else { return nil }
        let host = String(t[..<i])
        guard Target.isIPv4(host) || Target.isDomain(host) else { return nil }
        return (host, port)
    }
}

enum Exits {
    static let elseActions = ["block", "system", "next"]

    /// Does a VPN exit's portal (an alias from VPN Bar's tunnels.json, or a portal host such as
    /// cloudvpn.example.com from the older single-tunnel file) belong to `alias`? Exact, not a prefix:
    /// "cloud" must not match a pass tunnel just because a stale file says cloudvpn.
    static func vpnMatches(portal: String, alias: String) -> Bool {
        guard !portal.isEmpty, !alias.isEmpty else { return false }
        if portal == alias { return true }
        let first = portal.split(separator: ".").first.map(String.init) ?? portal
        return portal.contains(".") && (first == alias || first == alias + "vpn")
    }

    static func isValid(_ e: String) -> Bool {
        if ["wifi", "wired", "tether", "vpn:any"].contains(e) { return true }
        guard e.hasPrefix("vpn:") else { return false }
        let alias = e.dropFirst(4)
        return (1...63).contains(alias.count) && alias.first?.isLetter == true
            && alias.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func label(_ e: String) -> String {
        switch e {
        case "wifi": return "Wi-Fi"
        case "wired": return "유선"
        case "tether": return "테더링"
        case "vpn:any": return "VPN(아무거나)"
        default: return e.hasPrefix("vpn:") ? "VPN:" + e.dropFirst(4) : e
        }
    }

    static func elseLabel(_ e: String) -> String {
        switch e {
        case "system": return "평소 경로"
        case "next": return "다음 규칙"
        default: return "차단"
        }
    }

    /// "wifi,wired" → 검사한 목록. 잘못된 이름이 있으면 nil.
    static func parseList(_ s: String) -> [String]? {
        if s == "none" || s.isEmpty { return [] }
        var out: [String] = []
        for raw in s.lowercased().split(separator: ",") {
            let e = raw.trimmingCharacters(in: .whitespaces)
            guard isValid(e) else { return nil }
            if !out.contains(e) { out.append(e) }
        }
        return out.count <= 6 ? out : nil
    }
}

/// 상태 점검 한 건. 연달아 두 번 실패하면 내리고, 두 번 성공하면 올린다.
struct Health: Codable, Equatable {
    var ok = true
    var fails = 0
    var oks = 0
    var at = 0
    var ms: Int? = nil
    var detail = ""
}

struct HealthDB: Codable, Equatable {
    var exits: [String: Health] = [:]     // 인터페이스 → 점검
    var rules: [String: Health] = [:]     // "규칙id|인터페이스" → 규칙 점검 대상에 닿는지
}

/// pf 앵커의 규칙 한 줄이 무엇인지 (pflog 의 규칙 번호를 우리 규칙에 잇는다)
struct PFLine: Codable, Equatable {
    var addr: String
    var rule: String          // 규칙 id
    var kind: String          // pass | block
    var allow: String?        // 고른 출구 인터페이스 (block 줄이 "on ! en0" 이면 en0, 모두 막기면 nil)
}

/// watch 로 흘려보내는 연결 하나
struct ConnEvent: Codable {
    var t: Int                // ms
    var act: String           // pass | block
    var iface: String         // 패킷이 나가려던 인터페이스
    var proto: String         // tcp | udp | …
    var src: String
    var sport: Int
    var dst: String
    var dport: Int
    var rule: String?         // 규칙 id
    var allow: String?        // 그 규칙이 고른 출구 인터페이스
    var uid: Int?
    var pid: Int?
    var app: String?
    var exe: String? = nil    // 앱 번들(.app) 경로, 번들이 아니면 실행 파일 경로 (아이콘용)
    var outside: Bool? = nil  // 규칙 밖 연결 (앱이 연결 표를 훑어 찾은 것, pf 기록이 아님)
    var kind: String? = nil   // nil = 연결 시작(또는 막힘) · "traffic" = 패킷이 오감 · "close" = 연결이 닫힘
    var pout: Int? = nil      // 지난번 이후 나간 패킷 수 (traffic)
    var pin: Int? = nil       // 들어온 패킷 수
    var bout: Int? = nil      // 나간 바이트
    var bin: Int? = nil       // 들어온 바이트
    enum CodingKeys: String, CodingKey { case t, act, iface = "if", proto, src, sport, dst, dport, rule, allow, uid, pid, app, exe, outside, kind, pout, pin, bout, bin }

    /// 연결 하나를 가리키는 열쇠 (프로토콜, 출발 주소·포트, 목적지 주소·포트)
    var flowKey: String { "\(proto) \(src):\(sport)>\(dst):\(dport)" }
}

struct EngineConfig: Codable, Equatable {
    var version: Int = 2
    var paused: Bool = false
    var rules: [Rule] = []
    var profiles: [String: NetProfile] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        rules = Remaining.ordered(try c.decodeIfPresent([Rule].self, forKey: .rules) ?? [])
        profiles = try c.decodeIfPresent([String: NetProfile].self, forKey: .profiles) ?? [:]
    }
}

// MARK: - 대상 검사

enum TargetKind: String, Codable { case ip, cidr, domain, remaining }

enum Target {
    static func ipv4Octets(_ s: String) -> [UInt32]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt32] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let v = UInt32(p), v <= 255 else { return nil }
            out.append(v)
        }
        return out
    }
    static func ipv4Number(_ s: String) -> UInt32? {
        guard let o = ipv4Octets(s) else { return nil }
        return o[0] << 24 | o[1] << 16 | o[2] << 8 | o[3]
    }
    static func ipv4String(_ n: UInt32) -> String { "\(n >> 24 & 255).\(n >> 16 & 255).\(n >> 8 & 255).\(n & 255)" }

    static func isIPv4(_ s: String) -> Bool {
        guard let o = ipv4Octets(s) else { return false }
        return o[0] != 0 && o[0] != 127 && s != "255.255.255.255"
    }

    /// "10.1.2.3/24" → "10.1.2.0/24". 프리픽스는 8–32.
    static func normalizedCIDR(_ s: String) -> String? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, isIPv4(String(parts[0])), let p = Int(parts[1]), (8...32).contains(p),
              let n = ipv4Number(String(parts[0])) else { return nil }
        let mask: UInt32 = p == 32 ? ~0 : ~(~UInt32(0) >> UInt32(p))
        return "\(ipv4String(n & mask))/\(p)"
    }

    static func isDomain(_ s: String) -> Bool {
        guard s.count <= 253, s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        for l in labels {
            guard (1...63).contains(l.count), !l.hasPrefix("-"), !l.hasSuffix("-"),
                  l.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return false }
        }
        guard let tld = labels.last, tld.first?.isLetter == true else { return false }
        return true
    }

    /// 대상 문자열을 정규화하고 종류를 돌려준다. 받을 수 없는 값이면 nil.
    static func parse(_ raw: String) -> (String, TargetKind)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == Remaining.target { return (s, .remaining) }
        if isIPv4(s) { return (s, .ip) }
        if s.contains("/"), let c = normalizedCIDR(s) { return (c, .cidr) }
        if isDomain(s) { return (s, .domain) }
        return nil
    }
}

/// 메모: 탭·줄바꿈을 없애고 NFC 로 바꿔 80자까지.
func cleanNote(_ s: String) -> String {
    let flat = s.precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return String(flat.prefix(80))
}

// MARK: - 상태 (state/status.json)

struct LinkInfo: Codable, Equatable {
    var iface: String
    var ip: String
    var gateway: String
    var dns: [String]
    var signature: String      // 예: IPv4.Router=192.168.0.1;IPv4.RouterHardwareAddress=aa:bb:… (P3 네트워크 프로필용)
    var up: Bool
    enum CodingKeys: String, CodingKey { case iface = "if", ip, gateway, dns, signature, up }
}

struct AddressStatus: Codable, Hashable {
    var ip: String
    var interface: String      // 지금 커널이 고르는 인터페이스 (route get)
    var pinned: Bool           // 고른 출구로 가는 고정 라우트가 있는지
    var blocked: Bool          // 고른 출구 밖으로는(출구가 없으면 모든 곳으로) pf 가 막는지
    var owner: String?         // 앞 규칙이 이미 이 주소를 잡았으면 그 규칙 id
    var note: String?          // 예: 터널 붕괴 방지로 제외
}

/// 지금 쓸 수 있는(또는 없는) 출구 하나.
struct ExitInfo: Codable, Hashable {
    var name: String           // wifi | wired | tether | vpn
    var iface: String
    var ip: String
    var gateway: String        // VPN 은 빈 값 (인터페이스로 보낸다)
    var dns: [String]
    var portal: String         // VPN 포털 주소 (gpvpn), 그 밖엔 빈 값
    var up: Bool
    var signature: String? = nil   // IPv4.Router=…;IPv4.RouterHardwareAddress=… (네트워크 프로필 판별용)
    var healthy: Bool? = nil       // 상태 점검 결과 (nil = 아직 모름 → 쓸 수 있는 것으로 본다)
    var healthDetail: String? = nil
    var label: String {
        switch name {
        case "vpn": return portal.isEmpty ? "VPN(\(iface))" : "VPN:\(portal.split(separator: ".").first ?? "")"
        default: return Exits.label(name)
        }
    }
}

struct TargetStatus: Codable, Hashable {
    var target: String
    var kind: TargetKind
    var addresses: [AddressStatus]
}

struct RuleStatus: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var exits: [String]
    var elseAction: String
    var chosenExit: String?    // 지금 고른 출구 이름 (규칙에 적힌 그대로: wifi, vpn:pass …)
    var chosenIface: String?   // 그 출구의 실제 인터페이스 (en0, utun4 …)
    var decision: String       // route | block | system | next | skip(조건 안 맞음) | off
    var when: String? = nil    // 조건 글 (always 면 nil)
    var conditionDetail: String? = nil   // 조건을 사실마다 따져 본 결과
    var check: String? = nil             // 상태 점검 대상
    var reason: String         // 왜 그렇게 됐는지 한 줄
    var targets: [TargetStatus]

    var title: String { name.isEmpty ? (targets.first?.kind == .remaining ? "나머지 트래픽" : (targets.first?.target ?? id)) : name }
    var addresses: [AddressStatus] { targets.flatMap(\.addresses) }
    /// 이 규칙이 실제로 맡은 주소 (앞 규칙에 가려진 것 제외)
    var ownAddresses: [AddressStatus] { addresses.filter { $0.owner == nil } }
    var exitsText: String { exits.isEmpty ? "출구 없음" : exits.map(Exits.label).joined(separator: " → ") }
}

struct EngineStatus: Codable {
    var version: Int = 2
    var generatedAt: Int
    var paused: Bool
    var wifi: LinkInfo
    var defaultIf: String
    var pfEnabled: Bool
    var lastResolve: Int
    var lastApply: Int
    var rules: [RuleStatus]
    var exits: [ExitInfo]
    var errors: [String]
    var vpnOver: String? = nil     // VPN 터널이 올라탄 링크 (조건 vpnover)
}

enum RuleState {
    case ok, fixing, noExit, unresolved, leak, off, paused, bypass

    var text: String {
        switch self {
        case .ok: return "고정됨"
        case .fixing: return "차단됨 · 경로 맞추는 중"
        case .noExit: return "출구 없음 · 차단 중"
        case .unresolved: return "아직 IP를 못 풀었음"
        case .leak: return "차단 규칙 없음 — 다른 길로 샐 수 있음"
        case .off: return "꺼짐"
        case .paused: return "일시정지"
        case .bypass: return "규칙 미적용 · 평소 경로"
        }
    }
    var cliMark: String {
        switch self {
        case .ok: return "✓"
        case .fixing: return "~"
        case .noExit: return "⊘"
        case .unresolved: return "?"
        case .leak: return "!"
        case .off: return "-"
        case .paused: return "‖"
        case .bypass: return "·"
        }
    }
}

extension EngineStatus {
    func state(of r: RuleStatus) -> RuleState {
        if !r.enabled { return .off }
        if paused { return .paused }
        if r.addresses.isEmpty { return .unresolved }
        if r.decision == "system" || r.decision == "next" || r.decision == "skip" { return .bypass }
        let addrs = r.ownAddresses.filter { $0.note == nil }
        if addrs.contains(where: { !$0.blocked }) { return .leak }
        if r.decision == "block" { return .noExit }
        return addrs.filter { !$0.ip.contains(":") }.allSatisfy(\.pinned) ? .ok : .fixing
    }

    /// 사람이 읽을 상태 한 줄: "Wi-Fi(en0)로 고정" 처럼 출구를 넣는다.
    func stateText(of r: RuleStatus) -> String {
        let st = state(of: r)
        if st == .ok || st == .fixing, let e = r.chosenExit {
            let where_ = "\(Exits.label(e))(\(r.chosenIface ?? "?"))"
            return st == .ok ? "\(where_)로 고정" : "\(where_) · 경로 맞추는 중"
        }
        if st == .bypass {
            switch r.decision {
            case "skip": return "조건 안 맞음 → 다음 규칙으로"
            case "next": return "출구 없음 → 다음 규칙으로"
            default: return "출구 없음 → 평소 경로"
            }
        }
        return st.text
    }
    var hasLeak: Bool { rules.contains { state(of: $0) == .leak } }
    var activeCount: Int { rules.filter(\.enabled).count }
    var ageSeconds: Int { Int(Date().timeIntervalSince1970) - generatedAt }

    var defaultIfText: String {
        if defaultIf.hasPrefix("utun") { return "\(defaultIf) (VPN)" }
        if defaultIf == wifi.iface { return "\(defaultIf) (Wi-Fi)" }
        return defaultIf.isEmpty ? "없음" : "\(defaultIf) (유선 등)"
    }
}

func readStatus() -> EngineStatus? {
    guard let d = FileManager.default.contents(atPath: Paths.status) else { return nil }
    return try? JSONDecoder().decode(EngineStatus.self, from: d)
}

// MARK: - 자식 프로세스

extension Process {
    /// run() 하고 끝남을 기다릴 신호를 돌려준다. waitUntilExit() 는 런루프를 돌며 기다려서
    /// 자식이 끝난 뒤에도 60ms 남짓 늦게 돌아온다 (apply 한 번에 명령 20개면 1초 넘게 버린다).
    func runWatched() throws -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        terminationHandler = { _ in done.signal() }
        try run()
        return done
    }
}
