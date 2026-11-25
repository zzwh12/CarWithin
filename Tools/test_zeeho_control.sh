#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
"${SWIFTC:-swiftc}" -swift-version 5 "$root/App/TailingDisplayProfile.swift" \
    "$root/Sources/TDSCarKitCore/Localization.swift" "$root/App/TailingProtocol.swift" "$root/Tools/ZeehoControlSmoke.swift" -o "$stage/control-test"
"$stage/control-test"
