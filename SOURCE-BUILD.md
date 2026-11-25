# 源码构建说明 / Build from source

本候选对应 CarWithin **1.0.5（17）**。应用版本与构建号仅来自 `App/Info.plist`。

需要 Xcode，最低部署目标为 iOS/iPadOS 16.0。项目包含中英文界面资源、浏览器接收页、支持名单资源及完整第三方许可。请从同一版本的标签或源码附件构建，不混用其他版本的 Swift 文件和资源。

推送到 `main` 会触发 GitHub Actions 的「Build iOS IPA」，也可以在 Actions 页面手动运行。构建和投屏协议测试通过后，可在该次运行的 Artifacts 中下载 `CarWithin-iOS-unsigned`，解压后用自己的签名安装 IPA。

```sh
python3 Tools/generate_project.py
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/source
```

用于自己的设备时，在 Xcode 设置自己的开发团队与 Bundle ID 并签名。生成脚本保留本地选择，也可用 `TDS_DEVELOPMENT_TEAM` 与 `TDS_BUNDLE_IDENTIFIER` 配置。源码的开发团队为空，不包含 Apple 签名材料。

源码不包含配件认证身份、私钥或证书。没有身份仍可编译，但实际本机 CarPlay 连接需要有效身份。可把自己的 `certificate.p7b`、`leaf.cer`、`private.x963` 放到 `App/BundledIdentity/` 后重新生成工程，或通过 `Documents/IdentityImport` 导入 Keychain。本分支的 GitHub Actions 使用仓库源码构建未签名 IPA。个人使用的身份文件由持有人在本机打包。

English: use the same source revision and bundled resources. Run the commands above for an unsigned arm64 Release build, or configure your own team and bundle identifier for device signing. Accessory credentials and Apple signing material are excluded. The project can compile without credentials, but a working CarPlay session requires a valid accessory identity. Local identity resources can be staged before running the generator; they must not be committed to a public repository.

The combined distribution is AGPL-3.0-only. See `LICENSE`, `THIRD_PARTY_NOTICES.txt`, `LICENSES`, `ThirdParty`, `App/KCP-LICENSE.txt` and `App/ANTBMS-LICENSE.txt`.
