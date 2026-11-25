#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/carwithin-wifi-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  "$project_root/Sources/TDSCarKitCore/Localization.swift" \
  "$project_root/App/AirPlayCredentials.swift" \
  "$project_root/Tools/WiFiCredentialsSmoke.swift" -o "$work_dir/wifi-test"
"$work_dir/wifi-test"
