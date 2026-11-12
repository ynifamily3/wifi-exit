// Wi-Fi Exit 앱 규칙 확장 (A1: 뼈대).
// 지금은 모든 연결을 시스템에 그대로 돌려준다(return false). 앱 규칙을 읽어 중계·차단하는 일은 A3 에서 넣는다.
// 켜졌을 때 엔진 상태 파일을 읽을 수 있는지만 기록한다.

import Foundation
import NetworkExtension
import os

let log = Logger(subsystem: "com.miel.WifiExit.AppRules", category: "proxy")

final class AppRuleProvider: NETransparentProxyProvider {
    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let path = "/Library/Application Support/WifiExit/state/status.json"
        if let d = FileManager.default.contents(atPath: path) {
            log.notice("시작: 엔진 상태 파일 \(d.count) bytes 읽음")
        } else {
            log.error("시작: 엔진 상태 파일을 못 읽음 (\(path, privacy: .public))")
        }
        let s = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        s.includedNetworkRules = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        setTunnelNetworkSettings(s) { err in
            if let err { log.error("설정 실패: \(String(describing: err), privacy: .public)") }
            completionHandler(err)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.notice("멈춤: 이유 \(reason.rawValue)")
        completionHandler()
    }

    /// A1: 어떤 연결도 받지 않는다.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool { false }
}
