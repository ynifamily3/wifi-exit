import Foundation
import Security

enum SplitIdentity {
    static func selectedApp(_ url: URL) throws -> SplitRule {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier != nil else { throw error("앱 번들을 선택해 주세요") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw error("앱의 코드 서명을 확인하지 못했어요") }
        guard let values = signingInformation(code), let signingID = values[kSecCodeInfoIdentifier as String] as? String else {
            throw error("앱의 서명 식별자를 읽지 못했어요")
        }
        return SplitRule(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent,
            signingID: signingID, teamID: values[kSecCodeInfoTeamIdentifier as String] as? String ?? "")
    }
    static var lastLookupError = ""
    static func sourceTeam(_ token: Data?) -> String? {
        lastLookupError = ""
        guard let token else { lastLookupError = "audit token 없음"; return nil }
        // Prefer the ordinary guest, then use the public dynamic-code lookup when the
        // provider sandbox cannot read another app's on-disk signature/resources.
        for dynamic in [false, true] {
            var attributes: [CFString: Any] = [kSecGuestAttributeAudit: token]
            if dynamic {
                attributes[kSecGuestAttributeDynamicCode] = true
            }
            var code: SecCode?
            let guest = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
            guard guest == errSecSuccess, let code else { lastLookupError = "guest \(guest)"; continue }
            let valid = SecCodeCheckValidity(code, [], nil)
            guard valid == errSecSuccess else { lastLookupError = "validity \(valid)"; continue }
            var staticCode: SecStaticCode?
            let copied = SecCodeCopyStaticCode(code, [], &staticCode)
            guard copied == errSecSuccess, let staticCode else { lastLookupError = "static \(copied)"; continue }
            var information: CFDictionary?
            let copiedInfo = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            guard copiedInfo == errSecSuccess, let values = information as? [String: Any] else { lastLookupError = "signing info \(copiedInfo)"; continue }
            lastLookupError = ""
            return values[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        }
        return nil
    }
    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        // TeamIdentifier is only returned when signing information is explicitly requested.
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
    private static func error(_ text: String) -> NSError {
        NSError(domain: "WiFiExit.AppIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
