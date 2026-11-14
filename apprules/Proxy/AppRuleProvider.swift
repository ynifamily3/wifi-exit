import Foundation
import Network
import NetworkExtension
import Security
import SystemConfiguration
import Darwin
import os

private let proxyLog = Logger(subsystem: "com.miel.WifiExit.AppRules", category: "proxy")

final class ProxyTCPChannel: TCPChannel {
    let flow: NEAppProxyTCPFlow
    init(_ flow: NEAppProxyTCPFlow) { self.flow = flow }
    func open(_ completion: @escaping (Error?) -> Void) { flow.open(withLocalFlowEndpoint: nil, completionHandler: completion) }
    func read(_ completion: @escaping (Data?, Error?) -> Void) { flow.readData(completionHandler: completion) }
    func write(_ data: Data, completion: @escaping (Error?) -> Void) { flow.write(data, withCompletionHandler: completion) }
    func closeRead(_ error: Error?) { flow.closeReadWithError(error) }
    func closeWrite(_ error: Error?) { flow.closeWriteWithError(error) }
}
final class ProxyUDPChannel: UDPChannel {
    let flow: NEAppProxyUDPFlow
    init(_ flow: NEAppProxyUDPFlow) { self.flow = flow }
    func open(_ completion: @escaping (Error?) -> Void) { flow.open(withLocalFlowEndpoint: nil, completionHandler: completion) }
    func read(_ completion: @escaping ([(Data, Network.NWEndpoint)]?, Error?) -> Void) { flow.readDatagrams(completionHandler: completion) }
    func write(_ datagrams: [(Data, Network.NWEndpoint)], completion: @escaping (Error?) -> Void) { flow.writeDatagrams(datagrams, completionHandler: completion) }
    func close(_ error: Error?) { flow.closeReadWithError(error); flow.closeWriteWithError(error) }
}

final class AppRuleProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let queue = DispatchQueue(label: "wifi-exit.app-proxy")
    private var config = SplitConfig()
    private var monitors: [NWPathMonitor] = []
    private var paths: [Int: [NWInterface]] = [:]
    private var interfaces: [String: NWInterface] = [:]
    private var sessions: [UUID: SplitSession] = [:]
    private var timer: DispatchSourceTimer?
    private var engine: EngineStatus?
    private var engineSignature = Data()
    private var report = SplitReport()
    private var stopping = false
    private var teamCache: [Data: String] = [:]

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let data = protocolConfig.providerConfiguration?["config"] as? Data,
              let decoded = try? JSONDecoder().decode(SplitConfig.self, from: data), decoded.problem == nil else {
            completionHandler(relayError("앱 규칙 설정을 읽지 못했어요")); return
        }
        queue.sync {
            config = decoded
            if let id = decoded.configurationID,
               let cached = UserDefaults.standard.data(forKey: "config." + id),
               let newer = try? JSONDecoder().decode(SplitConfig.self, from: cached) { config = decoded.restoring(newer) }
            stopping = false
        }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
            localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound)]
        setTunnelNetworkSettings(settings) { error in
            if error == nil { self.queue.async { self.startMonitoring() } }
            completionHandler(error)
        }
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.stopping = true; self.cancelSessions()
            self.monitors.forEach { $0.cancel() }; self.monitors.removeAll(); self.paths.removeAll()
            self.timer?.cancel(); self.timer = nil; completionHandler()
        }
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        queue.async {
            if String(data: messageData, encoding: .utf8) == "status" {
                self.report.active = self.sessions.count
                self.report.configuration = self.config
                completionHandler?(try? JSONEncoder().encode(self.report)); return
            }
            if String(data: messageData, encoding: .utf8) == "clear" {
                if let id = self.config.configurationID { UserDefaults.standard.removeObject(forKey: "config." + id); UserDefaults.standard.synchronize() }
                completionHandler?(Data("ok".utf8)); return
            }
            guard let new = try? JSONDecoder().decode(SplitConfig.self, from: messageData), new.problem == nil, new.configurationID == self.config.configurationID,
                  (new.revision ?? 0) > (self.config.revision ?? 0) else {
                completionHandler?(Data("invalid".utf8)); return
            }
            if let id = new.configurationID {
                UserDefaults.standard.set(messageData, forKey: "config." + id)
                guard UserDefaults.standard.synchronize() else { completionHandler?(Data("persist-failed".utf8)); return }
            }
            self.config = new; self.cancelSessions(); completionHandler?(Data("ok".utf8))
        }
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow { return handle(flow, endpoint: tcp.remoteFlowEndpoint) }
        // UDP is delivered via NEAppProxyUDPFlowHandling on macOS 15+.
        return false
    }
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint endpoint: Network.NWEndpoint) -> Bool {
        handle(flow, endpoint: endpoint)
    }
    private func handle(_ flow: NEAppProxyFlow, endpoint: Network.NWEndpoint) -> Bool {
        return queue.sync { () -> Bool in
            guard !stopping else { reject(flow, error: relayError("프록시 종료 중")); return true }
            let signingID = flow.metaData.sourceAppSigningIdentifier
            if signingID == "com.miel.WifiExit.AppRules.proxy" { return false }
            let host: String
            if case .hostPort(let value, _) = endpoint { host = "\(value)" } else { host = "" }
            if SplitPolicy.ownedByHost(host, status: engine) { report.system += 1; return false }
            var decision = SplitDecision.system
            var ruleMatched = false
            if config.rules.contains(where: { $0.candidate(signingID: signingID) }) {
                let team = sourceTeam(flow.metaData.sourceAppAuditToken)
                decision = SplitPolicy.decide(config, signingID: signingID, teamID: team, exits: report.exits)
                ruleMatched = team.map { t in config.rules.contains { $0.matches(signingID: signingID, teamID: t) } } ?? false
            }
            // An app's own rule (including its "system" fallback) wins; only apps without one follow the others policy.
            if decision == .system, !ruleMatched {
                decision = SplitPolicy.decideOthers(config, signingID: signingID, flowInterface: interfaceName(flow),
                                                    defaultIf: engine?.defaultIf, exits: report.exits)
            }
            switch decision {
            case .system: report.system += 1; return false
            case .block(let rule):
                report.blocked += 1; report.note = "\(ruleName(rule)): 출구 없음 또는 앱 서명 확인 실패 → 차단" + (SplitIdentity.lastLookupError.isEmpty ? "" : " (\(SplitIdentity.lastLookupError))")
                reject(flow, error: relayError(report.note)); return true
            case .route(let rule, let iface):
                // Moving other apps off the VPN is best effort: past the relay limit they keep the system path.
                if rule == SplitPolicy.othersRule, sessions.count >= 4096 || interfaces[iface] == nil { report.system += 1; return false }
                guard sessions.count < 8192, let networkInterface = interfaces[iface] else {
                    report.blocked += 1
                    reject(flow, error: relayError("출구 없음 또는 연결 한도 초과")); return true
                }
                let id = UUID()
                let finished: () -> Void = { [weak self] in self?.sessions[id] = nil }
                if let tcp = flow as? NEAppProxyTCPFlow {
                    let relay = TCPRelay(channel: ProxyTCPChannel(tcp), endpoint: endpoint, interface: networkInterface, queue: queue, done: finished)
                    sessions[id] = relay; relay.start()
                } else if let udp = flow as? NEAppProxyUDPFlow {
                    let relay = UDPRelay(channel: ProxyUDPChannel(udp), interface: networkInterface, queue: queue, done: finished)
                    sessions[id] = relay; relay.start()
                } else { return false }
                report.accepted += 1; report.note = "\(ruleName(rule)) → \(iface)"; return true
            }
        }
    }
    private func reject(_ flow: NEAppProxyFlow, error: Error) {
        // Claim and open the local side before rejecting it, so the app receives a
        // socket error promptly instead of waiting for its connection timeout.
        flow.open(withLocalFlowEndpoint: nil) { _ in
            flow.closeReadWithError(error); flow.closeWriteWithError(error)
        }
    }
    /// Verified team per process. The audit token carries pid + pidversion, so a key
    /// never outlives the process it describes; only successful lookups are cached.
    private func sourceTeam(_ token: Data?) -> String? {
        if let token, let cached = teamCache[token] { return cached }
        let team = SplitIdentity.sourceTeam(token)
        if let token, let team {
            if teamCache.count >= 512 { teamCache.removeAll() }
            teamCache[token] = team
        }
        return team
    }
    private func ruleName(_ id: String) -> String {
        if id == SplitPolicy.othersRule { return "나머지 앱" }
        return config.rules.first { $0.id == id }?.name ?? "앱"
    }
    /// The interface the system would send this flow out of (before we take it).
    private func interfaceName(_ flow: NEAppProxyFlow) -> String? {
        guard let interface = flow.networkInterface else { return nil }
        return String(cString: nw_interface_get_name(interface))
    }
    private func cancelSessions() {
        let existing = Array(sessions.values); sessions.removeAll()
        for session in existing { session.cancel() }
    }
    private func startMonitoring() {
        // Type-specific monitors expose secondary physical links and VPN interfaces as well.
        for (index, type) in [NWInterface.InterfaceType.wifi, .wiredEthernet, .other, .cellular].enumerated() {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }; self.paths[index] = path.availableInterfaces; self.refreshNetwork()
            }
            monitor.start(queue: queue); monitors.append(monitor)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshNetwork() }; timer.resume(); self.timer = timer
    }
    private func refreshNetwork() {
        let oldExits = report.exits
        interfaces = [:]
        for value in paths.values.flatMap({ $0 }) { interfaces[value.name] = value }
        let status = readStatus()
        engine = status.flatMap { Date().timeIntervalSince1970 - Double($0.generatedAt) < 120 ? $0 : nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let newEngineSignature = (try? encoder.encode(engine?.rules)) ?? Data()
        let addresses = interfaceAddresses()
        let kinds = physicalKinds()
        report.exits = interfaces.values.sorted { $0.name < $1.name }.compactMap { interface in
            guard let address = addresses[interface.name], interface.type != .loopback else { return nil }
            let known = engine?.exits.first { $0.iface == interface.name }
            let selector: String
            if interface.name.hasPrefix("utun") || interface.name.hasPrefix("ipsec") || interface.name.hasPrefix("ppp") {
                selector = known?.portal.isEmpty == false ? "vpn:" + known!.portal : "vpn:any"
            } else if interface.type == .wifi { selector = "wifi" }
            else if interface.type == .cellular { selector = "tether" }
            else if interface.type == .wiredEthernet { selector = kinds[interface.name] == "tether" ? "tether" : "wired" }
            else { return nil }
            return SplitExit(selector: selector, iface: interface.name, ip: address, healthy: known?.healthy != false)
        }
        if oldExits != report.exits || newEngineSignature != engineSignature {
            engineSignature = newEngineSignature; cancelSessions()
        }
    }
}

private func physicalKinds() -> [String: String] {
    var result: [String: String] = [:]
    for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []) {
        guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
        let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""
        result[name] = display.localizedCaseInsensitiveContains("iPhone") ? "tether" : "wired"
    }
    return result
}
private func interfaceAddresses() -> [String: String] {
    var result: [String: String] = [:]
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return result }; defer { freeifaddrs(first) }
    var current = first
    while let entry = current {
        defer { current = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr,
              entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
        let name = String(cString: entry.pointee.ifa_name)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: buffer)
            if result[name] == nil || address.pointee.sa_family == UInt8(AF_INET) { result[name] = value }
        }
    }
    return result
}
