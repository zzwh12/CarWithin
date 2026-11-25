#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/carwithin-carlife.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  "$project_root"/Sources/TDSCarKitCore/{Binary,VideoCodec,AnnexB,Localization}.swift \
  "$project_root/App/CarPlayControls.swift" "$project_root/App/CarLifeOutput.swift" \
  "$project_root/Tools/CarLifeDiscoverySmoke.swift" -o "$work_dir/discovery-test"
"$work_dir/discovery-test" "$@"
