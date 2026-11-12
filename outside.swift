// 라우팅 보기의 "전체" 범위: 규칙에 없는 연결을 연결 표(netstat -anv)로 1초마다 훑어 찾는다.
// pf 를 건드리지 않는다 (모든 연결을 pf 로 기록하면 다른 방화벽 규칙과 엉킬 수 있어서).
// 1초 안에 열렸다 닫힌 연결은 놓칠 수 있다.

import AppKit
import Darwin
import Foundation

final class OutsideSampler {
    private let q = DispatchQueue(label: "wifi-exit.outside")
    private var timer: DispatchSourceTimer?
    private var seen = Set<String>()
    private var first = true
    private var bytes: [String: (rx: Int, tx: Int)] = [:]     // 연결 → 지난번 받은·보낸 바이트
    private var opened: [String: ConnEvent] = [:]             // 우리가 "열림"을 알린 연결 (닫힘·오감을 알릴 대상)
    /// 새 연결을 찾으면 (메인 스레드에서) 부른다.
    var onEvents: (([ConnEvent]) -> Void)?
    // 출구 목록과 규칙 주소는 메인 스레드가 넣어 준 사본을 쓴다 (이 큐에서 메인 액터 값을 읽지 않는다)
    private let lock = NSLock()
    private var ctxExits: [ExitInfo] = []
    private var ctxManaged: Set<String> = []

    func setContext(exits: [ExitInfo], managed: Set<String>) {
        lock.lock(); ctxExits = exits; ctxManaged = managed; lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        first = true; seen.removeAll(); bytes.removeAll(); opened.removeAll()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// "192.168.0.10.52683" → ("192.168.0.10", 52683), "fe80::1%en0.443" → ("fe80::1%en0", 443)
    private func split(_ s: String) -> (String, Int)? {
        guard let dot = s.lastIndex(of: "."), let port = Int(s[s.index(after: dot)...]) else { return nil }
        return (String(s[..<dot]), port)
    }

    private func poll() {
        let out = shRun("/usr/sbin/netstat", ["-anv", "-p", "tcp"])
        lock.lock(); let ex = ctxExits, skip = ctxManaged; lock.unlock()
        var now = Set<String>(), found: [ConnEvent] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 11, f[0].hasPrefix("tcp"), f[5] == "ESTABLISHED" || f[5] == "SYN_SENT" else { continue }
            guard let (src, sport) = split(String(f[3])), let (dst, dport) = split(String(f[4])) else { continue }
            if dst.hasPrefix("127.") || dst == "::1" || dst.hasPrefix("fe80:") || src.hasPrefix("127.") { continue }
            let key = "\(src):\(sport)>\(dst):\(dport)"
            now.insert(key)
            // 이미 알린 연결: 받은·보낸 바이트가 늘었으면 "오감"을 알린다 (패킷 수는 모르니 1200바이트에 하나로 어림)
            if var base = opened[key], let rx = Int(f[6]), let tx = Int(f[7]) {
                let prev = bytes[key] ?? (rx, tx)
                let din = max(0, rx - prev.rx), dout = max(0, tx - prev.tx)
                bytes[key] = (rx, tx)
                if din + dout > 0 {
                    base.t = Int(Date().timeIntervalSince1970 * 1000); base.kind = "traffic"
                    base.bin = din; base.bout = dout
                    base.pin = din > 0 ? max(1, din / 1200) : 0; base.pout = dout > 0 ? max(1, dout / 1200) : 0
                    found.append(base)
                }
                continue
            }
            guard !seen.contains(key), !first, !skip.contains(dst) else { continue }
            // process:pid 칸은 이름에 빈칸이 들어갈 수 있다 ("Claude Helper:3750"): ':숫자' 로 끝나는 칸까지 붙인다
            var procTokens: [Substring] = []
            for tok in f[10...] {
                procTokens.append(tok)
                if tok.range(of: #":[0-9]+$"#, options: .regularExpression) != nil { break }
            }
            let proc = procTokens.joined(separator: " ")
            var app: String?, pid: Int?, exe: String?
            if let c = proc.lastIndex(of: ":"), let p = Int(proc[proc.index(after: c)...]) {
                pid = p
                app = String(proc[..<c])
                var buf = [CChar](repeating: 0, count: 4096)
                if proc_pidpath(Int32(p), &buf, UInt32(buf.count)) > 0 {
                    let path = String(cString: buf)
                    if path.contains(".app/") {
                        let outer = (path.components(separatedBy: ".app/").first ?? path) + ".app"
                        exe = outer
                        app = ((outer as NSString).lastPathComponent as NSString).deletingPathExtension
                    } else { exe = path }
                }
            }
            // 나간 인터페이스: 로컬 주소가 어느 출구의 주소인지
            let iface = ex.first { $0.ip == src }?.iface ?? "?"
            let ev = ConnEvent(t: Int(Date().timeIntervalSince1970 * 1000), act: "pass", iface: iface, proto: "tcp",
                               src: src, sport: sport, dst: dst, dport: dport, rule: nil, allow: nil, uid: nil,
                               pid: pid, app: app, exe: exe, outside: true)
            found.append(ev)
            opened[key] = ev
            if let rx = Int(f[6]), let tx = Int(f[7]) { bytes[key] = (rx, tx) }
        }
        // 표에서 사라졌거나 ESTABLISHED 를 벗어난 연결 = 닫힘
        for (k, base) in opened where !now.contains(k) {
            var ev = base
            ev.t = Int(Date().timeIntervalSince1970 * 1000); ev.kind = "close"
            found.append(ev)
            opened[k] = nil; bytes[k] = nil
        }
        seen = now
        first = false
        if !found.isEmpty { DispatchQueue.main.async { self.onEvents?(found) } }
    }
}

func shRun(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe()
    p.standardOutput = o; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    let done: DispatchSemaphore
    do { done = try p.runWatched() } catch { return "" }
    let d = o.fileHandleForReading.readDataToEndOfFile()
    done.wait()
    return String(decoding: d, as: UTF8.self)
}

/// IP → 이름 (역방향 조회 PTR). 규칙 밖 연결은 평소 경로로 나가는 것이라 조회도 평소 경로로 간다.
/// PTR 이름은 앱이 실제로 쓴 도메인과 다를 수 있다 (CDN 이름 등).
@MainActor
final class HostNames: ObservableObject {
    @Published private(set) var names: [String: String] = [:]
    var onResolved: ((String, String) -> Void)?     // (IP, 이름) — 이름이 늦게 오면 IP 칸을 도메인 칸으로 합칠 때 쓴다
    private var asked = Set<String>()
    private let q = DispatchQueue(label: "wifi-exit.ptr", attributes: .concurrent)

    func name(_ ip: String) -> String? { names[ip] }

    func lookup(_ ip: String) {
        guard !asked.contains(ip) else { return }
        asked.insert(ip)
        q.async {
            var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else { return }
            defer { freeaddrinfo(res) }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return }
            let n = String(cString: host)
            DispatchQueue.main.async { self.names[ip] = n; self.onResolved?(ip, n) }
        }
    }
}
