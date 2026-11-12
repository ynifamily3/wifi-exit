// 출구가 "지금 없음"일 때 그 까닭: 어댑터가 안 보임 / 케이블 없음 / 주소 못 받음 / 게이트웨이 없음 / Wi-Fi 꺼짐 / 다른 VPN …
// 앱·CLI 쪽에서만 본다 (엔진은 그대로라 갱신할 필요 없음). 네트워크 설정(서비스 목록)과 SCDynamicStore 의 인터페이스 상태를 읽는다.

import Foundation
import SystemConfiguration

enum ExitWhy {
    /// 네트워크 설정에 있는 서비스 하나 (장치가 빠져 있어도 남아 있다)
    struct Port { let bsd: String; let display: String; let type: String; let enabled: Bool }

    /// 인터페이스 하나의 지금 상태
    struct Link { var present = false; var active: Bool?; var ip: String?; var power: Bool? }

    static func ports() -> [Port] {
        guard let prefs = SCPreferencesCreate(nil, "wifi-exit-why" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        return services.compactMap { s in
            guard let i = SCNetworkServiceGetInterface(s), let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { return nil }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? (SCNetworkServiceGetName(s) as String? ?? bsd)
            return Port(bsd: bsd, display: display, type: SCNetworkInterfaceGetInterfaceType(i) as String? ?? "",
                        enabled: SCNetworkServiceGetEnabled(s))
        }
    }

    static func links(_ names: [String]) -> [String: Link] {
        guard let store = SCDynamicStoreCreate(nil, "wifi-exit-why" as CFString, nil, nil) else { return [:] }
        func value(_ k: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, k as CFString) as? [String: Any] }
        let present = Set(value("State:/Network/Interface")?["Interfaces"] as? [String] ?? [])
        var out: [String: Link] = [:]
        for n in names {
            var l = Link(present: present.contains(n))
            l.active = value("State:/Network/Interface/\(n)/Link")?["Active"] as? Bool
            l.ip = (value("State:/Network/Interface/\(n)/IPv4")?["Addresses"] as? [String])?.first
            if let p = value("State:/Network/Interface/\(n)/AirPort")?["Power Status"] { l.power = (p as? Bool) ?? ((p as? Int).map { $0 != 0 }) }
            out[n] = l
        }
        return out
    }

    private static func isWiFi(_ p: Port) -> Bool { p.type == (kSCNetworkInterfaceTypeIEEE80211 as String) }
    private static func isEthernet(_ p: Port) -> Bool { p.type == (kSCNetworkInterfaceTypeEthernet as String) }
    private static func isTether(_ p: Port) -> Bool { isEthernet(p) && p.display.localizedCaseInsensitiveContains("iPhone") }

    /// 이 종류(wifi / wired / tether)에 해당하는 설정된 포트
    static func ports(for kind: String, in all: [Port]) -> [Port] {
        switch kind {
        case "wifi": return all.filter(isWiFi)
        case "wired": return all.filter { isEthernet($0) && !isTether($0) }
        case "tether": return all.filter(isTether)
        default: return []
        }
    }

    /// 출구 이름(wifi, wired, tether, vpn:any, vpn:<별칭>)이 지금 없는 까닭. 있으면 nil.
    static func reason(_ name: String, exits: [ExitInfo], ports all: [Port]? = nil) -> String? {
        guard matchingExits(name, in: exits).isEmpty else { return nil }
        if name.hasPrefix("vpn:") {
            let vpns = exits.filter { $0.up && $0.name == "vpn" }
            if name == "vpn:any" || vpns.isEmpty { return "VPN 연결 안 됨" }
            return "지금은 \(vpns.map(\.label).joined(separator: ", ")) 연결 중"
        }
        var candidates = ports(for: name, in: all ?? ports())
        // "Ethernet Adapter (en4)" 같은 이름 없는 서비스는 Mac 안쪽 가상 포트라 늘 있고 늘 꺼져 있다.
        // 이름 있는 포트(USB 10/100/1000 LAN 등)가 있으면 그쪽으로 말한다.
        let named = candidates.filter { !$0.display.hasPrefix("Ethernet Adapter (") }
        if !named.isEmpty { candidates = named }
        if candidates.isEmpty {
            switch name {
            case "wifi": return "Wi-Fi 장치 없음"
            case "tether": return "iPhone이 USB로 연결되지 않음"
            default: return "유선 포트가 네트워크 설정에 없음"
            }
        }
        let ls = links(candidates.map(\.bsd))
        // 여러 포트 중 가장 멀리 간 단계로 말한다: 안 보임 < 꺼짐 < 링크 없음 < 주소 없음 < 게이트웨이 없음
        func stage(_ p: Port) -> Int {
            let l = ls[p.bsd] ?? Link()
            if !l.present { return 0 }
            if !p.enabled { return 1 }
            if l.power == false { return 2 }
            if l.active == false { return 3 }
            if l.ip == nil { return 4 }
            return 5
        }
        let best = candidates.max { stage($0) < stage($1) }!
        switch stage(best) {
        case 0:
            return name == "tether" ? "iPhone이 안 보임 — 케이블을 다시 꽂아 보세요"
                 : name == "wifi" ? "Wi-Fi 장치가 안 보임"
                 : "어댑터가 안 보임(\(best.display)) — 다시 꽂아 보세요"
        case 1: return "네트워크 설정에서 \(best.display) 서비스가 꺼져 있음"
        case 2: return "Wi-Fi 꺼짐"
        case 3: return name == "wifi" ? "Wi-Fi 네트워크에 연결 안 됨" : "케이블이 안 꽂혔거나 링크 없음"
        case 4: return "주소를 못 받음 (DHCP)"
        default: return "게이트웨이 없음"
        }
    }
}
