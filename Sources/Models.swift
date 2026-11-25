import SwiftUI
import Combine
import AppKit

enum Phase: Equatable { case idle, scanning, results, working, done }

func runningBundleIDs() -> [String] {
    NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
}

func minDelay(_ start: ContinuousClock.Instant, _ ms: Int) async {
    let e = ContinuousClock.now - start
    if e < .milliseconds(ms) { try? await Task.sleep(for: .milliseconds(ms) - e) }
}

// MARK: - Cleanup

enum JunkKind: String, CaseIterable, Identifiable, Sendable {
    case caches, logs, temp, savedState, developer, iosUpdates, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: "User Cache Files"
        case .logs: "Log Files"
        case .temp: "Temporary Files"
        case .savedState: "Saved App States"
        case .developer: "Developer Junk"
        case .iosUpdates: "Old iOS Updates"
        case .trash: "Trash Bin"
        }
    }
    var subtitle: String {
        switch self {
        case .caches: "Data apps cache and rebuild on demand"
        case .logs: "Activity, diagnostic and crash logs"
        case .temp: "Leftover temp files older than a day"
        case .savedState: "Window positions apps restore on launch"
        case .developer: "Xcode DerivedData, simulator & npm caches"
        case .iosUpdates: "Downloaded iPhone/iPad firmware files"
        case .trash: "Files already in your Trash"
        }
    }
    var symbol: String {
        switch self {
        case .caches: "shippingbox.fill"
        case .logs: "doc.text.fill"
        case .temp: "clock.arrow.circlepath"
        case .savedState: "macwindow.on.rectangle"
        case .developer: "hammer.fill"
        case .iosUpdates: "iphone.gen3"
        case .trash: "trash.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .caches: [.violet, .sky]
        case .logs: [.aqua, .sky]
        case .temp: [.amber, .rose]
        case .savedState: [.lilac, .violet]
        case .developer: [.mint, .aqua]
        case .iosUpdates: [.sky, .teal]
        case .trash: [.pinkish, .rose]
        }
    }

    enum Source { case contents(URL), whole(URL) }
    var sources: [Source] {
        switch self {
        case .caches: [.contents(home("Library/Caches"))]
        case .logs: [.contents(home("Library/Logs"))]
        case .temp: [.contents(URL(fileURLWithPath: NSTemporaryDirectory()))]
        case .savedState: [.contents(home("Library/Saved Application State"))]
        case .developer: [.contents(home("Library/Developer/Xcode/DerivedData")),
                          .contents(home("Library/Developer/CoreSimulator/Caches")),
                          .whole(home(".npm/_cacache")), .whole(home(".gradle/caches"))]
        case .iosUpdates: [.contents(home("Library/iTunes/iPhone Software Updates")),
                           .contents(home("Library/iTunes/iPad Software Updates"))]
        case .trash: [.contents(home(".Trash"))]
        }
    }
    var allowedParents: [String] {
        sources.map {
            switch $0 {
            case .contents(let u): u.standardizedFileURL.path
            case .whole(let u): u.deletingLastPathComponent().standardizedFileURL.path
            }
        }
    }
}

struct JunkGroup: Identifiable {
    let kind: JunkKind
    var items: [FileItem]
    var enabled = true
    var id: String { kind.id }
    var size: Int64 { items.reduce(0) { $0 + ($1.selected ? $1.size : 0) } }
    var selectedCount: Int { items.filter(\.selected).count }
}

enum JunkScanner {
    static let protectedCacheNames: Set<String> = ["cloudkit", "familycircle", "geoservices", "passkit"]

    static func isProtected(_ name: String, _ kind: JunkKind, running: [String]) -> Bool {
        let lower = name.lowercased()
        if lower == ".ds_store" || lower == ".localized" { return true }
        if let own = Bundle.main.bundleIdentifier?.lowercased(), lower.contains(own) { return true }
        switch kind {
        case .caches:
            if lower.hasPrefix("com.apple.") || lower.hasPrefix(".") || protectedCacheNames.contains(lower) { return true }
            if running.contains(where: { $0 == lower || (lower.count >= 5 && $0.contains(lower)) }) { return true }
        case .savedState:
            let id = lower.replacingOccurrences(of: ".savedstate", with: "")
            if running.contains(id) { return true }
        case .temp:
            if lower.hasPrefix("com.apple.") || lower.hasPrefix(".") { return true }
        case .developer:
            if running.contains("com.apple.dt.xcode") { return true }
        default: break
        }
        return false
    }

    static func scan(_ kind: JunkKind, running: [String]) -> [FileItem] {
        var out: [FileItem] = []
        let dayAgo = Date().addingTimeInterval(-86400 * Double(PrefKeys.tempAgeDays))
        let excluded = PrefKeys.excluded
        for source in kind.sources {
            var candidates: [URL] = []
            switch source {
            case .whole(let u): if FS.exists(u) { candidates = [u] }
            case .contents(let u): candidates = FS.children(u)
            }
            for url in candidates {
                if isProtected(url.lastPathComponent, kind, running: running) { continue }
                if !excluded.isEmpty && PrefKeys.isExcluded(url) { continue }
                if kind == .temp, let m = FS.modified(url), m > dayAgo { continue }
                let s = FS.size(of: url)
                if s > 0 { out.append(FileItem(url: url, size: s)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Permanent delete, only directly inside an allowed folder. Returns bytes left behind.
    static func remove(_ item: FileItem) -> Int64 {
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        let allowed = JunkKind.allCases.flatMap(\.allowedParents)
        guard allowed.contains(parent) else { return item.size }
        do { try FS.fm.removeItem(at: item.url); return 0 }
        catch { return FS.exists(item.url) ? FS.size(of: item.url) : 0 }
    }
}

@MainActor
final class CleanupModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var groups: [JunkGroup] = []
    @Published var scanningNow: JunkKind?
    @Published var scanned: Set<JunkKind> = []
    @Published var found: Int64 = 0
    @Published var progress: Double = 0
    @Published var current = ""
    @Published var freed: Int64 = 0
    @Published var skipped = 0

    var total: Int64 { groups.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.size } } }
    var selected: Int64 { groups.filter(\.enabled).reduce(0) { $0 + $1.size } }
    var includesTrash: Bool { groups.contains { $0.kind == .trash && $0.enabled && $0.size > 0 } }

    func scan() { Task { await performScan(animated: true) } }

    func performScan(animated: Bool) async {
        withAnimation(.smooth) { phase = .scanning; groups = []; found = 0; scanned = [] }
        let running = runningBundleIDs()
        let disabled = PrefKeys.disabledKinds
        for k in JunkKind.allCases where !disabled.contains(k.rawValue) {
            withAnimation { scanningNow = k }
            let start = ContinuousClock.now
            let items = await Task.detached(priority: .userInitiated) { JunkScanner.scan(k, running: running) }.value
            if animated { await minDelay(start, 450) }
            let g = JunkGroup(kind: k, items: items)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                scanned.insert(k)
                if !items.isEmpty { groups.append(g) }
                found += g.size
            }
        }
        scanningNow = nil
        withAnimation(.smooth(duration: 0.6)) { phase = .results }
    }

    func clean() { Task { await performClean() } }

    func performClean() async {
        let targets = groups.filter(\.enabled).flatMap { $0.items.filter(\.selected) }
        withAnimation(.smooth) { phase = .working; progress = 0; freed = 0; skipped = 0 }
        let n = max(targets.count, 1)
        for (i, item) in targets.enumerated() {
            current = item.url.lastPathComponent
            let left = await Task.detached { JunkScanner.remove(item) }.value
            freed += max(0, item.size - left)
            if left > 0 { skipped += 1 }
            withAnimation(.linear(duration: 0.1)) { progress = Double(i + 1) / Double(n) }
            if targets.count < 80 { try? await Task.sleep(for: .milliseconds(30)) }
        }
        History.shared.log("Junk cleanup", freed)
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
    }

    func reset() { withAnimation(.smooth) { phase = .idle; groups = [] } }
}

// MARK: - Protection

struct PrivacyGroup: Identifiable {
    let id = UUID()
    let app: String
    let kind: String
    let symbol: String
    let bundleID: String?
    var urls: [URL]
    var size: Int64
    var selected: Bool
    var isRunning: Bool
}

enum ProtectionScanner {
    static let adwareSignatures = [
        "com.pcv.", "mackeeper", "zeobit", "genieo", "installmac", "searchmine", "adsearch", "spigot",
        "crossrider", "vsearch", "conduit", "bundlore", "myshopcoupon", "pplauncher", "chumsearch",
        "searchbaron", "mughthesec", "adload", "flashmall", "safefinder", "mysearch", "tapufind",
        "weknow", "surfbuyer", "advancedmaccleaner", "macbooster", "mac-auto-fixer", "searchpulse",
        "qsearch", "smartsearch", "shlayer", "pirrit", "imunizator", "macsearch", "searchmarquis",
    ]

    static func scanThreats() -> [FileItem] {
        let dirs = [home("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons")]
        var out: [FileItem] = []
        for d in dirs {
            for f in FS.children(d) where f.pathExtension == "plist" {
                let name = f.lastPathComponent.lowercased()
                var reason = ""
                if let sig = adwareSignatures.first(where: { name.contains($0) }) {
                    reason = "Matches known adware (\(sig.trimmingCharacters(in: CharacterSet(charactersIn: "."))))"
                } else if let dict = NSDictionary(contentsOf: f) {
                    let prog = (dict["Program"] as? String) ?? ((dict["ProgramArguments"] as? [String])?.first ?? "")
                    if prog.hasPrefix("/tmp/") || prog.hasPrefix("/private/tmp/") || prog.contains("/var/folders/") {
                        reason = "Runs a program from a temporary folder"
                    } else if prog.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0.count > 1 }) {
                        reason = "Runs a program from a hidden folder"
                    } else if !prog.isEmpty, !FS.exists(URL(fileURLWithPath: prog)), d.path.hasPrefix(homePath) {
                        reason = "Broken: points to a program that no longer exists"
                    }
                }
                if !reason.isEmpty {
                    out.append(FileItem(url: f, size: FS.size(of: f), note: reason))
                }
            }
        }
        return out
    }

    struct Browser { let name: String; let id: String; let support: String }
    static let chromium: [Browser] = [
        .init(name: "Google Chrome", id: "com.google.chrome", support: "Google/Chrome"),
        .init(name: "Brave", id: "com.brave.browser", support: "BraveSoftware/Brave-Browser"),
        .init(name: "Microsoft Edge", id: "com.microsoft.edgemac", support: "Microsoft Edge"),
        .init(name: "Arc", id: "company.thebrowser.browser", support: "Arc/User Data"),
        .init(name: "Opera", id: "com.operasoftware.opera", support: "com.operasoftware.Opera"),
        .init(name: "Vivaldi", id: "com.vivaldi.vivaldi", support: "Vivaldi"),
    ]

    static func scanPrivacy(running: [String]) -> [PrivacyGroup] {
        var out: [PrivacyGroup] = []
        for b in chromium {
            let root = home("Library/Application Support/\(b.support)")
            guard FS.exists(root) else { continue }
            let profiles = FS.children(root).filter {
                let n = $0.lastPathComponent
                return n == "Default" || n.hasPrefix("Profile ")
            }
            var hist: [URL] = [], cookies: [URL] = []
            for p in profiles {
                for n in ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"] {
                    let u = p.appending(path: n); if FS.exists(u) { hist.append(u) }
                }
                for n in ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"] {
                    let u = p.appending(path: n); if FS.exists(u) { cookies.append(u) }
                }
            }
            let isRunning = running.contains(b.id)
            if !hist.isEmpty {
                out.append(PrivacyGroup(app: b.name, kind: "Browsing & download history", symbol: "clock.arrow.circlepath", bundleID: b.id,
                                        urls: hist, size: hist.reduce(0) { $0 + FS.size(of: $1) }, selected: false, isRunning: isRunning))
            }
            if !cookies.isEmpty {
                out.append(PrivacyGroup(app: b.name, kind: "Cookies (signs you out of websites)", symbol: "birthday.cake.fill", bundleID: b.id,
                                        urls: cookies, size: cookies.reduce(0) { $0 + FS.size(of: $1) }, selected: false, isRunning: isRunning))
            }
        }
        let recents = home("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments")
        let r = FS.children(recents).filter { $0.pathExtension.hasPrefix("sfl") }
        if !r.isEmpty {
            out.append(PrivacyGroup(app: "macOS", kind: "Recent documents lists", symbol: "doc.badge.clock.fill", bundleID: nil,
                                    urls: r, size: r.reduce(0) { $0 + FS.size(of: $1) }, selected: true, isRunning: false))
        }
        return out
    }
}

@MainActor
final class ProtectionModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var threats: [FileItem] = []
    @Published var privacy: [PrivacyGroup] = []
    @Published var message = ""
    @Published var fullDiskAccess = FS.canReadProtected()

    var selectedCount: Int { threats.filter(\.selected).count + privacy.filter { $0.selected && !$0.isRunning }.count }

    func scan() { Task { await performScan(animated: true) } }

    func performScan(animated: Bool) async {
        withAnimation(.smooth) { phase = .scanning }
        let start = ContinuousClock.now
        let running = runningBundleIDs()
        let (t, p) = await Task.detached { (ProtectionScanner.scanThreats(), ProtectionScanner.scanPrivacy(running: running)) }.value
        if animated { await minDelay(start, 1800) }
        fullDiskAccess = FS.canReadProtected()
        withAnimation(.smooth(duration: 0.6)) { threats = t; privacy = p; phase = .results }
    }

    func quit(_ bundleID: String) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.lowercased() == bundleID { app.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            let running = runningBundleIDs()
            for i in privacy.indices where privacy[i].bundleID == bundleID { privacy[i].isRunning = running.contains(bundleID) }
        }
    }

    func fix() {
        Task {
            withAnimation(.smooth) { phase = .working }
            var removed = 0, failed = 0
            let t = threats.filter(\.selected).map(\.url)
            let userOwned = t.filter { $0.path.hasPrefix(homePath) }
            let system = t.filter { !$0.path.hasPrefix(homePath) }
            failed += FS.trash(userOwned).count
            removed += userOwned.count
            if !system.isEmpty {
                let trashDir = home(".Trash").path
                let cmd = system.map { "mv -f \(shellQuote($0.path)) \(shellQuote(trashDir + "/"))" }.joined(separator: "; ")
                _ = runAsAdmin(cmd)
                let left = system.filter { FS.exists($0) }.count
                removed += system.count - left; failed += left
            }
            for g in privacy where g.selected && !g.isRunning {
                let f = FS.trash(g.urls)
                if f.isEmpty { removed += 1 } else { failed += 1 }
            }
            try? await Task.sleep(for: .milliseconds(900))
            message = failed == 0 ? "\(removed) item\(removed == 1 ? "" : "s") taken care of." :
                "\(removed) fixed, \(failed) couldn't be changed."
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
        }
    }

    func reset() { withAnimation(.smooth) { phase = .idle } }
}

// MARK: - Performance

struct MaintTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let admin: Bool
    let command: String
    var selected: Bool
}

struct HeavyApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let memory: Int64
    let cpu: Double
    let app: NSRunningApplication
}

@MainActor
final class PerformanceModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var tasks: [MaintTask] = [
        .init(id: "ram", title: "Free Up RAM", detail: "Clears inactive memory so active apps have more room.", symbol: "memorychip.fill",
              admin: true, command: "/usr/sbin/purge", selected: true),
        .init(id: "dns", title: "Flush DNS Cache", detail: "Fixes websites that won't load or load slowly after network changes.", symbol: "network",
              admin: true, command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", selected: true),
        .init(id: "ql", title: "Reset Quick Look Thumbnails", detail: "Rebuilds file previews and removes stored thumbnails.", symbol: "eye.fill",
              admin: false, command: "/usr/bin/qlmanage -r cache", selected: true),
        .init(id: "tm", title: "Thin Time Machine Snapshots", detail: "Reclaims space held by local backup snapshots.", symbol: "clock.arrow.2.circlepath",
              admin: true, command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", selected: false),
        .init(id: "spot", title: "Reindex Spotlight", detail: "Fixes search that misses files. Indexing runs in the background for a while.", symbol: "magnifyingglass",
              admin: true, command: "/usr/bin/mdutil -E /", selected: false),
    ]
    @Published var agents: [FileItem] = []
    @Published var heavy: [HeavyApp] = []
    @Published var message = ""

    func scan() { Task { await performScan(animated: true) } }

    func performScan(animated: Bool) async {
        withAnimation(.smooth) { phase = .scanning }
        let start = ContinuousClock.now
        let a = await Task.detached { () -> [FileItem] in
            FS.children(home("Library/LaunchAgents")).filter { $0.pathExtension == "plist" }.map { u in
                let d = NSDictionary(contentsOf: u)
                let prog = (d?["Program"] as? String) ?? ((d?["ProgramArguments"] as? [String])?.first ?? "")
                return FileItem(url: u, size: FS.size(of: u), selected: false, note: prog, date: FS.modified(u))
            }
        }.value
        refreshHeavy()
        if animated { await minDelay(start, 1500) }
        withAnimation(.smooth(duration: 0.6)) { agents = a; phase = .results }
    }

    func refreshHeavy() {
        let out = shell("/bin/ps", ["-Ao", "pid=,rss=,pcpu="])
        var stats: [pid_t: (Int64, Double)] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 3, let pid = pid_t(p[0]), let rss = Int64(p[1]), let cpu = Double(p[2]) { stats[pid] = (rss * 1024, cpu) }
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        heavy = apps.compactMap { a in
            guard let s = stats[a.processIdentifier] else { return nil }
            return HeavyApp(id: a.processIdentifier, name: a.localizedName ?? "App", icon: a.icon, memory: s.0, cpu: s.1, app: a)
        }
        .sorted { $0.memory > $1.memory }
        .prefix(8).map { $0 }
    }

    func quit(_ h: HeavyApp) {
        h.app.terminate()
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { refreshHeavy() } }
    }

    func runTasks() {
        Task {
            let chosen = tasks.filter(\.selected)
            guard !chosen.isEmpty else { return }
            withAnimation(.smooth) { phase = .working }
            try? await Task.sleep(for: .milliseconds(300))
            var ok = 0, fail = 0
            for t in chosen where !t.admin {
                _ = await Task.detached { shell("/bin/sh", ["-c", t.command]) }.value
                ok += 1
            }
            let adminTasks = chosen.filter(\.admin)
            if !adminTasks.isEmpty {
                if runAsAdmin(adminTasks.map(\.command).joined(separator: "; ")) { ok += adminTasks.count } else { fail += adminTasks.count }
            }
            try? await Task.sleep(for: .milliseconds(700))
            message = fail == 0 ? "\(ok) maintenance task\(ok == 1 ? "" : "s") completed." :
                "\(ok) completed. \(fail) need your administrator password — try again and approve the prompt."
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
        }
    }

    func removeAgents() {
        let chosen = agents.filter(\.selected)
        let uid = getuid()
        for a in chosen { shell("/bin/launchctl", ["bootout", "gui/\(uid)", a.url.path]) }
        _ = FS.trash(chosen.map(\.url))
        withAnimation { agents.removeAll { a in chosen.contains { $0.id == a.id } } }
    }

    func reset() { withAnimation(.smooth) { phase = .idle } }
}

// MARK: - Applications

struct AppEntry: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let size: Int64
    let lastUsed: Date?
    var leftovers: [FileItem]
    var selected = false
    var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { size + leftoverSize }
    var unused: Bool { lastUsed.map { $0 < Date().addingTimeInterval(-90 * 86400) } ?? false }
}

enum AppScanner {
    static let appDirs = [URL(fileURLWithPath: "/Applications"), home("Applications")]

    static func bundles(in dirs: [URL], depth: Int = 1) -> [URL] {
        var out: [URL] = []
        for d in dirs {
            for c in FS.children(d) {
                if c.pathExtension == "app" { out.append(c) }
                else if depth > 0, (try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    out += bundles(in: [c], depth: depth - 1)
                }
            }
        }
        return out
    }

    static func leftovers(bundleID: String, name: String) -> [FileItem] {
        var paths: [URL] = []
        let lib = home("Library")
        for sub in ["Application Support", "Caches", "Logs", "HTTPStorages", "WebKit", "Application Scripts", "Containers"] {
            paths.append(lib.appending(path: "\(sub)/\(bundleID)"))
            if name.count >= 4 && sub != "Containers" && sub != "Application Scripts" {
                paths.append(lib.appending(path: "\(sub)/\(name)"))
            }
        }
        paths.append(lib.appending(path: "Preferences/\(bundleID).plist"))
        paths.append(lib.appending(path: "Saved Application State/\(bundleID).savedState"))
        paths.append(lib.appending(path: "Cookies/\(bundleID).binarycookies"))
        for f in FS.children(lib.appending(path: "LaunchAgents")) where f.lastPathComponent.lowercased().hasPrefix(bundleID.lowercased()) {
            paths.append(f)
        }
        var seen = Set<String>()
        return paths.compactMap { u in
            guard FS.exists(u), !PrefKeys.isExcluded(u), seen.insert(u.path).inserted else { return nil }
            return FileItem(url: u, size: FS.size(of: u))
        }
    }

    static func scan() -> [AppEntry] {
        let own = Bundle.main.bundleIdentifier ?? ""
        return bundles(in: appDirs).compactMap { url in
            guard let b = Bundle(url: url), let id = b.bundleIdentifier,
                  !id.hasPrefix("com.apple."), id != own else { return nil }
            let name = (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? (b.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let version = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            let exe = b.executableURL ?? url
            let used = (NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date)
                ?? (try? exe.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
            return AppEntry(url: url, name: name, bundleID: id, version: version, size: FS.size(of: url),
                            lastUsed: used, leftovers: leftovers(bundleID: id, name: name))
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    /// Support files that look like they belong to apps that are no longer installed.
    static func orphans(installed: [String]) -> [FileItem] {
        var known = Set(installed.map { $0.lowercased() })
        for u in bundles(in: [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Applications/Utilities")], depth: 0) {
            if let id = Bundle(url: u)?.bundleIdentifier { known.insert(id.lowercased()) }
        }
        known.formUnion(runningBundleIDs())
        let prefixes = ["com.", "org.", "net.", "io.", "app.", "co.", "de.", "us."]
        let lib = home("Library")
        var out: [FileItem] = []
        for sub in ["Application Support", "Caches", "Preferences", "Saved Application State", "HTTPStorages", "WebKit"] {
            for f in FS.children(lib.appending(path: sub)) {
                var n = f.lastPathComponent.lowercased()
                for ext in [".plist", ".savedstate"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
                guard prefixes.contains(where: { n.hasPrefix($0) }), n.split(separator: ".").count >= 3,
                      !n.hasPrefix("com.apple."), !n.contains("supermac") else { continue }
                let vendor = n.split(separator: ".").prefix(2).joined(separator: ".")
                if known.contains(n) || known.contains(where: { n.hasPrefix($0) || $0.hasPrefix(n) || $0.hasPrefix(vendor + ".") }) { continue }
                let s = FS.size(of: f)
                if s > 0 { out.append(FileItem(url: f, size: s, selected: false, note: sub)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    enum Filter: String, CaseIterable { case all = "All Apps", unused = "Unused", large = "Large", leftovers = "Leftovers" }
    @Published var phase: Phase = .idle
    @Published var apps: [AppEntry] = []
    @Published var orphans: [FileItem] = []
    @Published var filter: Filter = .all
    @Published var search = ""
    @Published var message = ""
    @Published var freed: Int64 = 0

    var unusedCount: Int { apps.filter(\.unused).count }

    /// Drag-and-drop uninstall: select the dropped app (scanning first if needed).
    func dropped(_ url: URL) {
        Task {
            if phase != .results { await performScan(animated: false) }
            let path = url.standardizedFileURL.path
            guard let i = apps.firstIndex(where: { $0.url.standardizedFileURL.path == path }) else { return }
            withAnimation(.smooth) {
                for j in apps.indices { apps[j].selected = (j == i) }
                filter = .all
                search = apps[i].name
            }
        }
    }
    var selectedApps: [AppEntry] { apps.filter(\.selected) }
    var selectedSize: Int64 {
        selectedApps.reduce(0) { $0 + $1.totalSize } + (filter == .leftovers ? orphans.filter(\.selected).reduce(0) { $0 + $1.size } : 0)
    }

    func scan() { Task { await performScan(animated: true) } }

    func performScan(animated: Bool) async {
        withAnimation(.smooth) { phase = .scanning }
        let start = ContinuousClock.now
        let (a, o) = await Task.detached { () -> ([AppEntry], [FileItem]) in
            let a = AppScanner.scan()
            let ids = AppScanner.bundles(in: AppScanner.appDirs).compactMap { Bundle(url: $0)?.bundleIdentifier }
            return (a, AppScanner.orphans(installed: ids))
        }.value
        if animated { await minDelay(start, 1200) }
        withAnimation(.smooth(duration: 0.6)) { apps = a; orphans = o; phase = .results }
    }

    func uninstall() {
        Task {
            let chosen = selectedApps
            let orphanChosen = filter == .leftovers ? orphans.filter(\.selected) : []
            withAnimation(.smooth) { phase = .working }
            var removed = 0, failed: [String] = []
            freed = 0
            for app in chosen {
                for r in NSWorkspace.shared.runningApplications where r.bundleIdentifier == app.bundleID { r.terminate() }
            }
            if !chosen.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            var needAdmin: [AppEntry] = []
            for app in chosen {
                if FS.trash([app.url]).isEmpty {
                    _ = FS.trash(app.leftovers.map(\.url)); removed += 1; freed += app.totalSize
                } else { needAdmin.append(app) }
            }
            if !needAdmin.isEmpty {
                let trashDir = home(".Trash").path
                let cmd = needAdmin.map { "mv -f \(shellQuote($0.url.path)) \(shellQuote(trashDir + "/"))" }.joined(separator: "; ")
                _ = runAsAdmin(cmd)
                for app in needAdmin {
                    if FS.exists(app.url) { failed.append(app.name) }
                    else { _ = FS.trash(app.leftovers.map(\.url)); removed += 1; freed += app.totalSize }
                }
            }
            let of = FS.trash(orphanChosen.map(\.url))
            freed += orphanChosen.filter { !of.contains($0.url) }.reduce(0) { $0 + $1.size }
            History.shared.log(removed > 0 ? "Uninstalled \(removed) app\(removed == 1 ? "" : "s")" : "Removed app leftovers", freed)
            try? await Task.sleep(for: .milliseconds(600))
            let removedIDs = Set(chosen.filter { !failed.contains($0.name) }.map(\.id))
            apps.removeAll { removedIDs.contains($0.id) }
            orphans.removeAll { o in orphanChosen.contains { $0.id == o.id } && !of.contains(o.url) }
            message = failed.isEmpty
                ? "Removed \(removed) app\(removed == 1 ? "" : "s")\(orphanChosen.isEmpty ? "" : " and \(orphanChosen.count) leftovers"). Everything is in the Trash if you change your mind."
                : "\(removed > 0 ? "Removed \(removed) app\(removed == 1 ? "" : "s"). " : "")Couldn't remove: \(failed.joined(separator: ", "))."
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
        }
    }

    func back() { withAnimation(.smooth) { phase = .results } }
}

// MARK: - My Clutter

struct DupGroup: Identifiable {
    let id = UUID()
    var items: [FileItem]
    var wasted: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
}

enum ClutterScanner {
    static let skipTop: Set<String> = ["Library", ".Trash"]

    static func walk(_ roots: [URL], minSize: Int64, _ visit: (URL, Int64, Date?) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        let excluded = PrefKeys.excluded
        for root in roots where !PrefKeys.isExcluded(root) {
            guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                if !excluded.isEmpty && PrefKeys.isExcluded(u) { e.skipDescendants(); continue }
                guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                if s >= minSize { visit(u, s, v.contentAccessDate ?? v.contentModificationDate) }
            }
        }
    }

    static func homeRoots() -> [URL] {
        FS.children(homeURL).filter {
            !skipTop.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") &&
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    static func large() -> [FileItem] {
        var out: [FileItem] = []
        walk(homeRoots(), minSize: 100 << 20) { u, s, d in
            out.append(FileItem(url: u, size: s, selected: false, note: u.pathExtension.uppercased(), date: d))
        }
        return out.sorted { $0.size > $1.size }
    }

    static func installers() -> [FileItem] {
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
        return FS.children(home("Downloads")).filter { exts.contains($0.pathExtension.lowercased()) && !PrefKeys.isExcluded($0) }.map {
            FileItem(url: $0, size: FS.size(of: $0), selected: true, note: $0.pathExtension.uppercased(), date: FS.modified($0))
        }.sorted { $0.size > $1.size }
    }

    static func duplicates() -> [DupGroup] {
        let roots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home($0) }
        var bySize: [Int64: [(URL, Date?)]] = [:]
        walk(roots, minSize: 512 << 10) { u, s, d in bySize[s, default: []].append((u, d)) }
        var groups: [DupGroup] = []
        for (size, files) in bySize where files.count > 1 {
            var byHash: [String: [(URL, Date?)]] = [:]
            for f in files { if let h = FS.sha256(f.0) { byHash[h, default: []].append(f) } }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
                let items = sorted.enumerated().map { i, f in
                    FileItem(url: f.0, size: size, selected: i > 0, note: i == 0 ? "Original" : "Copy", date: f.1)
                }
                groups.append(DupGroup(items: items))
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }
}

@MainActor
final class ClutterModel: ObservableObject {
    enum Tab: String, CaseIterable { case large = "Large & Old Files", duplicates = "Duplicates", installers = "Old Installers" }
    @Published var phase: Phase = .idle
    @Published var tab: Tab = .large
    @Published var large: [FileItem] = []
    @Published var dups: [DupGroup] = []
    @Published var installers: [FileItem] = []
    @Published var status = ""
    @Published var message = ""
    @Published var freed: Int64 = 0

    /// Only the current tab's selection is shown on the button and acted on.
    var selectedItems: [FileItem] {
        switch tab {
        case .large: large.filter(\.selected)
        case .duplicates: dups.flatMap { $0.items.filter(\.selected) }
        case .installers: installers.filter(\.selected)
        }
    }
    var selectedSize: Int64 {
        var seen = Set<URL>()
        return selectedItems.filter { seen.insert($0.url).inserted }.reduce(0) { $0 + $1.size }
    }
    var dupWasted: Int64 { dups.reduce(0) { $0 + $1.wasted } }

    func scan() { Task { await performScan(animated: true, full: true) } }

    func performScan(animated: Bool, full: Bool) async {
        withAnimation(.smooth) { phase = .scanning }
        let start = ContinuousClock.now
        status = "Looking for large files…"
        let l = await Task.detached(priority: .userInitiated) { ClutterScanner.large() }.value
        status = "Checking your Downloads…"
        let i = await Task.detached(priority: .userInitiated) { ClutterScanner.installers() }.value
        var d: [DupGroup] = []
        if full {
            status = "Comparing files for duplicates…"
            d = await Task.detached(priority: .userInitiated) { ClutterScanner.duplicates() }.value
        }
        if animated { await minDelay(start, 1500) }
        withAnimation(.smooth(duration: 0.6)) { large = l; installers = i; dups = d; phase = .results }
    }

    func remove() {
        Task {
            var seen = Set<URL>()
            let chosen = selectedItems.filter { seen.insert($0.url).inserted }
            withAnimation(.smooth) { phase = .working }
            let failed = Set(FS.trash(chosen.map(\.url)))
            freed = chosen.filter { !failed.contains($0.url) }.reduce(0) { $0 + $1.size }
            History.shared.log("Clutter moved to Trash", freed)
            try? await Task.sleep(for: .milliseconds(800))
            let gone = Set(chosen.map(\.url)).subtracting(failed)
            large.removeAll { gone.contains($0.url) }
            installers.removeAll { gone.contains($0.url) }
            for g in dups.indices { dups[g].items.removeAll { gone.contains($0.url) } }
            dups.removeAll { $0.items.count < 2 }
            message = failed.isEmpty ? "Moved \(chosen.count) file\(chosen.count == 1 ? "" : "s") to the Trash."
                : "\(chosen.count - failed.count) moved to the Trash, \(failed.count) couldn't be moved."
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
        }
    }

    func back() { withAnimation(.smooth) { phase = .results } }
}

// MARK: - Space Lens

struct LensNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let isDir: Bool
    var name: String { url.lastPathComponent }
}

@MainActor
final class LensModel: ObservableObject {
    @Published var path: [URL] = []
    @Published var nodes: [LensNode] = []
    @Published var loading = false
    @Published var done = 0
    @Published var totalChildren = 0
    private var cache: [URL: [LensNode]] = [:]
    private var loadTask: Task<Void, Never>?

    var current: URL? { path.last }
    var total: Int64 { nodes.reduce(0) { $0 + $1.size } }

    func open(_ url: URL, push: Bool = true) {
        if push { path.append(url) }
        loadTask?.cancel()
        if let c = cache[url] { withAnimation(.smooth) { nodes = c }; loading = false; return }
        nodes = []; loading = true; done = 0
        let kids = FS.children(url).filter { $0.lastPathComponent != ".DS_Store" }
        totalChildren = kids.count
        loadTask = Task {
            await withTaskGroup(of: LensNode.self) { group in
                for k in kids {
                    group.addTask(priority: .userInitiated) {
                        let isDir = (try? k.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
                        return LensNode(url: k, size: FS.size(of: k), isDir: isDir)
                    }
                }
                for await n in group {
                    if Task.isCancelled { return }
                    done += 1
                    if n.size > 0 {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                            nodes.append(n); nodes.sort { $0.size > $1.size }
                        }
                    }
                }
            }
            if !Task.isCancelled { cache[url] = nodes; loading = false }
        }
    }

    func back(to index: Int) {
        guard index < path.count else { return }
        path = Array(path.prefix(index + 1))
        open(path[index], push: false)
    }

    func trash(_ node: LensNode) {
        if FS.trash([node.url]).isEmpty {
            withAnimation { nodes.removeAll { $0.id == node.id } }
            cache = [:]
            if let c = current { cache[c] = nodes }
        }
    }
}

// MARK: - Smart Care

@MainActor
final class SmartCareModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var step = ""
    @Published var stepIndex = 0
    @Published var freed: Int64 = 0
    @Published var summary: [String] = []

    func scan(_ s: AppState) {
        Task {
            withAnimation(.smooth) { phase = .scanning; stepIndex = 0 }
            let steps: [(String, () async -> Void)] = [
                ("Looking for junk", { await s.cleanup.performScan(animated: false) }),
                ("Checking for threats & privacy", { await s.protection.performScan(animated: false) }),
                ("Analysing performance", { await s.performance.performScan(animated: false) }),
                ("Reviewing applications", { await s.apps.performScan(animated: false) }),
                ("Searching for clutter", { await s.clutter.performScan(animated: false, full: false) }),
            ]
            for (i, st) in steps.enumerated() {
                withAnimation { step = st.0; stepIndex = i }
                let start = ContinuousClock.now
                await st.1()
                await minDelay(start, 700)
            }
            withAnimation { stepIndex = steps.count }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.smooth(duration: 0.7)) { phase = .results }
        }
    }

    func run(_ s: AppState) {
        Task {
            withAnimation(.smooth) { phase = .working }
            summary = []
            let before = SysInfo.disk().free
            await s.cleanup.performClean()
            freed = s.cleanup.freed
            summary.append("Removed \(fmt(s.cleanup.freed)) of junk")
            let threats = s.protection.threats.filter(\.selected).map(\.url).filter { $0.path.hasPrefix(homePath) }
            if !threats.isEmpty {
                _ = FS.trash(threats)
                s.protection.threats.removeAll { threats.contains($0.url) }
                summary.append("Removed \(threats.count) suspicious item\(threats.count == 1 ? "" : "s")")
            }
            _ = await Task.detached { shell("/usr/bin/qlmanage", ["-r", "cache"]) }.value
            summary.append("Refreshed Quick Look thumbnails")
            let after = SysInfo.disk().free
            if after > before { freed = max(freed, after - before) }
            s.stats.tick()
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { phase = .done }
        }
    }

    func reset(_ s: AppState) {
        s.cleanup.reset()
        withAnimation(.smooth) { phase = .idle }
    }
}

// MARK: - Root state

@MainActor
final class AppState: ObservableObject {
    enum Page: Equatable { case settings, about }
    @Published var module: Module = .smartCare
    @Published var page: Page? = nil
    @Published var showPalette = false
    @Published var settingsTab: SettingsTab = .general
    let stats = LiveStats()
    let smart = SmartCareModel()
    let cleanup = CleanupModel()
    let protection = ProtectionModel()
    let performance = PerformanceModel()
    let apps = AppsModel()
    let clutter = ClutterModel()
    let lens = LensModel()
    private var bag: [AnyCancellable] = []

    /// Child models publish their own changes; re-publish them so any view observing AppState stays current.
    init() {
        let children: [ObservableObjectPublisher] = [
            stats.objectWillChange, smart.objectWillChange, cleanup.objectWillChange, protection.objectWillChange,
            performance.objectWillChange, apps.objectWillChange, clutter.objectWillChange, lens.objectWillChange,
            Prefs.shared.objectWillChange, History.shared.objectWillChange, Automation.shared.objectWillChange,
        ]
        for c in children {
            c.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }
}
