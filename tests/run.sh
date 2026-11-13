#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc -swift-version 5 -D WIFI_EXIT_TESTING -parse-as-library engine.swift events.swift shared.swift conditions.swift remaining.swift tests/PolicyTests.swift -o build/policy-tests
build/policy-tests
/sbin/pfctl -nf /tmp/wifi-exit-policy-test.pf > build/pf-parse.log 2>&1 || { cat build/pf-parse.log; exit 1; }
/sbin/pfctl -nf /tmp/wifi-exit-policy-test-logging.pf >> build/pf-parse.log 2>&1 || { cat build/pf-parse.log; exit 1; }
echo "PASS: macOS pf syntax (logging on/off)"
