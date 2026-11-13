#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc -target arm64-apple-macosx15.2 -swift-version 5 -parse-as-library shared.swift conditions.swift app_policy.swift app_identity.swift apprules/Proxy/Relays.swift tests/SplitTests.swift -o build/split-tests
test_app="${SPLIT_TEST_APP:-$PWD/build/Wi-Fi Exit.app}"
if [[ -d "$test_app" ]]; then build/split-tests "$test_app"; else build/split-tests; fi
swiftc -target arm64-apple-macosx15.2 -swift-version 5 -parse-as-library -typecheck apprules/Proxy/AppRuleProvider.swift apprules/Proxy/Relays.swift shared.swift conditions.swift app_policy.swift app_identity.swift

swiftc -target arm64-apple-macosx15.2 -swift-version 5 -parse-as-library -typecheck tests/NetworkProbe.swift
