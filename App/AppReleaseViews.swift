import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReleaseDownload: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: Double?
    @Published private(set) var isDownloading = false
    @Published private(set) var file: URL?
    @Published var error: String?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var requestID: String?
    nonisolated let asset: AppRelease.Asset

    init(asset: AppRelease.Asset) { self.asset = asset }

    func start() {
        guard !isDownloading else { return }
        error = nil
        file = nil
        progress = nil
        isDownloading = true
        let identifier = UUID().uuidString
        requestID = identifier
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: asset.browser_download_url)
        request.setValue("CarWithin-iOS", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.taskDescription = identifier
        self.task = task
        task.resume()
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        isDownloading = false
        progress = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let identifier = downloadTask.taskDescription
        if totalBytesWritten > asset.size {
            downloadTask.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.requestID == identifier else { return }
                self.error = ReleaseError.fileSize.localizedDescription
                self.cancel()
            }
            return
        }
        let amount = min(1, Double(totalBytesWritten) / Double(max(1, asset.size)))
        Task { @MainActor [weak self] in
            guard let self, self.requestID == identifier else { return }
            self.progress = amount
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let identifier = downloadTask.taskDescription
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw ReleaseError.invalid }
            guard response.statusCode == 200 else { throw ReleaseError.response(response.statusCode) }
            try AppReleaseService.verify(location, asset: asset)
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ReleaseDownloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor [weak self] in
                guard let self, self.requestID == identifier else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                self.file = destination
                self.progress = 1
                self.isDownloading = false
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.requestID == identifier else { return }
                self.error = message
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let identifier = task.taskDescription
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.requestID == identifier else { return }
            self.isDownloading = false
            self.task = nil
            self.session = nil
            if let message { self.error = message }
        }
    }
}

struct ReleaseHistoryView: View {
    let installed: String
    let canDownload: () -> Bool
    @State private var releases: [AppRelease] = []
    @State private var latestTag: String?
    @State private var page = 1
    @State private var hasNext = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(releases) { release in
                NavigationLink {
                    ReleaseDetailView(release: release, installed: installed, latestTag: latestTag,
                                      canDownload: canDownload)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(release.name ?? "CarWithin \(release.version)")
                                .foregroundStyle(.primary)
                            Spacer()
                            if ReleaseVersion(release.version) == ReleaseVersion(installed) {
                                Text(CWL("当前安装")).foregroundStyle(.secondary).font(.caption)
                            }
                            if release.tag_name == latestTag {
                                Text(CWL("最新发布")).foregroundStyle(.blue).font(.caption)
                            }
                        }
                        if let date = release.published_at {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button(CWL("重试")) { Task { await load() } }
                }
            } else if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if releases.isEmpty {
                Text(CWL("暂无公开版本")).foregroundStyle(.secondary)
            } else if hasNext {
                Button(CWL("加载更多")) { Task { await load() } }
            }
            Section {
                Link(CWL("在 GitHub 查看"), destination: AppRelease.repository.appendingPathComponent("releases"))
            }
        }
        .navigationTitle(CWL("版本记录"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if releases.isEmpty { await load() }
            if latestTag == nil { latestTag = try? await AppReleaseService().latestTag() }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await AppReleaseService().history(page: page)
            try Task.checkCancellation()
            let ids = Set(releases.map(\.id))
            releases += result.releases.filter { !ids.contains($0.id) }
            hasNext = result.hasNext
            page += 1
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReleaseDetailView: View {
    let release: AppRelease
    let installed: String
    let latestTag: String?
    let canDownload: () -> Bool
    var automatic = false
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var expandedNotes = false

    private var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }
    private var supportedOS: Bool {
        guard let minimum = release.update?.minimumOSVersion, let required = ReleaseVersion(minimum) else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
        return required <= current
    }

    private var status: String {
        guard release.tag_name == latestTag, let update = release.update else {
            return CWL("版本详情")
        }
        return update.build > installedBuild ? CWL("发现新版本") : CWL("已是最新发布版本")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(status, systemImage: automatic ? "arrow.down.circle" : "info.circle")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                    Text("CarWithin \(release.version)").font(.title2.bold())
                    if let update = release.update {
                        Text(CWL("发布构建 {1}", [String(describing: update.build)])).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(CWL("当前安装 {1}（{2}）", [String(describing: installed), String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")]))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let date = release.published_at {
                        Text(date, style: .date).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ReleaseNotesView(markdown: release.update?.localizedNotes() ?? release.body ?? CWL("此版本暂无更新说明。"))
                if release.update != nil, let body = release.body, !body.isEmpty {
                    DisclosureGroup(CWL("完整发布说明"), isExpanded: $expandedNotes) {
                        ReleaseNotesView(markdown: body).padding(.top, 12)
                    }
                }
                Link(CWL("在 GitHub 查看"), destination: release.pageURL)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if !supportedOS {
                    Text(CWL("此版本需要 iOS {1} 或更高版本。", [String(describing: release.update?.minimumOSVersion ?? "")]))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let asset = release.ipa {
                    ReleaseDownloadView(asset: asset, canDownload: canDownload)
                } else {
                    Text(CWL("此版本暂无 IPA 附件。")).font(.footnote).foregroundStyle(.secondary)
                }
                if automatic {
                    Button(CWL("下次再说")) {
                        AppUpdatePolicy().snooze()
                        finish()
                    }.buttonStyle(ReleaseActionStyle(kind: .secondary))
                    Button(CWL("此版本不再提醒")) {
                        AppUpdatePolicy().ignore(release)
                        finish()
                    }.buttonStyle(ReleaseActionStyle(kind: .outline))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle(automatic ? CWL("版本更新") : CWL("版本详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if close != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CWL("完成")) {
                        if automatic { AppUpdatePolicy().snooze() }
                        finish()
                    }
                }
            }
        }
    }

    private func finish() {
        if let close { close() } else { dismiss() }
    }
}

/// Keep all release actions consistent across OS versions and download states.
private struct ReleaseActionStyle: ButtonStyle {
    enum Kind { case primary, secondary, outline }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(kind == .primary ? Color.white : kind == .secondary ? Color.blue : Color.secondary)
            .background(kind == .primary ? Color.blue : kind == .secondary ? Color.blue.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if kind == .outline {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct ReleaseDownloadView: View {
    @StateObject private var download: ReleaseDownload
    let canDownload: () -> Bool
    @State private var sharing = false
    @State private var exporting = false

    init(asset: AppRelease.Asset, canDownload: @escaping () -> Bool) {
        _download = StateObject(wrappedValue: ReleaseDownload(asset: asset))
        self.canDownload = canDownload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if download.isDownloading {
                if let progress = download.progress {
                    ProgressView(value: progress)
                    Text(CWL("正在下载 {1}%", [String(describing: Int(progress * 100))])).font(.subheadline)
                } else { ProgressView(CWL("正在连接下载…")) }
                Button(CWL("取消下载"), role: .cancel) { download.cancel() }
                    .buttonStyle(ReleaseActionStyle(kind: .outline))
            } else if let file = download.file {
                Button { sharing = true } label: {
                    Label(CWL("打开或分享 IPA"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(ReleaseActionStyle(kind: .primary))
                Button { exporting = true } label: {
                    Label(CWL("保存到文件"), systemImage: "folder").frame(maxWidth: .infinity)
                }.buttonStyle(ReleaseActionStyle(kind: .secondary))
                Text(CWL("下载完成 · {1}", [String(describing: file.lastPathComponent)]))
                    .font(.caption).foregroundStyle(.secondary)
                if download.asset.sha256 == nil {
                    Text(CWL("此历史版本未提供 SHA-256，已核对文件大小与格式。")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    guard canDownload() else {
                        download.error = CWL("请先停止 CarPlay，再下载 IPA。")
                        return
                    }
                    download.start()
                } label: {
                    Label(CWL("下载此版本 · {1}", [String(describing: ByteCountFormatter.string(fromByteCount: download.asset.size, countStyle: .file))]),
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ReleaseActionStyle(kind: .primary))
                Text(CWL("IPA 需自行签名安装；下载后可分享给签名工具或保存到文件。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = download.error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .sheet(isPresented: $sharing) {
            if let file = download.file { ReleaseShareSheet(file: file) }
        }
        .sheet(isPresented: $exporting) {
            if let file = download.file { ReleaseExportSheet(file: file) }
        }
        .onChange(of: download.file) { file in
            if file != nil { sharing = true }
        }
        .onDisappear { download.cancel() }
    }
}

private struct ReleaseShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = controller.view.bounds
        controller.popoverPresentationController?.permittedArrowDirections = []
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ReleaseExportSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// Preserve paragraphs and code blocks while using native Markdown for inline links and emphasis.
private struct ReleaseNotesView: View {
    struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let code: Bool
    }
    let markdown: String

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var inCode = false
        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(Block(id: result.count, text: paragraph.joined(separator: "\n"), heading: 0, code: inCode))
            paragraph = []
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else if inCode {
                paragraph.append(line)
            } else if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).hasPrefix(" ") {
                    result.append(Block(id: result.count, text: String(line.dropFirst(level + 1)), heading: level, code: false))
                } else { paragraph.append(line) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") {
                flush()
                let prefix = line.hasPrefix("> ") ? "│ " : "• "
                result.append(Block(id: result.count, text: prefix + line.dropFirst(2), heading: 0, code: false))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                if block.code {
                    Text(block.text).font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(.init(block.text))
                        .font(block.heading > 0 ? .headline : .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }
}
