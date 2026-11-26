#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/carwithin-tailing.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
swiftc -swift-version 5 -D TAILING_MEDIA_SMOKE \
  "$project_root"/Sources/TDSCarKitCore/{Binary,VideoCodec,AnnexB,Localization}.swift \
  "$project_root"/App/Tailing*.swift "$project_root/App/PxcConnection.swift" "$project_root/Tools/CfmotoNegotiationSmoke.swift" \
  "$project_root/App/CarbitConnectionCode.swift" "$project_root/App/PXCH264Output.swift" \
  "$project_root"/App/Ninebot{Protocol,H264Encoder}.swift \
  "$project_root/Tools/TailingProtocolSmoke.swift" "$project_root/Tools/TailingMediaSmoke.swift" \
  -o "$work_dir/tailing-test"
"$work_dir/tailing-test"
