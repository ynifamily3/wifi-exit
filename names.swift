// 연결 이름 알아내기 (라우팅 보기). 엔진(root)이 보는 사람이 있는 동안만 tcpdump 로
//   1) DNS 응답: 앱이 물어본 이름(질문)과 받은 주소(A·AAAA)를 짝짓는다
//   2) TLS ClientHello 의 SNI: HTTPS 연결이 처음 보내는 패킷에 적힌 접속할 이름
// 를 읽어 IP → 이름 표를 만든다. 역방향 조회(PTR)는 CDN 이름(ec2-…, server-….cloudfront.net)을 주지만, 이건 앱이 실제로 쓴 이름이다.
// 암호화된 DNS(DoH·DoT)는 보이지 않고, ECH 를 쓰거나 ClientHello 가 한 패킷을 넘으면 SNI 를 못 읽을 수 있다.
// 표는 메모리에만 둔다 (30분, 최대 4096개). 디스크에 남기지 않는다.

import Foundation

enum NameSniff {
    /// tcpdump 거르개: DNS 응답, 그리고 443 으로 가는 TLS 핸드셰이크 첫 레코드 (TCP 자료가 0x16 으로 시작)
    static let filter = "udp src port 53 or (tcp dst port 443 and tcp[((tcp[12:1] & 0xf0) >> 2):1] = 0x16)"

    /// pcap 기록 하나에서 알아낸 (IP, 이름, 어디서)
    static func names(in p: [UInt8], linkType: UInt32) -> [LearnedName] {
        guard let (start, v6) = ipStart(p, 0, linkType, depth: 0) else { return [] }
        return v6 ? fromIPv6(p, start) : fromIPv4(p, start)
    }

    // MARK: 링크 층

    /// IP 머리가 시작하는 자리와 IPv6 인지
    static func ipStart(_ p: [UInt8], _ o: Int, _ link: UInt32, depth: Int) -> (Int, Bool)? {
        switch link {
        case 258, 149:                                        // DLT_PKTAP (Apple): 길이가 적힌 머리 뒤에 원래 링크의 프레임
            guard depth == 0, o + 12 <= p.count else { return nil }
            let len = Int(u32le(p, o)), inner = u32le(p, o + 8)
            guard len >= 12, o + len < p.count else { return nil }
            return ipStart(p, o + len, inner, depth: 1)
        case 1:                                               // 이더넷 (VLAN 하나까지)
            guard o + 14 <= p.count else { return nil }
            var type = u16be(p, o + 12), at = o + 14
            if type == 0x8100 { guard o + 18 <= p.count else { return nil }; type = u16be(p, o + 16); at = o + 18 }
            if type == 0x0800 { return (at, false) }
            if type == 0x86DD { return (at, true) }
            return nil
        case 0, 108:                                          // NULL·LOOP (utun, lo0): 4바이트 주소 계열
            guard o + 4 <= p.count else { return nil }
            let fam = link == 0 ? u32le(p, o) : u32be(p, o)
            if fam == 2 { return (o + 4, false) }
            if fam == 30 || fam == 24 || fam == 28 { return (o + 4, true) }
            return nil
        case 12, 101:                                         // RAW: 바로 IP
            guard o < p.count else { return nil }
            return (o, p[o] >> 4 == 6)
        default:
            return nil
        }
    }

    // MARK: IP·UDP·TCP

    static func fromIPv4(_ p: [UInt8], _ o: Int) -> [LearnedName] {
        guard o + 20 <= p.count, p[o] >> 4 == 4 else { return [] }
        let ihl = Int(p[o] & 0x0f) * 4
        let frag = u16be(p, o + 6) & 0x1fff
        guard ihl >= 20, frag == 0, o + ihl <= p.count else { return [] }
        let dst = (0..<4).map { String(p[o + 16 + $0]) }.joined(separator: ".")
        return transport(p, o + ihl, proto: p[o + 9], dst: dst)
    }

    static func fromIPv6(_ p: [UInt8], _ o: Int) -> [LearnedName] {
        guard o + 40 <= p.count, p[o] >> 4 == 6 else { return [] }
        return transport(p, o + 40, proto: p[o + 6], dst: ipv6(Array(p[o + 24 ..< o + 40])))
    }

    static func transport(_ p: [UInt8], _ o: Int, proto: UInt8, dst: String) -> [LearnedName] {
        if proto == 17 {                                      // UDP: 53 에서 온 DNS 응답
            guard o + 8 <= p.count, u16be(p, o) == 53 else { return [] }
            return dns(p, o + 8).map { LearnedName(ip: $0.0, host: $0.1, via: "dns") }
        }
        if proto == 6 {                                       // TCP: 443 으로 가는 ClientHello
            guard o + 20 <= p.count, u16be(p, o + 2) == 443 else { return [] }
            let off = Int(p[o + 12] >> 4) * 4
            guard off >= 20, let host = sni(p, o + off) else { return [] }
            return [LearnedName(ip: dst, host: host, via: "sni")]
        }
        return []
    }

    // MARK: DNS

    /// 응답의 (주소, 질문 이름). CNAME 을 거쳤어도 앱이 물어본 이름(질문)을 쓴다
    static func dns(_ p: [UInt8], _ s: Int) -> [(String, String)] {
        guard s + 12 <= p.count else { return [] }
        let flags = u16be(p, s + 2)
        guard flags & 0x8000 != 0, flags & 0x000f == 0 else { return [] }      // 응답, 오류 없음
        let qd = u16be(p, s + 4), an = u16be(p, s + 6)
        guard qd == 1, an > 0, let (qname, afterQ) = readName(p, s, s + 12), let host = clean(qname) else { return [] }
        var o = afterQ + 4                                    // 질문의 형식·분류
        var out: [(String, String)] = []
        for _ in 0 ..< min(Int(an), 64) {
            guard let (_, next) = readName(p, s, o), next + 10 <= p.count else { break }
            let type = u16be(p, next), len = Int(u16be(p, next + 8))
            let rd = next + 10
            guard rd + len <= p.count else { break }
            if type == 1, len == 4 { out.append(((0..<4).map { String(p[rd + $0]) }.joined(separator: "."), host)) }
            if type == 28, len == 16 { out.append((ipv6(Array(p[rd ..< rd + 16])), host)) }
            o = rd + len
        }
        return out
    }

    /// DNS 이름 (압축 포인터 따라감). 이름과, 원래 자리에서 이름이 끝난 다음 자리
    static func readName(_ p: [UInt8], _ msg: Int, _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var o = start, end: Int?, jumps = 0
        while o < p.count {
            let n = Int(p[o])
            if n == 0 { return (labels.joined(separator: "."), end ?? o + 1) }
            if n & 0xc0 == 0xc0 {
                guard o + 1 < p.count, jumps < 32 else { return nil }
                if end == nil { end = o + 2 }
                o = msg + ((n & 0x3f) << 8 | Int(p[o + 1]))
                jumps += 1
                continue
            }
            guard n <= 63, o + 1 + n <= p.count, labels.count < 64 else { return nil }
            labels.append(String(decoding: p[o + 1 ..< o + 1 + n], as: UTF8.self))
            o += 1 + n
        }
        return nil
    }

    // MARK: TLS

    /// TLS 레코드의 ClientHello 에서 server_name. 한 패킷 안에 있는 만큼만 읽는다
    static func sni(_ p: [UInt8], _ s: Int) -> String? {
        guard s + 9 <= p.count, p[s] == 0x16, p[s + 1] == 3, p[s + 5] == 1 else { return nil }
        var o = s + 9 + 2 + 32                                // 레코드 머리 5 + 핸드셰이크 머리 4, 버전 2, 무작위 32
        guard o < p.count else { return nil }
        o += 1 + Int(p[o])                                    // 세션 id
        guard o + 2 <= p.count else { return nil }
        o += 2 + Int(u16be(p, o))                             // 암호 묶음
        guard o < p.count else { return nil }
        o += 1 + Int(p[o])                                    // 압축
        guard o + 2 <= p.count else { return nil }
        let end = min(p.count, o + 2 + Int(u16be(p, o)))
        o += 2
        while o + 4 <= end {
            let type = u16be(p, o), len = Int(u16be(p, o + 2))
            o += 4
            if type == 0 {                                    // server_name: 목록 길이 2, 종류 1 (0 = 호스트 이름), 이름 길이 2
                guard o + 5 <= end, p[o + 2] == 0 else { return nil }
                let n = Int(u16be(p, o + 3))
                guard o + 5 + n <= end else { return nil }
                return clean(String(decoding: p[o + 5 ..< o + 5 + n], as: UTF8.self))
            }
            o += len
        }
        return nil
    }

    // MARK: 도우미

    /// 사람이 쓰는 호스트 이름만 (소문자 ASCII, 점이 있고, 253자까지). 역방향 조회용 이름은 뺀다
    static func clean(_ s: String) -> String? {
        let h = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard h.count <= 253, h.contains("."), !h.hasSuffix(".arpa"), !h.hasSuffix(".local"),
              h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else { return nil }
        return h
    }

    static func u16be(_ p: [UInt8], _ o: Int) -> UInt16 { UInt16(p[o]) << 8 | UInt16(p[o + 1]) }
    static func u32be(_ p: [UInt8], _ o: Int) -> UInt32 { UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3]) }
    static func u32le(_ p: [UInt8], _ o: Int) -> UInt32 { UInt32(p[o + 3]) << 24 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o]) }

    static func ipv6(_ b: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b.prefix(16)) }
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = withUnsafePointer(to: &addr) { inet_ntop(AF_INET6, UnsafeRawPointer($0), &out, socklen_t(INET6_ADDRSTRLEN)) }
        return String(cString: out)
    }
}

/// 보는 사람이 있는 동안 tcpdump 로 이름을 읽어 표에 담는다. 새로 알았거나 바뀐 것만 onName 으로.
/// 주소가 있는 인터페이스(Wi-Fi·유선·테더링·VPN 터널)마다 tcpdump 를 하나씩 띄우고, 30초마다 새로 생긴 것을 더한다.
/// 모든 인터페이스를 한 번에 잡는 pktap 은 거르개를 걸 수 없어("DLT 258 link-layer type filtering not implemented")
/// 모든 패킷을 받아야 해서 쓰지 않는다. tcpdump 가 끝나면 까닭(오류 글)을 엔진 기록에 남긴다.
final class NameSniffer {
    var onName: ((LearnedName) -> Void)?
    private let q: DispatchQueue
    private var readers: [Reader] = []
    private var running = false
    private var refresh: DispatchSourceTimer?
    private var table: [String: (host: String, via: String, at: Date)] = [:]

    /// tcpdump 하나와 그 출력 (pcap 흐름)
    private final class Reader {
        let iface: String
        let proc = Process()
        var buf = Data()
        var link: UInt32?
        var err = Data()
        init(_ iface: String) { self.iface = iface }
    }

    init(queue: DispatchQueue) { q = queue }

    /// 지금 아는 이름들 (새로 붙은 사람에게 한꺼번에 보낸다)
    var known: [LearnedName] { table.map { LearnedName(ip: $0.key, host: $0.value.host, via: $0.value.via) } }

    func start() {
        guard !running else { return }
        running = true
        addPerInterface()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.addPerInterface() }
        t.resume()
        refresh = t
    }

    func stop() {
        running = false
        refresh?.cancel(); refresh = nil
        readers.forEach { $0.proc.terminate() }
        readers.removeAll()
        table.removeAll()
    }

    private func addPerInterface() {
        guard running else { return }
        let have = Set(readers.map(\.iface))
        for i in Self.liveInterfaces() where !have.contains(i) { launch(i) }
    }

    /// 주소가 있는 켜진 인터페이스 (Wi-Fi·유선·테더링·VPN 터널). 링크 로컬 IPv6(fe80::)만 있는 시스템 터널은 뺀다
    static func liveInterfaces() -> [String] {
        var out = Set<String>()
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return [] }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            let name = String(cString: cur.pointee.ifa_name)
            var usable = false
            if let a = cur.pointee.ifa_addr {
                if a.pointee.sa_family == UInt8(AF_INET) { usable = true }
                if a.pointee.sa_family == UInt8(AF_INET6) {
                    let b = a.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8 }
                    usable = !(b.0 == 0xfe && b.1 & 0xc0 == 0x80)
                }
            }
            if usable, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               ["en", "utun", "ppp", "ipsec", "bridge"].contains(where: { name.hasPrefix($0) }) {
                out.insert(name)
            }
            p = cur.pointee.ifa_next
        }
        return out.sorted()
    }

    private func launch(_ iface: String) {
        let r = Reader(iface)
        r.proc.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
        r.proc.arguments = ["-n", "-U", "-s", "2048", "-i", iface, "-w", "-", NameSniff.filter]
        let out = Pipe(), err = Pipe()
        r.proc.standardOutput = out
        r.proc.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self, weak r] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.q.async { if let r { self?.consume(r, d) } }
        }
        // 오류 글은 따로 모아 둔다 (끝난 뒤에 기다려 읽으면 멈출 수 있다)
        err.fileHandleForReading.readabilityHandler = { [weak self, weak r] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.q.async { r?.err.append(d) }
        }
        r.proc.terminationHandler = { [weak self, weak r] t in
            self?.q.asyncAfter(deadline: .now() + 0.2) {
                guard let self, let r, self.running, self.readers.contains(where: { $0 === r }) else { return }
                self.readers.removeAll { $0 === r }
                let msg = String(decoding: r.err, as: UTF8.self).split(separator: "\n")
                    .filter { !$0.contains("listening on") && !$0.contains("packets") }.joined(separator: " / ")
                // 인터페이스가 사라지면 끝난다 (다시 생기면 30초 안에 다시 띄운다)
                log("names: tcpdump -i \(r.iface) ended (\(t.terminationStatus)) \(msg)")
            }
        }
        do {
            try r.proc.run()
            readers.append(r)
            log("names: reading DNS and TLS names (-i \(iface))")
        } catch {
            log("names: tcpdump -i \(iface) failed: \(error)")
        }
    }

    private func consume(_ r: Reader, _ d: Data) {
        r.buf.append(d)
        if r.link == nil {
            guard r.buf.count >= 24 else { return }
            let h = [UInt8](r.buf.prefix(24))
            r.link = NameSniff.u32le(h, 20)                   // pcap 전역 머리의 링크 종류 (이 Mac 의 바이트 순서)
            r.buf.removeFirst(24)
        }
        while r.buf.count >= 16 {
            let incl = Int(NameSniff.u32le([UInt8](r.buf.prefix(16)), 8))
            guard incl < 1 << 20 else { r.proc.terminate(); return }      // 흐름이 어긋났다
            guard r.buf.count >= 16 + incl else { return }
            let rec = [UInt8](r.buf[r.buf.startIndex + 16 ..< r.buf.startIndex + 16 + incl])
            r.buf.removeFirst(16 + incl)
            for n in NameSniff.names(in: rec, linkType: r.link ?? 0) { learn(n) }
        }
    }

    private func learn(_ n: LearnedName) {
        let now = Date()
        if table.count > 4096 { table = table.filter { now.timeIntervalSince($0.value.at) < 1800 } }
        let old = table[n.ip]
        table[n.ip] = (n.host, n.via, now)
        if old?.host != n.host { onName?(n) }
    }
}
