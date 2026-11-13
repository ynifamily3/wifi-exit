import Foundation

/// Internal IPv4 prefix arithmetic. User-entered CIDRs retain their existing validation.
struct IPv4Prefix: Equatable {
    let network: UInt32
    let length: Int

    init?(_ text: String) {
        let p = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(p.count), let ip = Target.ipv4Number(String(p[0])),
              let bits = p.count == 1 ? 32 : Int(p[1]), (0...32).contains(bits) else { return nil }
        length = bits
        network = ip & Self.mask(bits)
    }
    init(_ network: UInt32, _ length: Int) { self.network = network; self.length = length }
    static func mask(_ n: Int) -> UInt32 { n == 0 ? 0 : UInt32.max << (32 - n) }
    var text: String { length == 32 ? Target.ipv4String(network) : "\(Target.ipv4String(network))/\(length)" }
    func contains(_ other: IPv4Prefix) -> Bool {
        length <= other.length && other.network & Self.mask(length) == network
    }
    var children: [IPv4Prefix] {
        guard length < 32 else { return [self] }
        return [IPv4Prefix(network, length + 1), IPv4Prefix(network | (UInt32(1) << (31 - length)), length + 1)]
    }
    func subtracting(_ other: IPv4Prefix) -> [IPv4Prefix] {
        if other.contains(self) { return [] }
        guard contains(other), length < 32 else { return [self] }
        return children.flatMap { $0.subtracting(other) }
    }
}

enum Remaining {
    static let target = "remaining"
    // Local/private, link-local, shared address space (including Tailscale), multicast and reserved.
    // Individual host rules can still explicitly select an exit for these addresses.
    static let localIPv4 = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                            "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]
    static let localIPv6 = ["::/128", "::1/128", "fe80::/10", "fc00::/7", "ff00::/8"]

    static func prefixes(excluding addresses: [String], overriding networks: [String] = []) -> [String] {
        var out = [IPv4Prefix(0, 0)]
        for p in (localIPv4 + addresses).compactMap(IPv4Prefix.init) {
            out = out.flatMap { $0.subtracting(p) }
        }
        // More-specific routes owned by VPN software must not capture the remainder.
        // Split around them and install children, keeping their original routes for rollback.
        for route in networks.compactMap(IPv4Prefix.init) where route.length < 32 {
            out = out.flatMap { p in
                guard p.length <= route.length, p.contains(route) else { return [p] }
                return p.subtracting(route) + route.children
            }
        }
        return out.sorted { $0.network < $1.network }.map(\.text)
    }
    static func ordered(_ rules: [Rule]) -> [Rule] {
        rules.filter { !$0.isRemaining } + rules.filter(\.isRemaining)
    }
    static func validation(_ rules: [Rule]) -> String? {
        if rules.filter(\.isRemaining).count > 1 { return "나머지 트래픽 규칙은 하나만 만들 수 있어요" }
        for r in rules where r.isRemaining {
            if r.targets != [target] { return "나머지 트래픽은 다른 대상과 섞을 수 없어요" }
            if r.check != nil { return "나머지 트래픽은 출구 자체의 상태 점검을 사용해요" }
        }
        return nil
    }
}
