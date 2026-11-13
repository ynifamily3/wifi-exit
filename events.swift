// 실시간 연결 사건 (wifi-exit watch / 라우팅 보기).
//
// /var/run/wifi-exit/events.sock 에 누가 붙어 있는 동안만:
//   1) state/logging 파일을 만들어 pf 앵커에 기록 줄을 넣게 한다 (apply 가 읽는다)
//   2) pflog0 을 만들고 tcpdump -w - 로 pflog 를 받아 직접 해석한다
//   3) 연결마다 JSON 한 줄을 붙어 있는 모두에게 보낸다
// 마지막으로 떨어지면 기록 줄을 빼고 pflog0 을 지운다. 디스크에는 사건을 남기지 않는다.

import Darwin
import Foundation

final class EventHub {
    static let shared = EventHub()
    var onLoggingChange: ((Bool) -> Void)?

    private let q = DispatchQueue(label: "wifi-exitd.events")
    private let lookupQ = DispatchQueue(label: "wifi-exitd.lookup", attributes: .concurrent)
    private let lookupSlots = DispatchSemaphore(value: 4)
    private var acceptSrc: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var reader: Process?
    private var buf = Data()
    private var gotHeader = false
    private var map: [PFLine] = []
    private var recent: [String: Date] = [:]     // 막힌 연결은 상태가 없어 재전송마다 기록된다. 2초 안의 같은 연결은 한 번만
    private var mapStamp: Date?

    // MARK: 소켓

    func start() {
        try? FileManager.default.removeItem(atPath: Paths.logging)     // 지난번에 남은 것
        mkdir(Paths.eventsDir, 0o755)
        unlink(Paths.eventsSock)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("watch: socket failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Paths.eventsSock.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 8) == 0 else { log("watch: bind/listen failed errno \(errno)"); close(fd); return }
        chown(Paths.eventsSock, 0, 80)                 // root:admin (도메인 계정은 staff 가 아닐 수 있다)
        chmod(Paths.eventsSock, 0o660)                 // 관리자(admin)만 읽는다
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in
            let c = accept(fd, nil, nil)
            if c >= 0 { self?.addClient(c) }
        }
        src.resume()
        acceptSrc = src
    }

    private func addClient(_ c: Int32) {
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: q)
        src.setEventHandler { [weak self] in
            var b = [UInt8](repeating: 0, count: 256)
            if read(c, &b, b.count) <= 0 { self?.drop(c) }      // 받는 건 없다. 끊기면 0
        }
        src.setCancelHandler { close(c) }
        src.resume()
        clients[c] = src
        log("watch: viewer connected (\(clients.count))")
        _ = write(c, "{\"hello\":1}\n", 12)
        if clients.count == 1 { setLogging(true) }
    }

    private func drop(_ c: Int32) {
        guard let s = clients.removeValue(forKey: c) else { return }
        s.cancel()
        log("watch: viewer left (\(clients.count))")
        if clients.isEmpty { setLogging(false) }
    }

    private func broadcast(_ line: Data) {
        for c in Array(clients.keys) {
            let n = line.withUnsafeBytes { write(c, $0.baseAddress, line.count) }
            if n < 0 { drop(c) }
        }
    }

    // MARK: 기록 켜고 끄기

    private func setLogging(_ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: Paths.logging, contents: Data(), attributes: [.posixPermissions: 0o644])
            run("/sbin/ifconfig", ["pflog0", "create"])        // 이미 있으면 실패해도 괜찮다
            startReader()
            startStatePoller()
        } else {
            try? FileManager.default.removeItem(atPath: Paths.logging)
            reader?.terminate(); reader = nil
            statePoll?.cancel(); statePoll = nil
            lastStates.removeAll(); closedKeys.removeAll()
            q.asyncAfter(deadline: .now() + 3) {
                // 그 사이 다시 붙은 사람이 없으면 pflog0 을 지운다
                if !FileManager.default.fileExists(atPath: Paths.logging) { run("/sbin/ifconfig", ["pflog0", "destroy"]) }
            }
        }
        onLoggingChange?(on)
    }

    // MARK: 연결 상태 계수기: 패킷이 오갈 때마다

    private var statePoll: DispatchSourceTimer?
    private var lastStates: [String: [Int]] = [:]          // 열쇠 → [나간 패킷, 들어온 패킷, 나간 바이트, 들어온 바이트]
    private var closedKeys = Set<String>()
    private var primed = false                              // 첫 읽기는 기준으로만 쓴다 (지난 watch 에서 남은 상태를 새 사건으로 보내지 않게)
    private var awaitingOpen: [String: [ConnEvent]] = [:]   // 앱을 찾는 동안 열림보다 먼저 온 오감·닫힘을 붙잡아 둔다 (순서 보장)
    private var earlyHeld: [String: [ConnEvent]] = [:]      // pflog 의 열림보다 상태 계수기가 먼저 본 연결: 잠깐(1.5초) 기다린다
    private var openedKeys = Set<String>()                  // 열림을 보냈거나 기다리기를 끝낸 연결

    /// watch 중에는 우리 앵커의 통과 줄이 keep state 라 연결마다 pf 상태가 생긴다. 그 계수기를 0.5초마다 읽어 차이를 보낸다.
    private func startStatePoller() {
        statePoll?.cancel()
        primed = false
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.pollStates() }
        t.resume()
        statePoll = t
    }

    /// "192.168.0.10:65395" → ("192.168.0.10", 65395), "2001:db8::1[443]" → ("2001:db8::1", 443)
    private func hostPort(_ s: Substring) -> (String, Int)? {
        if let b = s.firstIndex(of: "["), let e = s.firstIndex(of: "]"), let p = Int(s[s.index(after: b)..<e]) { return (String(s[..<b]), p) }
        guard let c = s.lastIndex(of: ":"), let p = Int(s[s.index(after: c)...]) else { return nil }
        return (String(s[..<c]), p)
    }

    private func pollStates() {
        loadMap()
        var passFor: [String: PFLine] = [:]
        for l in map where l.kind == "pass" && passFor[l.addr] == nil { passFor[l.addr] = l }
        guard !passFor.isEmpty else { return }
        let out = run("/sbin/pfctl", ["-vss"]).out
        var cur: [String: [Int]] = [:]
        var base: [String: ConnEvent] = [:]
        var closing = Set<String>()
        var pending: (String, ConnEvent, Bool)?
        func num(_ line: Substring, _ unit: String) -> (Int, Int)? {
            guard let r = line.range(of: #"([0-9]+):([0-9]+) "# + unit, options: .regularExpression) else { return nil }
            let parts = line[r].split(separator: " ")[0].split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
            return (a, b)
        }
        for line in out.split(separator: "\n") {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                pending = nil
                // "ALL tcp 192.168.0.10:65395 -> 1.0.0.1:443   ESTABLISHED:ESTABLISHED" (나가는 연결만)
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 6, f[3] == "->", let (src, sport) = hostPort(f[2]), let (dst, dport) = hostPort(f[4]),
                      let l = passFor[dst] ?? passFor.first(where: { targetCovered(dst, by: $0.key) })?.value else { continue }
                let proto = String(f[1])
                let st = String(f[5])
                let ev = ConnEvent(t: 0, act: "pass", iface: l.allow ?? "", proto: proto, src: src, sport: sport, dst: dst, dport: dport,
                                   rule: l.rule, allow: l.allow, uid: nil, pid: nil, app: nil)
                pending = (ev.flowKey, ev, st.contains("FIN") || st.contains("CLOSED") || st.contains("TIME_WAIT"))
            } else if let (k, ev, fin) = pending, let pk = num(line, "pkts"), let by = num(line, "bytes") {
                cur[k] = [pk.0, pk.1, by.0, by.1]          // 앞 = 연결을 연 쪽(우리)에서 나간 것, 뒤 = 들어온 것
                base[k] = ev
                if fin { closing.insert(k) }
                pending = nil
            }
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if !primed {
            primed = true; lastStates = cur; closedKeys = closing; openedKeys = Set(cur.keys)
            return
        }
        for (k, c) in cur {
            let p = lastStates[k] ?? [0, 0, 0, 0]
            let d = zip(c, p).map { max(0, $0 - $1) }
            if d.contains(where: { $0 > 0 }), var ev = base[k] {
                ev.t = now; ev.kind = "traffic"
                ev.pout = d[0]; ev.pin = d[1]; ev.bout = d[2]; ev.bin = d[3]
                sendOrHold(ev)
            }
            if closing.contains(k), !closedKeys.contains(k), var ev = base[k] {
                ev.t = now; ev.kind = "close"; closedKeys.insert(k); sendOrHold(ev)
            }
        }
        // 사라진 상태 = 닫힌 연결
        for k in lastStates.keys where cur[k] == nil {
            if !closedKeys.contains(k), let parts = Optional(k.split(separator: " ")), parts.count == 2 {
                let sd = parts[1].split(separator: ">")
                if sd.count == 2, let (src, sport) = hostPort(sd[0]), let (dst, dport) = hostPort(sd[1]) {
                    sendOrHold(ConnEvent(t: now, act: "pass", iface: passFor[dst]?.allow ?? "", proto: String(parts[0]), src: src, sport: sport,
                                         dst: dst, dport: dport, rule: passFor[dst]?.rule, allow: passFor[dst]?.allow, uid: nil, pid: nil, app: nil, kind: "close"))
                }
            }
            closedKeys.remove(k); openedKeys.remove(k)
        }
        lastStates = cur
    }

    private func startReader() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
        p.arguments = ["-n", "-U", "-s", "160", "-i", "pflog0", "-w", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        buf = Data(); gotHeader = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.q.async { self?.consume(d) }
        }
        do { try p.run(); reader = p } catch { log("watch: tcpdump failed: \(error)") }
    }

    // MARK: pflog 해석

    private func consume(_ d: Data) {
        buf.append(d)
        if !gotHeader {
            guard buf.count >= 24 else { return }
            buf.removeFirst(24)                                // pcap 전역 머리 (이 Mac 의 바이트 순서)
            gotHeader = true
        }
        while buf.count >= 16 {
            let incl = Int(buf.u32le(8))
            guard buf.count >= 16 + incl else { return }
            let rec = Data(buf[buf.startIndex + 16 ..< buf.startIndex + 16 + incl])
            buf.removeFirst(16 + incl)
            if let e = parse(rec), fresh(e) { deliver(e) }
        }
    }

    private func fresh(_ e: ConnEvent) -> Bool {
        let now = Date()
        if recent.count > 512 { recent = recent.filter { now.timeIntervalSince($0.value) < 2 } }
        let key = "\(e.act) \(e.proto) \(e.src):\(e.sport) \(e.dst):\(e.dport) \(e.iface)"
        if let t = recent[key], now.timeIntervalSince(t) < 2 { return false }
        recent[key] = now
        return true
    }

    private func loadMap() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Paths.pfMap)[.modificationDate]) as? Date
        if m != mapStamp { map = readJSON(Paths.pfMap, [PFLine].self) ?? []; mapStamp = m }
    }

    /// struct pfloghdr (61바이트, 4바이트 정렬로 64) 뒤에 IP 패킷이 온다.
    private func parse(_ p: Data) -> ConnEvent? {
        guard p.count >= 64 else { return nil }
        let hl = Int(p[p.startIndex])
        let af = p[p.startIndex + 1]
        let action = p[p.startIndex + 2]
        let ifname = p.cstring(4, 16)
        let ruleset = p.cstring(20, 16)
        guard ruleset == "wifi-exit" else { return nil }      // 우리 앵커에서 남긴 것만
        // pfloghdr: rulenr(36) 는 메인 규칙집에서 앵커 자리, subrulenr(40) 이 앵커 안 규칙 번호다 (tcpdump 의 "rule 0.wifi-exit.<n>/")
        let rulenr = Int(p.u32be(40))
        let uid = Int(Int32(bitPattern: p.u32le(44)))
        let ipo = (hl + 3) & ~3
        guard p.count > ipo + 20 else { return nil }
        var proto = 0, src = "", dst = "", sport = 0, dport = 0
        if af == 2 {                                           // IPv4
            let ihl = Int(p[p.startIndex + ipo] & 0x0f) * 4
            proto = Int(p[p.startIndex + ipo + 9])
            src = p.ipv4(ipo + 12); dst = p.ipv4(ipo + 16)
            if (proto == 6 || proto == 17), p.count >= ipo + ihl + 4 { sport = Int(p.u16be(ipo + ihl)); dport = Int(p.u16be(ipo + ihl + 2)) }
        } else if af == 30 {                                   // IPv6 (macOS AF_INET6)
            guard p.count >= ipo + 40 else { return nil }
            proto = Int(p[p.startIndex + ipo + 6])
            src = p.ipv6(ipo + 8); dst = p.ipv6(ipo + 24)
            if (proto == 6 || proto == 17), p.count >= ipo + 44 { sport = Int(p.u16be(ipo + 40)); dport = Int(p.u16be(ipo + 42)) }
        } else { return nil }
        loadMap()
        let line = map.indices.contains(rulenr) ? map[rulenr] : nil
        return ConnEvent(t: Int(Date().timeIntervalSince1970 * 1000), act: action == 0 ? "pass" : "block", iface: ifname,
                         proto: proto == 6 ? "tcp" : proto == 17 ? "udp" : proto == 1 ? "icmp" : "\(proto)",
                         src: src, sport: sport, dst: dst, dport: dport,
                         rule: line?.rule, allow: line?.allow,
                         uid: (uid >= 0 && uid < 2_147_483_647) ? uid : nil, pid: nil, app: nil)
    }

    /// 출발 포트로 소켓 주인을 찾아 앱 이름을 붙인 뒤 보낸다. 너무 몰리면 이름 없이 바로 보낸다.
    private func deliver(_ e: ConnEvent) {
        let key = e.flowKey
        if e.act == "pass" { openedKeys.insert(key) }
        guard e.sport > 0, lookupSlots.wait(timeout: .now()) == .success else {
            send(e); earlyHeld.removeValue(forKey: key)?.forEach { send($0) }; return
        }
        if e.act == "pass" { awaitingOpen[key] = earlyHeld.removeValue(forKey: key) ?? [] }
        lookupQ.async { [weak self] in
            var ev = e
            if let (pid, app, exe) = appFor(proto: e.proto, sport: e.sport, dst: e.dst) { ev.pid = pid; ev.app = app; ev.exe = exe }
            self?.lookupSlots.signal()
            self?.q.async {
                self?.send(ev)
                // 그동안 붙잡아 둔 같은 연결의 사건을 순서대로
                if let held = self?.awaitingOpen.removeValue(forKey: key) { held.forEach { self?.send($0) } }
            }
        }
    }

    /// 오감·닫힘: 그 연결의 열림이 아직 앱을 찾는 중이면 뒤에 보낸다
    private func sendOrHold(_ e: ConnEvent) {
        let k = e.flowKey
        if awaitingOpen[k] != nil { awaitingOpen[k]?.append(e); return }
        if openedKeys.contains(k) { send(e); return }
        // 열림이 아직 안 왔다: pflog 가 늦을 수 있어 잠깐 붙잡는다. 끝내 안 오면 (watch 전에 열린 연결 등) 그대로 보낸다.
        if earlyHeld[k] != nil { earlyHeld[k]?.append(e); return }
        earlyHeld[k] = [e]
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let held = self.earlyHeld.removeValue(forKey: k) else { return }
            if self.openedKeys.count > 4096 { self.openedKeys.removeAll() }
            self.openedKeys.insert(k)
            held.forEach { self.send($0) }
        }
    }

    private func send(_ e: ConnEvent) {
        guard var d = try? JSONEncoder().encode(e) else { return }
        d.append(0x0a)
        broadcast(d)
    }
}

/// lsof 로 (프로토콜, 출발 포트)의 소켓 주인을 찾는다. 막힌 연결은 소켓이 금방 닫혀 못 찾을 수 있다.
func appFor(proto: String, sport: Int, dst: String) -> (Int, String, String?)? {
    guard proto == "tcp" || proto == "udp" else { return nil }
    let out = run("/usr/sbin/lsof", ["-nP", "-i\(proto.uppercased()):\(sport)", "-F", "pcn"]).out
    var pid: Int?, cmd = ""
    for line in out.split(separator: "\n") {
        switch line.first {
        case "p": pid = Int(line.dropFirst()); cmd = ""
        case "c": cmd = String(line.dropFirst())
        case "n":
            // 이 연결의 로컬 쪽이 sport 인 것 (상대 쪽 포트가 우연히 같은 것은 뺀다)
            let n = line.dropFirst()
            let local = n.split(separator: "-").first.map(String.init) ?? String(n)
            if local.hasSuffix(":\(sport)"), let p = pid {
                let (name, exe) = appIdentity(pid: p)
                return (p, name ?? cmd, exe)
            }
        default: break
        }
    }
    return nil
}

/// 실행 파일 경로에서 사람이 아는 이름과 아이콘용 경로: …/Slack.app/…/Slack Helper → ("Slack", "…/Slack.app")
func appIdentity(pid: Int) -> (String?, String?) {
    // proc_pidpath: 실행 파일의 전체 경로 (ps 는 명령 이름만 줄 때가 있다)
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
    let path = n > 0 ? String(cString: buf) : run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return (nil, nil) }
    if path.contains(".app/") {
        // 도우미 앱(…/Slack Helper.app)보다 바깥 앱을 쓴다
        let outer = (path.components(separatedBy: ".app/").first ?? path) + ".app"
        return (((outer as NSString).lastPathComponent as NSString).deletingPathExtension, outer)
    }
    return ((path as NSString).lastPathComponent, path.hasPrefix("/") ? path : nil)
}

private extension Data {
    func u32le(_ o: Int) -> UInt32 { self[startIndex + o ..< startIndex + o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
    func u32be(_ o: Int) -> UInt32 { self[startIndex + o ..< startIndex + o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian }
    func u16be(_ o: Int) -> UInt16 { self[startIndex + o ..< startIndex + o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian }
    func cstring(_ o: Int, _ n: Int) -> String {
        let bytes = self[startIndex + o ..< startIndex + o + n].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    func ipv4(_ o: Int) -> String { (0..<4).map { String(self[startIndex + o + $0]) }.joined(separator: ".") }
    func ipv6(_ o: Int) -> String {
        let bytes: [UInt8] = Array(self[startIndex + o ..< startIndex + o + 16])
        var addr = in6_addr()
        Swift.withUnsafeMutableBytes(of: &addr) { raw in raw.copyBytes(from: bytes) }
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = Swift.withUnsafePointer(to: &addr) { ptr in inet_ntop(AF_INET6, UnsafeRawPointer(ptr), &out, socklen_t(INET6_ADDRSTRLEN)) }
        return String(cString: out)
    }
}
