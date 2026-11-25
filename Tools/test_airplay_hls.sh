#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/carwithin-hls.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  "$project_root"/Sources/TDSCarKitCore/{Binary,VideoCodec,AnnexB,Localization}.swift \
  "$project_root/App/FragmentedMP4.swift" "$project_root/Tools/AirPlayHLSSmoke.swift" -o "$work_dir/hls-test"
"$work_dir/hls-test"
