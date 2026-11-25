#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
compiler="${SWIFTC:-swiftc}"
"$compiler" -swift-version 5 "$root/App/TailingDisplayProfile.swift" \
    "$root/Sources/TDSCarKitCore/Localization.swift" "$root/App/TailingProtocol.swift" "$root/Tools/ZeehoSEPlusSizeSmoke.swift" -o "$stage/test-seplus"
"$stage/test-seplus"
