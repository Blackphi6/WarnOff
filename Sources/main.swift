import AppKit
import CoreServices
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

/// 対象拡張子だけ触る。ほかのファイルは見ない。
enum QuarantineCore {
    static let attribute = "com.apple.quarantine"
    static let targetExts: Set<String> = ["app", "dmg", "zip"]
    private static let incompleteSuffixes = [".download", ".crdownload", ".part", ".tmp"]

    static func isTarget(_ url: URL) -> Bool {
        targetExts.contains(url.pathExtension.lowercased())
    }

    static func isIncomplete(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return incompleteSuffixes.contains { name.hasSuffix($0) }
    }

    /// 祖先に途中ダウンロードがあれば捨て、いちばん外側の対象を返す。
    static func resolveTarget(from url: URL) -> URL? {
        var current = url.standardizedFileURL
        var found: URL?
        while current.path != "/" {
            if isIncomplete(current) { return nil }
            if isTarget(current) { found = current }
            current.deleteLastPathComponent()
        }
        return found
    }

    static func isInside(root: URL, url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr else { return false }
            return getxattr(ptr, attribute, nil, 0, 0, 0) > 0
        }
    }

    /// バンドル根だけでなく、Gatekeeper が見る実行ファイルも見る。
    static func needsClear(_ url: URL) -> Bool {
        if hasQuarantine(url) { return true }
        guard url.pathExtension.lowercased() == "app" else { return false }
        let execDir = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: execDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.contains(where: hasQuarantine)
    }

    /// 無いパスは黙って無視。属性が無いときも失敗扱いにしない。
    @discardableResult
    static func clear(at url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard isTarget(url) else { return false }
        guard needsClear(url) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", attribute, path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            Log.line("xattr failed \(path): \(error.localizedDescription)")
            return false
        }
        let still = needsClear(url)
        if !still {
            Log.line("cleared \(path)")
        }
        return !still
    }

    static func scan(root: URL) -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var cleared = 0
        if isTarget(root), clear(at: root) { cleared += 1 }

        while let url = en.nextObject() as? URL {
            if isIncomplete(url) {
                en.skipDescendants()
                continue
            }
            if isTarget(url), clear(at: url) {
                cleared += 1
            }
        }
        return cleared
    }

    /// resolveTarget とフォルダ閉じ込めの確認。失敗したら 1 を返す。
    static func runSelfTests() -> Int {
        func fail(_ message: String) -> Int {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            return 1
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("warnoff-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            return fail("tmpdir")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let innerDmg = tmp.appendingPathComponent("Foo.dmg.download/Foo.dmg")
        do {
            try FileManager.default.createDirectory(at: innerDmg.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: innerDmg)
        } catch {
            return fail("write incomplete")
        }
        if resolveTarget(from: innerDmg) != nil {
            return fail("incomplete inner dmg must be ignored")
        }

        let exec = tmp.appendingPathComponent("Wrap.app/Contents/MacOS/bin")
        do {
            try FileManager.default.createDirectory(at: exec.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: exec)
        } catch {
            return fail("write wrap.app")
        }
        guard let outer = resolveTarget(from: exec), outer.lastPathComponent == "Wrap.app" else {
            return fail("outermost .app")
        }

        let watchRoot = tmp.appendingPathComponent("Downloads/Big.app/Contents", isDirectory: true)
        let event = tmp.appendingPathComponent("Downloads/Big.app/Contents/MacOS/bin")
        do {
            try FileManager.default.createDirectory(at: event.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: event)
        } catch {
            return fail("write escape case")
        }
        guard let escaped = resolveTarget(from: event) else {
            return fail("resolve Big.app")
        }
        if isInside(root: watchRoot, url: escaped) {
            return fail("resolved target escaped watch root")
        }

        let originalTrust = TrustStore.load()
        defer {
            if let data = try? JSONEncoder().encode(originalTrust) {
                UserDefaults.standard.set(data, forKey: "trustList")
            }
        }
        let trustTestPath = "/tmp/warnoff-selftest-trust.app"
        let afterUpsert = TrustStore.upsert(path: trustTestPath, status: .fullyTrusted)
        guard afterUpsert.first(where: { $0.path == trustTestPath })?.status == .fullyTrusted else {
            return fail("trust upsert")
        }
        guard TrustStore.status(forPath: trustTestPath) == .fullyTrusted else {
            return fail("trust status lookup")
        }

        FileHandle.standardOutput.write(Data("self-test ok\n".utf8))
        return 0
    }
}

/// アプリの署名・ノータライズ状態。自動クリアを許可する範囲を決めるために使う。
enum SignatureStatus: String, Codable {
    case fullyTrusted
    case signedNotNotarized
    case unsigned

    var labelKey: String {
        switch self {
        case .fullyTrusted: return "trust.status.fullyTrusted"
        case .signedNotNotarized: return "trust.status.signedNotNotarized"
        case .unsigned: return "trust.status.unsigned"
        }
    }

    var detailKey: String {
        switch self {
        case .fullyTrusted: return "trust.detail.fullyTrusted"
        case .signedNotNotarized: return "trust.detail.signedNotNotarized"
        case .unsigned: return "trust.detail.unsigned"
        }
    }

    var color: Color {
        switch self {
        case .fullyTrusted: return .green
        case .signedNotNotarized: return .yellow
        case .unsigned: return .red
        }
    }
}

/// codesign と spctl を外部プロセスとして呼んで署名状態を判定する。メインスレッドをブロックしないよう、呼び出し側でバックグラウンドから呼ぶこと。
enum CodeSignChecker {
    static func check(path: String) -> SignatureStatus {
        guard run("/usr/bin/codesign", ["-dv", "--verbose=4", path]) else {
            return .unsigned
        }
        let notarized = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose", path])
        return notarized ? .fullyTrusted : .signedNotNotarized
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: exe) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            Log.line("\(exe) failed: \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}

/// ユーザーが「信頼する」と決めたアプリの一覧。UserDefaults に JSON で保存する。
struct TrustEntry: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    var status: SignatureStatus
    let addedAt: Date
}

enum TrustStore {
    private static let key = "trustList"

    static func load() -> [TrustEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TrustEntry].self, from: data)) ?? []
    }

    static func status(forPath path: String) -> SignatureStatus? {
        load().first { $0.path == path }?.status
    }

    @discardableResult
    static func upsert(path: String, status: SignatureStatus) -> [TrustEntry] {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.path == path }) {
            entries[idx] = TrustEntry(path: path, status: status, addedAt: entries[idx].addedAt)
        } else {
            entries.append(TrustEntry(path: path, status: status, addedAt: Date()))
        }
        guard let data = try? JSONEncoder().encode(entries) else { return entries }
        UserDefaults.standard.set(data, forKey: key)
        return entries
    }
}

enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WarnOff.log")
    }()

    private static let io = DispatchQueue(label: "local.warnoff.log")

    static func line(_ text: String) {
        let row = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        guard let data = row.data(using: .utf8) else { return }
        io.sync {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            _ = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
        }
    }
}

/// フォルダの変化を FSEvents で見る。
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "local.warnoff.watch")
    private var pending = Set<String>()
    private var debounceWork: DispatchWorkItem?
    private var recentlyDone: [String: Date] = [:]
    private var root: URL
    var onCleared: ((URL) -> Void)?
    var onNeedsConfirmation: ((URL, SignatureStatus) -> Void)?

    init(root: URL) {
        self.root = root
    }

    func start() {
        stop()
        guard FileManager.default.fileExists(atPath: root.path) else {
            Log.line("skip missing watch root \(root.path)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var names: [String] = []
            names.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                if let s = array[i] as? String { names.append(s) }
            }
            watcher.enqueue(names)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else {
            Log.line("FSEventStreamCreate failed")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        Log.line("watching \(root.path)")
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func enqueue(_ paths: [String]) {
        for path in paths { pending.insert(path) }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func flush() {
        let cutoff = Date().addingTimeInterval(-30)
        recentlyDone = recentlyDone.filter { $0.value > cutoff }
        let batch = pending
        pending.removeAll()
        var seen = Set<String>()
        for path in batch {
            let url = URL(fileURLWithPath: path)
            guard let target = QuarantineCore.resolveTarget(from: url),
                  QuarantineCore.isInside(root: root, url: target) else { continue }
            if seen.contains(target.path) { continue }
            seen.insert(target.path)
            if let last = recentlyDone[target.path], Date().timeIntervalSince(last) < 30 {
                continue
            }
            process(target: target)
        }
    }

    /// .app は署名状態を見て、十分信頼できる(Fully Trusted)ときだけ自動でクリアする。dmg/zip は従来どおり即クリア。
    private func process(target: URL) {
        guard target.pathExtension.lowercased() == "app" else {
            if QuarantineCore.clear(at: target) {
                recentlyDone[target.path] = Date()
                DispatchQueue.main.async { self.onCleared?(target) }
            }
            return
        }

        let status = TrustStore.status(forPath: target.path) ?? CodeSignChecker.check(path: target.path)
        guard status == .fullyTrusted else {
            recentlyDone[target.path] = Date()
            DispatchQueue.main.async { self.onNeedsConfirmation?(target, status) }
            return
        }
        TrustStore.upsert(path: target.path, status: .fullyTrusted)
        if QuarantineCore.clear(at: target) {
            recentlyDone[target.path] = Date()
            DispatchQueue.main.async { self.onCleared?(target) }
        }
    }
}

enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

@MainActor
@Observable
final class AppState {
    var watchPath: String
    var lastMessage: String = L10n.t("status.watching")
    var clearedCount: Int = 0
    var openAtLogin: Bool = false
    var trustList: [TrustEntry] = TrustStore.load()
    private var watcher: FolderWatcher?

    init(initialPath: String) {
        watchPath = initialPath
        // 初めて入れた人は、ログイン項目を最初からオンにする（一度だけ）
        Self.enableLoginItemOnFirstLaunch()
        openAtLogin = SMAppService.mainApp.status == .enabled
        startWatcher()
        let path = watchPath
        Task.detached { [weak self] in
            let n = QuarantineCore.scan(root: URL(fileURLWithPath: path))
            await self?.noteScan(count: n, message: L10n.f("status.clearedOnLaunch", n), skipIfZero: true)
        }
    }

    /// 初回起動だけログイン項目を登録する。あとはユーザーのオン/オフを尊重する。
    private static func enableLoginItemOnFirstLaunch() {
        let key = "didConfigureLoginItem"
        if UserDefaults.standard.bool(forKey: key) { return }
        if SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.line("login item default: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    func startWatcher() {
        watcher?.stop()
        watcher = nil
        let root = URL(fileURLWithPath: watchPath, isDirectory: true)
        let w = FolderWatcher(root: root)
        w.onCleared = { [weak self] url in
            Task { @MainActor in
                self?.clearedCount += 1
                self?.lastMessage = L10n.f("status.clearedFile", url.lastPathComponent)
            }
        }
        w.onNeedsConfirmation = { [weak self] url, status in
            Task { @MainActor in
                self?.trustList = TrustStore.load()
                self?.lastMessage = L10n.f("status.needsConfirmation", url.lastPathComponent)
            }
        }
        watcher = w
        w.start()
    }

    /// ファイル選択 → 署名確認 → ダイアログ確認、の順で信頼リストに追加する。
    func addAppToTrustList() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.prompt = L10n.t("panel.chooseApp")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        lastMessage = L10n.t("status.checkingSignature")
        let path = url.path
        Task.detached { [weak self] in
            let status = CodeSignChecker.check(path: path)
            await self?.confirmTrust(path: path, status: status)
        }
    }

    private func confirmTrust(path: String, status: SignatureStatus) {
        let name = (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = L10n.f("trust.dialogTitle", name)
        alert.informativeText = L10n.t(status.detailKey)
        alert.alertStyle = status == .unsigned ? .critical : .informational
        alert.addButton(withTitle: L10n.t(status == .unsigned ? "trust.addAnyway" : "trust.add"))
        alert.addButton(withTitle: L10n.t("trust.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            lastMessage = L10n.t("status.trustCancelled")
            return
        }

        trustList = TrustStore.upsert(path: path, status: status)
        lastMessage = L10n.f("status.trustAdded", name)
        if status == .fullyTrusted {
            _ = QuarantineCore.clear(at: URL(fileURLWithPath: path))
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: watchPath, isDirectory: true)
        panel.prompt = L10n.t("panel.choose")
        panel.message = L10n.t("panel.hint")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watchPath = url.path
        UserDefaults.standard.set(watchPath, forKey: "watchPath")
        startWatcher()
        lastMessage = L10n.f("status.folderSet", url.lastPathComponent)
    }

    func clearNow() {
        lastMessage = L10n.t("status.clearing")
        let path = watchPath
        Task.detached { [weak self] in
            let n = QuarantineCore.scan(root: URL(fileURLWithPath: path))
            let message = n == 0 ? L10n.t("status.clearedNone") : L10n.f("status.clearedCount", n)
            await self?.noteScan(count: n, message: message, skipIfZero: false)
        }
    }

    private func noteScan(count: Int, message: String, skipIfZero: Bool) {
        if skipIfZero, count == 0 { return }
        clearedCount += count
        lastMessage = message
    }

    func setOpenAtLogin(_ on: Bool) {
        guard on != openAtLogin else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLogin = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
        } catch {
            lastMessage = L10n.t("status.loginFailed")
            Log.line("login item: \(error.localizedDescription)")
        }
    }

    func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WarnOff",
            .credits: NSAttributedString(string: L10n.t("about.credits"))
        ])
    }
}

struct MenuContent: View {
    @Bindable var state: AppState

    var body: some View {
        Text(L10n.f("menu.watchFolder", state.watchPath))
        Text(state.lastMessage)
        Text(L10n.f("menu.clearedCount", state.clearedCount))
        Divider()
        Button(L10n.t("menu.changeFolder")) { state.pickFolder() }
        Button(L10n.t("menu.clearNow")) { state.clearNow() }
        Toggle(L10n.t("menu.openAtLogin"), isOn: Binding(
            get: { state.openAtLogin },
            set: { state.setOpenAtLogin($0) }
        ))
        Divider()
        ForEach(state.trustList) { entry in
            Label(
                (entry.path as NSString).lastPathComponent,
                systemImage: "circle.fill"
            )
            .foregroundStyle(entry.status.color)
        }
        Button(L10n.t("menu.addTrustedApp")) { state.addAppToTrustList() }
        Divider()
        Button(L10n.t("menu.openLog")) { state.openLog() }
        Button(L10n.t("menu.about")) { state.showAbout() }
        Divider()
        // 「やめる」は監視の停止と取り違えるので、終了だけを書く
        Button(L10n.t("menu.quit")) { NSApp.terminate(nil) }
    }
}

@main
struct WarnOffApp: App {
    @State private var state: AppState

    init() {
        if CommandLine.arguments.contains("--self-test") {
            Darwin.exit(Int32(QuarantineCore.runSelfTests()))
        }
        if CommandLine.arguments.contains("--once") {
            let dir = rawCliDirectory() ?? defaultWatchPath()
            let n = QuarantineCore.scan(root: URL(fileURLWithPath: dir))
            FileHandle.standardOutput.write(Data("cleared \(n)\n".utf8))
            Darwin.exit(0)
        }
        let saved = UserDefaults.standard.string(forKey: "watchPath")
        let start = cliDirectory() ?? saved ?? defaultWatchPath()
        _state = State(initialValue: AppState(initialPath: start))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: "checkmark.shield")
        }
    }
}

private func defaultWatchPath() -> String {
    FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?.path
        ?? "/Applications"
}

private func rawCliDirectory() -> String? {
    let skip: Set<String> = ["--once", "--self-test"]
    return CommandLine.arguments.dropFirst().first { !skip.contains($0) && !$0.hasPrefix("-") }
}

private func cliDirectory() -> String? {
    guard let first = rawCliDirectory() else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: first, isDirectory: &isDir), isDir.boolValue else {
        return nil
    }
    return first
}
