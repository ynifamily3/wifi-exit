// 라우팅 보기에서 바로 규칙 만들기: 규칙 밖 목적지 줄이나 앱 칸을 누르면 뜨는 팝오버, 그리고 목적지 옆 나라 표시.

import AppKit
import SwiftUI

// MARK: - 팝오버 상태

/// 흐름도에서 연 팝오버 하나. anchor 는 흐름도 좌표 (줄이기 전)
struct QuickPop: Identifiable {
    let id = UUID()
    var kind: Kind
    var anchor: CGRect
    var edge: Edge
    enum Kind {
        case rule(QuickRuleSeed)      // 목적지로 규칙 만들기
        case app(String)              // 앱이 간 곳 고르기
    }
}

/// 규칙 대상 후보 하나 (IPv4)
struct QuickItem: Identifiable, Equatable {
    let id: String                    // IP
    var sub = ""                      // 이름 (역방향 조회) 또는 어느 목적지였는지
    var cc: String?                   // 나라
    var ruled: String?                // 이미 맡은 규칙 이름이 있으면 고를 수 없다
}

struct QuickRuleSeed: Equatable {
    var title: String                 // "amazonaws.com"
    var context: String               // "지금 유선으로 나가요 · claude 연결 2개"
    var items: [QuickItem]
    var name: String                  // 규칙 이름 (메모) 기본값
    var reverseNamed = false          // 이름이 역방향 조회에서 왔으면 도메인 대신 IP 로 넣는다고 알린다
}

/// 앱이 간 곳 하나
struct QuickAppRow: Identifiable {
    let id: String                    // 목적지 줄 열쇠 또는 IP
    let title: String
    let sub: String
    let cc: String?
    let ips: [String]
    let ruled: String?                // 이미 규칙이 맡은 곳: 그 규칙 이름
}

// MARK: - 목적지로 규칙 만들기

struct QuickRuleForm: View {
    let seed: QuickRuleSeed
    let candidates: [String]          // 출구 이름 (wifi, wired, vpn:pass …)
    let save: (Rule) async -> String? // 실패하면 까닭
    let more: (RuleDraft) -> Void     // 규칙 창에서 마저 고치기
    let cancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var picked: Set<String>
    @State private var widen = false
    @State private var order: [String] = ["wifi"]   // 누른 순서가 순위
    @State private var block = false
    @State private var elseAction = "block"
    @State private var name: String
    @State private var error: String?
    @State private var busy = false

    init(seed: QuickRuleSeed, candidates: [String], save: @escaping (Rule) async -> String?, more: @escaping (RuleDraft) -> Void,
         cancel: @escaping () -> Void) {
        self.seed = seed; self.candidates = candidates; self.save = save; self.more = more; self.cancel = cancel
        _picked = State(initialValue: Set(seed.items.filter { $0.ruled == nil }.map(\.id)))
        _name = State(initialValue: seed.name)
    }

    /// 고른 IP. 넓히면 /24 대역으로 (겹치면 하나로)
    private var targets: [String] {
        let ips = seed.items.map(\.id).filter { picked.contains($0) }
        guard widen else { return ips }
        var out: [String] = []
        for ip in ips {
            guard let n = Target.ipv4Number(ip) else { continue }
            let c = Target.ipv4String(n & 0xFFFF_FF00) + "/24"
            if !out.contains(c) { out.append(c) }
        }
        return out
    }
    private var rule: Rule {
        Rule(id: "", name: cleanNote(name), enabled: true, targets: targets, when: .always,
             exits: block ? [] : order, elseAction: block ? "block" : elseAction)
    }
    private var draft: RuleDraft {
        var d = RuleDraft(nil)
        d.targets = targets; d.name = name; d.exits = block ? [] : order; d.elseAction = block ? "block" : elseAction
        return d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(seed.title) 규칙 만들기").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(seed.context).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            section("대상") {
                ForEach(seed.items.prefix(8)) { it in
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(get: { picked.contains(it.id) }, set: { on in if on { picked.insert(it.id) } else { picked.remove(it.id) } })) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(it.id).font(.system(size: 12, weight: .medium).monospacedDigit())
                                if !it.sub.isEmpty { Text(it.sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(it.ruled != nil)
                        Spacer(minLength: 4)
                        if let r = it.ruled { QuickTag(text: r) }
                        if let cc = it.cc { CountryTag(cc: cc) }
                    }
                }
                if seed.items.count > 8 { Text("그 밖에 \(seed.items.count - 8)개는 자세히…에서").font(.system(size: 10)).foregroundStyle(.secondary) }
                Toggle(isOn: $widen) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("/24 대역으로 넓히기").font(.system(size: 12, weight: .medium))
                        Text("같은 대역의 다른 서버도").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                if seed.reverseNamed {
                    Text("역방향 조회 이름이라 도메인 대신 IP로 넣어요").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            section("출구 · 누른 순서가 순위") {
                let all = candidates + ["block"]
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(stride(from: 0, to: all.count, by: 3)), id: \.self) { i in
                        HStack(spacing: 6) {
                            ForEach(all[i ..< min(i + 3, all.count)], id: \.self) { e in chip(e) }
                        }
                    }
                }
            }
            section("출구가 없으면") {
                Picker("출구가 없으면", selection: $elseAction) {
                    Text("차단").tag("block")
                    Text("평소 경로").tag("system")
                    Text("다음 규칙").tag("next")
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(block)
            }
            section("이름") {
                TextField("이름", text: $name).textFieldStyle(.roundedBorder)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.statusError).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("자세히…") { more(draft) }
                Spacer()
                Button("취소") { cancel() }.keyboardShortcut(.cancelAction)
                Button("추가") {
                    busy = true
                    Task { error = await save(rule); busy = false }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty || (!block && order.isEmpty) || busy)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// 출구 칩: 누르면 순위 끝에 붙고, 다시 누르면 빠진다. "막기"는 출구 없이 막는다
    private func chip(_ e: String) -> some View {
        let dark = scheme == .dark
        let isBlock = e == "block"
        let rank = isBlock ? (block ? 0 : nil) : order.firstIndex(of: e).map { $0 + 1 }
        let on = isBlock ? block : rank != nil && !block
        let col = Color.exit(isBlock ? "block" : e, dark: dark)
        return Button {
            if isBlock { block.toggle() }
            else { block = false; if let i = order.firstIndex(of: e) { order.remove(at: i) } else { order.append(e) } }
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    if on {
                        Circle().fill(col)
                        if isBlock { Image(systemName: "nosign").font(.system(size: 8, weight: .bold)).foregroundStyle(dark ? .black : .white) }
                        else if let rank { Text("\(rank)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(dark ? .black : .white) }
                    } else {
                        Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    }
                }
                .frame(width: 14, height: 14)
                Text(isBlock ? "막기" : Exits.label(e)).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? col.opacity(dark ? 0.18 : 0.11) : .clear))
            .overlay(Capsule().strokeBorder(on ? col.opacity(0.6) : Color.secondary.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 앱이 간 곳

struct QuickAppMenu: View {
    let app: String
    let icon: NSImage?
    let context: String               // "연결 3개 · 유선"
    let rows: [QuickAppRow]
    let canSplit: Bool
    let makeRule: ([QuickAppRow]) -> Void
    let split: () -> Void
    let zoom: () -> Void
    @State private var picked: Set<String>

    init(app: String, icon: NSImage?, context: String, rows: [QuickAppRow], canSplit: Bool,
         makeRule: @escaping ([QuickAppRow]) -> Void, split: @escaping () -> Void, zoom: @escaping () -> Void) {
        self.app = app; self.icon = icon; self.context = context; self.rows = rows; self.canSplit = canSplit
        self.makeRule = makeRule; self.split = split; self.zoom = zoom
        _picked = State(initialValue: Set(rows.filter { $0.ruled == nil }.prefix(8).map(\.id)))
    }

    var body: some View {
        let chosen = rows.filter { picked.contains($0.id) && $0.ruled == nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                else { Image(systemName: "app.dashed").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24, height: 24) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app).font(.system(size: 13, weight: .semibold))
                    Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text("최근 10분에 간 곳이 없어요").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("간 곳 · 고른 곳으로 규칙 만들기").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(rows.prefix(8)) { r in
                        HStack(spacing: 6) {
                            Toggle(isOn: Binding(get: { picked.contains(r.id) }, set: { on in if on { picked.insert(r.id) } else { picked.remove(r.id) } })) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(r.sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(r.ruled != nil)
                            Spacer(minLength: 4)
                            if let ruled = r.ruled { QuickTag(text: ruled) }
                            if let cc = r.cc { CountryTag(cc: cc) }
                        }
                    }
                    if rows.count > 8 { Text("그 밖에 \(rows.count - 8)곳").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if rows.contains(where: { $0.ruled != nil }) {
                        Text("이미 규칙이 있는 곳은 그 규칙을 따라요").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("\(chosen.count)곳으로 규칙 만들기…") { makeRule(chosen) }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("앱 통째로").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Button(action: split) {
                    menuRow("square.stack.3d.down.right", "앱별 스플리팅에 추가…",
                            canSplit ? "이 앱의 모든 연결을 고른 출구로" : "앱 묶음(.app)이 아니라 넣을 수 없어요")
                }
                .buttonStyle(.plain).disabled(!canSplit)
                Button(action: zoom) { menuRow("scope", "이 앱만 보기", "") }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func menuRow(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .medium))
                if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// 작은 회색 꼬리표 (이미 맡은 규칙 이름)
struct QuickTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

/// 나라 두 글자 (KR, US …): 네모 테두리만, 국기는 쓰지 않는다
struct CountryTag: View {
    let cc: String
    var body: some View {
        Text(cc).font(.system(size: 9, weight: .semibold).monospaced()).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.8))
            .help(Locale(identifier: "ko").localizedString(forRegionCode: cc) ?? cc)
    }
}

// MARK: - 나라

/// IP → 나라 두 글자. DB-IP 의 "IP to Country Lite" (CC BY 4.0, https://db-ip.com) 를 geo/make_geo.sh 가
/// 바꿔 둔 ipv4-country.bin 을 앱 묶음에서 읽는다 (오프라인, 처음 쓸 때 한 번). 사설·예약 주소는 nil.
final class GeoIP {
    static let shared = GeoIP()
    private var starts: [UInt32] = []
    private var codes: [UInt16] = []

    private init() {
        guard let url = Bundle.main.url(forResource: "ipv4-country", withExtension: "bin"),
              let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 8, d.prefix(4) == Data("WXG1".utf8) else { return }
        d.withUnsafeBytes { raw in
            let n = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard raw.count >= 8 + n * 6 else { return }
            starts = (0..<n).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8 + $0 * 4, as: UInt32.self)) }
            let base = 8 + n * 4
            codes = (0..<n).map { UInt16(raw[base + $0 * 2]) << 8 | UInt16(raw[base + $0 * 2 + 1]) }
        }
    }

    func country(_ ip: String) -> String? {
        guard let first = starts.first, let v = Target.ipv4Number(ip), v >= first else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= v { lo = mid } else { hi = mid - 1 }
        }
        let c = codes[lo]
        let s = String(decoding: [UInt8(c >> 8), UInt8(c & 0xff)], as: UTF8.self)
        return s == "ZZ" ? nil : s
    }
}
