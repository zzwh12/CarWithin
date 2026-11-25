#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
"${SWIFTC:-swiftc}" -swift-version 5 "$root/Sources/TDSCarKitCore/Localization.swift" "$root/App/TailingSocket.swift" "$root/App/TailingDisplayProfile.swift" "$root/App/TailingProtocol.swift" "$root/App/TailingDiscovery.swift" \
    "$root/Tools/TailingDiscoverySmoke.swift" -o "$stage/discovery-test"
"$stage/discovery-test"
