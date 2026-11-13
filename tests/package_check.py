#!/usr/bin/env python3
"""Check the signed, exported package before activation or release."""
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
proxy = app / 'Contents/Library/SystemExtensions/com.miel.WifiExit.AppRules.proxy.systemextension'
def plist(path):
    return plistlib.loads(path.read_bytes())
def entitlements(path):
    return plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(path)], stderr=subprocess.DEVNULL))
main_info = plist(app / 'Contents/Info.plist')
proxy_info = plist(proxy / 'Contents/Info.plist')
main_entitlements, proxy_entitlements = entitlements(app), entitlements(proxy)
service = proxy_info['NetworkExtension']['NEMachServiceName']
groups = set(proxy_entitlements['com.apple.security.application-groups'])
assert any(service.startswith(group + '.') for group in groups), 'NEMachServiceName must be inside an entitled app group'
assert groups.intersection(main_entitlements['com.apple.security.application-groups']), 'host and provider must share their app group'
assert main_info['CFBundleIdentifier'] == 'com.miel.WifiExit'
assert main_info['NSSystemExtensionUsageDescription']
assert proxy_info['CFBundleIdentifier'] == 'com.miel.WifiExit.AppRules.proxy'
for bundle in [app, proxy]:
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
for executable in [app/'Contents/MacOS/WifiExit', app/'Contents/Helpers/wifi-exitd', proxy/'Contents/MacOS/com.miel.WifiExit.AppRules.proxy']:
    output = subprocess.check_output(['otool', '-l', str(executable)], text=True)
    assert 'minos 15.2' in output, str(executable)
print('PASS: exported host/provider identities, app-group Mach service, signatures and macOS 15.2 binaries')
