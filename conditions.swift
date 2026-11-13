// 규칙 조건(when)과 출구 결정. 엔진과 앱(CLI simulate/explain)이 같은 코드로 판단한다.
//
// 조건 글:  vpn=pass and (link=wired or profile=사무실)
//           not vpn=none, day=mon-fri and time=09:00-18:00
//   키      값
//   vpn     none | any | <포털 별칭>(포털 주소가 이걸로 시작) — 지금 붙어 있는 VPN
//   link    wifi | wired | tether — 그 링크가 살아 있음
//   profile <이름> — 지금 붙은 망이 저장해 둔 네트워크 프로필(게이트웨이 IP + MAC)과 같음
//   default wifi | wired | tether | vpn — 기본 경로가 그쪽
//   vpnover wifi | wired | tether — VPN 터널이 그 링크 위에 있음
//   time    HH:MM-HH:MM (자정을 넘겨도 됨)
//   day     mon,tue,… 또는 mon-fri
//   =, != / and(&&, 그리고) / or(||, 또는) / not(!) / 괄호 / always
//
// JSON: "always" | {"all":[…]} | {"any":[…]} | {"not":…} | {"vpn":"pass"} …

import Foundation

indirect enum Condition: Equatable {
    case always
    case all([Condition])
    case any([Condition])
    case not(Condition)
    case fact(String, String)        // 키, 값

    static let keys = ["vpn", "link", "profile", "default", "vpnover", "time", "day"]
    static let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]   // Calendar weekday 1…7

    var isAlways: Bool { self == .always }

    /// 사람이 쓰는 글로 (parse 의 역).
    var text: String { render(top: true) }

    private func render(top: Bool) -> String {
        switch self {
        case .always: return "always"
        case .fact(let k, let v): return "\(k)=\(v)"
        case .not(.fact(let k, let v)): return "\(k)!=\(v)"
        case .not(let c): return "not \(c.render(top: false).wrappedIfCompound(c))"
        case .all(let cs): let s = cs.map { c in c.isAny ? "(\(c.render(top: false)))" : c.render(top: false) }.joined(separator: " and "); return s
        case .any(let cs): return cs.map { c in c.isAll ? "(\(c.render(top: false)))" : c.render(top: false) }.joined(separator: " or ")
        }
    }
    var isAny: Bool { if case .any = self { return true }; return false }
    var isAll: Bool { if case .all = self { return true }; return false }

    /// 키·값이 올바른지. 프로필 이름은 profiles 안에 있어야 한다.
    func validate(profiles: Set<String>) -> String? {
        switch self {
        case .always: return nil
        case .all(let cs), .any(let cs): return cs.isEmpty ? "빈 조건 묶음" : cs.lazy.compactMap { $0.validate(profiles: profiles) }.first
        case .not(let c): return c.validate(profiles: profiles)
        case .fact(let k, let v):
            switch k {
            case "vpn":
                return v == "none" || v == "any" || Exits.isValid("vpn:" + v) ? nil : "vpn 값은 none | any | <포털 별칭>: '\(v)'"
            case "link", "vpnover":
                return ["wifi", "wired", "tether"].contains(v) ? nil : "\(k) 값은 wifi | wired | tether: '\(v)'"
            case "default":
                return ["wifi", "wired", "tether", "vpn"].contains(v) ? nil : "default 값은 wifi | wired | tether | vpn: '\(v)'"
            case "profile":
                return profiles.contains(v) ? nil : "없는 프로필: '\(v)' (wifi-exit profile add 로 먼저 저장)"
            case "time":
                return Condition.timeRange(v) != nil ? nil : "time 값은 HH:MM-HH:MM: '\(v)'"
            case "day":
                return Condition.daySet(v) != nil ? nil : "day 값은 mon,tue… 또는 mon-fri: '\(v)'"
            default:
                return "알 수 없는 조건 키: '\(k)' (\(Condition.keys.joined(separator: ", ")))"
            }
        }
    }

    /// "09:00-18:00" → (분, 분)
    static func timeRange(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: "-")
        guard p.count == 2, let a = minutes(String(p[0])), let b = minutes(String(p[1])), a != b else { return nil }
        return (a, b)
    }
    private static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h) || (h == 24 && m == 0), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
    /// "mon-fri" / "sat,sun" → weekday 집합 (1=일 … 7=토)
    static func daySet(_ s: String) -> Set<Int>? {
        var out = Set<Int>()
        for part in s.split(separator: ",") {
            let r = part.split(separator: "-").map { String($0) }
            guard (1...2).contains(r.count), let a = days.firstIndex(of: r[0]) else { return nil }
            if r.count == 1 { out.insert(a + 1); continue }
            guard let b = days.firstIndex(of: r[1]) else { return nil }
            var i = a
            while true { out.insert(i + 1); if i == b { break }; i = (i + 1) % 7 }
        }
        return out.isEmpty ? nil : out
    }
}

private extension String {
    func wrappedIfCompound(_ c: Condition) -> String {
        switch c { case .all, .any: return "(\(self))"; default: return self }
    }
}

// MARK: - JSON

extension Condition: Codable {
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            guard s == "always" else {
                // 글로 적어 둔 조건도 받는다
                guard let c = try? Condition.parse(s) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad condition: \(s)"))
                }
                self = c; return
            }
            self = .always; return
        }
        let d = try decoder.container(keyedBy: AnyKey.self)
        guard let k = d.allKeys.first, d.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "condition object needs exactly one key"))
        }
        switch k.stringValue {
        case "all": self = .all(try d.decode([Condition].self, forKey: k))
        case "any": self = .any(try d.decode([Condition].self, forKey: k))
        case "not": self = .not(try d.decode(Condition.self, forKey: k))
        default: self = .fact(k.stringValue, try d.decode(String.self, forKey: k))
        }
    }
    func encode(to encoder: Encoder) throws {
        switch self {
        case .always:
            var c = encoder.singleValueContainer(); try c.encode("always")
        case .all(let cs):
            var c = encoder.container(keyedBy: AnyKey.self); try c.encode(cs, forKey: AnyKey("all"))
        case .any(let cs):
            var c = encoder.container(keyedBy: AnyKey.self); try c.encode(cs, forKey: AnyKey("any"))
        case .not(let x):
            var c = encoder.container(keyedBy: AnyKey.self); try c.encode(x, forKey: AnyKey("not"))
        case .fact(let k, let v):
            var c = encoder.container(keyedBy: AnyKey.self); try c.encode(v, forKey: AnyKey(k))
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - 글 → 조건

struct ConditionError: Error, CustomStringConvertible { let description: String }

extension Condition {
    static func parse(_ text: String) throws -> Condition {
        var p = Parser(tokens: tokenize(text))
        if p.tokens.isEmpty { return .always }
        let c = try p.parseOr()
        guard p.atEnd else { throw ConditionError(description: "알 수 없는 부분: '\(p.tokens[p.i...].joined(separator: " "))'") }
        return c
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { flush() }
            else if ch == "(" || ch == ")" { flush(); out.append(String(ch)) }
            else if ch == "!" && i + 1 < chars.count && chars[i + 1] == "=" { flush(); out.append("!="); i += 1 }
            else if ch == "=" { flush(); out.append("=") }
            else if ch == "&" && i + 1 < chars.count && chars[i + 1] == "&" { flush(); out.append("and"); i += 1 }
            else if ch == "|" && i + 1 < chars.count && chars[i + 1] == "|" { flush(); out.append("or"); i += 1 }
            else if ch == "!" && cur.isEmpty { out.append("not") }
            else { cur.append(ch) }
            i += 1
        }
        flush()
        return out.map { t in
            switch t.lowercased() {
            case "and", "그리고": return "and"
            case "or", "또는": return "or"
            case "not": return "not"
            default: return t
            }
        }
    }

    private struct Parser {
        let tokens: [String]
        var i = 0
        var atEnd: Bool { i >= tokens.count }
        var peek: String? { atEnd ? nil : tokens[i] }
        mutating func next() -> String? { defer { i += 1 }; return peek }

        mutating func parseOr() throws -> Condition {
            var xs = [try parseAnd()]
            while peek == "or" { _ = next(); xs.append(try parseAnd()) }
            return xs.count == 1 ? xs[0] : .any(xs)
        }
        mutating func parseAnd() throws -> Condition {
            var xs = [try parseUnary()]
            while peek == "and" { _ = next(); xs.append(try parseUnary()) }
            return xs.count == 1 ? xs[0] : .all(xs)
        }
        mutating func parseUnary() throws -> Condition {
            guard let t = next() else { throw ConditionError(description: "조건이 덜 끝났어요") }
            switch t {
            case "not": return .not(try parseUnary())
            case "(":
                let c = try parseOr()
                guard next() == ")" else { throw ConditionError(description: "괄호가 닫히지 않았어요") }
                return c
            case "always": return .always
            case ")", "and", "or", "=", "!=": throw ConditionError(description: "'\(t)' 앞에 조건이 필요해요")
            default:
                let key = t.lowercased()
                guard let op = next(), op == "=" || op == "!=" else { throw ConditionError(description: "'\(t)' 뒤에 = 또는 != 가 필요해요") }
                guard let v = next(), !["(", ")", "and", "or", "not", "=", "!="].contains(v) else { throw ConditionError(description: "'\(t)\(op)' 뒤에 값이 필요해요") }
                let value = key == "profile" ? v.precomposedStringWithCanonicalMapping : v.lowercased()
                return op == "=" ? .fact(key, value) : .not(.fact(key, value))
            }
        }
    }
}

// MARK: - 판단에 쓰는 사실

/// 저장해 둔 네트워크 프로필: 이 링크가 이 게이트웨이(그리고 MAC)에 붙어 있으면 같은 망으로 본다.
struct NetProfile: Codable, Equatable {
    var link: String          // wifi | wired | tether
    var gateway: String
    var gatewayMac: String
}

struct Facts {
    var exits: [ExitInfo]                 // 살아 있는 것과 아닌 것 모두
    var profiles: [String: NetProfile]
    var defaultIf: String
    var vpnOver: String                   // VPN 터널이 올라탄 링크 (wifi/wired/tether, 모르면 "")
    var date: Date
    var forcedProfiles: Set<String>? = nil   // simulate 에서 "지금 이 프로필 망에 있다"고 가정할 때
    var ruleChecks: [String: Bool] = [:]     // "규칙id|인터페이스" → 그 출구로 규칙의 점검 대상에 닿는지

    var up: [ExitInfo] { exits.filter(\.up) }

    func linkUp(_ l: String) -> Bool { up.contains { $0.name == l } }
    var vpn: ExitInfo? { up.first { $0.name == "vpn" } }

    func profileMatches(_ name: String) -> Bool {
        if let f = forcedProfiles { return f.contains(name) }
        guard let p = profiles[name] else { return false }
        return up.contains { e in
            e.name == p.link && e.gateway == p.gateway
                && (p.gatewayMac.isEmpty || (e.signature ?? "").lowercased().contains("routerhardwareaddress=\(p.gatewayMac.lowercased())"))
        }
    }

    var defaultLink: String {
        if defaultIf.isEmpty { return "" }
        return exits.first { $0.iface == defaultIf }?.name ?? (defaultIf.hasPrefix("utun") ? "vpn" : "")
    }

    /// 사실 하나의 값과 참·거짓. 설명에 쓰려고 지금 값도 돌려준다.
    func fact(_ k: String, _ v: String) -> (Bool, String) {
        switch k {
        case "vpn":
            let now = vpn.map { $0.portal.isEmpty ? "any(\($0.iface))" : $0.portal } ?? "none"
            switch v {
            case "none": return (vpn == nil, now)
            case "any": return (vpn != nil, now)
            default: return (vpn.map { Exits.vpnMatches(portal: $0.portal, alias: v) } ?? false, now)
            }
        case "link":
            return (linkUp(v), up.map(\.name).filter { $0 != "vpn" }.joined(separator: ",").ifEmpty("없음"))
        case "profile":
            let names = profiles.keys.filter(profileMatches).sorted()
            return (profileMatches(v), names.joined(separator: ",").ifEmpty("없음"))
        case "default":
            return (defaultLink == v, defaultLink.ifEmpty("없음"))
        case "vpnover":
            return (vpnOver == v, vpnOver.ifEmpty("없음"))
        case "time":
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            let now = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            guard let (a, b) = Condition.timeRange(v) else { return (false, now) }
            return (a < b ? (m >= a && m < b) : (m >= a || m < b), now)
        case "day":
            let wd = Calendar.current.component(.weekday, from: date)
            return (Condition.daySet(v)?.contains(wd) ?? false, Condition.days[wd - 1])
        default:
            return (false, "?")
        }
    }

    func eval(_ c: Condition) -> Bool {
        switch c {
        case .always: return true
        case .all(let cs): return cs.allSatisfy(eval)
        case .any(let cs): return cs.contains(where: eval)
        case .not(let x): return !eval(x)
        case .fact(let k, let v): return fact(k, v).0
        }
    }

    /// "vpn=work ✗(지금 다른 VPN…) and link=wired ✓" 처럼 사실마다 결과를 붙인다.
    func explain(_ c: Condition) -> String {
        switch c {
        case .always: return "always ✓"
        case .fact(let k, let v):
            let (ok, now) = fact(k, v)
            return "\(k)=\(v) \(ok ? "✓" : "✗(지금 \(now))")"
        case .not(.fact(let k, let v)):
            let (ok, now) = fact(k, v)
            return "\(k)!=\(v) \(!ok ? "✓" : "✗(지금 \(now))")"
        case .not(let x): return "not (\(explain(x)))"
        case .all(let cs): return cs.map { c in c.isAny ? "(\(explain(c)))" : explain(c) }.joined(separator: " and ")
        case .any(let cs): return cs.map { c in c.isAll ? "(\(explain(c)))" : explain(c) }.joined(separator: " or ")
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - 출구 결정

/// 규칙에 적힌 출구 이름에 맞는, 지금 연결된 출구들 (상태 점검과 상관없이).
func matchingExits(_ name: String, in exits: [ExitInfo]) -> [ExitInfo] {
    let up = exits.filter(\.up)
    switch name {
    case "wifi", "wired", "tether": return up.filter { $0.name == name }
    case "vpn:any": return up.filter { $0.name == "vpn" }
    default:
        guard name.hasPrefix("vpn:") else { return [] }
        let alias = String(name.dropFirst(4))
        return up.filter { $0.name == "vpn" && Exits.vpnMatches(portal: $0.portal, alias: alias) }
    }
}

/// 규칙에 적힌 출구 이름으로 지금 쓸 수 있는 출구를 찾는다 (응답 없는 출구는 뺀다).
func findExit(_ name: String, in exits: [ExitInfo]) -> ExitInfo? {
    matchingExits(name, in: exits).first { $0.healthy != false }
}

/// 이 규칙에 이 출구를 쓸 수 있는지: 연결돼 있고, 응답하고, 규칙의 점검 대상에 닿아야 한다.
func usable(_ e: ExitInfo, for r: Rule, facts: Facts) -> Bool {
    e.healthy != false && (r.check == nil || facts.ruleChecks["\(r.id)|\(e.iface)"] != false)
}

/// 출구 이름을 못 쓰는 이유: 없음 / 응답 없음 / 점검 대상에 안 닿음
func whyNot(_ name: String, for r: Rule, facts: Facts) -> String {
    let ms = matchingExits(name, in: facts.exits)
    if ms.isEmpty { return "\(Exits.label(name)) 없음" }
    if ms.allSatisfy({ $0.healthy == false }) { return "\(Exits.label(name)) 응답 없음" }
    if let c = r.check { return "\(Exits.label(name))로 \(c) 안 닿음" }
    return "\(Exits.label(name)) 못 씀"
}

enum Outcome {
    case route(name: String, exit: ExitInfo)
    case block, system, next, skip, off

    var word: String {
        switch self {
        case .route: return "route"; case .block: return "block"; case .system: return "system"
        case .next: return "next"; case .skip: return "skip"; case .off: return "off"
        }
    }
}

/// 규칙 하나를 지금 사실로 판단한다. 조건이 안 맞으면 skip(다음 규칙으로).
func decide(_ r: Rule, facts: Facts) -> Outcome {
    guard r.enabled else { return .off }
    guard facts.eval(r.when) else { return .skip }
    for n in r.exits {
        if let e = matchingExits(n, in: facts.exits).first(where: { usable($0, for: r, facts: facts) }) {
            return .route(name: n, exit: e)
        }
    }
    switch r.elseAction {
    case "system": return .system
    case "next": return .next
    default: return .block
    }
}

/// 사람이 읽을 이유 한 줄.
func reasonText(_ r: Rule, _ o: Outcome, facts: Facts, paused: Bool) -> String {
    switch o {
    case .off: return !r.enabled ? "꺼짐" : paused ? "일시정지 — 평소 경로로 나감" : "꺼짐"
    case .skip: return "조건 안 맞음: \(facts.explain(r.when)) → 다음 규칙으로"
    case .route(let name, let e):
        let skipped = r.exits.prefix { $0 != name }.map { whyNot($0, for: r, facts: facts) }
        let rank = (r.exits.firstIndex(of: name) ?? 0) + 1
        return (skipped.isEmpty ? "" : skipped.joined(separator: ", ") + " → ") + "\(rank)순위 \(Exits.label(name))(\(e.iface)) 사용, 다른 출구는 차단"
    case .block: return r.exits.isEmpty ? "출구 없음(그냥 막기) → 차단" : "\(r.exits.map { whyNot($0, for: r, facts: facts) }.joined(separator: ", ")) → 차단 (다른 길로 새지 않음)"
    case .system: return "\(r.exits.map { whyNot($0, for: r, facts: facts) }.joined(separator: ", ")) → 규칙 미적용, 평소 경로로"
    case .next: return "\(r.exits.map { whyNot($0, for: r, facts: facts) }.joined(separator: ", ")) → 다음 규칙으로"
    }
}

// MARK: - 조건 빌더 (편집 화면용)
//
// 화면은 "모두/하나라도" 묶음 하나와, 그 안에 한 단계 더 묶음을 둘 수 있다.
//   묶음 = 사실 줄들(키 = / != 값) + 하위 묶음들(사실 줄만)
// 이 꼴로 나타낼 수 없는 조건(더 깊은 중첩, not (묶음))은 글로만 고친다.

struct CondRow: Identifiable, Equatable {
    var id = UUID()
    var key: String = "vpn"
    var negate = false
    var value: String = ""

    static func == (a: CondRow, b: CondRow) -> Bool { a.key == b.key && a.negate == b.negate && a.value == b.value }
    var condition: Condition { negate ? .not(.fact(key, value)) : .fact(key, value) }
}

struct CondGroup: Identifiable, Equatable {
    var id = UUID()
    var any = false                 // false: 모두(and), true: 하나라도(or)
    var rows: [CondRow] = []
    var groups: [CondGroup] = []    // 맨 위 묶음에서만 쓴다

    static func == (a: CondGroup, b: CondGroup) -> Bool { a.any == b.any && a.rows == b.rows && a.groups == b.groups }
    var isEmpty: Bool { rows.isEmpty && groups.allSatisfy(\.isEmpty) }

    var condition: Condition {
        var items: [Condition] = rows.map(\.condition)
        for g in groups where !g.isEmpty {
            let sub = g.rows.map(\.condition)
            items.append(sub.count == 1 ? sub[0] : (g.any ? .any(sub) : .all(sub)))
        }
        if items.isEmpty { return .always }
        if items.count == 1 { return items[0] }
        return any ? .any(items) : .all(items)
    }
}

extension Condition {
    private var atomRow: CondRow? {
        switch self {
        case .fact(let k, let v): return CondRow(key: k, negate: false, value: v)
        case .not(.fact(let k, let v)): return CondRow(key: k, negate: true, value: v)
        default: return nil
        }
    }

    /// 빌더로 나타낼 수 있으면 그 꼴로, 아니면 nil.
    var builder: CondGroup? {
        switch self {
        case .always: return CondGroup()
        case .fact, .not(.fact): return CondGroup(rows: [atomRow!])
        case .all(let cs), .any(let cs):
            var g = CondGroup(any: isAny)
            for c in cs {
                if let r = c.atomRow { g.rows.append(r); continue }
                switch c {
                case .all(let sub), .any(let sub):
                    let rows = sub.compactMap(\.atomRow)
                    guard rows.count == sub.count else { return nil }
                    g.groups.append(CondGroup(any: c.isAny, rows: rows))
                default: return nil
                }
            }
            return g
        default: return nil
        }
    }
}

// MARK: - 가려진 규칙

/// 대상 a 가 대상 b 에 포함되는지 (같은 값, 또는 IP/망이 망 안에).
func targetCovered(_ a: String, by b: String) -> Bool {
    if a == b { return true }
    guard b.contains("/"), let bn = Target.normalizedCIDR(b) else { return false }
    let parts = bn.split(separator: "/")
    guard let net = Target.ipv4Number(String(parts[0])), let p = UInt32(parts[1]) else { return false }
    let mask: UInt32 = p == 32 ? ~0 : ~(~UInt32(0) >> p)
    let aIP = String(a.split(separator: "/")[0])
    let aP = a.contains("/") ? UInt32(a.split(separator: "/")[1]) ?? 32 : 32
    guard let an = Target.ipv4Number(aIP), aP >= p else { return false }
    return an & mask == net
}

/// rules[index] 의 대상 중 앞 규칙이 먼저 잡는 것. addresses: 도메인 → 지금 풀린 IP (상태 파일에서).
/// 앞 규칙에 조건이 있거나 "다음 규칙"으로 넘길 수 있으면 "때때로" 가려진다.
func shadowWarnings(_ rules: [Rule], index: Int, addresses: [String: [String]]) -> [String] {
    guard rules.indices.contains(index) else { return [] }
    let me = rules[index]
    var out: [String] = []
    for t in me.targets {
        let mine = Target.parse(t)?.1 == .domain ? (addresses[t] ?? []) : [t]
        for (j, r) in rules.enumerated() where j < index && r.enabled {
            let sometimes = !r.when.isAlways || r.elseAction == "next"
            let hit: String?
            if r.targets.contains(where: { targetCovered(t, by: $0) }) {
                hit = t
            } else {
                let theirs = r.targets.flatMap { Target.parse($0)?.1 == .domain ? (addresses[$0] ?? []) : [$0] }
                hit = mine.first { m in theirs.contains { targetCovered(m, by: $0) } }
            }
            if let h = hit {
                out.append("\(h == t ? t : "\(t)의 \(h)")는 #\(j + 1) \(r.title) 규칙이 \(sometimes ? "조건이 맞을 때" : "늘") 먼저 맡아요")
                break
            }
        }
    }
    return out
}
