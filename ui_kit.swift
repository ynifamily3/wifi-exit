// 세 화면(메뉴바 팝업, 규칙 창, 라우팅 보기)이 같이 쓰는 모양: 출구 기호·색, 동그라미 배지, 규칙 요약 문구, 경고 목록.
// 앱 쪽에만 들어간다 (엔진은 그대로).

import AppKit
import SwiftUI

extension Exits {
    /// 출구 이름(wifi, wired, tether, vpn:…, block) → 종류
    static func kind(_ e: String) -> String {
        if e.hasPrefix("vpn") { return "vpn" }
        return e
    }

    /// SF Symbols 이름
    static func symbol(_ e: String) -> String {
        switch kind(e) {
        case "wifi": return "wifi"
        case "wired": return "cable.connector"
        case "tether": return "iphone"
        case "vpn": return "lock.shield"
        case "block": return "nosign"
        default: return "questionmark"
        }
    }
}

/// 출구 기호. 출구마다 색을 칠하지 않고(무지개 동그라미는 장난감처럼 보였다) 옅은 무채색 동그라미에
/// 기호만 둔다. 막기만 산호색, 지금 없는 출구는 흐리게.
struct ExitBadge: View {
    let name: String
    var off = false
    var size: CGFloat = 20

    var body: some View {
        let block = Exits.kind(name) == "block" && !off
        ZStack {
            Circle().fill(block ? Color.statusError.opacity(0.14) : Color.primary.opacity(off ? 0.05 : 0.09))
            Image(systemName: Exits.symbol(name))
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(block ? Color.statusError : off ? Color.secondary.opacity(0.7) : Color.primary)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Exits.label(name))
    }
}

/// 흑연 팔레트: 정상·켜짐은 무채색(밝은 모양에서 검정, 어두운 모양에서 흰색)이고, 색은 문제에만 쓴다.
///   호박색(주의) — 앱 아이콘의 화살표, 산호색(막힘·오류). 시스템 기본 초록·주황·빨강·파랑은 쓰지 않는다.
/// 글자로 쓸 때는 밝은/어두운 모양에서 각각 읽히는 밝기로, 바탕에 깔 때는 옅게(12%) 쓴다. 그라데이션은 쓰지 않는다.
extension Color {
    static let statusOK = Color.primary
    static let statusWarn = adaptive(light: (0.60, 0.38, 0.0), dark: (0.97, 0.74, 0.29))
    static let statusError = adaptive(light: (0.75, 0.24, 0.18), dark: (1.0, 0.56, 0.48))
    /// 정상·켜짐 판의 칠과 그 위 기호: 검정 판에 흰 기호, 어두운 모양에서는 흰 판에 검정 기호
    static let solidFill = Color.primary
    static let onSolidFill = Color(nsColor: .textBackgroundColor)
    static let brandInk = Color(red: 17 / 255, green: 24 / 255, blue: 64 / 255)
    static let brandAmber = Color(red: 245 / 255, green: 178 / 255, blue: 52 / 255)
    static let brandCoral = Color(red: 226 / 255, green: 87 / 255, blue: 72 / 255)
    /// 카드 바탕: 무채색을 옅게
    static let cardFill = adaptive(light: (0, 0, 0), dark: (1, 1, 1), lightAlpha: 0.045, darkAlpha: 0.06)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double),
                                 lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// 상태 기호: 정상 = 초록 방패, 경고 = 주황 삼각, 오류 = 빨강, 꺼짐 = 회색
struct StatusBadge: View {
    enum Level { case ok, warn, error, off }
    let level: Level
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
    private var color: Color {
        switch level { case .ok: return .green; case .warn: return .orange; case .error: return .red; case .off: return .secondary.opacity(0.6) }
    }
    private var symbol: String {
        switch level { case .ok: return "checkmark.shield.fill"; case .warn, .error: return "exclamationmark.triangle.fill"; case .off: return "pause.fill" }
    }
}

// MARK: - 규칙 요약 문구 (세 화면이 같은 말을 쓰도록 한 곳에서)

extension RuleStatus {
    /// 지금 나가는 출구 종류 (배지 색). 보내는 중이 아니면 nil
    var nowExit: String? { decision == "route" ? chosenExit.map(Exits.kind) : decision == "block" ? "block" : nil }

    /// 지금 상태 한 줄: "Wi-Fi로 보내는 중" / "막는 중" / "유선 없음 → 다음 규칙으로" …
    var nowText: String {
        switch decision {
        case "route": return "\(chosenExit.map(Exits.label) ?? "?")로 보내는 중"
        case "block": return "막는 중 (쓸 수 있는 출구 없음)"
        case "system": return "평소 경로로 둠 (쓸 수 있는 출구 없음)"
        case "next": return "출구 없음 → 다음 규칙으로"
        case "skip": return "조건이 안 맞아 건너뜀"
        default: return enabled ? "적용 안 함" : "꺼짐"
        }
    }
}

extension Rule {
    /// 설정 요약: "Wi-Fi → VPN:pass · 없으면 차단"
    var settingsText: String {
        (exits.isEmpty ? "그냥 막기" : exits.map(Exits.label).joined(separator: " → ")) + " · 없으면 " + Exits.elseLabel(elseAction)
    }
}

// MARK: - 경고 (팝업에 띠로 쌓는다)

struct AppWarning: Identifiable {
    enum Action { case installEngine, apply, resume, openRules }
    let id: String
    let level: StatusBadge.Level
    let title: String
    let detail: String
    var action: Action? = nil
    var actionLabel: String? = nil
}

@MainActor
extension AppModel {
    /// 우선순위 순: 엔진 설치·갱신 → 엔진 멈춤 → 차단 빠짐 → 일시정지 → 규칙이 쓰는 출구 응답 없음 → 규칙 오류·가려짐
    var warnings: [AppWarning] {
        var out: [AppWarning] = []
        if !engineReady {
            out.append(AppWarning(id: "engine", level: .warn, title: engineOutdated ? "엔진 갱신 필요" : "엔진 없음",
                                  detail: engineOutdated ? "앱과 버전이 달라요" : "관리자 암호로 설치",
                                  action: .installEngine, actionLabel: engineOutdated ? "갱신" : "설치"))
        }
        guard let s = status else { return out }
        if s.ageSeconds > STALE_AFTER {
            out.append(AppWarning(id: "stale", level: .error, title: "엔진 멈춤",
                                  detail: "\(s.ageSeconds)초째 응답 없음", action: .installEngine, actionLabel: "다시 설치"))
        }
        let leaks = s.rules.filter { s.state(of: $0) == .leak }
        if !leaks.isEmpty {
            out.append(AppWarning(id: "leak", level: .error, title: "차단 빠짐 \(leaks.count)",
                                  detail: leaks.map(\.title).joined(separator: ", "), action: .apply, actionLabel: "다시 적용"))
        }
        if s.paused {
            out.append(AppWarning(id: "paused", level: .warn, title: "일시정지 중",
                                  detail: "모두 평소 경로로", action: .resume, actionLabel: "재개"))
        }
        // 규칙이 쓰려는 출구가 응답 없음
        let down = s.exits.filter { $0.up && $0.healthy == false }
        for e in down {
            let users = s.rules.filter { r in r.enabled && r.exits.contains { matchingExits($0, in: [e]).isEmpty == false } }
            guard !users.isEmpty else { continue }
            out.append(AppWarning(id: "down:\(e.iface)", level: .warn, title: "\(e.label) 응답 없음",
                                  detail: "규칙 \(users.count)개 → 다음 출구"))
        }
        for (i, e) in s.errors.enumerated() {
            out.append(AppWarning(id: "err\(i)", level: .warn, title: "규칙 확인", detail: e, action: .openRules, actionLabel: "열기"))
        }
        return out
    }

    /// 맨 위 상태 기호의 단계
    var statusLevel: StatusBadge.Level {
        if let s = status, s.paused, warnings.count == 1 { return .off }
        if warnings.contains(where: { $0.level == .error }) { return .error }
        if !warnings.isEmpty { return .warn }
        return .ok
    }

    /// 규칙이 앞 규칙에 가려졌으면 그 앞 규칙 이름
    func shadowedBy(_ r: Rule) -> String? {
        guard let rules = config?.rules, let i = rules.firstIndex(where: { $0.id == r.id }) else { return nil }
        let ws = shadowWarnings(rules, index: i, addresses: resolvedIPs)
        guard !ws.isEmpty else { return nil }
        // 경고 글에서 앞 규칙 이름을 찾는다
        for j in 0..<i where ws.contains(where: { $0.contains(rules[j].title) }) { return rules[j].title }
        return "앞 규칙"
    }
}
