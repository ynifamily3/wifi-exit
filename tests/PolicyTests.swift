import Foundation

@main
struct PolicyTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let host = Rule(id: "host", name: "", targets: ["8.8.8.8"], exits: ["wired"])
        var rest = Rule(id: "rest", name: "", targets: ["remaining"])
        check(Target.parse("remaining")?.1 == .remaining, "parse remaining")
        check(Target.parse("0.0.0.0/0") == nil, "do not broaden user CIDR validation")
        check(Remaining.ordered([rest, host]).map(\.id) == ["host", "rest"], "default always last")
        check(Remaining.validation([host, rest]) == nil, "valid policy")
        check(Remaining.validation([rest, rest]) != nil, "one catchall")
        rest.targets.append("example.org")
        check(Remaining.validation([rest]) != nil, "no mixed targets")
        rest.targets = ["remaining"]; rest.check = "example.org:443"
        check(Remaining.validation([rest]) != nil, "no unsafe custom checks")
        rest.check = nil
        let old = try JSONDecoder().decode(EngineConfig.self, from: Data(#"{"version":2,"rules":[]}"#.utf8))
        check(old.rules.isEmpty && !old.paused, "old config")
        var config = old; config.rules = [rest, host]
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: JSONEncoder().encode(config))
        check(decoded.rules.map(\.id) == ["host", "rest"], "decoded order")
        check(try! JSONDecoder().decode(EngineConfig.self, from: JSONEncoder().encode(decoded)) == decoded, "roundtrip")
        let excluded = ["8.8.8.8", "203.0.113.0/24", "198.51.100.7", "1.1.1.1"]
        let prefixes = Remaining.prefixes(excluding: excluded).compactMap(IPv4Prefix.init)
        for address in excluded + ["10.0.0.1", "127.0.0.1", "100.64.0.1", "224.0.0.1", "192.168.1.1"] {
            check(!prefixes.contains { $0.contains(IPv4Prefix(address)!) }, "must exclude \(address)")
        }
        check(prefixes.contains { $0.contains(IPv4Prefix("9.9.9.9")!) }, "ordinary Internet covered")
        // Deterministic full-range samples check complement completeness and non-overlap.
        var n: UInt32 = 0x12345678
        let exclusions = (Remaining.localIPv4 + excluded).compactMap(IPv4Prefix.init)
        for _ in 0..<10000 {
            n = n &* 1664525 &+ 1013904223
            let ip = IPv4Prefix(n, 32)
            let hits = prefixes.filter { $0.contains(ip) }.count
            check(hits == (exclusions.contains { $0.contains(ip) } ? 0 : 1), "exact complement \(n)")
        }
        check(IPv4Prefix("0.0.0.0/0")!.subtracting(IPv4Prefix("0.0.0.0/0")!).isEmpty, "/0 subtraction")
        check(IPv4Prefix("255.255.255.255")!.subtracting(IPv4Prefix("255.255.255.254")!).count == 1, "/32 boundary")
        let wifi = ExitInfo(name: "wifi", iface: "en0", ip: "192.168.1.2", gateway: "192.168.1.1", dns: ["192.168.1.1"], portal: "", up: true)
        let wired = ExitInfo(name: "wired", iface: "en1", ip: "10.0.0.2", gateway: "10.0.0.1", dns: [], portal: "", up: true)
        var facts = Facts(exits: [wifi, wired], profiles: [:], defaultIf: "en1", vpnOver: "", date: Date())
        check(decide(rest, facts: facts).word == "route", "available default exit")
        facts.exits = [wired]
        check(decide(rest, facts: facts).word == "block", "missing exit fail closed")
        rest.elseAction = "system"
        check(decide(rest, facts: facts).word == "system", "explicit system fallback")
        rest.exits = ["wifi", "wired"]
        check(decide(rest, facts: facts).word == "route", "secondary exit")
        rest.enabled = false
        check(decide(rest, facts: facts).word == "off", "disabled default")
        let groups = [PFGroup(rule: "host", allow: "en1", v4: ["8.8.8.8"], v6: ["2001:db8::1"]),
                      PFGroup(rule: "system", allow: nil, v4: [], v6: ["2001:db8::2"], system: true),
                      PFGroup(rule: "rest", allow: "en0", v4: prefixes.map(\.text), v6: ["::/0"], remaining: true)]
        let (pf, map) = renderPF(groups, logging: false, probes: [("1.1.1.1", 443), ("8.8.8.8", 53), ("192.168.1.1", 53)])
        check(pf.contains("to 1.1.1.1 port 443 user root"), "root-only engine probe")
        check(pf.contains("proto udp from any to 192.168.1.1 port 53 user root"), "root DNS can resolve before reapply")
        check(!pf.contains("to 8.8.8.8 port 53 user root"), "probe cannot bypass explicit host rule")
        check(pf.contains("block return out quick inet6 from any to ::/0"), "remaining IPv6 fail closed")
        check(!pf.contains("pass out quick on en0 inet6"), "no accidental IPv6 pass")
        check(pf.range(of: "on en1 inet6")!.lowerBound < pf.range(of: "to ::/0")!.lowerBound, "explicit IPv6 first")
        check(pf.contains("pass out quick inet6 from any to 2001:db8::2"), "system IPv6 exemption")
        check(pf.split(separator: "\n").count == map.count + 1, "event rule indices align")
        try pf.write(toFile: "/tmp/wifi-exit-policy-test.pf", atomically: true, encoding: .utf8)
        try renderPF(groups, logging: true).0.write(toFile: "/tmp/wifi-exit-policy-test-logging.pf", atomically: true, encoding: .utf8)
        for logging in [true, false] {
            let (oldPF, _) = renderPF([groups[0]], logging: logging)
            check(!oldPF.contains("user root") && !oldPF.contains("::/0"), "opt-in only")
        }
        let override = Remaining.prefixes(excluding: [], overriding: ["203.0.113.0/24", "203.0.113.0/25"]).compactMap(IPv4Prefix.init)
        check(override.contains { $0.text == "203.0.113.0/26" }, "overlapping foreign routes")
        check(override.filter { $0.contains(IPv4Prefix("203.0.113.1")!) }.count == 1, "overrides remain disjoint")
        check(RouteEntry(dest: "128/1", gateway: "", flags: "US", netif: "utun9").prefix?.text == "128.0.0.0/1", "netstat abbreviated route")
        check(displayedPFTarget("block return out quick inet6 all") == "::/0", "pf canonical IPv6 any")
        check(displayedPFTarget("block return out quick inet from any to 9.9.9.9") == "9.9.9.9", "pf canonical host")
        check(IPv4Prefix("9.9.9.9/32")!.text == "9.9.9.9", "canonical /32")
        try integration(wifi: wifi, wired: wired)
        print("PASS: \(count) policy checks; generated /tmp/wifi-exit-policy-test.pf")
    }
    static func integration(wifi: ExitInfo, wired: ExitInfo) throws {
        defer { try? FileManager.default.removeItem(atPath: Paths.dir) }
        ensureDirs()
        TestHooks.net = NetSnapshot(exits: [wifi, wired], masks: ["en0": "255.255.255.0", "en1": "255.255.255.0"],
            wifi: LinkInfo(iface: "en0", ip: wifi.ip, gateway: wifi.gateway, dns: wifi.dns, signature: "", up: true))
        let external = [RouteEntry(dest: "default", gateway: wired.gateway, flags: "UGSc", netif: "en1"),
                        RouteEntry(dest: "198.51.100.7", gateway: wired.gateway, flags: "UGHS", netif: "en1"),
                        RouteEntry(dest: "203.0.113/24", gateway: "link#9", flags: "US", netif: "utun9")]
        var table = external
        var loadedPF = ""
        var mutations = 0
        TestHooks.run = { path, args in
            if path == "/usr/sbin/netstat" {
                return Out(code: 0, out: table.map { "\($0.dest) \($0.gateway) \($0.flags) \($0.netif)" }.joined(separator: "\n"), err: "")
            }
            if path == "/sbin/route" {
                if args.contains("get") { return Out(code: 0, out: "interface: en1\n", err: "") }
                mutations += 1
                let dest = args[3]
                if args[1] == "delete" {
                    let had = table.contains { $0.dest == dest }
                    table.removeAll { $0.dest == dest }
                    return Out(code: had ? 0 : 1, out: "", err: "")
                }
                let iface = args.contains("-interface") ? args.last! : (args.last == wifi.gateway ? "en0" : "en1")
                table.append(RouteEntry(dest: dest, gateway: args.last!, flags: "UGS", netif: iface))
                return Out(code: 0, out: "", err: "")
            }
            if path == "/sbin/pfctl" {
                if args.contains("-f"), args.last == Paths.anchorFile {
                    loadedPF = (try? String(contentsOfFile: Paths.anchorFile, encoding: .utf8)) ?? ""
                }
                let out: String
                if args.contains("Anchors") { out = "com.apple" }
                else if args.contains("info") { out = "Status: Enabled" }
                else if args.contains("rules") {
                    out = loadedPF.replacingOccurrences(of: "inet6 from any to ::/0", with: "inet6 all")
                } else { out = "" }
                return Out(code: 0, out: out, err: "")
            }
            if path == "/usr/bin/dig" { return Out(code: 0, out: args.contains("AAAA") ? "2001:db8::1" : "8.8.8.8", err: "") }
            fatalError("Unexpected external command: \(path) \(args)")
        }
        var config = EngineConfig()
        let host = Rule(id: "host", name: "", targets: ["8.8.8.8"], exits: ["wired"])
        let system = Rule(id: "system", name: "", targets: ["9.9.9.9"], exits: ["vpn:any"], elseAction: "system")
        var rest = Rule(id: "rest", name: "", targets: ["remaining"])
        config.rules = [host, system]
        saveConfig(config)
        var status = apply()
        check(status.rules.count == 2 && table.count == external.count + 1, "legacy apply unchanged")
        config.rules = [rest, host, system]
        saveConfig(config)
        status = apply()
        let remaining = status.rules.last!
        check(remaining.id == "rest" && status.state(of: remaining) == .ok, "apply default and verified route/pf status")
        for excluded in ["8.8.8.8", "9.9.9.9", "198.51.100.7", "192.168.1.99", "10.0.0.1"] {
            check(!remaining.addresses.contains { targetCovered(excluded, by: $0.ip) }, "effective exclusion \(excluded)")
        }
        check(table.contains { $0.dest == "default" && $0.netif == "en1" }, "system default untouched")
        check(table.contains { $0.dest == "198.51.100.7" && $0.netif == "en1" }, "VPN transport untouched")
        check(table.contains { $0.dest == "203.0.113/24" && $0.netif == "utun9" }, "foreign VPN route preserved")
        check(remaining.addresses.contains { $0.ip == "203.0.113.0/25" && $0.pinned }, "override public VPN subnet without replacing it")
        let countBefore = mutations
        status = apply()
        check(mutations == countBefore, "idempotent reapply")
        TestHooks.net!.exits = [wired]
        status = apply()
        check(status.rules.last!.decision == "block" && status.state(of: status.rules.last!) == .noExit, "link loss closes remaining")
        check(table.count == external.count + 1, "link loss removes all remaining routes")
        rest.elseAction = "system"; config.rules = [host, system, rest]; saveConfig(config)
        status = apply()
        check(status.rules.last!.decision == "system" && !loadedPF.contains("::/0"), "system fallback restores firewall")
        rest.exits = ["wifi", "wired"]; config.rules = [host, system, rest]; saveConfig(config)
        status = apply()
        check(status.rules.last!.chosenIface == "en1" && status.state(of: status.rules.last!) == .ok, "secondary exit apply")
        config.paused = true; saveConfig(config); status = apply()
        check(table.count == external.count && pfRules().isEmpty, "pause removes all managed policy")
        config.paused = false; config.rules = [host, rest]
        config.rules[0].when = try Condition.parse("link=wifi")
        saveConfig(config); status = apply()
        check(status.rules.last!.addresses.contains { targetCovered("8.8.8.8", by: $0.ip) }, "skipped host belongs to remaining")
        let blocked = Rule(id: "blocked", name: "", targets: ["8.8.8.8"], exits: [])
        let next = Rule(id: "next", name: "", targets: ["9.9.9.9"], exits: ["vpn:any"], elseAction: "next")
        config.rules = [blocked, next, rest]; saveConfig(config); status = apply()
        check(status.rules.last!.addresses.contains { targetCovered("9.9.9.9", by: $0.ip) }, "next host belongs to remaining")
        check(!status.rules.last!.addresses.contains { targetCovered("8.8.8.8", by: $0.ip) }, "explicit block beats remaining")
        TestHooks.net!.exits = [wifi, wired]
        let domain = Rule(id: "domain", name: "", targets: ["example.org"], exits: ["wifi"])
        rest.exits = ["wired"]; config.rules = [domain, rest]; saveConfig(config); status = apply(forceResolve: true)
        check(status.rules.first!.addresses.contains { $0.ip == "8.8.8.8" && $0.pinned }, "domain uses its own exit")
        check(!status.rules.last!.addresses.contains { targetCovered("8.8.8.8", by: $0.ip) }, "resolved domain excluded from default")
        check(status.state(of: status.rules.last!) == .ok, "different domain/default exits are enforced")
        config.rules = [host]; saveConfig(config); status = apply()
        check(table.count == external.count + 1 && !loadedPF.contains("inet6 all"), "remove default restores original routes")
    }

}
