import SwiftUI
import AppKit

let phaseTransition = AnyTransition.asymmetric(
    insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 18)),
    removal: .opacity.combined(with: .scale(scale: 1.03)))

// MARK: - Smart Care

struct SmartCareScreen: View {
    @ObservedObject var s: AppState
    var m: SmartCareModel { s.smart }

    var body: some View {
        ZStack {
            switch m.phase {
            case .idle:
                ModuleLanding(module: .smartCare, action: { m.scan(s) }) {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            HealthBadge(s: s)
                            HealthStrip(stats: s.stats)
                        }
                        AutopilotChip(s: s)
                    }
                }
            case .scanning:
                SmartScanning(m: m)
            case .results:
                SmartResults(s: s)
            case .working:
                WorkingScreen(module: .smartCare, title: "Running Smart Care…", progress: s.cleanup.phase == .working ? s.cleanup.progress : nil,
                              detail: s.cleanup.current)
            case .done:
                DoneScreen(module: .smartCare, big: fmt(m.freed), subtitle: "freed up — your Mac is in great shape.",
                           lines: m.summary) { m.reset(s) }
            }
        }
        .id(m.phase).transition(phaseTransition)
    }
}

struct HealthStrip: View {
    @ObservedObject var stats: LiveStats
    var body: some View {
        HStack(spacing: 14) {
            gauge("Disk", stats.disk.usedFraction, "\(fmt(stats.disk.free)) free", [.aqua, .sky])
            gauge("Memory", stats.memFraction, "\(fmt(Int64(stats.memUsed))) used", [.violet, .pinkish])
            gauge("CPU", stats.cpu, "\(Int(stats.cpu * 100))% load", [.amber, .coral])
        }
    }
    func gauge(_ t: String, _ v: Double, _ d: String, _ c: [Color]) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Ring(value: v, colors: c, lineWidth: 5).frame(width: 34, height: 34)
                Text("\(Int(v * 100))").font(.system(size: 10, weight: .bold)).contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.system(size: 12, weight: .bold)).lineLimit(1).fixedSize()
                Text(d).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).contentTransition(.numericText()).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9).glass(14)
        .fixedSize()
        .animation(.smooth, value: v)
    }
}

struct SmartScanning: View {
    @ObservedObject var m: SmartCareModel
    let steps: [Module] = [.cleanup, .protection, .performance, .applications, .clutter]
    var body: some View {
        HStack(spacing: 60) {
            ZStack {
                SpinnerRing(colors: Module.smartCare.colors, size: 300)
                ArtView(module: .smartCare, size: 200).modifier(Breathing())
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Scanning your Mac…").font(.system(size: 26, weight: .bold))
                Text(m.step).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).padding(.bottom, 6)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, mod in
                    let done = i < m.stepIndex, now = i == m.stepIndex
                    HStack(spacing: 14) {
                        ArtView(module: mod, size: 36)
                        Text(mod.title).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        ZStack {
                            if done {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(Color.mint)
                                    .transition(.scale.combined(with: .opacity))
                            } else if now { ProgressView().controlSize(.small) }
                            else { Circle().strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3])).frame(width: 17, height: 17) }
                        }.frame(width: 24)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).glass(14)
                    .opacity(done || now ? 1 : 0.45).scaleEffect(now ? 1.03 : 1)
                }
            }
            .frame(width: 340)
        }
    }
}

struct SmartResults: View {
    @ObservedObject var s: AppState
    var body: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .smartCare, title: "Here's what we found",
                          subtitle: "Run cleans junk and fixes safe issues. Review anything else on your own terms.")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                    tile(0, .cleanup, value: fmt(s.cleanup.total), status: s.cleanup.total > 0 ? "Junk to clean" : "Already clean",
                         good: s.cleanup.total == 0, run: true)
                    tile(1, .protection, value: s.protection.threats.isEmpty ? "No threats" : "\(s.protection.threats.count) found",
                         status: "\(s.protection.privacy.count) privacy items to review", good: s.protection.threats.isEmpty,
                         run: !s.protection.threats.isEmpty)
                    tile(2, .performance, value: "\(s.performance.tasks.filter(\.selected).count) tasks",
                         status: "Maintenance recommended", good: false, run: false)
                    tile(3, .applications, value: "\(s.apps.apps.count) apps",
                         status: "\(s.apps.unusedCount) unused for 3+ months", good: s.apps.unusedCount == 0, run: false)
                    tile(4, .clutter, value: fmt(s.clutter.large.reduce(0) { $0 + $1.size } + s.clutter.installers.reduce(0) { $0 + $1.size }),
                         status: "\(s.clutter.large.count) large files, \(s.clutter.installers.count) installers", good: false, run: false)
                    autopilotTile
                }
                .padding(.horizontal, 32).padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            BottomBar(module: .smartCare, title: "Run", detail: fmt(s.cleanup.selected), disabled: false, action: { s.smart.run(s) }) {
                Button { s.smart.scan(s) } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    var autopilotTile: some View {
        let p = Prefs.shared
        return AppearCard(index: 5) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    PageArt(name: "automation", symbol: "clock.arrow.2.circlepath", colors: [.sky, .violet], size: 64)
                    Spacer()
                    if p.autoScan != .off { TagPill(text: "ON", color: .mint) }
                }
                Text("Autopilot").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text(p.autoScan == .off ? "Off" : p.autoScan.title).font(.system(size: 26, weight: .heavy))
                Text(p.autoScan == .off ? "Let Super Mac keep things tidy for you" : (p.autoClean ? "Scans and cleans on its own" : "Scans and lets you know"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Button { withAnimation(.smooth) { s.settingsTab = .automation; s.page = .settings } } label: {
                    HStack(spacing: 4) { Text(p.autoScan == .off ? "Set up" : "Edit"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func tile(_ i: Int, _ mod: Module, value: String, status: String, good: Bool, run: Bool) -> some View {
        AppearCard(index: i) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ArtView(module: mod, size: 64)
                    Spacer()
                    if run { TagPill(text: "INCLUDED IN RUN", color: .mint) }
                    else if good { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.mint) }
                }
                Text(mod.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.system(size: 26, weight: .heavy))
                Text(status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Button { withAnimation(.smooth) { s.module = mod } } label: {
                    HStack(spacing: 4) { Text("Review"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppearCard<C: View>: View {
    let index: Int
    @ViewBuilder var content: () -> C
    @State private var appeared = false
    @State private var hover = false
    var body: some View {
        content()
            .glass(22)
            .scaleEffect(hover ? 1.02 : 1)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 26)
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
            .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.07)) { appeared = true } }
    }
}

// MARK: - Cleanup

struct CleanupScreen: View {
    @ObservedObject var m: CleanupModel
    @State private var detail: JunkKind?
    @State private var confirm = false

    var body: some View {
        ZStack {
            switch m.phase {
            case .idle:
                ModuleLanding(module: .cleanup, action: m.scan)
            case .scanning:
                ScanningScreen(module: .cleanup, title: "Looking for junk…",
                               detail: "\(m.scanningNow?.title ?? "Finishing up") · \(fmt(m.found)) found")
            case .results:
                results
            case .working:
                WorkingScreen(module: .cleanup, title: "Sweeping things up…", progress: m.progress, detail: m.current)
            case .done:
                DoneScreen(module: .cleanup, big: fmt(m.freed), subtitle: "of junk cleaned up"
                    + (m.skipped > 0 ? " · \(m.skipped) items in use or ignored were left alone" : "")) { m.reset() }
            }
        }
        .id(m.phase).transition(phaseTransition)
    }

    @ViewBuilder var results: some View {
        if m.groups.isEmpty {
            VStack(spacing: 18) {
                EmptyState(symbol: "checkmark.seal.fill", title: "Already spotless", subtitle: "Nothing worth cleaning right now.")
                Button("Back") { m.reset() }.buttonStyle(GhostButtonStyle())
            }
        } else {
            VStack(spacing: 0) {
                ResultsHeader(module: .cleanup, title: "\(fmt(m.total)) of junk", subtitle: "Pick what to remove. Apps recreate these files whenever they need them.")
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(Array($m.groups.enumerated()), id: \.element.id) { i, $g in
                            AppearCard(index: i) { JunkCard(group: $g) { detail = g.kind } }
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                BottomBar(module: .cleanup, title: "Clean", detail: fmt(m.selected), disabled: m.selected == 0, action: { confirm = true }) {
                    Button { m.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
                }
            }
            .sheet(item: $detail) { k in
                if let i = m.groups.firstIndex(where: { $0.kind == k }) { JunkDetail(group: $m.groups[i]) }
            }
            .alert("Clean \(fmt(m.selected))?", isPresented: $confirm) {
                Button("Clean", role: .destructive) { m.clean() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Caches, logs and temporary files are rebuilt automatically. Anything in use is skipped."
                     + (m.includesTrash ? "\n\nItems in the Trash will be deleted permanently." : ""))
            }
        }
    }
}

struct KindTile: View {
    let kind: JunkKind
    var size: CGFloat = 46
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: kind.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
            .overlay(Image(systemName: kind.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: kind.colors[0].opacity(0.5), radius: 10, y: 4)
    }
}

struct JunkCard: View {
    @Binding var group: JunkGroup
    var onDetails: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                KindTile(kind: group.kind)
                Spacer()
                Toggle("", isOn: $group.enabled.animation(.spring)).toggleStyle(.switch).labelsHidden().tint(group.kind.colors[0])
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(group.kind.title).font(.system(size: 16, weight: .bold))
                Text(group.kind.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(fmt(group.size)).font(.system(size: 24, weight: .heavy)).contentTransition(.numericText())
                Spacer()
                Button(action: onDetails) {
                    HStack(spacing: 4) { Text("\(group.selectedCount) items"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(18)
        .saturation(group.enabled ? 1 : 0.15).opacity(group.enabled ? 1 : 0.6)
    }
}

struct JunkDetail: View {
    @Binding var group: JunkGroup
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                KindTile(kind: group.kind, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.kind.title).font(.system(size: 18, weight: .bold))
                    Text("\(group.selectedCount) of \(group.items.count) selected · \(fmt(group.size))")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                let all = group.selectedCount == group.items.count
                Button(all ? "Deselect All" : "Select All") { for i in group.items.indices { group.items[i].selected = !all } }
                    .buttonStyle(GhostButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(colors: group.kind.colors)).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach($group.items) { $item in FileRow(item: $item, tint: group.kind.colors[0]) }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(width: 680, height: 560)
        .background(Color(hex: 0x15122A))
        .foregroundStyle(.white)
    }
}

// MARK: - Protection

struct ProtectionScreen: View {
    @ObservedObject var m: ProtectionModel
    var body: some View {
        ZStack {
            switch m.phase {
            case .idle: ModuleLanding(module: .protection, action: m.scan)
            case .scanning: ScanningScreen(module: .protection, title: "Checking your Mac…", detail: "Launch agents, browsers and recent items")
            case .results: results
            case .working: WorkingScreen(module: .protection, title: "Securing your Mac…")
            case .done: DoneScreen(module: .protection, big: "All set", subtitle: m.message, buttonTitle: "Back") { m.scan() }
            }
        }
        .id(m.phase).transition(phaseTransition)
    }

    var results: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .protection, title: m.threats.isEmpty ? "No threats found" : "\(m.threats.count) suspicious item\(m.threats.count == 1 ? "" : "s")",
                          subtitle: "Launch agents were checked against known adware and suspicious patterns.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !m.fullDiskAccess {
                        HStack(spacing: 14) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 26)).foregroundStyle(Color.amber)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Give Super Mac Full Disk Access for a deeper check").font(.system(size: 14, weight: .bold))
                                Text("macOS hides Safari data and the Trash from apps until you allow it. Turn on Super Mac in the list, then rescan.")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }.buttonStyle(GhostButtonStyle())
                        }
                        .padding(16).glass(18)
                    }
                    SectionTitle(text: "Adware & suspicious launch agents", trailing: m.threats.isEmpty ? "Clean" : nil)
                    if m.threats.isEmpty {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundStyle(Color.mint)
                            Text("Nothing suspicious is set to run on your Mac.").font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .padding(18).glass(18)
                    } else {
                        VStack(spacing: 4) { ForEach($m.threats) { $t in FileRow(item: $t, tint: .rose) } }.padding(8).glass(18)
                    }
                    SectionTitle(text: "Privacy", trailing: "Moved to the Trash, so you can undo")
                    if m.privacy.isEmpty {
                        EmptyState(symbol: "hand.raised.fill", title: "Nothing to clear", subtitle: "No supported browser data was found.").glass(18)
                    } else {
                        VStack(spacing: 4) {
                            ForEach($m.privacy) { $p in PrivacyRow(group: $p) { if let id = p.bundleID { m.quit(id) } } }
                        }
                        .padding(8).glass(18)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            BottomBar(module: .protection, title: "Remove", detail: m.selectedCount > 0 ? "\(m.selectedCount) selected" : "",
                      disabled: m.selectedCount == 0, action: m.fix) {
                Button { m.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
            }
        }
    }
}

struct PrivacyRow: View {
    @Binding var group: PrivacyGroup
    var onQuit: () -> Void
    var appIcon: NSImage? {
        guard let id = group.bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $group.selected.animation(.snappy)).toggleStyle(.checkbox).labelsHidden().disabled(group.isRunning)
            if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 30, height: 30) }
            else { Image(systemName: group.symbol).font(.system(size: 16)).frame(width: 30, height: 30).foregroundStyle(Color.aqua) }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.app).font(.system(size: 13, weight: .semibold))
                Text(group.kind).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if group.isRunning {
                Text("Quit \(group.app) first").font(.system(size: 11)).foregroundStyle(Color.amber)
                Button("Quit", action: onQuit).buttonStyle(GhostButtonStyle())
            }
            Text(fmt(group.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(group.selected ? Color.sky.opacity(0.14) : .white.opacity(0.02)))
    }
}

// MARK: - Performance

struct PerformanceScreen: View {
    @ObservedObject var m: PerformanceModel
    @ObservedObject var stats: LiveStats
    @State private var confirmAgents = false

    var body: some View {
        ZStack {
            switch m.phase {
            case .idle: ModuleLanding(module: .performance, action: m.scan)
            case .scanning: ScanningScreen(module: .performance, title: "Analysing performance…", detail: "Memory, background items and maintenance")
            case .results: results
            case .working: WorkingScreen(module: .performance, title: "Running maintenance…", detail: "macOS may ask for your password")
            case .done: DoneScreen(module: .performance, big: "Done", subtitle: m.message, buttonTitle: "Back") { m.scan() }
            }
        }
        .id(m.phase).transition(phaseTransition)
    }

    var results: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .performance, title: "Speed things up", subtitle: "Live system load, maintenance scripts and what runs in the background.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        bigGauge("CPU", stats.cpu, "\(Int(stats.cpu * 100))%", "processor load", [.amber, .coral])
                        bigGauge("Memory", stats.memFraction, fmt(Int64(stats.memUsed)), "of \(fmt(Int64(stats.memTotal)))", [.violet, .pinkish])
                        bigGauge("Disk", stats.disk.usedFraction, fmt(stats.disk.free), "free", [.aqua, .sky])
                    }
                    SectionTitle(text: "Maintenance", trailing: "Some tasks ask for your Mac password")
                    VStack(spacing: 4) {
                        ForEach($m.tasks) { $t in
                            HStack(spacing: 14) {
                                Toggle("", isOn: $t.selected.animation(.snappy)).toggleStyle(.checkbox).labelsHidden()
                                Image(systemName: t.symbol).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                                    .background(LinearGradient(colors: [.amber, .coral], startPoint: .topLeading, endPoint: .bottomTrailing),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(t.title).font(.system(size: 13, weight: .semibold))
                                        if t.admin { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)) }
                                    }
                                    Text(t.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.selected ? Color.amber.opacity(0.12) : .white.opacity(0.02)))
                        }
                    }
                    .padding(8).glass(18)

                    HStack {
                        SectionTitle(text: "Heavy memory users")
                        Button { withAnimation { m.refreshHeavy() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
                    }
                    VStack(spacing: 4) {
                        ForEach(m.heavy) { h in
                            HStack(spacing: 12) {
                                if let i = h.icon { Image(nsImage: i).resizable().frame(width: 30, height: 30) }
                                Text(h.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(String(format: "%.0f%% CPU", h.cpu)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 70, alignment: .trailing)
                                Text(fmt(h.memory)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                Button("Quit") { m.quit(h) }.buttonStyle(GhostButtonStyle())
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                    }
                    .padding(8).glass(18)

                    HStack {
                        SectionTitle(text: "Launch agents (\(m.agents.count))")
                        Button("Login Items Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }.buttonStyle(GhostButtonStyle())
                        Button("Remove Selected") { confirmAgents = true }.buttonStyle(GhostButtonStyle())
                            .disabled(!m.agents.contains(where: \.selected))
                    }
                    if m.agents.isEmpty {
                        EmptyState(symbol: "power", title: "No launch agents", subtitle: "Nothing extra starts with your account.").glass(18)
                    } else {
                        VStack(spacing: 4) { ForEach($m.agents) { $a in FileRow(item: $a, tint: .amber) } }.padding(8).glass(18)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            BottomBar(module: .performance, title: "Run Tasks", detail: "\(m.tasks.filter(\.selected).count)",
                      disabled: !m.tasks.contains(where: \.selected), action: m.runTasks) {
                Button { m.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
            }
        }
        .alert("Remove selected launch agents?", isPresented: $confirmAgents) {
            Button("Remove", role: .destructive) { m.removeAgents() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("They'll stop running and move to the Trash. The apps they belong to may stop updating or syncing in the background.") }
    }

    func bigGauge(_ title: String, _ v: Double, _ value: String, _ sub: String, _ c: [Color]) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Ring(value: v, colors: c, lineWidth: 8).frame(width: 64, height: 64)
                Text("\(Int(v * 100))%").font(.system(size: 13, weight: .heavy)).contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.system(size: 19, weight: .heavy)).contentTransition(.numericText())
                Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(16).glass(18)
        .animation(.smooth, value: v)
    }
}

// MARK: - Applications

struct ApplicationsScreen: View {
    @ObservedObject var m: AppsModel
    @State private var confirm = false
    @State private var dropTarget = false

    var filtered: [Binding<AppEntry>] {
        $m.apps.filter { b in
            let a = b.wrappedValue
            let q = m.search.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty && !a.name.lowercased().contains(q) { return false }
            switch m.filter {
            case .unused: return a.unused
            case .large: return a.totalSize > 1 << 30
            default: return true
            }
        }
    }

    var body: some View {
        ZStack {
            switch m.phase {
            case .idle:
                ModuleLanding(module: .applications, action: m.scan) {
                    Label("Tip: drag any app here to uninstall it", systemImage: "hand.draw.fill")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            case .scanning: ScanningScreen(module: .applications, title: "Reviewing applications…", detail: "Measuring apps and their support files")
            case .results: results
            case .working: WorkingScreen(module: .applications, title: "Uninstalling…", detail: "Moving apps and their files to the Trash")
            case .done: DoneScreen(module: .applications, big: fmt(m.freed), subtitle: m.message, buttonTitle: "Back") { m.back() }
            }
            if dropTarget {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .foregroundStyle(Color.sky.opacity(0.9))
                    .background(Color.sky.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(Label("Drop to uninstall", systemImage: "trash.fill").font(.system(size: 18, weight: .bold)).padding(.horizontal, 20).padding(.vertical, 12).glassCapsule())
                    .padding(24)
                    .transition(.opacity)
            }
        }
        .id(m.phase).transition(phaseTransition)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget.animation(.smooth)) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                Task { @MainActor in m.dropped(url) }
            }
            return true
        }
    }

    var results: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .applications, title: "\(m.apps.count) apps installed",
                          subtitle: "Uninstall removes the app plus its caches, preferences and support files.")
            HStack(spacing: 8) {
                ForEach(AppsModel.Filter.allCases, id: \.self) { f in
                    let c: Int = switch f {
                    case .all: m.apps.count
                    case .unused: m.unusedCount
                    case .large: m.apps.filter { $0.totalSize > 1 << 30 }.count
                    case .leftovers: m.orphans.count
                    }
                    Chip(title: f.rawValue, selected: m.filter == f, count: c, colors: Module.applications.colors) {
                        withAnimation(.snappy) { m.filter = f }
                    }
                }
                Spacer()
                if m.filter != .leftovers {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                        TextField("Search apps", text: $m.search).textFieldStyle(.plain).frame(width: 150)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(12)
                }
            }
            .padding(.horizontal, 32).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if m.filter == .leftovers {
                        Text("Support files whose app no longer seems to be installed. Check each one before removing.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
                        if m.orphans.isEmpty { EmptyState(symbol: "puzzlepiece.extension.fill", title: "No leftovers", subtitle: "Nothing left behind by deleted apps.") }
                        ForEach($m.orphans) { $o in FileRow(item: $o, tint: .sky) }
                    } else {
                        let list = filtered
                        if list.isEmpty { EmptyState(symbol: "square.stack.3d.up.fill", title: "No apps here", subtitle: "Try another filter.") }
                        ForEach(list) { $a in AppRow(app: $a) }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            BottomBar(module: .applications, title: m.filter == .leftovers ? "Remove" : "Uninstall", detail: fmt(m.selectedSize),
                      disabled: m.selectedSize == 0, action: { confirm = true }) {
                Button { m.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
            }
        }
        .alert("Uninstall selected items?", isPresented: $confirm) {
            Button("Uninstall", role: .destructive) { m.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(m.selectedApps.map(\.name).joined(separator: ", "))\n\nOpen apps will be quit first. Everything goes to the Trash, so you can put it back.")
        }
    }
}

struct AppRow: View {
    @Binding var app: AppEntry
    @State private var expanded = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: $app.selected.animation(.snappy)).toggleStyle(.checkbox).labelsHidden()
                Image(nsImage: fileIcon(app.url)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if !app.version.isEmpty { Text(app.version).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)) }
                        if app.unused { TagPill(text: "UNUSED", color: .amber) }
                    }
                    Text(app.lastUsed == nil ? "Last opened: unknown" : "Last opened \(relativeDate(app.lastUsed))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if !app.leftovers.isEmpty {
                    Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("\(app.leftovers.count) files · \(fmt(app.leftoverSize))")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                Text(fmt(app.totalSize)).font(.system(size: 14, weight: .bold)).monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.leftovers) { l in
                        HStack {
                            Image(systemName: "doc.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                            Text(tilde(l.url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(fmt(l.size)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 64).padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(app.selected ? Color.sky.opacity(0.15) : .white.opacity(hover ? 0.07 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - My Clutter

struct ClutterScreen: View {
    @ObservedObject var m: ClutterModel
    @State private var confirm = false

    var body: some View {
        ZStack {
            switch m.phase {
            case .idle: ModuleLanding(module: .clutter, action: m.scan)
            case .scanning: ScanningScreen(module: .clutter, title: "Searching for clutter…", detail: m.status)
            case .results: results
            case .working: WorkingScreen(module: .clutter, title: "Tidying up…", detail: "Moving files to the Trash")
            case .done: DoneScreen(module: .clutter, big: fmt(m.freed), subtitle: m.message, buttonTitle: "Back") { m.back() }
            }
        }
        .id(m.phase).transition(phaseTransition)
    }

    var results: some View {
        VStack(spacing: 0) {
            ResultsHeader(module: .clutter, title: "Your clutter",
                          subtitle: "Nothing is selected unless it's clearly a spare copy. Removed files go to the Trash.")
            HStack(spacing: 8) {
                Chip(title: ClutterModel.Tab.large.rawValue, selected: m.tab == .large, count: m.large.count, colors: Module.clutter.colors) { withAnimation(.snappy) { m.tab = .large } }
                Chip(title: ClutterModel.Tab.duplicates.rawValue, selected: m.tab == .duplicates, count: m.dups.count, colors: Module.clutter.colors) { withAnimation(.snappy) { m.tab = .duplicates } }
                Chip(title: ClutterModel.Tab.installers.rawValue, selected: m.tab == .installers, count: m.installers.count, colors: Module.clutter.colors) { withAnimation(.snappy) { m.tab = .installers } }
                Spacer()
            }
            .padding(.horizontal, 32).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 4) {
                    switch m.tab {
                    case .large:
                        if m.large.isEmpty { EmptyState(symbol: "externaldrive.fill", title: "No large files", subtitle: "Nothing over 100 MB in your folders.") }
                        ForEach($m.large) { $f in FileRow(item: $f, showDate: true, tint: .lilac) }
                    case .duplicates:
                        if m.dups.isEmpty {
                            EmptyState(symbol: "doc.on.doc.fill", title: "No duplicates", subtitle: "Run a full scan from My Clutter to compare files.")
                        }
                        ForEach($m.dups) { $g in
                            VStack(spacing: 4) {
                                HStack {
                                    Text("\(g.items.count) identical copies").font(.system(size: 12, weight: .bold))
                                    Spacer()
                                    Text("\(fmt(g.wasted)) selected").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                                }
                                .padding(.horizontal, 10).padding(.top, 6)
                                ForEach($g.items) { $f in FileRow(item: $f, showDate: true, tint: .peach) }
                            }
                            .padding(8).glass(16).padding(.bottom, 8)
                        }
                    case .installers:
                        if m.installers.isEmpty { EmptyState(symbol: "shippingbox.and.arrow.backward.fill", title: "No installers", subtitle: "Your Downloads folder has no .dmg or .pkg files.") }
                        ForEach($m.installers) { $f in FileRow(item: $f, showDate: true, tint: .lilac) }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            BottomBar(module: .clutter, title: "Move to Trash", detail: fmt(m.selectedSize), disabled: m.selectedSize == 0, action: { confirm = true }) {
                Button { m.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
            }
        }
        .alert("Move \(fmt(m.selectedSize)) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { m.remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can put anything back from the Trash until you empty it.") }
    }
}

// MARK: - Space Lens

struct SpaceLensScreen: View {
    @ObservedObject var m: LensModel
    @State private var toTrash: LensNode?

    var body: some View {
        ZStack {
            if m.path.isEmpty {
                ModuleLanding(module: .spaceLens, buttonTitle: "Map", action: { m.open(homeURL) }) {
                    Button {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { m.open(u) }
                    } label: { Label("Choose another folder…", systemImage: "folder") }
                    .buttonStyle(GhostButtonStyle())
                }
                .transition(phaseTransition)
            } else {
                map.transition(phaseTransition)
            }
        }
        .alert("Move “\(toTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let n = toTrash { m.trash(n) }; toTrash = nil }
            Button("Cancel", role: .cancel) { toTrash = nil }
        } message: { Text("\(fmt(toTrash?.size ?? 0)) · You can restore it from the Trash.") }
    }

    var map: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Button { withAnimation(.smooth) { m.path = []; m.nodes = [] } } label: { Image(systemName: "house.fill") }
                    .buttonStyle(GhostButtonStyle())
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(m.path.enumerated()), id: \.offset) { i, u in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4)) }
                            Button(i == 0 && u == homeURL ? "Home" : u.lastPathComponent) { m.back(to: i) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: i == m.path.count - 1 ? .bold : .medium))
                                .foregroundStyle(.white.opacity(i == m.path.count - 1 ? 1 : 0.6))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Spacer()
                if m.loading {
                    ProgressView(value: Double(m.done), total: Double(max(m.totalChildren, 1))).frame(width: 120).tint(Color.aqua)
                }
                Text(fmt(m.total)).font(.system(size: 18, weight: .heavy)).contentTransition(.numericText())
            }
            TreemapView(nodes: m.nodes, onOpen: { n in withAnimation(.smooth) { m.open(n.url) } }, onTrash: { toTrash = $0 })
                .overlay {
                    if m.nodes.isEmpty && m.loading {
                        VStack(spacing: 14) { SpinnerRing(colors: Module.spaceLens.colors, size: 120); Text("Measuring…").foregroundStyle(.white.opacity(0.6)) }
                    }
                }
            Text("Click a folder to look inside · Right-click for more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }
}

struct TreemapView: View {
    let nodes: [LensNode]
    let onOpen: (LensNode) -> Void
    let onTrash: (LensNode) -> Void
    @State private var hovered: UUID?
    let palette: [Color] = [.violet, .pinkish, .aqua, .amber, .mint, .sky, .coral, .lilac, .teal, .magenta]

    var body: some View {
        GeometryReader { g in
            let shown = Array(nodes.prefix(40))
            let rest = nodes.dropFirst(40).reduce(Int64(0)) { $0 + $1.size }
            let values = shown.map { Double($0.size) } + (rest > 0 ? [Double(rest)] : [])
            let rects = squarify(values, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                    if i < rects.count { tile(n, rects[i], palette[i % palette.count]) }
                }
                if rest > 0, let r = rects.last {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08))
                        .overlay(Text("Other").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)))
                        .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                        .offset(x: r.minX + 2, y: r.minY + 2)
                }
            }
        }
    }

    func tile(_ n: LensNode, _ r: CGRect, _ c: Color) -> some View {
        let hover = hovered == n.id
        let big = r.width > 90 && r.height > 54
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [c.opacity(hover ? 0.95 : 0.75), c.opacity(hover ? 0.6 : 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(hover ? 0.6 : 0.15), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if big {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(nsImage: fileIcon(n.url)).resizable().frame(width: 18, height: 18)
                            Text(n.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                        }
                        Text(fmt(n.size)).font(.system(size: 11, weight: .medium)).opacity(0.8)
                    }
                    .padding(10)
                }
            }
            .shadow(color: c.opacity(hover ? 0.5 : 0), radius: 12)
            .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
            .offset(x: r.minX + 2, y: r.minY + 2)
            .help("\(n.name) — \(fmt(n.size))")
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? n.id : (hovered == n.id ? nil : hovered) } }
            .onTapGesture { if n.isDir { onOpen(n) } else { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } }
            .contextMenu {
                if n.isDir { Button("Open") { onOpen(n) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                Divider()
                Button("Move to Trash…", role: .destructive) { onTrash(n) }
            }
    }
}
