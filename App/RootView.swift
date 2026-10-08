import SwiftUI

/// The app shell: sidebar of sections, the selected section's screen on the right.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let onboarding = appState.onboarding
        // The shell always stays in the window (so its split view is set up once); the
        // first-run steps cover it while shown, and plain paper covers it until `load()` decides.
        ZStack {
            shell
                .accessibilityHidden(!onboarding.isLoaded || onboarding.isPresented)
                // No Return/Escape shortcuts or Tab stops behind the first-run steps.
                .disabled(!onboarding.isLoaded || onboarding.isPresented)
            if !onboarding.isLoaded {
                Palette.paper.ignoresSafeArea()
            } else if onboarding.isPresented {
                OnboardingView(model: onboarding)
                    .ignoresSafeArea()
            }
        }
        .background(Palette.paper)
        .task { await loadOnboarding() }
        .task {
            // Re-check access when the user comes back from System Settings, and re-read free space
            // and the Trash (they may have emptied it in Finder). Events only, no polling here.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await onboarding.refreshAccess()
                appState.refreshSpace()
            }
        }
        #if DEBUG
            .task {
                if let output = DebugScan.outputURL {
                    let permissions = appState.permissions
                    let access = await Task.detached { permissions.hasFullDiskAccess() }.value
                    await DebugScan.run(writingTo: output, model: appState.junk, hasFullDiskAccess: access)
                }
                if let request = DebugClean.request {
                    await DebugClean.run(request, appState: appState)
                }
                if let request = DebugApps.request {
                    await DebugApps.run(request, appState: appState)
                }
                if let request = DebugWalk.request {
                    await DebugWalk.run(request, appState: appState)
                }
                if let request = DebugClutter.request {
                    await DebugClutter.run(request, appState: appState)
                }
                if let request = DebugSweep.request {
                    await DebugSweep.run(request, appState: appState)
                }
                if let output = DebugUpdates.outputURL {
                    await DebugUpdates.run(writingTo: output, appState: appState)
                }
            }
        #endif
    }

    private var shell: some View {
        @Bindable var state = appState
        return NavigationSplitView {
            Sidebar(selection: $state.section, disk: appState.disk)
                // The frame keeps the column from opening narrower than its minimum on a first launch
                // (with no saved split-view width, macOS restored it at 144 pt).
                .frame(minWidth: Metric.sidebarMinWidth)
                .navigationSplitViewColumnWidth(min: Metric.sidebarMinWidth, ideal: Metric.sidebarMinWidth + Space.xl)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if appState.onboarding.showsBanner {
                    AccessBanner(onboarding: appState.onboarding)
                        .padding(.horizontal, Space.xxl)
                        .padding(.top, Space.l)
                }
                detail(for: appState.section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.paper)
        }
        .background(Palette.paper)
        .task { await appState.disk.refresh() }
        #if DEBUG
            .task {
                guard DebugSnapshot.directory != nil, DebugSnapshot.onboardingStep == nil else { return }
                if DebugSnapshot.bannerOnly {
                    await DebugSnapshot.writeBanner()
                } else if DebugSnapshot.junkFlow {
                    await DebugSnapshot.walkJunkFlow(appState: appState)
                } else if DebugSnapshot.appsFlow {
                    await DebugSnapshot.walkAppsFlow(appState: appState)
                } else if DebugSnapshot.trashFinderFlow {
                    await DebugSnapshot.walkTrashFinderFlow(appState: appState)
                } else if DebugSnapshot.uninstallAdminFlow {
                    await DebugSnapshot.walkUninstallAdminFlow(appState: appState)
                } else if DebugSnapshot.spaceMapFlow {
                    await DebugSnapshot.walkSpaceMapFlow(appState: appState)
                } else if DebugSnapshot.clutterFlow {
                    await DebugSnapshot.walkClutterFlow(appState: appState)
                } else if DebugSnapshot.sweepFlow {
                    await DebugSnapshot.walkSweepFlow(appState: appState)
                } else if DebugSnapshot.menuBarFlow {
                    await DebugSnapshot.walkMenuBarFlow(appState: appState)
                } else if DebugSnapshot.layoutAudit {
                    await DebugSnapshot.walkLayoutAudit(appState: appState)
                } else if DebugSnapshot.openAppsFlow {
                    await DebugSnapshot.walkOpenAppsFlow(appState: appState)
                } else if DebugSnapshot.updatesFlow {
                    await DebugSnapshot.walkUpdatesFlow(appState: appState)
                } else {
                    await DebugSnapshot.walkSections { appState.section = $0 }
                }
            }
        #endif
    }

    /// Decides whether the first-run steps show. DEBUG launch args:
    /// `-resetOnboarding YES` forgets earlier choices; `-onboardingStep 1|2|3` shows a step
    /// (and, with `-snapshotDir`, saves it and quits); `-chooseLimitedScan YES` takes the
    /// "Continue with limited scan" path; screenshot and scan runs keep the steps hidden.
    private func loadOnboarding() async {
        let onboarding = appState.onboarding
        #if DEBUG
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "resetOnboarding") { await onboarding.debugReset() }
            if let step = DebugSnapshot.onboardingStep {
                await onboarding.load(allowPresentation: false)
                onboarding.debugPresent(step)
                if DebugSnapshot.directory != nil { await DebugSnapshot.writeOnboarding(step: step) }
                return
            }
            await onboarding.load(
                allowPresentation: DebugSnapshot.directory == nil && DebugScan.outputURL == nil
                    && DebugClean.request == nil && DebugApps.request == nil
                    && DebugWalk.request == nil && DebugClutter.request == nil && DebugSweep.request == nil
                    && DebugUpdates.outputURL == nil)
            if defaults.bool(forKey: "chooseLimitedScan"), onboarding.isPresented {
                await onboarding.continueWithLimitedScan()
            }
        #else
            await onboarding.load()
        #endif
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .sweep: SweepView()
        case .junk: JunkView()
        case .apps: AppsView()
        case .spaceMap: SpaceMapView()
        case .clutter: ClutterView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: AppSection
    let disk: DiskSpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Dustpan")
                .font(Typo.title)
                .tracking(Typo.displayTracking / 2)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.l)

            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(AppSection.tools) { row($0) }
                Rectangle()
                    .fill(Palette.line)
                    .frame(height: Stroke.hairline)
                    .padding(.vertical, Space.s)
                    .padding(.horizontal, Space.xs)
                ForEach(AppSection.housekeeping) { row($0) }
            }
            .padding(.horizontal, Space.s)

            Spacer(minLength: Space.l)

            DiskFooter(disk: disk)
                .padding(Space.l)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.paper.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.ink).frame(width: Stroke.outline).ignoresSafeArea()
        }
    }

    private func row(_ section: AppSection) -> some View {
        SidebarRow(section: section, isSelected: selection == section) {
            selection = section
        }
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        Button(action: select) {
            HStack(spacing: Space.s) {
                ToneGlyph(tone: section.tone)
                Text(section.title)
                    .font(Typo.sidebar)
                    .foregroundStyle(isSelected ? section.tone.onFill : Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    shape.fill(section.tone.fill)
                        .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
                } else if hovering {
                    shape.fill(Palette.line)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.select, value: isSelected)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct DiskFooter: View {
    let disk: DiskSpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Startup disk").textStyle(.caption)
            if let space = disk.space {
                SizeBar(value: space.usedBytes, total: space.totalBytes, tone: .sweep)
                Text(space.summary)
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(Palette.ink)
            } else if disk.failed {
                Text("Free space unavailable").textStyle(.caption)
            } else {
                SizeBar(value: 0, total: 1)
                Text(" ").textStyle(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The quiet, persistent notice shown while Full Disk Access is off.
private struct AccessBanner: View {
    let onboarding: OnboardingModel

    var body: some View {
        QuietBanner(
            systemImage: "lock",
            message: message,
            actionTitle: "Show me how",
            action: { onboarding.showAccessSteps() }
        )
        .accessibilityLabel("Limited scan")
    }

    private var message: String {
        let count = onboarding.accessCategories.count
        let reach = "Dustpan skips the Trash, Downloads and other apps' folders"
        guard count > 0 else { return "Limited scan: without Full Disk Access, \(reach)." }
        let categories = count == 1 ? "1 category is" : "\(count) categories are"
        return "Limited scan: without Full Disk Access, \(reach), so \(categories) only partly checked."
    }
}
