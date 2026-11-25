# CarWithin iOS 更新协议

本协议于开发版 1.0.1（12）接入，已随正式版 1.0.1（13）发布，并提供配套 ios-update.json。日常开发保持应用版本号和构建号不变。准备正式发布时，未指定版本则末位版本号与构建号各加 1；用户指定版本号时按要求设置，构建号仍保持全局递增。先更新本地 `App/Info.plist`，再从同一份源码打包并生成清单。同一轮发布重打包或重试上传不重复递增；已公开的版本不覆盖、不回退。详细规则见 [AGENTS.md](AGENTS.md)。

## 发现与比较

读取 `https://api.github.com/repos/xmz28/CarWithin/releases/latest`，再下载该正式发布中的 `ios-update.json`。每次实际检查都会读取 JSON，即使本机已是最新版。自动检查沿用前台空闲、成功后间隔 24 小时、失败 15 分钟后再试的策略。

只比较 JSON 的整数 `build` 与本机 `CFBundleVersion`；远端更大才自动提示。`version` 用于展示，并须与 Release 的数字标签一致。忽略按构建号记录。所有公开构建号必须全局递增，不重复、不归零；旧分支补发也必须由发布者确认不会把用户引向更旧的产品版本。

不以运行时 Bundle ID 作为更新身份，避免合法自签改 Bundle ID 后无法检查。产品固定为 `CarWithin`，平台固定为 `ios`。

## JSON 与文件校验

附件名称为 `ios-update.json`，UTF-8，最大 128 KiB。字段：`schemaVersion`（1）、`product`、`platform`、`version`、`build`、`minimumOSVersion`、`releaseTag`、`ipaName`、`size`、`sha256`、`notes`。

`notes` 保存简短更新说明。App 默认显示该说明，完整 Release 正文通过展开入口查看。JSON 中的标签、IPA 文件名、大小、SHA-256 与 Release 附件必须一致。下载包沿用文件格式、大小和 SHA-256 校验；最低系统不满足时显示要求并禁用该版本下载入口。

最新版本缺少或包含无效 JSON 时明确报错，不回退到仅比较版本号。历史记录仍可浏览没有 JSON 的旧发布及其原始说明，不据此判定当前是否有更新。

## 生成与发布

从最终对外发布的 IPA 生成，避免手填构建号和哈希：

```sh
python3 Tools/make_ios_update.py /absolute/path/CarWithin-1.0.1-unsigned.ipa \
  --notes /absolute/path/update-notes.md --output /absolute/path/ios-update.json
```

审核后将 IPA 与 JSON 上传到同一个正式 Release，并设置 Latest。发布新版本时使用数字标签，例如 `v1.0.1`，保留 IPA 和 Release 正文，让只识别版本号的旧客户端仍能发现升级。首次迁移版本必须高于公开的 1.0.0，仅递增构建号不足以触发旧客户端更新。

## 检查次数

开发者查看该 JSON 附件的 GitHub `download_count`，作为各版本清单请求量的近似参考。它不是精确检查成功次数或独立用户数：人工下载、重试、缓存、网络失败、计数延迟和测试都会影响结果；在请求 JSON 前失败的检查不会计入。各 Release 的清单分别计数，跨版本汇总需相加。删除并重新上传附件可能重置计数。客户端不包含 GitHub 管理令牌，不上传设备标识。

## 当前线上边界

2026-11-18 经用户授权，已向公开 Latest v1.0.0（11）补上传 ios-update.json。按原 IPA 核对最低 iOS 16.4、大小 1,789,882 字节及 SHA-256；通过当前解析器、下载校验和构建 12 不提示降级的检查。上传后回读一致，原 IPA、正文、标签、发布日期及 Latest 未变。v0.2 暂未补充。

用户确认历史详情继续显示 Release Markdown，不接入逐条 JSON 详情读取。此方案作为后续跨项目版本记录文案的默认值；Ninebot Pro iOS 当前先显示 JSON notes、展开显示完整 Markdown，保留现状，不因规范更新立即迁移。减少的是文案展示的额外网络请求，更新发现与安装包校验仍按各项目协议执行。当前版本检查页面仍按现有实现优先显示 JSON notes，历史页面显示正文，两者不混同。本轮未修改应用代码。CarWithin 与 Ninebot Pro iOS 的检查和 App 内版本记录均排除草稿、预发布；GitHub 网页仍可访问它们。

## 本地回归检查

```sh
xcrun swiftc -parse-as-library App/AppReleaseService.swift Tools/UpdateSmoke.swift -o /tmp/carwithin-update-smoke
/tmp/carwithin-update-smoke
```

覆盖 JSON 发现、产品和附件一致性、仅构建号排序、按构建忽略、检查间隔、缺失清单，以及浏览历史不读取统计清单。使用模拟响应，不修改线上发布。

## 英文更新说明（2026-11-24）

清单新增可选字符串 `notesEn`，`schemaVersion` 继续为 1。`notes` 仍为非空中文说明，旧客户端忽略新增字段。新版 App 根据当前 App 语言选择说明：英文优先使用非空 `notesEn`，缺失或空白回退 `notes`；中文始终使用 `notes`。不改变构建号比较与附件校验。

生成时可追加 `--notes-en /absolute/path/update-notes.en.md`；未指定时不输出该字段。GitHub Release 正文保持中文。历史页面及展开的完整发布说明仍直接显示原始 Release Markdown，不额外下载各版本 JSON。

本地更新回归命令需同时编译语言支持文件：

```sh
xcrun swiftc -parse-as-library Sources/TDSCarKitCore/Localization.swift App/AppReleaseService.swift Tools/UpdateSmoke.swift -o /tmp/carwithin-update-smoke
/tmp/carwithin-update-smoke
```
