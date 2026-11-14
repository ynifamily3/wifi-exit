import Foundation

struct SplitRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var signingID: String
    var teamID: String
    var helpers = true
    var enabled = true
    var exits = ["wifi"]
    var fallback = "block"

    /// The app itself or a helper nested under its signing identifier (e.g. `<id>.helper`).
    /// Fails closed when the source's team cannot be verified.
    func strictCandidate(signingID source: String) -> Bool {
        enabled && (source == signingID || (helpers && !teamID.isEmpty && source.hasPrefix(signingID + ".")))
    }
    /// Also helpers signed under a sibling identifier from the same vendor, such as
    /// Dia (`company.thebrowser.dia`) whose network traffic comes from
    /// `company.thebrowser.browser.helper`. These still need a verified team match.
    func candidate(signingID source: String) -> Bool {
        strictCandidate(signingID: source) || (enabled && helpers && !teamID.isEmpty && !source.isEmpty
            && SplitRule.vendor(source) == SplitRule.vendor(signingID))
    }
    func matches(signingID source: String, teamID team: String) -> Bool {
        guard enabled, !source.isEmpty, teamID == team else { return false }
        return candidate(signingID: source)
    }
    /// Reverse-DNS vendor part of a signing identifier: `company.thebrowser.dia` → `company.thebrowser`.
    static func vendor(_ id: String) -> String {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : id
    }
}

/// What happens to apps without a rule while a VPN tunnel holds the default route.
/// Off: they follow the system (the VPN). On: they leave through `exits` (Wi-Fi by default),
/// so only apps with an explicit VPN rule stay in the tunnel.
struct OthersPolicy: Codable, Equatable {
    var enabled = false
    var exits = ["wifi"]
}

struct SplitConfig: Codable, Equatable {
    var version = 1
    var configurationID: String? = UUID().uuidString
    var revision: Int? = nil
    var rules: [SplitRule] = []
    var others: OthersPolicy? = nil

    func restoring(_ cached: SplitConfig?) -> SplitConfig {
        guard let id = configurationID, let cached, cached.configurationID == id,
              cached.problem == nil, (cached.revision ?? 0) > (revision ?? 0) else { return self }
        return cached
    }
    var problem: String? {
        guard configurationID == nil || UUID(uuidString: configurationID!) != nil, (revision ?? 0) >= 0 else { return "설정 식별자가 올바르지 않아요" }
        guard version == 1, rules.count <= 100 else { return "지원하지 않는 설정이거나 앱이 100개를 넘어요" }
        var seen = Set<String>()
        for r in rules {
            guard !r.signingID.isEmpty, r.signingID.count <= 255, r.name.count <= 255,
                  r.exits.count <= 6, r.exits.allSatisfy(Exits.isValid), ["block", "system"].contains(r.fallback),
                  r.teamID.isEmpty || (r.teamID.count == 10 && r.teamID.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }),
                  seen.insert(r.id).inserted else { return "앱 규칙의 식별자·출구·동작이 올바르지 않아요" }
        }
        if let o = others, o.exits.isEmpty || o.exits.count > 6 || !o.exits.allSatisfy(Exits.isValid) {
            return "나머지 앱의 출구가 올바르지 않아요"
        }
        return nil
    }
}

struct SplitExit: Codable, Equatable {
    var selector: String
    var iface: String
    var ip: String
    var healthy = true
    var label: String { Exits.label(selector) + " (" + iface + ")" }
    func matches(_ name: String) -> Bool {
        if name == selector { return true }
        if name == "vpn:any" { return selector.hasPrefix("vpn:") }
        if name.hasPrefix("vpn:"), selector.hasPrefix("vpn:") {
            return Exits.vpnMatches(portal: String(selector.dropFirst(4)), alias: String(name.dropFirst(4)))
        }
        return false
    }
}

enum SplitDecision: Equatable {
    case system
    case route(rule: String, iface: String)
    case block(rule: String)
}

enum SplitPolicy {
    /// Only the removed catch-all policy conflicts with app routing. A harmless
    /// engine code-signature difference must not block an otherwise compatible engine.
    static func requiresEngineMigration(config: Data?, status: Data?) -> Bool {
        [config, status].contains { data in
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rules = object["rules"] as? [[String: Any]] else { return false }
            return rules.contains { rule in
                (rule["targets"] as? [Any] ?? []).contains { value in
                    if let target = value as? String { return target == "remaining" }
                    if let target = value as? [String: Any] { return target["target"] as? String == "remaining" || target["kind"] as? String == "remaining" }
                    return false
                }
            }
        }
    }

    static func decide(_ config: SplitConfig, signingID: String, teamID: String?, exits: [SplitExit]) -> SplitDecision {
        if teamID == nil {
            if let candidate = config.rules.first(where: { $0.strictCandidate(signingID: signingID) }) { return .block(rule: candidate.id) }
            return .system
        }
        guard let rule = config.rules.first(where: { $0.matches(signingID: signingID, teamID: teamID ?? "") }) else { return .system }
        for name in rule.exits {
            if let exit = exits.first(where: { $0.healthy && $0.matches(name) }) { return .route(rule: rule.id, iface: exit.iface) }
        }
        return rule.fallback == "system" ? .system : .block(rule: rule.id)
    }

    static let othersRule = "others"
    /// Processes that must keep the system path even when other apps are moved off the VPN:
    /// the resolver (DNS must keep following the VPN's resolver configuration) and Wi-Fi Exit
    /// itself (its health probes bind to a specific interface).
    static func othersExcluded(_ signingID: String) -> Bool {
        signingID.isEmpty || signingID == "com.apple.mDNSResponder" || signingID.hasPrefix("com.miel.WifiExit")
    }
    static func isTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    /// Apps without a matching rule. Only a flow the system would send into the VPN tunnel that
    /// holds the default route is moved; flows already on a physical link and specific routes into
    /// other tunnels (e.g. Tailscale peers, the VPN client's own gateway traffic) stay untouched.
    /// Never blocks: with no usable exit the flow keeps the system path.
    static func decideOthers(_ config: SplitConfig, signingID: String, flowInterface: String?, defaultIf: String?,
                             exits: [SplitExit]) -> SplitDecision {
        guard let others = config.others, others.enabled, !othersExcluded(signingID),
              let flowInterface, isTunnel(flowInterface), flowInterface == defaultIf else { return .system }
        for name in others.exits {
            if let exit = exits.first(where: { $0.healthy && $0.iface != flowInterface && $0.matches(name) }) {
                return .route(rule: othersRule, iface: exit.iface)
            }
        }
        return .system
    }

    /// Host rules take precedence over app rules, including explicit system bypasses.
    static func ownedByHost(_ host: String, status: EngineStatus?) -> Bool {
        guard let status, !status.paused else { return false }
        return status.rules.contains { rule in
            guard rule.enabled, ["route", "block", "system"].contains(rule.decision) else { return false }
            return rule.targets.contains { target in
                target.target == host || target.addresses.contains { a in
                    a.owner == nil && a.note == nil && targetCovered(host, by: a.ip)
                }
            }
        }
    }
}

struct SplitReport: Codable {
    var active = 0
    var accepted = 0
    var blocked = 0
    var system = 0
    var exits: [SplitExit] = []
    var note = ""
    var configuration: SplitConfig? = nil
}
