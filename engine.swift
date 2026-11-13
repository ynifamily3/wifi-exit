// wifi-exitd — Wi-Fi Exit 의 root 엔진. /Library/PrivilegedHelperTools/com.miel.WifiExit.engine 에 root 소유로 깔린다.
//
//   wifi-exitd daemon                         상주. 네트워크 변화(SCDynamicStore)·설정 변경에 곧바로, 그리고 30초마다 적용
//   wifi-exitd apply [--resolve]              지금 적용 (--resolve: 도메인도 지금 다시 풀기)
//   wifi-exitd add <대상> [--via a,b] [--else block|system|next] [--when 조건] [메모...]
//   wifi-exitd set <대상|id> [--via a,b] [--else …] [--when 조건] [--name 메모...]
//   wifi-exitd profile add <이름> [wifi|wired|tether] | profile rm <이름>
//   wifi-exitd health check | health fail <출구|인터페이스> [초] | health clear
//   wifi-exitd move <대상|id> up|down|top|bottom|<위치>
//   wifi-exitd rm|on|off <대상|규칙 id>
//   wifi-exitd pause | resume
//   wifi-exitd status | log [n] | selftest [--port N] [--verbose]
//   wifi-exitd install | uninstall
//
// 앱·CLI 는 sudoers 규칙으로 암호 없이 이 파일을 부른다. 그래서 인자는 모두 엄격하게 검사하고,
// 셸을 거치지 않고 절대 경로의 도구만 부른다.
//
// 규칙은 위에서부터 본다. 한 주소에는 처음 맞는 규칙 하나만 적용한다 (방화벽과 같다).
// 규칙마다 출구 목록에서 지금 쓸 수 있는 첫 출구로 보내고, 그 출구 밖으로는 pf 로 막는다.
// 쓸 수 있는 출구가 없으면 else 에 따라 차단 / 평소 경로 / 다음 규칙.
// 조건(when)이 안 맞는 규칙은 건너뛴다 (다음 규칙이 그 주소를 맡을 수 있다).

import Darwin
import Foundation
import SystemConfiguration

let RESOLVE_EVERY = 300      // 도메인 재해석 주기(초)
let GRACE = 3600             // DNS 답에서 빠진 IP 를 더 붙잡아 두는 시간(초)
let SAFETY_TICK = 30.0       // 이벤트를 놓쳐도 이 주기로 한 번 더 맞춘다
let HEALTH_EVERY = 10.0      // 출구 상태 점검 주기(초)
let HEALTH_DOWN_AFTER = 2    // 연달아 이만큼 실패하면 "응답 없음"
let HEALTH_UP_AFTER = 2      // 연달아 이만큼 성공하면 다시 씀
let MARK = "# managed by WifiExit"

// MARK: - 기본 도구

struct Out { let code: Int32; let out: String; let err: String; var ok: Bool { code == 0 } }

#if WIFI_EXIT_TESTING
enum TestHooks {
    static var run: ((String, [String]) -> Out)?
    static var net: NetSnapshot?
}
#endif

@discardableResult
func run(_ path: String, _ args: [String]) -> Out {
    #if WIFI_EXIT_TESTING
    if let hook = TestHooks.run { return hook(path, args) }
    fatalError("Tests must intercept every command")
    #else
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
    let done: DispatchSemaphore
    do { done = try p.runWatched() } catch { return Out(code: -1, out: "", err: "\(error)") }
    var errData = Data()
    let g = DispatchGroup(); g.enter()
    DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    g.wait(); done.wait()
    return Out(code: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    #endif
}

func now() -> Int { Int(Date().timeIntervalSince1970) }

/// 순서를 지키며 중복을 뺀다.
func uniq<T: Hashable>(_ xs: [T]) -> [T] { var seen = Set<T>(); return xs.filter { seen.insert($0).inserted } }

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("wifi-exit: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

func ensureDirs() {
    let fm = FileManager.default
    for d in [Paths.dir, Paths.stateDir] where !fm.fileExists(atPath: d) {
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }
}

func writeAtomic(_ data: Data, _ path: String, mode: Int = 0o644) {
    let tmp = path + ".tmp"
    FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode])
    if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
}

func readJSON<T: Decodable>(_ path: String, _ t: T.Type) -> T? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(t, from: d)
}

func writeJSON<T: Encodable>(_ v: T, _ path: String) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let d = try? enc.encode(v) { writeAtomic(d, path) }
}

func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        FileManager.default.createFile(atPath: Paths.log, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o644])
    }
    // 600줄이 넘으면 최근 400줄만 남긴다
    if let text = try? String(contentsOfFile: Paths.log, encoding: .utf8) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 600 { writeAtomic((lines.suffix(400).joined(separator: "\n")).data(using: .utf8)!, Paths.log) }
    }
}

/// 설정·적용을 한 번에 한 프로세스만 하게 한다 (데몬과 CLI 사이).
func withLock<T>(_ body: () -> T) -> T {
    ensureDirs()
    let fd = open(Paths.lock, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

// MARK: - 설정

func loadConfig() -> EngineConfig { readJSON(Paths.config, EngineConfig.self) ?? EngineConfig() }
func saveConfig(_ c: EngineConfig) {
    if let why = Remaining.validation(c.rules) { die(why) }
    var ordered = c; ordered.rules = Remaining.ordered(c.rules)
    writeJSON(ordered, Paths.config)
}

func newRuleID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

func validRule(_ r: Rule, profiles: Set<String>) -> String? {
    if let why = Remaining.validation([r]) { return why }
    if let why = r.when.validate(profiles: profiles) { return "조건: \(why)" }
    if !r.exits.allSatisfy(Exits.isValid) { return "알 수 없는 출구: \(r.exits.filter { !Exits.isValid($0) }.joined(separator: ", "))" }
    if !Exits.elseActions.contains(r.elseAction) { return "알 수 없는 else: \(r.elseAction)" }
    if r.targets.isEmpty || !r.targets.allSatisfy({ Target.parse($0)?.0 == $0 }) { return "대상이 올바르지 않아요" }
    if let c = r.check, CheckTarget.parse(c) == nil { return "점검 대상은 host:port: '\(c)'" }
    return nil
}

// MARK: - 네트워크 상태 (출구)

/// BSD 이름 → (종류, 표시 이름). Wi-Fi·Ethernet·iPhone 테더링을 가린다.
func interfaceKinds() -> [String: (type: String, display: String)] {
    var out: [String: (String, String)] = [:]
    guard let arr = SCNetworkInterfaceCopyAll() as CFArray? else { return [:] }
    for i in 0..<CFArrayGetCount(arr) {
        let iface = unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: SCNetworkInterface.self)
        guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
        let type = SCNetworkInterfaceGetInterfaceType(iface) as String? ?? ""
        let display = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? ""
        out[bsd] = (type, display)
    }
    return out
}

struct NetSnapshot {
    var exits: [ExitInfo]
    var masks: [String: String]          // 인터페이스 → 서브넷 마스크
    var wifi: LinkInfo                   // 상태 표시용 (Wi-Fi 칸)

    /// ip 가 그 출구의 서브넷 안(게이트웨이 없이 바로 닿음)인지.
    func onSubnet(_ ip: String, of e: ExitInfo) -> Bool {
        guard let a = Target.ipv4Number(ip), let me = Target.ipv4Number(e.ip),
              let m = Target.ipv4Number(masks[e.iface] ?? "") else { return false }
        return a & m == me & m
    }
}

func readNet() -> NetSnapshot {
    #if WIFI_EXIT_TESTING
    if let net = TestHooks.net { return net }
    #endif
    let kinds = interfaceKinds()
    let wifiName = kinds.first { $0.value.type == (kSCNetworkInterfaceTypeIEEE80211 as String) }?.key ?? "en0"
    var exits: [ExitInfo] = []
    var masks: [String: String] = [:]
    var wifi = LinkInfo(iface: wifiName, ip: "", gateway: "", dns: [], signature: "", up: false)
    guard let store = SCDynamicStoreCreate(nil, "wifi-exitd-read" as CFString, nil, nil) else {
        return NetSnapshot(exits: [], masks: [:], wifi: wifi)
    }
    let portal = ((try? String(contentsOfFile: "/var/run/gpvpn/portal", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []).sorted()
    for k in keys {
        guard let v = SCDynamicStoreCopyValue(store, k as CFString) as? [String: Any],
              let ifname = v["InterfaceName"] as? String else { continue }
        let sid = k.split(separator: "/").dropFirst(3).first.map(String.init) ?? ""
        let ifv = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(ifname)/IPv4" as CFString) as? [String: Any]
        let ip = (ifv?["Addresses"] as? [String])?.first ?? (v["Addresses"] as? [String])?.first ?? ""
        if let m = (ifv?["SubnetMasks"] as? [String])?.first ?? (v["SubnetMasks"] as? [String])?.first { masks[ifname] = m }
        let router = v["Router"] as? String ?? ""
        let dnsv = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(sid)/DNS" as CFString) as? [String: Any]
        let dns = ((dnsv?["ServerAddresses"] as? [String]) ?? []).filter { Target.ipv4Number($0) != nil }

        let name: String
        if ifname == wifiName { name = "wifi" }
        else if ifname.hasPrefix("utun") || ifname.hasPrefix("ipsec") || ifname.hasPrefix("ppp") { name = "vpn" }
        else if let kd = kinds[ifname], kd.type == (kSCNetworkInterfaceTypeEthernet as String) {
            name = kd.display.localizedCaseInsensitiveContains("iPhone") ? "tether" : "wired"
        } else { continue }

        let isVPN = name == "vpn"
        let gw = isVPN ? "" : (Target.ipv4Number(router) != nil ? router : "")
        let e = ExitInfo(name: name, iface: ifname, ip: ip, gateway: gw, dns: dns,
                         portal: isVPN && sid == "gpvpn-tun" ? portal : "",
                         up: !ip.isEmpty && (isVPN || !gw.isEmpty),
                         signature: v["NetworkSignature"] as? String)
        exits.append(e)
        if name == "wifi" {
            wifi = LinkInfo(iface: ifname, ip: ip, gateway: gw, dns: dns, signature: v["NetworkSignature"] as? String ?? "", up: e.up)
        }
    }
    // 같은 인터페이스를 가리키는 서비스가 둘 이상이면(예: VPN 클라이언트 둘) 하나로 합친다. 포털을 아는 쪽을 남긴다.
    var byIf: [String: ExitInfo] = [:]
    for e in exits {
        if let old = byIf[e.iface] {
            var keep = !old.portal.isEmpty || e.portal.isEmpty ? old : e
            if keep.dns.isEmpty { keep.dns = old.dns.isEmpty ? e.dns : old.dns }
            keep.up = old.up || e.up
            byIf[e.iface] = keep
        } else { byIf[e.iface] = e }
    }
    exits = Array(byIf.values)
    // VPN Bar 다중 연결: tunnels.json 에 터널마다 별칭·DNS 가 있다. 대기 터널은 네트워크 서비스가 없어서
    // 여기서만 보인다. 파일이 오래됐거나(30초) 쓴 프로세스가 죽었으면 무시하고 위의 서비스만 쓴다.
    var vpnRank: [String: Int] = [:]
    if let tj = readJSON(gpTunnelsPath, GPTunnels.self), now() - tj.updatedAt <= 30,
       kill(tj.writerPid, 0) == 0 || errno == EPERM {
        for (i, t) in tj.tunnels.enumerated() where t.iface.hasPrefix("utun") && Target.ipv4Number(t.ip) != nil {
            let dns = t.dns.filter { Target.ipv4Number($0) != nil }
            // 1순위(기본 경로)를 맨 앞에: 조건의 vpn= 과 vpn:any 가 그 터널을 먼저 본다.
            vpnRank[t.iface] = t.alias == tj.primary ? -1 : i
            if let j = exits.firstIndex(where: { $0.iface == t.iface }) {
                exits[j].name = "vpn"; exits[j].portal = t.alias
                if !dns.isEmpty { exits[j].dns = dns }
            } else {
                let has = (ifaddrsIPv4()[t.iface] ?? []).contains(t.ip)
                exits.append(ExitInfo(name: "vpn", iface: t.iface, ip: t.ip, gateway: "", dns: dns, portal: t.alias, up: has))
            }
        }
    }
    // 정렬: wifi, wired, tether, vpn 순 (VPN 끼리는 VPN Bar 순위)
    let order = ["wifi": 0, "wired": 1, "tether": 2, "vpn": 3]
    exits.sort { (order[$0.name] ?? 9, vpnRank[$0.iface] ?? 99, $0.iface) < (order[$1.name] ?? 9, vpnRank[$1.iface] ?? 99, $1.iface) }
    return NetSnapshot(exits: exits, masks: masks, wifi: wifi)
}

/// VPN Bar 가 쓰는 공개 계약 (/var/run/gpvpn/tunnels.json, 다중 연결 모드).
let gpTunnelsPath = "/var/run/gpvpn/tunnels.json"
struct GPTunnels: Decodable {
    struct Tunnel: Decodable { let alias: String; let portal: String; let iface: String; let ip: String; let dns: [String] }
    let updatedAt: Int
    let writerPid: Int32
    let primary: String?
    let tunnels: [Tunnel]
}

/// 인터페이스 → IPv4 주소들 (getifaddrs).
func ifaddrsIPv4() -> [String: [String]] {
    var out: [String: [String]] = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return out }
    defer { freeifaddrs(head) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out[String(cString: cur.pointee.ifa_name), default: []].append(String(cString: host))
            }
        }
        p = cur.pointee.ifa_next
    }
    return out
}

func routeGet(_ dest: String) -> [String: String] {
    var d: [String: String] = [:]
    for line in run("/sbin/route", ["-n", "get", dest]).out.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { d[parts[0]] = parts[1] }
    }
    return d
}

// MARK: - 라우트

struct RouteEntry {
    let dest: String; let gateway: String; let flags: String; let netif: String
    var prefix: IPv4Prefix? {
        guard dest != "default" else { return nil }
        let parts = dest.split(separator: "/")
        let octets = parts[0].split(separator: ".")
        guard (1...4).contains(octets.count) else { return nil }
        let address = (octets.map(String.init) + Array(repeating: "0", count: 4 - octets.count)).joined(separator: ".")
        let bits = parts.count == 2 ? String(parts[1]) : String(flags.contains("H") ? 32 : octets.count * 8)
        return IPv4Prefix(address + "/" + bits)
    }
}

func routeTable() -> [RouteEntry] {
    run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out.split(separator: "\n").compactMap { line in
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count >= 4, f[0] != "Destination", f[0] != "Routing", f[0] != "Internet:" else { return nil }
        return RouteEntry(dest: f[0], gateway: f[1], flags: f[2], netif: f[3])
    }
}

/// 우리가 거는 라우트 하나: 목적지와 보낼 곳(게이트웨이 또는 인터페이스).
struct RouteSpec: Hashable {
    let kind: String          // host | net
    let dest: String
    let gateway: String       // 비어 있으면 -interface 로
    let iface: String

    /// routes.json 에 남기는 꼴: "host 1.2.3.4 192.168.0.1 en0" / "host 1.2.3.4 - utun4" (P1 의 "host 1.2.3.4" 도 읽는다)
    var key: String { "\(kind) \(dest) \(gateway.isEmpty ? "-" : gateway) \(iface)" }
    var target: String { "\(kind) \(dest)" }

    init(_ kind: String, _ dest: String, gateway: String, iface: String) {
        self.kind = kind; self.dest = dest; self.gateway = gateway; self.iface = iface
    }
    init?(key: String) {
        let p = key.split(separator: " ").map(String.init)
        guard p.count >= 2, p[0] == "host" || p[0] == "net" else { return nil }
        kind = p[0]; dest = p[1]
        gateway = p.count > 2 && p[2] != "-" ? p[2] : ""
        iface = p.count > 3 ? p[3] : ""
    }

    /// netstat 이 보여 주는 목적지 이름들. 망은 끝의 .0 을 줄이고, 클래스 기본 마스크면 /p 도 뺀다.
    var netstatNames: Set<String> {
        guard kind == "net" else { return [dest] }
        let parts = dest.split(separator: "/")
        var t = String(parts[0])
        while t.hasSuffix(".0") { t.removeLast(2) }
        return [dest, "\(t)/\(parts[1])", t]
    }
}

/// 라우팅 테이블에 이 출구로 가는 고정 라우트가 있는지.
/// route get 은 다른 프로그램이 인터페이스에 묶어 만든 복제 경로(IFSCOPE)를 먼저 보여 줄 수 있어 netstat 으로 본다.
func routeOK(_ r: RouteSpec, table: [RouteEntry]) -> Bool {
    let names = r.netstatNames
    return table.contains {
        names.contains($0.dest) && $0.netif == r.iface && $0.flags.contains("S") && !$0.flags.contains("I")
            && (r.gateway.isEmpty || $0.gateway == r.gateway)
    }
}

func routeSet(_ r: RouteSpec, table: [RouteEntry]) {
    if routeOK(r, table: table) { return }
    for _ in 0..<3 { if !run("/sbin/route", ["-n", "delete", "-\(r.kind)", r.dest]).ok { break } }   // 복제·이전 경로 정리
    let args = r.gateway.isEmpty ? ["-n", "add", "-\(r.kind)", r.dest, "-interface", r.iface]
                                 : ["-n", "add", "-\(r.kind)", r.dest, r.gateway]
    if run("/sbin/route", args).ok { log("route \(r.dest) -> \(r.gateway.isEmpty ? r.iface : "\(r.gateway) (\(r.iface))")") }
    else { log("route add failed: \(r.dest) via \(r.gateway.isEmpty ? r.iface : r.gateway)") }
}

func routeDelete(kind: String, dest: String) {
    if run("/sbin/route", ["-n", "delete", "-\(kind)", dest]).ok { log("route removed: \(dest)") }
}

// MARK: - pf

func pfEnsure() {
    if !run("/sbin/pfctl", ["-s", "Anchors"]).out.contains("com.apple") { run("/sbin/pfctl", ["-q", "-f", "/etc/pf.conf"]) }
    if !pfEnabled() { run("/sbin/pfctl", ["-q", "-e"]) }
}
func pfEnabled() -> Bool { run("/sbin/pfctl", ["-s", "info"]).out.contains("Status: Enabled") }

/// 규칙 줄의 대상 → 주소들. pfctl 최적화기가 주소를 표(<__automatic_…>)로 묶었으면 표 내용을 읽는다.
func pfTargetAddresses(_ target: String) -> [String] {
    guard target.hasPrefix("<"), target.hasSuffix(">") else { return [target] }
    let table = String(target.dropFirst().dropLast())
    return run("/sbin/pfctl", ["-a", Paths.anchor, "-t", table, "-T", "show"]).out
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// 앵커에 올라가 있는 규칙: 주소 → 허용한 인터페이스 (nil = 모든 곳에서 막음)
func displayedPFTarget(_ line: String) -> String? {
    if line.hasSuffix(" inet6 all") { return "::/0" }
    if line.hasSuffix(" inet all") { return "0.0.0.0/0" }
    guard let r = line.range(of: " to ") else { return nil }
    let target = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
    if target == "any" { return line.contains(" inet6 ") ? "::/0" : "0.0.0.0/0" }
    return target
}

func pfRules() -> [String: String?] {
    var out: [String: String?] = [:]
    for line in run("/sbin/pfctl", ["-a", Paths.anchor, "-s", "rules"]).out.split(separator: "\n") {
        guard line.hasPrefix("block"), let target = displayedPFTarget(String(line)) else { continue }
        let allow: String? = line.range(of: " on ! ").map { o in line[o.upperBound...].split(separator: " ").first.map(String.init) ?? "" }
        for addr in pfTargetAddresses(target) where out[addr] == nil { out[addr] = .some(allow) }
    }
    return out
}

/// 앵커를 올린다. 최적화기가 주소를 표로 묶으면 주소별 카운터를 못 보므로 최적화를 끄고, 안 되면 그냥 올린다.
func pfLoad() -> Bool {
    if run("/sbin/pfctl", ["-q", "-o", "none", "-a", Paths.anchor, "-f", Paths.anchorFile]).ok { return true }
    log("pf load with -o none failed, loading with defaults")
    return run("/sbin/pfctl", ["-q", "-a", Paths.anchor, "-f", Paths.anchorFile]).ok
}

/// 한 줄 = (규칙 id, 허용 인터페이스 또는 nil, IPv4 목록, IPv6 목록). 규칙 순서대로.
struct PFGroup { let rule: String; let allow: String?; let v4: [String]; let v6: [String]; var remaining = false; var system = false }

/// Pure renderer, also checked without changing the host firewall.
func renderPF(_ groups: [PFGroup], logging: Bool, probes: [(String, UInt16)] = []) -> (String, [PFLine]) {
    var text = MARK + "\n"
    var map: [PFLine] = []
    let lg = logging ? "log (user) " : ""
    let hasRemaining = groups.contains { $0.remaining }
    func add(_ line: String, _ l: PFLine) { text += line + "\n"; map.append(l) }
    // Only engine-owned TCP probes may bypass the final rule. User traffic to the same
    // servers still follows the selected exit. IP_BOUND_IF chooses each probe's interface.
    if hasRemaining {
        for (ip, port) in probes where !groups.contains(where: { !$0.remaining && ($0.v4 + $0.v6).contains { $0 == ip || targetCovered(ip, by: $0) } }) {
            add("pass out quick inet proto tcp from any to \(ip) port \(port) user root flags S/SA keep state",
                PFLine(addr: ip, rule: "", kind: "probe", allow: nil))
            if port == 53 {
                add("pass out quick inet proto udp from any to \(ip) port 53 user root keep state",
                    PFLine(addr: ip, rule: "", kind: "probe", allow: nil))
            }
        }
    }
    for g in groups {
        if g.remaining {
            for ip in Remaining.localIPv6 {
                add("pass out quick inet6 from any to \(ip)", PFLine(addr: ip, rule: "", kind: "local", allow: nil))
            }
        }
        for (fam, addrs) in [("inet", g.v4), ("inet6", g.v6)] {
            for a in addrs {
                if g.system {
                    add("pass out quick \(fam) from any to \(a)", PFLine(addr: a, rule: g.rule, kind: "system", allow: nil))
                    continue
                }
                // Explicit rules get a terminal pass before the final IPv6 block.
                // Remaining IPv6 fails closed until the engine supports IPv6 route pinning.
                if let al = g.allow, !(g.remaining && fam == "inet6"), logging || hasRemaining {
                    add("pass out \(lg)quick on \(al) \(fam) proto tcp from any to \(a) flags S/SA keep state", PFLine(addr: a, rule: g.rule, kind: "pass", allow: al))
                    add("pass out \(lg)quick on \(al) \(fam) proto udp from any to \(a) keep state", PFLine(addr: a, rule: g.rule, kind: "pass", allow: al))
                    if hasRemaining {
                        add("pass out quick on \(al) \(fam) from any to \(a)", PFLine(addr: a, rule: g.rule, kind: "other", allow: al))
                    }
                }
                let on = g.remaining && fam == "inet6" ? "" : (g.allow.map { "on ! \($0) " } ?? "")
                add("block return out \(lg)quick \(on)\(fam) from any to \(a)", PFLine(addr: a, rule: g.rule, kind: "block", allow: g.remaining && fam == "inet6" ? nil : g.allow))
            }
        }
    }
    return (text, map)
}

func pfWrite(_ groups: [PFGroup]) {
    let probes: [(String, UInt16)] = [("1.1.1.1", 443)] + readNet().exits.compactMap { e in e.dns.first.map { ($0, UInt16(53)) } }
    let (text, map) = renderPF(groups, logging: FileManager.default.fileExists(atPath: Paths.logging), probes: probes)
    writeJSON(map, Paths.pfMap)
    let old = try? String(contentsOfFile: Paths.anchorFile, encoding: .utf8)
    if old != text { writeAtomic(text.data(using: .utf8)!, Paths.anchorFile) }
    pfEnsure()
    // 다시 올리면 규칙 카운터가 0 이 되므로, 파일이 바뀌었거나 시스템이 pf.conf 를 다시 읽어 앵커가 비었을 때만 올린다.
    var want: [String: String?] = [:]
    for g in groups where !g.system { for a in g.v4 + g.v6 where want[a] == nil { want[a] = .some(g.remaining && a.contains(":") ? nil : g.allow) } }
    let loaded = pfRules()
    // 표로 묶여 올라가 있으면(이전 버전) 한 번 다시 올려 주소별 줄로 바꾼다
    let tabled = run("/sbin/pfctl", ["-a", Paths.anchor, "-s", "rules"]).out.contains("<__automatic")
    if old != text || loaded != want || tabled {
        if !pfLoad() { log("pf load failed") }
    }
    if old != text {
        log("pf rules updated: " + groups.map { "\($0.allow.map { "via \($0)" } ?? "block"): \(($0.v4 + $0.v6).joined(separator: " "))" }.joined(separator: " | "))
    }
}

// MARK: - 도메인 해석

struct DomainMeta: Codable { var at = 0; var server = "" }

struct ResolvedDB: Codable {
    var lastResolve = 0
    var lastDNS = ""                               // P1 호환 (읽기만)
    var domains: [String: [String: Int]] = [:]     // 도메인 → IP → 마지막으로 본 시각
    var meta: [String: DomainMeta]? = [:]          // 도메인 → 마지막 해석 시각·쓴 DNS 서버
}

func dig(_ type: String, _ name: String, server: String, source: String) -> [String] {
    run("/usr/bin/dig", ["+short", "+time=2", "+tries=2", "-b", source, "@\(server)", type, name]).out
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// 도메인 하나를 그 출구의 DNS 로 다시 푼다. DNS 서버로 가는 라우트는 apply 가 미리 그 출구로 고정한다.
func resolve(_ d: String, via e: ExitInfo, db: inout ResolvedDB) {
    guard let server = e.dns.first else { return }
    let t = now()
    var got = dig("A", d, server: server, source: e.ip).filter { Target.ipv4Number($0) != nil }
    got += dig("AAAA", d, server: server, source: e.ip).filter { $0.contains(":") && $0.allSatisfy { $0.isHexDigit || $0 == ":" } }
    var meta = db.meta ?? [:]
    meta[d] = DomainMeta(at: t, server: server)
    db.meta = meta
    db.lastResolve = t
    if got.isEmpty { log("resolve \(d) via \(server): no answer (keeping previous)"); return }
    var seen = db.domains[d] ?? [:]
    for ip in got {
        if seen[ip] == nil { log("resolve \(d): + \(ip)") }
        seen[ip] = t
    }
    for (ip, at) in seen where !got.contains(ip) && t - at >= GRACE {
        seen[ip] = nil
        log("resolve \(d): - \(ip) (gone for \(GRACE)s)")
    }
    db.domains[d] = seen
}

// MARK: - /etc/resolver

func resolverSet(_ domain: String, nameserver: String?) {
    let path = "\(Paths.resolverDir)/\(domain)"
    let existing = try? String(contentsOfFile: path, encoding: .utf8)
    if let e = existing, !e.contains(MARK) { return }   // 남이 만든 파일은 건드리지 않는다
    let body = nameserver.map { "\(MARK)\nnameserver \($0)\n" }
        ?? "\(MARK) (출구 없음: 다른 길로 새지 않게 조회를 막아 둠)\nnameserver 127.0.0.1\nport 9\n"
    if existing == body { return }
    try? FileManager.default.createDirectory(atPath: Paths.resolverDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    writeAtomic(body.data(using: .utf8)!, path)
    log("resolver \(domain) -> \(nameserver ?? "blocked")")
}

func resolverPrune(keep: Set<String>) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.resolverDir) else { return }
    for n in names where !keep.contains(n) {
        let path = "\(Paths.resolverDir)/\(n)"
        guard let t = try? String(contentsOfFile: path, encoding: .utf8), t.contains(MARK) else { continue }
        try? FileManager.default.removeItem(atPath: path)
        log("resolver removed: \(n)")
    }
}

// MARK: - 상태 점검

/// 시험용으로 실패로 둔 출구: 이름(wifi…)이나 인터페이스(en0…) → 끝나는 시각
func healthOverrides() -> [String: Int] {
    (readJSON(Paths.healthOverride, [String: Int].self) ?? [:]).filter { $0.value > now() }
}
func forcedDown(_ e: ExitInfo, _ ov: [String: Int]) -> Bool { ov[e.iface] != nil || ov[e.name] != nil }

func resolveIPv4(_ host: String) -> String? {
    if Target.isIPv4(host) { return host }
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
    defer { freeaddrinfo(res) }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var sin = r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

/// 그 인터페이스로 ip:port 에 닿는지. 연결되거나 상대가 거절(RST)하면 닿은 것이다.
func reach(_ ip: String, _ port: UInt16, iface: String) -> (Bool, Int) {
    let t0 = Date()
    let r = probe(ip, port, ifname: iface, timeout: 2000)
    return (r == .connected || r == .refused, Int(Date().timeIntervalSince(t0) * 1000))
}

func nextHealth(_ old: Health?, ok: Bool, ms: Int?, detail: String, forced: Bool) -> Health {
    var h = old ?? Health()
    if ok { h.oks += 1; h.fails = 0; if !h.ok && h.oks >= HEALTH_UP_AFTER { h.ok = true } }
    else { h.fails += 1; h.oks = 0; if h.ok && (h.fails >= HEALTH_DOWN_AFTER || forced) { h.ok = false } }
    h.at = now(); h.ms = ms; h.detail = detail
    return h
}

/// 출구마다(그리고 점검 대상이 있는 규칙마다) 한 번씩 점검한다. 쓸 수 있는지가 바뀌었으면 true.
/// 잠금 없이 돈다 (점검이 느려도 규칙 적용을 붙잡지 않는다).
@discardableResult
func healthRound() -> Bool {
    let net = readNet(), config = loadConfig(), ov = healthOverrides()
    let old = readJSON(Paths.health, HealthDB.self) ?? HealthDB()
    let pf = pfRules()
    let pfMap = readJSON(Paths.pfMap, [PFLine].self) ?? []
    let lock = NSLock(), g = DispatchGroup()
    var exitRes: [String: (Bool, Int?, String, Bool)] = [:]
    var ruleRes: [String: (Bool, Int?, String, Bool)] = [:]

    for e in net.exits where e.up {
        // 출구의 DNS 서버(53)와, VPN 이 아니면 1.1.1.1:443. 우리 규칙이 이 출구에서 막는 주소는 빼고.
        var targets: [(String, UInt16)] = []
        if let d = e.dns.first { targets.append((d, 53)) }
        if e.name != "vpn" { targets.append(("1.1.1.1", 443)) }
        targets = targets.filter { t in
            let entries = pf.filter { $0.key == t.0 || targetCovered(t.0, by: $0.key) }
            let explicit = pfMap.first {
                $0.kind == "block" && ($0.addr == t.0 || targetCovered(t.0, by: $0.addr))
            }
            if let explicit, config.rules.first(where: { $0.id == explicit.rule })?.isRemaining == true { return true }
            return entries.isEmpty || entries.values.allSatisfy { $0 == e.iface }
        }
        let forced = forcedDown(e, ov)
        let tgs = targets
        g.enter()
        DispatchQueue.global().async {
            let targets = tgs
            var res: (Bool, Int?, String, Bool)
            if forced { res = (false, nil, "시험: 실패로 둠", true) }
            else if targets.isEmpty { res = (true, nil, "점검할 대상 없음", false) }
            else {
                res = (false, nil, targets.map { "\($0.0):\($0.1)" }.joined(separator: ", ") + " 응답 없음", false)
                for (ip, port) in targets {
                    let (ok, ms) = reach(ip, port, iface: e.iface)
                    if ok { res = (true, ms, "\(ip):\(port) \(ms)ms", false); break }
                }
            }
            lock.lock(); exitRes[e.iface] = res; lock.unlock(); g.leave()
        }
    }
    let st = readStatus()
    for r in config.rules where r.enabled && !config.paused {
        guard let c = r.check, let (host, port) = CheckTarget.parse(c) else { continue }
        let ip = resolveIPv4(host)
        // 점검 대상이 이 규칙이 보호하는 주소면, 피하려는 출구로 그 주소에 보내게 되므로 점검하지 않는다
        let own = Set(st?.rules.first { $0.id == r.id }?.addresses.map(\.ip) ?? []).union(r.targets)
        if let ip, own.contains(ip) || own.contains(host) {
            for e in r.exits.flatMap({ matchingExits($0, in: net.exits) }) {
                ruleRes["\(r.id)|\(e.iface)"] = (true, nil, "\(c) 는 이 규칙의 대상이라 점검하지 않음 (다른 주소를 넣으세요)", false)
            }
            continue
        }
        let es = r.exits.flatMap { matchingExits($0, in: net.exits) }
        for e in uniq(es.map(\.iface)).compactMap({ i in es.first { $0.iface == i } }) {
            let forced = forcedDown(e, ov)
            g.enter()
            DispatchQueue.global().async {
                var res: (Bool, Int?, String, Bool)
                if forced { res = (false, nil, "시험: 실패로 둠", true) }
                else if let ip, pf.contains(where: { ($0.key == ip || targetCovered(ip, by: $0.key)) && $0.value != e.iface }) {
                    // 우리 pf 규칙이 이 출구에서 막는 주소: pf 가 돌려주는 RST 를 "닿음"으로 착각하지 않게 보내 보지 않는다
                    res = (false, nil, "\(c) — 이 출구에서는 규칙이 막는 주소", false)
                }
                else if let ip {
                    let (ok, ms) = reach(ip, port, iface: e.iface)
                    res = (ok, ok ? ms : nil, ok ? "\(c) \(ms)ms" : "\(c) 응답 없음", false)
                } else { res = (false, nil, "\(host) 를 풀지 못함", false) }
                lock.lock(); ruleRes["\(r.id)|\(e.iface)"] = res; lock.unlock(); g.leave()
            }
        }
    }
    g.wait()

    var db = HealthDB()
    for (k, v) in exitRes { db.exits[k] = nextHealth(old.exits[k], ok: v.0, ms: v.1, detail: v.2, forced: v.3) }
    for (k, v) in ruleRes { db.rules[k] = nextHealth(old.rules[k], ok: v.0, ms: v.1, detail: v.2, forced: v.3) }
    writeJSON(db, Paths.health)

    var changed = false
    for (k, h) in db.exits where (old.exits[k]?.ok ?? true) != h.ok { changed = true; log("health \(k): \(h.ok ? "다시 응답" : "응답 없음") (\(h.detail))") }
    for (k, h) in db.rules where (old.rules[k]?.ok ?? true) != h.ok { changed = true; log("check \(k): \(h.ok ? "닿음" : "안 닿음") (\(h.detail))") }
    for (k, h) in old.exits where db.exits[k] == nil && !h.ok { changed = true; _ = k }
    for (k, h) in old.rules where db.rules[k] == nil && !h.ok { changed = true; _ = k }
    return changed
}

/// 점검 결과를 출구 정보와 사실에 붙인다. 시험용 실패는 점검을 기다리지 않고 바로 반영한다.
func attachHealth(_ net: inout NetSnapshot) -> [String: Bool] {
    let db = readJSON(Paths.health, HealthDB.self) ?? HealthDB()
    let ov = healthOverrides()
    for i in net.exits.indices {
        let e = net.exits[i]
        if forcedDown(e, ov) { net.exits[i].healthy = false; net.exits[i].healthDetail = "시험: 실패로 둠"; continue }
        if let h = db.exits[e.iface] { net.exits[i].healthy = h.ok; net.exits[i].healthDetail = h.detail }
    }
    var checks: [String: Bool] = [:]
    for (k, h) in db.rules { checks[k] = h.ok }
    for e in net.exits where forcedDown(e, ov) { for k in db.rules.keys where k.hasSuffix("|\(e.iface)") { checks[k] = false } }
    return checks
}

func cmdHealth(_ args: [String]) {
    switch args.first {
    case "check", nil:
        if healthRound() { withLock { _ = apply() } }
    case "fail":
        guard args.count >= 2 else { die("사용법: health fail <wifi|wired|tether|vpn|인터페이스> [초]", code: 2) }
        let who = args[1].lowercased()
        guard ["wifi", "wired", "tether", "vpn"].contains(who) || who.range(of: "^[a-z]{2,8}[0-9]{1,3}$", options: .regularExpression) != nil else {
            die("출구 이름(wifi, wired, tether, vpn)이나 인터페이스(en0 …)를 주세요", code: 2)
        }
        let secs = args.count > 2 ? Int(args[2]) ?? -1 : 60
        guard (1...3600).contains(secs) else { die("시간은 1–3600초", code: 2) }
        var ov = healthOverrides()
        ov[who] = now() + secs
        writeJSON(ov, Paths.healthOverride)
        log("health override: \(who) fails for \(secs)s")
        healthRound()
        withLock { _ = apply() }
        print("\(who) 를 \(secs)초 동안 응답 없음으로 둬요 (wifi-exit health clear 로 바로 풀기)")
    case "clear":
        try? FileManager.default.removeItem(atPath: Paths.healthOverride)
        log("health override cleared")
        healthRound()
        withLock { _ = apply() }
        print("시험용 실패를 풀었어요. 실제 점검 결과로 돌아가요.")
    default:
        die("사용법: health [check] | health fail <출구|인터페이스> [초] | health clear", code: 2)
    }
}

// MARK: - 적용

extension Outcome {
    var isBlock: Bool { if case .block = self { return true }; return false }
}

/// VPN 출구로 보내면 안 되는 주소: 다른 프로그램(VPN 클라이언트)이 물리 인터페이스로 고정해 둔 호스트 라우트.
/// 대개 VPN 게이트웨이 주소다. 이걸 터널로 보내면 터널이 자기 자신을 통해 나가려다 끊긴다.
func protectedAddresses(table: [RouteEntry], ours: Set<String>) -> Set<String> {
    Set(table.filter { $0.flags.contains("H") && $0.flags.contains("S") && $0.flags.contains("G")
                       && !$0.netif.hasPrefix("utun") && !ours.contains($0.dest) }.map(\.dest))
}

/// 지금 네트워크에서 조건 판단에 쓸 사실을 모은다.
func currentFacts(net: NetSnapshot, config: EngineConfig, table: [RouteEntry], ours: Set<String>) -> Facts {
    // VPN 이 어느 링크 위에 있는지: VPN 클라이언트가 물리 인터페이스에 고정해 둔 게이트웨이 경로의 인터페이스
    var over = ""
    if net.exits.contains(where: { $0.name == "vpn" && $0.up }) {
        let ifs = Set(protectedAddresses(table: table, ours: ours).compactMap { a in table.first { $0.dest == a }?.netif })
        over = net.exits.first { $0.name != "vpn" && ifs.contains($0.iface) }?.name ?? ""
    }
    return Facts(exits: net.exits, profiles: config.profiles, defaultIf: routeGet("default")["interface"] ?? "",
                 vpnOver: over, date: Date())
}

@discardableResult
func apply(forceResolve: Bool = false) -> EngineStatus {
    ensureDirs()
    let config = loadConfig()
    var net = readNet()
    let ruleChecks = attachHealth(&net)
    var errors: [String] = []
    var table = routeTable()
    let oldRoutes = (readJSON(Paths.routes, [String].self) ?? []).compactMap(RouteSpec.init(key:))

    // 0) 판단에 쓰는 사실
    var facts = currentFacts(net: net, config: config, table: table, ours: Set(oldRoutes.map(\.dest)))
    facts.ruleChecks = ruleChecks

    // 1) 규칙마다 결정 (조건 → 출구 순위 → 없을 때)
    var decisions: [String: Outcome] = [:]
    let profileNames = Set(config.profiles.keys)
    for r in config.rules {
        guard r.enabled, !config.paused else { decisions[r.id] = .off; continue }
        if let why = validRule(r, profiles: profileNames) { errors.append("규칙 \(r.title): \(why) — 건너뜀"); decisions[r.id] = .off; continue }
        decisions[r.id] = decide(r, facts: facts)
    }

    // 2) 도메인 해석: 출구로 보내는 규칙의 도메인만, 그 출구의 DNS 로
    var db = readJSON(Paths.resolved, ResolvedDB.self) ?? ResolvedDB()
    let allDomains = Set(config.rules.flatMap { $0.targets.filter { Target.parse($0)?.1 == .domain } })
    for d in db.domains.keys where !allDomains.contains(d) { db.domains[d] = nil; db.meta?[d] = nil }

    var dnsPins: [RouteSpec] = []
    var domainExit: [String: ExitInfo?] = [:]          // 도메인 → 조회를 보낼 출구 (nil = 막기)
    for r in config.rules {
        let ds = r.targets.filter { Target.parse($0)?.1 == .domain }
        guard !ds.isEmpty, let dec = decisions[r.id] else { continue }
        switch dec {
        case .route(_, let e):
            guard let server = e.dns.first else { for d in ds where domainExit[d] == nil { domainExit[d] = .some(nil) }; continue }
            // VPN 출구는 고정하지 않는다: dig -b <터널 주소> 가 그 터널의 scoped 기본 경로를 탄다. 여러 터널이
            // 같은 DNS(8.8.8.8 등)를 쓰거나 그 주소가 시스템 DNS 여도 전역 경로를 건드리지 않는다.
            if e.name != "vpn", !net.onSubnet(server, of: e), !dnsPins.contains(where: { $0.dest == server }) {
                let pin = RouteSpec("host", server, gateway: e.gateway, iface: e.iface)
                routeSet(pin, table: table)        // 해석 전에 DNS 서버 경로부터
                table = routeTable()
                dnsPins.append(pin)
            }
            for d in ds where domainExit[d] == nil {
                domainExit[d] = .some(e)
                let m = db.meta?[d]
                if forceResolve || now() - (m?.at ?? 0) >= RESOLVE_EVERY || m?.server != server { resolve(d, via: e, db: &db) }
            }
        case .block:
            for d in ds where domainExit[d] == nil { domainExit[d] = .some(nil) }
        default: break
        }
    }
    writeJSON(db, Paths.resolved)

    var remainingV4: [String] = []
    func addresses(of target: String) -> [String] {
        guard let (t, k) = Target.parse(target) else { return [] }
        switch k {
        case .ip, .cidr: return [t]
        case .domain: return (db.domains[t] ?? [:]).keys.sorted()
        case .remaining: return remainingV4 + ["::/0"]
        }
    }

    // 3) 주소마다 처음 맞는 규칙이 맡는다
    let protected = protectedAddresses(table: table, ours: Set(oldRoutes.map(\.dest) + dnsPins.map(\.dest)))
    var owner: [String: String] = [:]                  // 주소 → 규칙 id
    var excluded: [String: String] = [:]               // 주소 → 이유
    var groups: [PFGroup] = []
    var routes: [RouteSpec] = []
    for r in config.rules {
        guard let dec = decisions[r.id] else { continue }
        if r.isRemaining {
            // Reserve earlier rule destinations, local networks, VPN transports, DNS pins and
            // host routes owned by other software. Never replace the system default route.
            let connected = net.exits.compactMap { e -> String? in
                guard e.name != "vpn", let ip = Target.ipv4Number(e.ip),
                      let mask = Target.ipv4Number(net.masks[e.iface] ?? "") else { return nil }
                let bits = mask.nonzeroBitCount
                guard bits > 0, mask == IPv4Prefix.mask(bits) else { return nil }
                return IPv4Prefix(ip & mask, bits).text
            }
            let foreign = table.filter { entry in
                !entry.flags.contains("I") && !oldRoutes.contains { $0.netstatNames.contains(entry.dest) }
                    && !dnsPins.contains { $0.netstatNames.contains(entry.dest) }
            }
            let fixedHosts = foreign.filter { $0.flags.contains("S") && $0.prefix?.length == 32 }.compactMap { $0.prefix?.text }
            let networks = foreign.filter { !$0.flags.contains("H") }.compactMap { $0.prefix?.text }
            remainingV4 = Remaining.prefixes(excluding: Array(owner.keys) + Array(protected)
                + fixedHosts + dnsPins.map(\.dest) + connected, overriding: networks)
        }
        switch dec { case .off, .next, .skip: continue; default: break }   // 뒤 규칙에 넘긴다
        var v4: [String] = [], v6: [String] = []
        for t in r.targets {
            for a in addresses(of: t) where owner[a] == nil {
                if case .route(_, let e) = dec, e.name == "vpn", protected.contains(a) {
                    excluded[a] = "VPN 연결에 쓰이는 주소라 터널로 보내지 않음"
                    errors.append("\(r.title): \(a) 는 VPN 연결에 쓰이는 주소라 VPN 출구에서 뺐어요")
                    continue
                }
                owner[a] = r.id
                if a.contains(":") { v6.append(a) } else { v4.append(a) }
            }
        }
        switch dec {
        case .route(_, let e):
            groups.append(PFGroup(rule: r.id, allow: e.iface, v4: v4, v6: v6, remaining: r.isRemaining))
            routes += v4.map { RouteSpec($0.contains("/") ? "net" : "host", $0, gateway: e.gateway, iface: e.iface) }
        case .block:
            groups.append(PFGroup(rule: r.id, allow: nil, v4: v4, v6: v6, remaining: r.isRemaining))
        case .system:
            // IPv4 was subtracted from remaining prefixes; explicitly preserve IPv6 too.
            if config.rules.contains(where: { $0.isRemaining && ["route", "block"].contains(decisions[$0.id]?.word ?? "") }) {
                groups.append(PFGroup(rule: r.id, allow: nil, v4: [], v6: v6, system: true))
            }
        default: break
        }
    }
    routes += dnsPins.filter { p in !routes.contains { $0.dest == p.dest } }
    routes = uniq(routes)

    // 4) 차단 규칙 — 출구가 있든 없든 항상
    let before = pfRules()
    pfWrite(groups)
    for g in groups where !g.system {
        for a in g.v4 where before[a] != .some(g.allow) { run("/sbin/pfctl", ["-q", "-k", "0.0.0.0/0", "-k", a]) }   // 이미 열린 연결 끊기
        for a in g.v6 where before[a] != .some(g.remaining ? nil : g.allow) { run("/sbin/pfctl", ["-q", "-k", "::/0", "-k", a]) }
    }

    // 5) 라우트
    let wanted = Set(routes.map(\.target))
    for r in oldRoutes where !wanted.contains(r.target) { routeDelete(kind: r.kind, dest: r.dest) }
    for r in routes { routeSet(r, table: table) }
    writeJSON(routes.map(\.key), Paths.routes)

    // 6) 앱들의 이름 조회: 출구가 있으면 그 출구의 DNS, 막는 규칙이면 조회도 막기
    var keepResolvers = Set<String>()
    if !config.paused {
        for (d, e) in domainExit {
            resolverSet(d, nameserver: e?.dns.first)
            keepResolvers.insert(d)
        }
    }
    resolverPrune(keep: keepResolvers)

    // 7) 상태 기록
    table = routeTable()
    let pf = pfRules()
    let rules: [RuleStatus] = config.rules.map { r in
        let dec = decisions[r.id] ?? .off
        var chosen: String?, iface: String?
        if case .route(let name, let e) = dec { chosen = name; iface = e.iface }
        var reason = reasonText(r, dec, facts: facts, paused: config.paused)
        if case .off = dec, r.enabled, !config.paused, let why = validRule(r, profiles: profileNames) { reason = why }
        let targets: [TargetStatus] = r.targets.compactMap { t in
            guard let (norm, kind) = Target.parse(t) else { return nil }
            let addrs = addresses(of: norm).map { a -> AddressStatus in
                let isV6 = a.contains(":")
                var pinned = false, blocked = false
                switch dec {
                case .route(_, let e):
                    pinned = !isV6 && routeOK(RouteSpec(a.contains("/") ? "net" : "host", a, gateway: e.gateway, iface: e.iface), table: table)
                    blocked = pf[a] == .some(r.isRemaining && isV6 ? nil : .some(e.iface))
                case .block:
                    blocked = pf[a] == .some(nil)
                default: break
                }
                let own = owner[a]
                return AddressStatus(
                    ip: a,
                    interface: isV6 ? "" : (r.isRemaining ? (pinned ? iface ?? "" : "") : (routeGet(String(a.split(separator: "/")[0]))["interface"] ?? "")),
                    pinned: pinned, blocked: blocked,
                    owner: own != nil && own != r.id ? own : nil,
                    note: excluded[a])
            }
            return TargetStatus(target: norm, kind: kind, addresses: addrs)
        }
        return RuleStatus(id: r.id, name: r.name, enabled: r.enabled, exits: r.exits, elseAction: r.elseAction,
                          chosenExit: chosen, chosenIface: iface, decision: dec.word,
                          when: r.when.isAlways ? nil : r.when.text,
                          conditionDetail: r.when.isAlways ? nil : facts.explain(r.when),
                          check: r.check,
                          reason: reason, targets: targets)
    }
    let st = EngineStatus(generatedAt: now(), paused: config.paused, wifi: net.wifi,
                          defaultIf: routeGet("default")["interface"] ?? "", pfEnabled: pfEnabled(),
                          lastResolve: db.lastResolve, lastApply: now(), rules: rules, exits: net.exits, errors: uniq(errors),
                          vpnOver: facts.vpnOver.isEmpty ? nil : facts.vpnOver)
    writeJSON(st, Paths.status)
    return st
}

// MARK: - 설정 편집

func findRule(_ c: EngineConfig, _ key: String) -> Int? {
    let k = key.lowercased()
    let norm = Target.parse(k)?.0
    return c.rules.firstIndex { $0.id == k } ?? c.rules.firstIndex { r in r.targets.contains { $0 == norm || $0 == k } }
}

/// --via / --else / --name 를 뽑아내고 나머지 단어를 돌려준다.
func takeFlags(_ args: [String]) -> (via: [String]?, els: String?, when: Condition?, targets: [String]?, check: String??, name: String?, rest: [String]) {
    var via: [String]?, els: String?, when: Condition?, targets: [String]?, check: String??, name: String?, rest: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--via":
            guard i + 1 < args.count, let v = Exits.parseList(args[i + 1]) else {
                die("--via 뒤에 출구 목록 (wifi, wired, tether, vpn:any, vpn:<별칭> 을 쉼표로, 최대 6개. 없으면 none)", code: 2)
            }
            via = v; i += 2
        case "--else":
            guard i + 1 < args.count, Exits.elseActions.contains(args[i + 1]) else { die("--else 는 block | system | next", code: 2) }
            els = args[i + 1]; i += 2
        case "--when":
            guard i + 1 < args.count else { die("--when 뒤에 조건 (예: 'vpn=pass and link=wired', always)", code: 2) }
            do { when = try Condition.parse(args[i + 1]) } catch { die("조건을 읽지 못했어요: \(error)", code: 2) }
            i += 2
        case "--check":
            guard i + 1 < args.count else { die("--check 뒤에 host:port 또는 none", code: 2) }
            let v = args[i + 1]
            if v == "none" { check = .some(nil) }
            else {
                guard let (h, p) = CheckTarget.parse(v) else { die("점검 대상은 host:port (예: git.example.corp:443) 또는 none", code: 2) }
                check = .some("\(h):\(p)")
            }
            i += 2
        case "--targets":
            guard i + 1 < args.count else { die("--targets 뒤에 대상 목록 (쉼표로)", code: 2) }
            var ts: [String] = []
            for raw in args[i + 1].split(separator: ",") {
                guard let (t, _) = Target.parse(String(raw)) else { die("IPv4, IPv4/프리픽스(8–32), 도메인 또는 remaining을 넣어 주세요: '\(raw)'", code: 2) }
                if !ts.contains(t) { ts.append(t) }
            }
            guard (1...50).contains(ts.count) else { die("대상은 1–50개", code: 2) }
            targets = ts; i += 2
        case "--name":
            name = cleanNote(args[(i + 1)...].joined(separator: " ")); i = args.count
        default:
            rest.append(a); i += 1
        }
    }
    return (via, els, when, targets, check, name, rest)
}

func cmdAdd(_ args: [String]) {
    let forceNew = args.contains("--new")          // 같은 대상이 있어도 새 규칙으로 (편집 창의 "새 규칙")
    let f = takeFlags(args.filter { $0 != "--new" })
    guard let raw = f.rest.first else { die("사용법: add <대상> [--via 출구,…] [--else block|system|next] [메모]", code: 2) }
    guard let (t, _) = Target.parse(raw) else { die("IPv4, IPv4/프리픽스(8–32), 도메인 또는 remaining을 넣어 주세요: '\(raw)'") }
    let note = f.name ?? cleanNote(f.rest.dropFirst().joined(separator: " "))
    withLock {
        var c = loadConfig()
        if let w = f.when, let why = w.validate(profiles: Set(c.profiles.keys)) { die("조건: \(why)") }
        if let ck = f.check ?? nil, let h = CheckTarget.parse(ck)?.host, (f.targets ?? [t]).contains(h) {
            die("점검 대상은 이 규칙의 대상과 다른 곳이어야 해요 (보호하는 주소를 피하려는 출구로 보내지 않으려고)")
        }
        if (!forceNew || t == Remaining.target), let i = findRule(c, t) {
            c.rules[i].enabled = true
            if !note.isEmpty { c.rules[i].name = note }
            if let v = f.via { c.rules[i].exits = v }
            if let e = f.els { c.rules[i].elseAction = e }
            if let w = f.when { c.rules[i].when = w }
            if let ck = f.check { c.rules[i].check = ck }
        } else {
            c.rules.append(Rule(id: newRuleID(), name: note, targets: f.targets ?? [t], when: f.when ?? .always, exits: f.via ?? ["wifi"], elseAction: f.els ?? "block", check: f.check ?? nil))
            print("id \(c.rules.last!.id)")
        }
        saveConfig(c)
        log("add \(t)\(note.isEmpty ? "" : " (\(note))")\(f.via.map { " via \($0.joined(separator: ","))" } ?? "")\(f.els.map { " else \($0)" } ?? "")")
        apply(forceResolve: true)
    }
    if f.check != nil, healthRound() { withLock { _ = apply() } }
}

func cmdEdit(_ args: [String]) {
    let f = takeFlags(args)
    guard let key = f.rest.first, f.rest.count == 1 else { die("사용법: set <대상|id> [--via 출구,…] [--else …] [--name 메모]", code: 2) }
    guard f.via != nil || f.els != nil || f.when != nil || f.targets != nil || f.check != nil || f.name != nil else {
        die("바꿀 것을 주세요 (--via, --else, --when, --targets, --name)", code: 2)
    }
    withLock {
        var c = loadConfig()
        guard let i = findRule(c, key) else { die("등록되지 않은 대상: '\(key)'") }
        if let v = f.via { c.rules[i].exits = v }
        if let e = f.els { c.rules[i].elseAction = e }
        if let n = f.name { c.rules[i].name = n }
        if let ts = f.targets { c.rules[i].targets = ts }
        if let ck = f.check { c.rules[i].check = ck }
        if let ck = c.rules[i].check, let h = CheckTarget.parse(ck)?.host, c.rules[i].targets.contains(h) {
            die("점검 대상은 이 규칙의 대상과 다른 곳이어야 해요 (보호하는 주소를 피하려는 출구로 보내지 않으려고)")
        }
        if let w = f.when {
            if let why = w.validate(profiles: Set(c.profiles.keys)) { die("조건: \(why)") }
            c.rules[i].when = w
        }
        saveConfig(c)
        log("set \(c.rules[i].id): via \(c.rules[i].exits.joined(separator: ",")) else \(c.rules[i].elseAction) when \(c.rules[i].when.text)")
        apply(forceResolve: f.via != nil || f.targets != nil)
    }
    // 점검 대상이 바뀌었으면 바로 한 번 점검해 결과를 반영한다 (잠금 밖에서)
    if f.check != nil, healthRound() { withLock { _ = apply() } }
}

func cmdMove(_ key: String, _ where_: String) {
    withLock {
        var c = loadConfig()
        guard let i = findRule(c, key) else { die("등록되지 않은 대상: '\(key)'") }
        if c.rules[i].isRemaining { die("나머지 트래픽은 항상 개별 규칙 뒤에 적용돼요") }
        let last = c.rules.filter { !$0.isRemaining }.count - 1
        let to: Int
        switch where_ {
        case "up": to = max(0, i - 1)
        case "down": to = min(last, i + 1)
        case "top": to = 0
        case "bottom": to = last
        default:
            guard let n = Int(where_), (1...(last + 1)).contains(n) else { die("위치는 up | down | top | bottom | 1–\(last + 1)", code: 2) }
            to = n - 1
        }
        let r = c.rules.remove(at: i)
        c.rules.insert(r, at: to)
        saveConfig(c)
        log("move \(r.id) -> \(to + 1)")
        apply()
    }
}

func cmdSet(_ action: String, _ key: String) {
    withLock {
        var c = loadConfig()
        guard let i = findRule(c, key) else { die("등록되지 않은 대상: '\(key)'") }
        switch action {
        case "rm":
            let norm = Target.parse(key)?.0
            if let n = norm, c.rules[i].targets.count > 1, c.rules[i].targets.contains(n) {
                c.rules[i].targets.removeAll { $0 == n }      // 여러 대상 중 하나만 지운다
            } else {
                c.rules.remove(at: i)
            }
        case "on": c.rules[i].enabled = true
        default: c.rules[i].enabled = false
        }
        saveConfig(c)
        log("\(action) \(key)")
        apply()
    }
}

/// 지금 붙은 링크의 게이트웨이(와 MAC)를 이름 붙여 저장한다.
func cmdProfile(_ args: [String]) {
    guard let sub = args.first else { die("사용법: profile add <이름> [wifi|wired|tether] | profile rm <이름>", code: 2) }
    withLock {
        var c = loadConfig()
        switch sub {
        case "add":
            guard args.count >= 2 else { die("사용법: profile add <이름> [wifi|wired|tether]", code: 2) }
            let name = args[1].precomposedStringWithCanonicalMapping
            guard (1...40).contains(name.count), !name.contains(where: { $0.isWhitespace || "()=!,".contains($0) }) else {
                die("프로필 이름은 공백·괄호·=·!·쉼표 없이 40자까지", code: 2)
            }
            let link = args.count > 2 ? args[2] : "wifi"
            guard ["wifi", "wired", "tether"].contains(link) else { die("링크는 wifi | wired | tether", code: 2) }
            guard let e = readNet().exits.first(where: { $0.name == link && $0.up }) else { die("\(Exits.label(link))이 지금 연결돼 있지 않아요") }
            var mac = ""
            if let sig = e.signature, let r = sig.range(of: "RouterHardwareAddress=") {
                mac = String(sig[r.upperBound...].prefix { $0 != ";" })
            }
            c.profiles[name] = NetProfile(link: link, gateway: e.gateway, gatewayMac: mac)
            saveConfig(c)
            log("profile \(name) = \(link) \(e.gateway) \(mac)")
            print("저장했어요: \(name) = \(Exits.label(link)) 게이트웨이 \(e.gateway)\(mac.isEmpty ? "" : " (\(mac))")")
        case "rm":
            guard args.count == 2 else { die("사용법: profile rm <이름>", code: 2) }
            let name = args[1].precomposedStringWithCanonicalMapping
            guard c.profiles[name] != nil else { die("없는 프로필: \(name)") }
            let users = c.rules.filter { $0.when.text.contains("profile=\(name)") || $0.when.text.contains("profile!=\(name)") }
            guard users.isEmpty else { die("이 프로필을 쓰는 규칙이 있어요: \(users.map(\.title).joined(separator: ", "))") }
            c.profiles[name] = nil
            saveConfig(c)
            log("profile removed: \(name)")
            print("지웠어요: \(name)")
        default:
            die("사용법: profile add <이름> [wifi|wired|tether] | profile rm <이름>", code: 2)
        }
        apply()
    }
}

func cmdPause(_ p: Bool) {
    withLock {
        var c = loadConfig()
        c.paused = p
        saveConfig(c)
        log(p ? "paused" : "resumed")
        apply(forceResolve: !p)
    }
}

// MARK: - 데몬

final class Daemon {
    let queue = DispatchQueue(label: "wifi-exitd.apply")
    var pending: DispatchWorkItem?
    var store: SCDynamicStore?
    var dirSource: DispatchSourceFileSystemObject?
    var timer: DispatchSourceTimer?
    var healthTimer: DispatchSourceTimer?

    func schedule(_ why: String, delay: Double = 0.7) {
        queue.async {
            self.pending?.cancel()
            let w = DispatchWorkItem { withLock { _ = apply() } }
            self.pending = w
            self.queue.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    func start() {
        ensureDirs()
        log("daemon started (pid \(getpid()))")
        queue.async { withLock { _ = apply(forceResolve: true) } }

        // 네트워크 변화: 링크·주소·라우터·DNS (VPN 터널 포함)
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue().schedule("network")
        }
        if let s = SCDynamicStoreCreate(nil, "wifi-exitd" as CFString, cb, &ctx) {
            SCDynamicStoreSetNotificationKeys(s, ["State:/Network/Global/IPv4"] as CFArray,
                                              ["State:/Network/Interface/[^/]+/IPv4", "State:/Network/Service/[^/]+/(IPv4|DNS)"] as CFArray)
            SCDynamicStoreSetDispatchQueue(s, DispatchQueue.main)
            store = s
        }

        // 설정 변경: config.json 은 원자적으로 바뀌므로 디렉터리를 본다 (state/ 안의 변화는 여기 걸리지 않는다)
        let fd = open(Paths.dir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.schedule("config", delay: 0.3) }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }

        // 출구 상태 점검 (잠금 없이 따로 돌고, 바뀌면 적용)
        let hq = DispatchQueue(label: "wifi-exitd.health")
        let ht = DispatchSource.makeTimerSource(queue: hq)
        ht.schedule(deadline: .now() + 3, repeating: HEALTH_EVERY)
        ht.setEventHandler { [weak self] in if healthRound() { self?.schedule("health", delay: 0) } }
        ht.resume()
        healthTimer = ht

        // 안전망
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + SAFETY_TICK, repeating: SAFETY_TICK)
        t.setEventHandler { [weak self] in self?.schedule("tick", delay: 0) }
        t.resume()
        timer = t

        // 연결 사건 흐름: 누가 붙으면 기록 줄을 넣고, 다 떨어지면 뺀다
        signal(SIGPIPE, SIG_IGN)
        EventHub.shared.onLoggingChange = { [weak self] on in
            log(on ? "watch: logging on" : "watch: logging off")
            self?.schedule("watch", delay: 0)
        }
        EventHub.shared.start()

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { log("daemon stopped"); exit(0) }
        term.resume()
        withExtendedLifetime(term) { dispatchMain() }
    }
}

// MARK: - 자체 점검 (selftest)

/// 앵커 규칙별 차단 패킷 수. 키는 대상 주소.
func pfCounters() -> [String: Int] {
    var out: [String: Int] = [:]
    var current: String?
    for line in run("/sbin/pfctl", ["-a", Paths.anchor, "-vvs", "rules"]).out.split(separator: "\n") {
        if line.hasPrefix("@"), line.contains(" pass ") {
            current = nil                                  // 기록용 통과 줄은 세지 않는다
        } else if line.hasPrefix("@"), let target = displayedPFTarget(String(line)) {
            current = target
        } else if let c = current, let r = line.range(of: "Packets: ") {
            let n = Int(line[r.upperBound...].split(separator: " ").first ?? "") ?? 0
            for a in pfTargetAddresses(c) { out[a] = n }
            current = nil
        }
    }
    return out
}

enum Probe: String { case connected = "연결됨", refused = "거절(서버)", timeout = "응답 없음", error = "오류" }

/// ip:port 로 TCP 연결을 시도한다. ifname 이 있으면 그 인터페이스에 묶는다.
func probe(_ ip: String, _ port: UInt16, ifname: String?, timeout: Int32 = 2500) -> Probe {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return .error }
    defer { close(fd) }
    if let n = ifname {
        var idx = if_nametoindex(n)
        guard idx != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return .error }
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &addr.sin_addr)
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if rc == 0 { return .connected }
    if errno == ECONNREFUSED { return .refused }
    guard errno == EINPROGRESS else { return .error }
    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&p, 1, timeout) > 0 else { return .timeout }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    if err == 0 { return .connected }
    return err == ECONNREFUSED ? .refused : .error
}

/// IPv4 주소가 있는 인터페이스들 (루프백 제외).
func ipv4Interfaces() -> [String] {
    var names: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
        let n = String(cString: p.pointee.ifa_name)
        if n != "lo0", !names.contains(n) { names.append(n) }
    }
    return names
}

func cmdSelftest(port: UInt16, verbose: Bool) -> Int32 {
    // 점검하는 동안 데몬이 규칙을 다시 올리지 못하게 잠금을 쥔다.
    withLock { selftestLocked(port: port, verbose: verbose) }
}

func selftestLocked(port: UInt16, verbose: Bool) -> Int32 {
    let st = apply()
    if st.paused { print("일시정지 중이라 점검할 규칙이 없어요."); return 0 }
    let ifaces = ipv4Interfaces()
    var fails = 0, total = 0
    print("점검: TCP \(port) 로 출구별 연결 시도. 고른 출구로는 나가고, 다른 출구는 막히거나 못 나가야 통과")
    print("인터페이스: \(ifaces.joined(separator: ", ")) · 기본 경로 \(st.defaultIf)\n")
    for r in st.rules where r.enabled {
        let allow: String?
        switch r.decision {
        case "route": allow = r.chosenIface
        case "block": allow = nil
        default: print("  · \(r.title): \(r.reason) — 점검 안 함\n"); continue
        }
        // 도메인은 주소 두 개까지만, 가려진 주소·제외한 주소는 빼고
        let addrs = r.targets.flatMap { t -> [AddressStatus] in
            if t.kind == .remaining {
                // Avoid the root-only health probe exemption at 1.1.1.1:443.
                guard let ip = ["1.0.0.1", "9.9.9.9", "8.8.8.8"].first(where: { candidate in
                    t.addresses.contains { targetCovered(candidate, by: $0.ip) }
                }), let prefix = t.addresses.first(where: { targetCovered(ip, by: $0.ip) }) else { return [] }
                var address = prefix; address.ip = ip
                return [address]
            }
            return Array(
            t.addresses.filter { !$0.ip.contains(":") && !$0.ip.contains("/") && $0.owner == nil && $0.note == nil }.prefix(t.kind == .domain ? 2 : 1))
        }
        guard !addrs.isEmpty else { print("  ? \(r.title): 점검할 IPv4 주소 없음\n"); continue }
        print("  \(r.title) — \(allow.map { "\(r.chosenExit.map(Exits.label) ?? "")(\($0))로만" } ?? "모두 차단")")
        for a in addrs {
            for ifc in [nil] + ifaces.map(Optional.some) {
                let c0 = pfCounters().filter { $0.key == a.ip || targetCovered(a.ip, by: $0.key) }.values.reduce(0, +)
                let t0 = Date()
                let res = probe(a.ip, port, ifname: ifc)
                let elapsed = Date().timeIntervalSince(t0)
                let c1 = pfCounters().filter { $0.key == a.ip || targetCovered(a.ip, by: $0.key) }.values.reduce(0, +)
                let byRule = c1 > c0
                // 경로가 없어 아예 못 보낸 경우(오류)는 새지 않은 것이다 (링크 꺼짐, 터널 재연결 중 등).
                let notSent = res == .error && !byRule
                let expectBlocked: Bool = ifc == nil ? allow == nil : ifc != allow
                let pass = expectBlocked ? (byRule || notSent) : !byRule && !notSent
                total += 1; if !pass { fails += 1 }
                let what = byRule ? "규칙이 막음" : (notSent ? "못 나감 (보낼 경로 없음)" : "나감 · \(res.rawValue)")
                let label = ifc ?? "기본(\(routeGet(a.ip)["interface"] ?? "?"))"
                print("    \(pass ? "✓" : "✗") \(a.ip.padding(toLength: 16, withPad: " ", startingAt: 0)) \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(what)")
                if verbose || !pass {
                    print(String(format: "        pf 패킷 %d → %d · %.2f초 · %@", c0, c1, elapsed, res.rawValue))
                    if !pass, let ifc {
                        print("        route(\(ifc)): \(run("/sbin/route", ["-n", "get", "-ifscope", ifc, a.ip]).out.split(separator: "\n").filter { $0.contains("interface") || $0.contains("gateway") }.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · "))")
                    }
                }
            }
        }
        print("")
    }
    print(fails == 0 ? "통과: \(total)건 모두 예상대로" : "실패: \(total)건 중 \(fails)건이 예상과 다름")
    return fails == 0 ? 0 : 1
}

// MARK: - 설치·제거

func plist(_ engine: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(Paths.daemonLabel)</string>
      <key>ProgramArguments</key>
      <array><string>\(engine)</string><string>daemon</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>5</integer>
      <key>StandardErrorPath</key><string>\(Paths.stateDir)/daemon.err</string>
    </dict>
    </plist>

    """
}

/// v1(zsh 도우미)의 파일을 v2 로 옮긴다. 이미 v2 면 아무것도 안 한다.
func migrateV1() {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: Paths.config) else { return }
    var c = EngineConfig()
    let v1 = Paths.dir
    if let text = try? String(contentsOfFile: v1 + "/hosts", encoding: .utf8) {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let raw = f.first, let (t, _) = Target.parse(raw) else { continue }
            c.rules.append(Rule(id: newRuleID(), name: cleanNote(f.count > 2 ? f[2] : ""), enabled: (f.count > 1 ? f[1] : "on") != "off", targets: [t]))
        }
        c.paused = fm.fileExists(atPath: v1 + "/paused")
        log("migrated v1 hosts: \(c.rules.flatMap(\.targets).joined(separator: " "))")
    }
    saveConfig(c)
    if let text = try? String(contentsOfFile: v1 + "/resolved", encoding: .utf8) {
        var db = ResolvedDB()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count == 3, Target.isDomain(f[0]), let ts = Int(f[2]) { db.domains[f[0], default: [:]][f[1]] = ts }
        }
        writeJSON(db, Paths.resolved)
    }
    if let text = try? String(contentsOfFile: v1 + "/routes", encoding: .utf8) {
        writeJSON(text.split(separator: "\n").map(String.init).filter { RouteSpec(key: $0) != nil }, Paths.routes)
    }
    if let old = try? String(contentsOfFile: v1 + "/log", encoding: .utf8) { writeAtomic(old.data(using: .utf8)!, Paths.log) }
    for f in ["hosts", "resolved", "routes", "last-resolve", "last-apply", "paused", "log", "daemon.err"] {
        try? fm.removeItem(atPath: v1 + "/" + f)
    }
}

func cmdInstall() {
    ensureDirs()
    withLock {
        migrateV1()
        try? FileManager.default.removeItem(atPath: "/Library/Application Support/wifi-exit")   // v0 의 apply.sh
        try? FileManager.default.removeItem(atPath: Paths.legacyHelper)
    }
    run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"])
    // bootout 은 옛 데몬이 다 내려가기 전에 돌아온다. 그새 bootstrap 하면 "5: Input/output error" 가 난다.
    for _ in 0..<50 where run("/bin/launchctl", ["print", "system/\(Paths.daemonLabel)"]).ok { usleep(100_000) }
    writeAtomic(plist(Paths.engine).data(using: .utf8)!, Paths.daemonPlist)
    chown(Paths.daemonPlist, 0, 0)
    var r = run("/bin/launchctl", ["bootstrap", "system", Paths.daemonPlist])
    for _ in 0..<5 where !r.ok {
        usleep(500_000)
        r = run("/bin/launchctl", ["bootstrap", "system", Paths.daemonPlist])
    }
    if !r.ok { die("데몬을 올리지 못했어요: \(r.err)") }
    log("installed engine (daemon)")
    withLock { _ = apply(forceResolve: true) }
}

func cmdUninstall() {
    run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"])
    try? FileManager.default.removeItem(atPath: Paths.daemonPlist)
    for r in (readJSON(Paths.routes, [String].self) ?? []).compactMap(RouteSpec.init(key:)) { routeDelete(kind: r.kind, dest: r.dest) }
    run("/sbin/pfctl", ["-q", "-a", Paths.anchor, "-F", "all"])
    try? FileManager.default.removeItem(atPath: Paths.anchorFile)
    resolverPrune(keep: [])
    try? FileManager.default.removeItem(atPath: Paths.dir)
    try? FileManager.default.removeItem(atPath: Paths.sudoers)
    try? FileManager.default.removeItem(atPath: Paths.legacyHelper)
    try? FileManager.default.removeItem(atPath: Paths.engine)
    print("모두 지웠어요.")
}

// MARK: - 진입

#if !WIFI_EXIT_TESTING
@main
enum Engine {
    static func main() {
        guard geteuid() == 0 else { die("root 권한이 필요해요 (wifi-exit CLI 나 앱으로 실행하세요)") }
        umask(0o022)
        var args = Array(CommandLine.arguments.dropFirst())
        let cmd = args.isEmpty ? "" : args.removeFirst()
        switch cmd {
        case "daemon":
            Daemon().start()
        case "apply":
            guard args.isEmpty || args == ["--resolve"] else { die("사용법: apply [--resolve]", code: 2) }
            withLock { _ = apply(forceResolve: !args.isEmpty) }
        case "resolve":
            withLock { _ = apply(forceResolve: true) }
        case "add":
            cmdAdd(args)
        case "set":
            cmdEdit(args)
        case "profile":
            cmdProfile(args)
        case "health":
            cmdHealth(args)
        case "diag":
            // pf 가 실제로 어떤 상태인지 그대로 보여 준다 (규칙이 안 걸릴 때 원인 찾기)
            func show(_ title: String, _ a: [String]) {
                let r = run("/sbin/pfctl", a)
                print("== \(title)  (pfctl \(a.joined(separator: " ")) → \(r.code))")
                print(r.out.trimmingCharacters(in: .newlines))
                if !r.err.isEmpty { print(r.err.split(separator: "\n").filter { !$0.contains("ALTQ") }.joined(separator: "\n")) }
            }
            show("info", ["-s", "info"])
            show("anchors (top)", ["-s", "Anchors"])
            show("anchors (com.apple)", ["-a", "com.apple", "-s", "Anchors"])
            show("main rules", ["-s", "rules"])
            show("wifi-exit rules", ["-a", Paths.anchor, "-vs", "rules"])
            show("load (dry run)", ["-n", "-v", "-a", Paths.anchor, "-f", Paths.anchorFile])
            show("load", ["-v", "-a", Paths.anchor, "-f", Paths.anchorFile])
            show("wifi-exit rules after load", ["-a", Paths.anchor, "-s", "rules"])
        case "move":
            guard args.count == 2 else { die("사용법: move <대상|id> up|down|top|bottom|<위치>", code: 2) }
            cmdMove(args[0], args[1])
        case "rm", "on", "off":
            guard args.count == 1 else { die("사용법: \(cmd) <대상|규칙 id>", code: 2) }
            cmdSet(cmd, args[0])
        case "pause", "resume":
            cmdPause(cmd == "pause")
        case "status":
            if readStatus() == nil { withLock { _ = apply() } }
            if let d = FileManager.default.contents(atPath: Paths.status) { FileHandle.standardOutput.write(d) }
        case "log":
            let n = Int(args.first ?? "50") ?? 50
            guard (1...2000).contains(n) else { die("줄 수는 1–2000", code: 2) }
            let text = (try? String(contentsOfFile: Paths.log, encoding: .utf8)) ?? ""
            print(text.split(separator: "\n").suffix(n).joined(separator: "\n"))
        case "selftest":
            var port: UInt16 = 443
            if let i = args.firstIndex(of: "--port") {
                guard i + 1 < args.count, let p = UInt16(args[i + 1]), p > 0 else { die("--port 뒤에 포트 번호", code: 2) }
                port = p
            }
            exit(cmdSelftest(port: port, verbose: args.contains("--verbose")))
        case "install":
            cmdInstall()
        case "uninstall":
            cmdUninstall()
        default:
            die("사용법: daemon | apply [--resolve] | resolve | add <대상> [--via …] [--else …] [--when …] [메모] | set <대상> [--via …] [--else …] [--when …] [--name …] | profile add|rm <이름> | move <대상> <위치> | rm|on|off <대상> | pause | resume | status | log [n] | selftest [--port N] [--verbose] | install | uninstall", code: 2)
        }
    }
}

#endif
