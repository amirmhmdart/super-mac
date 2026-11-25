import SwiftUI
import Combine
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - App info

enum AppInfo {
    static let version = "0.9"
    static let label = "v0.9 beta"
    static let repo = "amirmhmdart/super-mac"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases/latest")!
}

// MARK: - Preferences (UserDefaults-backed; readable from background threads through `Prefs.raw`)

enum Frequency: String, CaseIterable, Identifiable, Codable {
    case off, daily, weekly, monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        }
    }
    var days: Int { switch self { case .off: 0; case .daily: 1; case .weekly: 7; case .monthly: 30 } }
}

/// Plain reads that are safe from any thread (scanners run detached).
enum PrefKeys {
    static let d = UserDefaults.standard
    static var excluded: [String] { d.stringArray(forKey: "excluded") ?? [] }
    static var disabledKinds: Set<String> { Set(d.stringArray(forKey: "disabledKinds") ?? []) }
    static var tempAgeDays: Int { max(1, d.object(forKey: "tempAgeDays") as? Int ?? 1) }

    static func isExcluded(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return excluded.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// True when an ignored item lives somewhere inside `url`.
    static func holdsExcluded(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let inside = p.hasSuffix("/") ? p : p + "/"
        return excluded.contains { $0.hasPrefix(inside) }
    }

    /// True when `url` is ignored or holds an ignored item, so it must not be removed as a whole.
    static func mustKeep(_ url: URL) -> Bool { isExcluded(url) || holdsExcluded(url) }

    /// What can be removed without touching the Ignore List: `url` itself, or the pieces around the ignored items inside it.
    static func removable(_ url: URL) -> [URL] {
        if isExcluded(url) { return [] }
        guard holdsExcluded(url) else { return [url] }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return [] }
        return FS.children(url).flatMap(removable)
    }
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    // General
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock"); applyDock() } }
    @Published var menuBarFreeSpace: Bool { didSet { d.set(menuBarFreeSpace, forKey: "menuBarFreeSpace") } }
    @Published var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: "reduceMotion") } }
    @Published var launchAtLogin: Bool = false

    // Automation
    @Published var autoScan: Frequency { didSet { d.set(autoScan.rawValue, forKey: "autoScan") } }
    @Published var autoHour: Int { didSet { d.set(autoHour, forKey: "autoHour") } }
    @Published var autoClean: Bool { didSet { d.set(autoClean, forKey: "autoClean") } }
    @Published var autoCleanMinMB: Int { didSet { d.set(autoCleanMinMB, forKey: "autoCleanMinMB") } }
    @Published var lastAutoRun: Date? { didSet { d.set(lastAutoRun, forKey: "lastAutoRun") } }

    // Alerts
    @Published var lowDiskAlert: Bool { didSet { d.set(lowDiskAlert, forKey: "lowDiskAlert") } }
    @Published var lowDiskGB: Int { didSet { d.set(lowDiskGB, forKey: "lowDiskGB") } }
    @Published var trashAlert: Bool { didSet { d.set(trashAlert, forKey: "trashAlert") } }
    @Published var trashGB: Int { didSet { d.set(trashGB, forKey: "trashGB") } }
    @Published var memoryAlert: Bool { didSet { d.set(memoryAlert, forKey: "memoryAlert") } }
    @Published var downloadsAlert: Bool { didSet { d.set(downloadsAlert, forKey: "downloadsAlert") } }
    @Published var downloadsGB: Int { didSet { d.set(downloadsGB, forKey: "downloadsGB") } }

    // Cleanup
    @Published var disabledKinds: Set<String> { didSet { d.set(Array(disabledKinds), forKey: "disabledKinds") } }
    @Published var tempAgeDays: Int { didSet { d.set(tempAgeDays, forKey: "tempAgeDays") } }
    @Published var excluded: [String] { didSet { d.set(excluded, forKey: "excluded") } }

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        showInDock = b("showInDock", true)
        menuBarFreeSpace = b("menuBarFreeSpace", false)
        reduceMotion = b("reduceMotion", false)
        autoScan = Frequency(rawValue: d.string(forKey: "autoScan") ?? "") ?? .off
        autoHour = i("autoHour", 11)
        autoClean = b("autoClean", false)
        autoCleanMinMB = i("autoCleanMinMB", 500)
        lastAutoRun = d.object(forKey: "lastAutoRun") as? Date
        lowDiskAlert = b("lowDiskAlert", true)
        lowDiskGB = i("lowDiskGB", 15)
        trashAlert = b("trashAlert", true)
        trashGB = i("trashGB", 5)
        memoryAlert = b("memoryAlert", false)
        downloadsAlert = b("downloadsAlert", true)
        downloadsGB = i("downloadsGB", 10)
        disabledKinds = Set(d.stringArray(forKey: "disabledKinds") ?? [])
        tempAgeDays = i("tempAgeDays", 1)
        excluded = d.stringArray(forKey: "excluded") ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func isEnabled(_ k: JunkKind) -> Bool { !disabledKinds.contains(k.rawValue) }
    func setEnabled(_ k: JunkKind, _ on: Bool) {
        if on { disabledKinds.remove(k.rawValue) } else { disabledKinds.insert(k.rawValue) }
    }

    func applyDock() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
        if showInDock { NSApp?.activate(ignoringOtherApps: true) }
    }

    /// Returns an error message when macOS refuses (e.g. the app isn't in /Applications).
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return "macOS didn't allow it. Move Super Mac to Applications and try again."
        }
    }

    var nextAutoRun: Date? {
        guard autoScan != .off else { return nil }
        let cal = Calendar.current
        let base = lastAutoRun.map { cal.date(byAdding: .day, value: autoScan.days, to: $0)! } ?? Date()
        var c = cal.dateComponents([.year, .month, .day], from: base)
        c.hour = autoHour; c.minute = 0
        var when = cal.date(from: c) ?? base
        if lastAutoRun == nil, when < Date() { when = cal.date(byAdding: .day, value: 1, to: when)! }
        return when
    }

    func addExclusion() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.prompt = "Exclude"
        p.message = "Super Mac will never touch anything inside these items."
        if p.runModal() == .OK {
            for u in p.urls where !excluded.contains(u.standardizedFileURL.path) { excluded.append(u.standardizedFileURL.path) }
        }
    }
}

// MARK: - History (every clean is logged so users see what Super Mac did)

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var title: String
    var bytes: Int64
    var automatic: Bool
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var entries: [HistoryEntry] = []
    private let key = "history.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([HistoryEntry].self, from: data) { entries = e }
    }

    var totalFreed: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var cleans: Int { entries.count }

    func log(_ title: String, _ bytes: Int64, automatic: Bool = false) {
        guard bytes > 0 else { return }
        entries.insert(HistoryEntry(date: Date(), title: title, bytes: bytes, automatic: automatic), at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
        save()
    }

    func clear() { entries = []; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Freed bytes for each of the last `days` days (oldest first).
    func daily(_ days: Int = 14) -> [(Date, Int64)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { off in
            let day = cal.date(byAdding: .day, value: -off, to: today)!
            let sum = entries.filter { cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.bytes }
            return (day, sum)
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Automation: scheduled scans, auto-clean and watchdog alerts

@MainActor
final class Automation: ObservableObject {
    static let shared = Automation()
    @Published var running = false
    @Published var lastResult: String?
    @Published var trashSize: Int64 = 0
    private var timer: Timer?
    private var lastAlert: [String: Date] = [:]
    private let launched = Date()
    private var wakeObserver: NSObjectProtocol?

    /// Only the categories that apps rebuild on their own — never the Trash, iOS backups or developer data.
    static let autoKinds: [JunkKind] = [.caches, .logs, .temp, .savedState]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Automation.shared.tick() }
        }
        // A schedule missed while the Mac slept runs shortly after it wakes.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(90))
                    Automation.shared.tick()
                }
            }
        }
        DiskForecast.shared.sample()
        Task.detached(priority: .background) {
            let size = FS.size(of: home(".Trash"))
            await MainActor.run { Automation.shared.trashSize = size }
        }
    }

    func tick() {
        let p = Prefs.shared
        // Give the Mac a couple of minutes after login before doing anything heavy.
        if let next = p.nextAutoRun, Date() >= next, !running, Date().timeIntervalSince(launched) > 120 {
            Task { await runNow(automatic: true) }
        }
        DiskForecast.shared.sample()
        watchdog()
    }

    func runNow(automatic: Bool, forceClean: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let p = Prefs.shared
        let kinds = Automation.autoKinds.filter { p.isEnabled($0) }
        let running = runningBundleIDs()
        let items = await Task.detached(priority: .utility) { kinds.flatMap { JunkScanner.scan($0, running: running) } }.value
        let found = items.reduce(0) { $0 + $1.size }
        if automatic { p.lastAutoRun = Date() }

        if forceClean || (p.autoClean && found >= Int64(p.autoCleanMinMB) << 20) {
            let left = await Task.detached(priority: .utility) { items.reduce(Int64(0)) { $0 + JunkScanner.remove($1) } }.value
            let freed = max(0, found - left)
            History.shared.log(automatic ? "Automatic cleanup" : "Quick Clean", freed, automatic: automatic)
            lastResult = "Cleaned \(fmt(freed))\(automatic ? " automatically" : "")"
            Notifier.post("Super Mac cleaned up", "Freed \(fmt(freed)) of caches, logs and temp files. Nothing personal was touched.")
        } else if automatic && found > 100 << 20 {
            lastResult = "Found \(fmt(found)) of junk"
            Notifier.post("\(fmt(found)) of junk found", "Open Super Mac to review and clean it.")
        } else {
            lastResult = "All clean — nothing worth removing"
        }
    }

    private func throttle(_ key: String, hours: Double) -> Bool {
        if let t = lastAlert[key], Date().timeIntervalSince(t) < hours * 3600 { return false }
        lastAlert[key] = Date()
        return true
    }

    func watchdog() {
        let p = Prefs.shared
        let disk = SysInfo.disk()
        if p.lowDiskAlert, disk.total > 0, disk.free < Int64(p.lowDiskGB) << 30, throttle("disk", hours: 6) {
            Notifier.post("Your disk is almost full", "Only \(fmt(disk.free)) left. Open Super Mac to free up space.")
        }
        if p.downloadsAlert, throttle("downloadsCheck", hours: 24) {
            Task.detached(priority: .background) {
                let size = FS.size(of: home("Downloads"))
                await MainActor.run {
                    if size > Int64(Prefs.shared.downloadsGB) << 30 {
                        Notifier.post("Downloads is getting big", "It's holding \(fmt(size)). My Clutter can find old installers and large files there.")
                    }
                }
            }
        }
        if p.trashAlert, throttle("trashCheck", hours: 12) {
            Task.detached(priority: .background) {
                let size = FS.size(of: home(".Trash"))
                await MainActor.run {
                    Automation.shared.trashSize = size
                    if size > Int64(Prefs.shared.trashGB) << 30 {
                        Notifier.post("Your Trash is holding \(fmt(size))", "Empty it from Super Mac › Cleanup to get that space back.")
                    }
                }
            }
        }
        if p.memoryAlert {
            let m = SysInfo.memoryUsed(), t = SysInfo.memoryTotal
            if t > 0, Double(m) / Double(t) > 0.92, throttle("mem", hours: 2) {
                Notifier.post("Memory is running low", "Close a few heavy apps, or open Super Mac › Performance.")
            }
        }
    }
}

// MARK: - Update check (GitHub releases)

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(String), failed }
    @Published var state: State = .idle

    func check() {
        state = .checking
        Task {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { state = .failed; return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).components(separatedBy: "-")[0]
            state = latest.compare(AppInfo.version, options: .numeric) == .orderedDescending ? .available(tag) : .upToDate
        }
    }
}

// MARK: - Disk forecast (one free-space sample per day, linear trend)

@MainActor
final class DiskForecast: ObservableObject {
    static let shared = DiskForecast()
    struct Sample: Codable { var day: Date; var free: Int64 }
    @Published private(set) var samples: [Sample] = []
    private let key = "diskSamples.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode([Sample].self, from: data) { samples = s }
    }

    func sample() {
        let today = Calendar.current.startOfDay(for: Date())
        let free = SysInfo.disk().free
        guard free > 0 else { return }
        if let i = samples.firstIndex(where: { $0.day == today }) { samples[i].free = free }
        else { samples.append(Sample(day: today, free: free)) }
        if samples.count > 90 { samples.removeFirst(samples.count - 90) }
        if let data = try? JSONEncoder().encode(samples) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Bytes per day (negative = filling up), from a least-squares fit. Needs a few days of data.
    var dailyChange: Double? {
        guard samples.count >= 3, let first = samples.first?.day,
              let last = samples.last?.day, last.timeIntervalSince(first) >= 2 * 86400 else { return nil }
        let xs = samples.map { $0.day.timeIntervalSince(first) / 86400 }, ys = samples.map { Double($0.free) }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den > 0 ? num / den : nil
    }

    /// Days until the disk is full at the current pace, or nil if it isn't filling up.
    var daysLeft: Int? {
        guard let c = dailyChange, c < -50_000_000 else { return nil }
        return Int(Double(SysInfo.disk().free) / -c)
    }

    var summary: String {
        guard let c = dailyChange else { return "Super Mac is learning how your disk is used. A forecast appears after a few days." }
        if let d = daysLeft {
            return d > 365 ? "Your disk is filling slowly — more than a year of room left at this pace."
                : "You use about \(fmt(Int64(-c))) a day. At this pace your disk is full in ~\(d) days."
        }
        return c > 0 ? "Free space is growing — nice. You gain about \(fmt(Int64(c))) a day." : "Your free space is steady."
    }
}

// MARK: - Mac Health score

struct HealthReport {
    var score: Int
    var notes: [String]
    var label: String {
        switch score { case 90...: "Excellent"; case 75..<90: "Good"; case 55..<75: "Fair"; default: "Needs care" }
    }
    var colors: [Color] {
        switch score { case 90...: [.mint, .teal]; case 75..<90: [.aqua, .sky]; case 55..<75: [.amber, .coral]; default: [.coral, .rose] }
    }

    @MainActor static func compute(_ s: AppState) -> HealthReport {
        var score = 100, notes: [String] = []
        let u = s.stats.disk.usedFraction
        if u > 0.9 { score -= 30; notes.append("Disk is over 90% full") }
        else if u > 0.8 { score -= 15; notes.append("Disk is over 80% full") }
        else if u > 0.7 { score -= 5 }
        if let d = DiskForecast.shared.daysLeft, d < 60 { score -= 10; notes.append("Disk full in ~\(d) days at this pace") }
        let m = s.stats.memFraction
        if m > 0.9 { score -= 12; notes.append("Memory is under pressure") } else if m > 0.82 { score -= 5 }
        if s.cleanup.phase == .results || s.smart.phase == .results {
            let j = s.cleanup.total
            if j > 5 << 30 { score -= 15; notes.append("\(fmt(j)) of junk") } else if j > 1 << 30 { score -= 8; notes.append("\(fmt(j)) of junk") }
        }
        if !s.protection.threats.isEmpty { score -= 20; notes.append("\(s.protection.threats.count) suspicious items") }
        if Automation.shared.trashSize > Int64(Prefs.shared.trashGB) << 30 { score -= 6; notes.append("Trash holds \(fmt(Automation.shared.trashSize))") }
        if Prefs.shared.autoScan == .off { score -= 4; notes.append("Autopilot is off") }
        return HealthReport(score: max(5, min(100, score)), notes: notes)
    }
}
