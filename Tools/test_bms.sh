#!/bin/bash
# Run the pure Swift ANT decoder tests without UIKit, CoreBluetooth or CryptoKit.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v swift >/dev/null 2>&1; then
    echo 'Swift 5.9+ is required to run the ANT BMS protocol tests.' >&2
    exit 127
fi
bms_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-bms-tests.XXXXXX")"
trap 'rm -rf "$bms_test_dir"' EXIT
mkdir -p "$bms_test_dir/Sources/TDSCarKitCore" "$bms_test_dir/Tests/TDSCarKitCoreTests"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSProtocol.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Sources/TDSCarKitCore/ANTBMSCardConfiguration.swift" "$bms_test_dir/Sources/TDSCarKitCore/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSProtocolTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cp "$project_root/Tests/TDSCarKitCoreTests/ANTBMSCardConfigurationTests.swift" "$bms_test_dir/Tests/TDSCarKitCoreTests/"
cat > "$bms_test_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ANTBMSProtocolValidation", targets: [
    .target(name: "TDSCarKitCore"),
    .testTarget(name: "TDSCarKitCoreTests", dependencies: ["TDSCarKitCore"])
])
PACKAGE
swift test --disable-sandbox --package-path "$bms_test_dir"
