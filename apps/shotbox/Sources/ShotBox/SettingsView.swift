import ServiceManagement
import SwiftUI

/// A rule that would remove captures, held until the user confirms it.
private struct PendingRule: Equatable {
    let rule: Retention
    let removal: Int
}

/// Retention, shortcut, launch at login and storage. Retention is typed as a draft: nothing is removed until
/// Return or Apply, and a change that would remove captures asks first, since removal cannot be undone.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: RetentionMode = .count
    @State private var count = 500
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var storageText = ""
    @State private var shrinkDays = 30
    @State private var confirming: PendingRule?

    /// The rule as it is typed, not yet applied.
    private var draft: Retention { Retention(mode: mode, n: max(1, count)) }

    private var isDraft: Bool { draft != model.retention }

    /// The warning colour is for a rule that will actually remove something.
    private var summaryRemoves: Bool {
        isDraft ? model.wouldRemove(draft) > 0 : model.nextCount > 0
    }

    private var summary: String {
        if isDraft {
            let removal = model.wouldRemove(draft)
            return "Press Return to apply. \(Self.plural(removal, "capture")) would be removed."
        }
        let unit = model.retention.mode == .count ? "by the next capture" : "within a day"
        return "Currently \(Self.plural(model.totalCount, "capture")); \(model.nextCount) would be removed \(unit)"
    }

    /// "1 capture", "2 captures". Used wherever a count reads as a noun.
    static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(n == 1 ? noun : noun + "s")"
    }

    /// Fits the visible screen at its default size, so the Storage rows are reachable without leaving the window.
    private var fittedHeight: CGFloat {
        min(820, (NSScreen.main?.visibleFrame.height ?? 820) - 40)
    }

    /// Set after a committed change, so the user sees what the change itself removed.
    private var removedText: String? {
        guard let removed = model.lastRemoved else { return nil }
        return removed == 0 ? "Nothing was removed by the last change." : "The last change removed \(removed) \(removed == 1 ? "capture" : "captures")."
    }

    private var nothingDueText: String {
        if isDraft {
            return mode == .count
                ? "Nothing would be removed with a limit of \(draft.n)."
                : "Nothing would be removed with a limit of \(draft.n) days."
        }
        switch model.retention.mode {
        case .count: return "Nothing is due. Captures are under the limit of \(model.retention.n)."
        case .days: return "Nothing is due. No capture is older than the \(model.retention.n)-day limit."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep", selection: $mode) {
                    Text("Keep last N captures").tag(RetentionMode.count)
                    Text("Keep last N days").tag(RetentionMode.days)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("retentionMode")
                .onChange(of: mode) { _, new in
                    // Each mode brings back the N it last had. A count is never reused as days, or the reverse.
                    count = model.engine.store.remembered(new)
                }

                LabeledContent(mode == .count ? "Captures to keep" : "Days to keep") {
                    HStack(spacing: 4) {
                        TextField("", value: $count, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { commit() }
                            .accessibilityIdentifier("retentionField")
                        Stepper(value: $count, in: 1...1_000_000) {
                            EmptyView()
                        }
                        .accessibilityIdentifier("retentionStepper")
                    }
                }

                Text(summary)
                    .font(Theme.mono(11))
                    .foregroundStyle(summaryRemoves ? Theme.orange : Theme.meta)
                    .accessibilityIdentifier("retentionSummary")
                if isDraft {
                    HStack {
                        Button("Revert") { revert() }
                            .accessibilityIdentifier("revertRetentionButton")
                        Spacer()
                        Button("Apply") { commit() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("applyRetentionButton")
                    }
                }
                if let removedText {
                    Text(removedText)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.meta)
                        .accessibilityIdentifier("retentionRemoved")
                }

                nextToGoStrip
            } header: {
                Text("Retention").sectionLabel()
            }

            Section {
                Text("Images copied to the clipboard are always captured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                OnOffSwitch(title: "Also watch a screenshot folder", isOn: model.watchFolder, identifier: "watchFolderToggle") {
                    model.watchFolder.toggle()
                }
            } header: {
                Text("Capture").sectionLabel()
            }

            Section {
                LabeledContent("Show ShotBox window") {
                    Text("⌃⌥⌘S")
                        .font(Theme.mono(12, .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                        .accessibilityIdentifier("hotkeyLabel")
                }
                LabeledContent("Toggle Clothesline") {
                    Text("⌃⌥⌘L")
                        .font(Theme.mono(12, .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                        .accessibilityIdentifier("clotheslineHotkeyLabel")
                }
            } header: {
                Text("Shortcut").sectionLabel()
            }

            Section {
                OnOffSwitch(title: "Launch at login", isOn: launchAtLogin, identifier: "launchAtLoginToggle") {
                    setLaunchAtLogin(!launchAtLogin)
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Shrink full images after N days") {
                    HStack(spacing: 4) {
                        TextField("", value: $shrinkDays, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { model.setShrinkDays(max(1, shrinkDays)) }
                            .accessibilityIdentifier("shrinkDaysField")
                        Stepper(onIncrement: {
                            shrinkDays += 1
                            model.setShrinkDays(shrinkDays)
                        }, onDecrement: {
                            shrinkDays = max(1, shrinkDays - 1)
                            model.setShrinkDays(shrinkDays)
                        }) {
                            EmptyView()
                        }
                        .accessibilityIdentifier("shrinkDaysStepper")
                    }
                }
                LabeledContent("Data folder") {
                    Text(model.engine.store.dataDir.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dataFolderPath")
                }
                LabeledContent("Size on disk") {
                    Text(storageText)
                        .accessibilityIdentifier("storageSize")
                }
                LabeledContent("Watched folder") {
                    Text(Config.watchDir.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("watchFolderPath")
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.engine.store.dataDir])
                    }
                    .accessibilityIdentifier("revealDataButton")
                }
            } header: {
                Text("Storage").sectionLabel()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sheet)
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.select)
        .font(.system(size: 12))
        .frame(minWidth: 480, idealWidth: 480, minHeight: 480, idealHeight: fittedHeight)
        .onAppear {
            mode = model.retention.mode
            count = model.retention.n
            shrinkDays = model.shrinkDays
            refreshStorage()
            // Opened from the main window, this window can come up behind it. Keys must reach its fields, not the grid,
            // or Backspace typed here would delete the selected capture.
            DispatchQueue.main.async {
                NSApp.windows.first { $0.title == "Settings" }?.makeKeyAndOrderFront(nil)
            }
        }
        .onChange(of: model.revision) { _, _ in refreshStorage() }
        .alert("Remove \(Self.plural(confirming?.removal ?? 0, "capture"))?", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { pending in
            Button("Remove \(Self.plural(pending.removal, "capture"))", role: .destructive) {
                model.setRetention(pending.rule)
            }
            .accessibilityIdentifier("confirmRemoveButton")
            Button("Cancel", role: .cancel) { revert() }
                .accessibilityIdentifier("cancelRemoveButton")
        } message: { _ in
            Text("Removed captures and their files cannot be recovered. Pinned captures are kept.")
        }
    }

    /// Oldest unpinned captures the rule removes next. Live: it follows the captures list, not a snapshot.
    private var nextToGoStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next to go")
                .sectionLabel()
            if isDraft {
                draftStrip
            } else if model.nextToGo.isEmpty {
                Text(nothingDueText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                    .accessibilityIdentifier("nextToGoEmpty")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(model.nextToGo.enumerated()), id: \.element.id) { index, capture in
                            VStack(alignment: .leading, spacing: 4) {
                                NextToGoThumb(capture: capture, store: model.engine.store)
                                Text(countdown(index))
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.orange)
                            }
                        }
                        Rectangle().fill(Theme.orange).frame(width: 2, height: 48)
                        Text("Removed")
                            .font(Theme.mono(10))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.orange)
                            .frame(height: 48)
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("nextToGoStrip")
            }
        }
    }

    /// What the typed rule would remove, shown dimmed and struck through before Apply, so the strip agrees with the summary.
    @ViewBuilder
    private var draftStrip: some View {
        let candidates = model.draftCandidates(draft)
        if candidates.isEmpty {
            Text(nothingDueText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.meta)
                .accessibilityIdentifier("nextToGoEmpty")
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(candidates) { capture in
                        VStack(alignment: .leading, spacing: 4) {
                            NextToGoThumb(capture: capture, store: model.engine.store)
                                .opacity(0.5)
                            Text("on Apply")
                                .font(Theme.mono(10))
                                .strikethrough()
                                .foregroundStyle(Theme.orange)
                        }
                    }
                    Rectangle().fill(Theme.orange).frame(width: 2, height: 48)
                    Text(verbatim: "\(Self.plural(model.wouldRemove(draft), "capture")) removed")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.orange)
                        .frame(height: 48)
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("nextToGoDraftStrip")
        }
    }

    /// Order of removal as a countdown. Count mode removes one per new capture; day mode removes them within a day.
    private func countdown(_ index: Int) -> String {
        if model.retention.mode == .days { return "≤ 1 day" }
        return index == 0 ? "next capture" : "in \(index + 1) captures"
    }

    /// Applies the typed rule. A rule that would remove captures waits for confirmation first.
    private func commit() {
        guard isDraft else { return }
        let removal = model.wouldRemove(draft)
        if removal > 0 {
            confirming = PendingRule(rule: draft, removal: removal)
        } else {
            model.setRetention(draft)
        }
    }

    /// Puts the fields back to the applied rule.
    private func revert() {
        mode = model.retention.mode
        count = model.retention.n
    }

    private func refreshStorage() {
        storageText = Fmt.bytes(model.engine.store.diskUsage())
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A labelled on/off switch. It is drawn here rather than native, because the native switch reports its state
/// to the accessibility tree as 1 or 0. This one is a button whose value reads On or Off; the ON/OFF text stays visible.
private struct OnOffSwitch: View {
    let title: String
    let isOn: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(isOn ? "ON" : "OFF")
                .font(Theme.mono(10, .medium))
                .foregroundStyle(isOn ? Theme.ink.opacity(0.9) : Theme.coord)
                .accessibilityHidden(true)
            Button(action: action) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.select : Theme.hairline)
                        .frame(width: 34, height: 20)
                    Circle()
                        .fill(isOn ? Theme.sheet : Theme.meta)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(Motion.hero, value: isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(identifier)
        }
    }
}

/// A small thumbnail in the "Next to go" strip.
private struct NextToGoThumb: View {
    let capture: Capture
    let store: Store
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .frame(width: 72, height: 48)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        .help(capture.name)
        .accessibilityIdentifier("nextToGo-\(capture.id)")
        .task(id: capture.id) {
            thumb = await Images.load(store.thumbURL(capture))
        }
    }
}
