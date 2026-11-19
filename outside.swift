// 라우팅 보기의 "전체" 범위: 규칙에 없는 연결을 연결 표로 1초마다 훑어 찾는다.
// 연결 표는 netstat -anv 로 읽고, netstat 이 빈 출력을 주면 nettop 으로 읽는다: macOS 27 에서는 앱이 띄운
// netstat 에게 커널이 연결 표를 비워서 준다 (터미널에서 친 netstat 은 다 보인다). nettop 은 한 번에 60ms 쯤
// CPU 를 써서 netstat(몇 ms)보다 무겁지만 그 경우에도 다 보인다.
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
    private var useNettop = false                             // netstat 이 빈 출력을 주면 이번 수집 동안 nettop 으로
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
        first = true; seen.removeAll(); bytes.removeAll(); opened.removeAll(); useNettop = false
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// "192.168.0.10.52683" → ("192.168.0.10", 52683), "fe80::1%en0.443" → ("fe80::1%en0", 443).
    /// nettop 은 IPv4 를 "192.168.0.10:52683" 처럼 쓴다 (sep ":").
    private func split(_ s: Substring, sep: Character = ".") -> (String, Int)? {
        guard let dot = s.lastIndex(of: sep), let port = Int(s[s.index(after: dot)...]) else { return nil }
        return (String(s[..<dot]), port)
    }

    /// 연결 표의 한 줄 (ESTABLISHED·SYN_SENT 인 TCP 만). netstat 이든 nettop 이든 같은 모양으로 맞춘다.
    private struct Row {
        var src: String, sport: Int, dst: String, dport: Int
        var rx: Int?, tx: Int?        // 지금까지 받은·보낸 바이트
        var iface: String?            // nettop 만 알려 준다
        var name: String?, pid: Int?  // 프로세스 (nettop 은 이름을 15자로 자른다. 앱 이름은 pid 의 실행 파일로 다시 찾는다)
    }

    private func rows() -> [Row] {
        if !useNettop {
            let out = shRun("/usr/sbin/netstat", ["-anv", "-p", "tcp"])
            if !out.isEmpty { return netstatRows(out) }
            useNettop = true      // 연결이 하나도 없어도 netstat 은 머리줄을 찍는다. 아예 비었으면 표를 못 본 것
        }
        return nettopRows(shRun("/usr/bin/nettop", ["-L", "1", "-n", "-x", "-m", "tcp", "-J", "interface,state,bytes_in,bytes_out"]))
    }

    /// tcp4  0  0  10.0.0.5.52683  1.2.3.4.443  ESTABLISHED  rxbytes txbytes rhiwat shiwat  Claude Helper:3750 …
    private func netstatRows(_ out: String) -> [Row] {
        var rows: [Row] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 11, f[0].hasPrefix("tcp"), f[5] == "ESTABLISHED" || f[5] == "SYN_SENT" else { continue }
            guard let (src, sport) = split(f[3]), let (dst, dport) = split(f[4]) else { continue }
            // process:pid 칸은 이름에 빈칸이 들어갈 수 있다 ("Claude Helper:3750"): ':숫자' 로 끝나는 칸까지 붙인다
            var procTokens: [Substring] = []
            for tok in f[10...] {
                procTokens.append(tok)
                if tok.range(of: #":[0-9]+$"#, options: .regularExpression) != nil { break }
            }
            let proc = procTokens.joined(separator: " ")
            var name: String?, pid: Int?
            if let c = proc.lastIndex(of: ":"), let p = Int(proc[proc.index(after: c)...]) { name = String(proc[..<c]); pid = p }
            rows.append(Row(src: src, sport: sport, dst: dst, dport: dport, rx: Int(f[6]), tx: Int(f[7]), iface: nil, name: name, pid: pid))
        }
        return rows
    }

    /// nettop -L 1 -J interface,state,bytes_in,bytes_out 의 CSV. 프로세스 줄 다음에 그 프로세스의 연결 줄이 온다:
    ///   Claude Helper.32680,,,3283440,5045418,
    ///   tcp4 10.0.0.5:63521<->160.79.104.10:443,en13,Established,3139546,4080901,
    ///   tcp6 fe80::1%utun5.1024<->fe80::2%utun5.1024,utun5,Established,1281,1276,
    private func nettopRows(_ out: String) -> [Row] {
        var rows: [Row] = []
        var name: String?, pid: Int?
        // 칸 순서는 머리줄(",interface,state,bytes_in,bytes_out,")에서 읽는다 (nettop 이 -J 순서를 바꿀 수 있다고 해서)
        var col = ["interface": 1, "state": 2, "bytes_in": 3, "bytes_out": 4]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            if f.first?.isEmpty == true {
                for (i, c) in f.enumerated() where col[String(c)] != nil { col[String(c)] = i }
                continue
            }
            guard let iI = col["interface"], let sI = col["state"], let inI = col["bytes_in"], let outI = col["bytes_out"],
                  f.count > max(iI, sI, inI, outI) else { continue }
            let v4 = f[0].hasPrefix("tcp4 "), v6 = f[0].hasPrefix("tcp6 ")
            guard v4 || v6 else {
                // 프로세스 줄: "이름.pid" (이름에도 점이 들어갈 수 있다: "com.apple.WebKi.41518")
                if let d = f[0].lastIndex(of: "."), let p = Int(f[0][f[0].index(after: d)...]) { name = String(f[0][..<d]); pid = p }
                else { name = String(f[0]); pid = nil }
                continue
            }
            guard f[sI] == "Established" || f[sI] == "SynSent" else { continue }
            let ends = f[0].dropFirst(5).components(separatedBy: "<->")
            guard ends.count == 2, let (src, sport) = split(Substring(ends[0]), sep: v4 ? ":" : "."),
                  let (dst, dport) = split(Substring(ends[1]), sep: v4 ? ":" : ".") else { continue }
            rows.append(Row(src: src, sport: sport, dst: dst, dport: dport, rx: Int(f[inI]), tx: Int(f[outI]),
                            iface: f[iI].isEmpty ? nil : String(f[iI]), name: name, pid: pid))
        }
        return rows
    }

    private func poll() {
        let table = rows()
        lock.lock(); let ex = ctxExits, skip = ctxManaged; lock.unlock()
        var now = Set<String>(), found: [ConnEvent] = []
        for r in table {
            let (src, sport, dst, dport) = (r.src, r.sport, r.dst, r.dport)
            if dst.hasPrefix("127.") || dst == "::1" || dst.hasPrefix("fe80:") || src.hasPrefix("127.") { continue }
            let key = "\(src):\(sport)>\(dst):\(dport)"
            now.insert(key)
            // 이미 알린 연결: 받은·보낸 바이트가 늘었으면 "오감"을 알린다 (패킷 수는 모르니 1200바이트에 하나로 어림)
            if var base = opened[key], let rx = r.rx, let tx = r.tx {
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
            guard !seen.contains(key), !first, !skip.contains(where: { $0 == dst || targetCovered(dst, by: $0) }) else { continue }
            var app = r.name, exe: String?
            let pid = r.pid
            if let p = pid {
                var buf = [CChar](repeating: 0, count: 4096)
                if proc_pidpath(Int32(p), &buf, UInt32(buf.count)) > 0 {
                    let path = String(cString: buf)
                    if path.contains(".app/") {
                        let outer = (path.components(separatedBy: ".app/").first ?? path) + ".app"
                        exe = outer
                        app = ((outer as NSString).lastPathComponent as NSString).deletingPathExtension
                    } else {
                        exe = path
                        app = (path as NSString).lastPathComponent      // nettop 이 자른 이름 대신 온전한 이름
                    }
                }
            }
            // 나간 인터페이스: nettop 이 알려 준 것, 아니면 로컬 주소가 어느 출구의 주소인지
            let iface = r.iface ?? ex.first { $0.ip == src }?.iface ?? "?"
            let ev = ConnEvent(t: Int(Date().timeIntervalSince1970 * 1000), act: "pass", iface: iface, proto: "tcp",
                               src: src, sport: sport, dst: dst, dport: dport, rule: nil, allow: nil, uid: nil,
                               pid: pid, app: app, exe: exe, outside: true)
            found.append(ev)
            opened[key] = ev
            if let rx = r.rx, let tx = r.tx { bytes[key] = (rx, tx) }
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
