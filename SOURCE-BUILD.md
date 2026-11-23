# 源码构建说明

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

推送到 `main` 会触发 GitHub Actions 的「Build iOS IPA」，也可以在 Actions 页面手动运行。构建和投屏协议测试通过后，可在该次运行的 Artifacts 中下载 `CarWithin-iOS-unsigned`，解压后用自己的签名安装 IPA。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。
