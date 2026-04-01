import SwiftUI

extension Session {
    var sourceBadgeColor: Color {
        switch source {
        case "opencode": return .blue
        case "pi": return .green
        default: return .amber
        }
    }
}

struct SessionCardView: View {
    let session: Session
    /// Override the displayed project name (e.g. worktree root name)
    var displayName: String?
    /// 1-based index for navigate mode (1-9). nil = normal mode (show accent bar).
    var navigateIndex: Int?
    var showSourceBadge = false
    var isSelected = false
    var isPerkupWorktree = false
    var onOpenCursor: (() -> Void)?
    var onOpenChrome: (() -> Void)?
    var onToggleServer: (() -> Void)?
    var isServerRunning = false
    var isServerLoading = false
    var onOpenPR: (() -> Void)?
    var prMerged = false
    var prReviewDecision: String = ""
    var prAutoMerge = false
    var gitAhead: Int = 0
    var gitBehind: Int = 0
    var gitUnpushed = false
    var gitStaged: Int = 0
    var gitUnstaged: Int = 0
    var onReview: (() -> Void)?
    var isReviewing = false
    var onSync: (() -> Void)?
    var isSyncing = false
    var onPush: (() -> Void)?
    var isPushing = false
    var onAutomerge: (() -> Void)?
    var isAutomerging = false
    var onShip: (() -> Void)?
    var isShipping = false
    var onRemove: (() -> Void)?
    var isRemoving = false
    var selectedActionIndex: Int = -1  // -1 = none, 0+ = button index
    @State private var isHovered = false
    @State private var titleHovered = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            // Left accent bar
            accentBar
                .accessibilityHidden(true)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Row 1: project name + badges + action buttons
                HStack(spacing: 6) {
                    Text(displayName ?? session.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            session.status == .idle
                                ? Color.textDimmed : Color.textPrimary
                        )
                        .underline(titleHovered)
                        .onHover { titleHovered = $0 }
                        .onTapGesture {
                            onOpenCursor?()
                        }

                    if session.subagentCount > 0 {
                        let count = session.subagentCount
                        Text("\(count) agent\(count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.agentBadge)
                    }

                    if showSourceBadge {
                        Text(session.sourceLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(session.sourceBadgeColor)
                    }

                    // Action buttons (always visible)
                    if isPerkupWorktree {
                        actionButtons
                    }

                    Spacer()
                }

                // Row 2: branch + git sync indicators
                HStack(spacing: 5) {
                    Text(session.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    if isPerkupWorktree {
                        // Git sync badges
                        if gitUnpushed {
                            gitBadge(
                                icon: "exclamationmark.arrow.triangle.2.circlepath",
                                text: "unpushed",
                                color: .orange
                            )
                        } else if gitAhead > 0 {
                            gitBadge(
                                icon: "arrow.up",
                                text: "\(gitAhead)",
                                color: .statusGreen
                            )
                        }
                        if gitBehind > 0 {
                            gitBadge(
                                icon: "arrow.down",
                                text: "\(gitBehind)",
                                color: .statusAttention
                            )
                        }
                        if gitUnstaged > 0 {
                            gitBadge(
                                icon: "pencil",
                                text: "\(gitUnstaged)",
                                color: .orange
                            )
                        }
                        if gitStaged > 0 {
                            gitBadge(
                                icon: "checkmark.square",
                                text: "\(gitStaged)",
                                color: .statusGreen
                            )
                        }
                        if !gitUnpushed && gitAhead == 0
                            && gitBehind == 0
                            && gitStaged == 0
                            && gitUnstaged == 0
                        {
                            gitBadge(
                                icon: "checkmark",
                                text: "clean",
                                color: .textMuted
                            )
                        }
                    } else {
                        if let name = session.sessionName {
                            Text("/")
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    Color.textMuted.opacity(0.6)
                                )
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        } else if let context = session.contextLine {
                            Text("/")
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    Color.textMuted.opacity(0.6)
                                )
                            Text(context)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Right: status
            statusLabel
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(flashBackground)
        .cardSelectionStyle(
            isSelected: isSelected, isHovered: false, cornerRadius: 0
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
        .onChange(of: session.status) { newStatus in
            if newStatus.needsAttention {
                triggerFlash(for: newStatus)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .openGitMenu
            )
        ) { notification in
            guard let path = notification.userInfo?["projectPath"]
                as? String,
                path == session.projectPath else { return }
            showGitMenu = true
        }
        .onChange(of: showGitMenu) { open in
            NotificationCenter.default.post(
                name: .submenuStateChanged,
                object: nil,
                userInfo: ["open": open]
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sessionNeedsAttention
            )
        ) { notification in
            guard let path = notification.userInfo?["projectPath"]
                as? String,
                path == session.projectPath else { return }
            triggerFlash(for: session.status)
        }
    }

    @ViewBuilder
    private var accentBar: some View {
        if let idx = navigateIndex, idx <= 9 {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(session.status.color)
                    .frame(width: 16, height: 16)
                Text("\(idx)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 16)
            .accessibilityLabel("Press \(idx) to jump")
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(session.status.color.opacity(accentOpacity))
                .frame(width: 3)
                .frame(width: 16)
        }
    }

    private var accentOpacity: Double {
        switch session.status {
        case .waitingPermission, .waitingInput, .needsAttention: return 1.0
        case .working, .compacting: return 0.4
        case .idle: return 0.1
        }
    }

    private var statusLabel: some View {
        statusIcon
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .working, .compacting:
            SpinningIcon()
        case .waitingPermission:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.statusPermission)
        case .waitingInput, .needsAttention:
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.statusAttention)
        case .idle:
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
        }
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = []
        if let idx = navigateIndex, idx <= 9 {
            parts.append("Press \(idx) to jump to")
        }
        parts += [
            session.projectName, "on branch", session.branch,
            session.status.accessibilityDescription,
        ]
        if session.subagentCount > 0 {
            parts.append(
                "\(session.subagentCount) active subagent\(session.subagentCount == 1 ? "" : "s")"
            )
        }
        if let context = session.contextLine {
            parts.append(context)
        }
        return parts.joined(separator: ", ")
    }

    private var flashBackground: some View {
        let color: Color = session.status == .waitingPermission
            ? Color.statusPermission : Color.statusAttention
        return color.opacity(flashOpacity)
    }

    private func triggerFlash(for status: SessionStatus) {
        flashOpacity = 0.3
        withAnimation(.easeOut(duration: 4.0)) {
            flashOpacity = 0
        }
    }

    private var actionButtons: some View {
        var idx = 0
        func nextIdx() -> Int {
            let i = idx; idx += 1; return i
        }

        let isGitLoading = isSyncing || isPushing || isShipping
            || isReviewing || isAutomerging

        return HStack(spacing: 2) {
            // Git submenu
            let gitIdx = nextIdx()
            if isGitLoading {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 16, height: 16)
            } else {
                PerkupIconButton(
                    systemImage: prIcon,
                    active: prReviewDecision == "APPROVED"
                        && !prAutoMerge,
                    merged: prMerged,
                    inQueue: prAutoMerge,
                    highlighted: selectedActionIndex == gitIdx,
                    destructive:
                        prReviewDecision == "CHANGES_REQUESTED",
                    action: { showGitMenu.toggle() }
                )
                .popover(isPresented: $showGitMenu) {
                    gitMenuContent
                }
            }

            // Chrome
            if let chromeAction = onOpenChrome {
                let i = nextIdx()
                perkupActionButton(
                    systemImage: "globe",
                    action: chromeAction,
                    highlighted: selectedActionIndex == i
                )
            }

            // Server toggle
            if isServerLoading {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 16, height: 16)
            } else if let serverAction = onToggleServer {
                let i = nextIdx()
                perkupActionButton(
                    systemImage: isServerRunning
                        ? "stop.fill" : "play.fill",
                    action: serverAction,
                    destructive: isServerRunning,
                    active: !isServerRunning,
                    highlighted: selectedActionIndex == i
                )
            }

            // Delete
            if isRemoving {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 16, height: 16)
            } else if let removeAction = onRemove {
                let i = nextIdx()
                perkupActionButton(
                    systemImage: "trash",
                    action: removeAction,
                    destructive: true,
                    highlighted: selectedActionIndex == i
                )
            }
        }
    }

    @State private var showGitMenu = false

    private var gitMenuItems: [(String, String, () -> Void)] {
        var items: [(String, String, () -> Void)] = []
        if let prAction = onOpenPR {
            items.append((
                prMerged ? "View Merged PR" : "View PR",
                prMerged ? "arrow.triangle.merge" : "arrow.triangle.pull",
                { prAction(); showGitMenu = false }
            ))
        }
        if let shipAction = onShip {
            items.append((
                "Ship PR", "paperplane.fill",
                { shipAction(); showGitMenu = false }
            ))
        }
        if let reviewAction = onReview {
            items.append((
                "Review", "magnifyingglass",
                { reviewAction(); showGitMenu = false }
            ))
        }
        if let syncAction = onSync {
            items.append((
                "Sync (Rebase)", "arrow.down.circle",
                { syncAction(); showGitMenu = false }
            ))
        }
        if let pushAction = onPush {
            items.append((
                "Push", "arrow.up.circle",
                { pushAction(); showGitMenu = false }
            ))
        }
        if let automergeAction = onAutomerge {
            items.append((
                "Auto-merge", "arrow.triangle.merge",
                { automergeAction(); showGitMenu = false }
            ))
        }
        return items
    }

    private var gitMenuContent: some View {
        GitMenuPopover(
            items: gitMenuItems,
            isPresented: $showGitMenu
        )
    }

    private var prIcon: String {
        if prMerged { return "arrow.triangle.merge" }
        if prAutoMerge { return "hourglass" }
        if prReviewDecision == "APPROVED" {
            return "checkmark.seal.fill"
        }
        if prReviewDecision == "CHANGES_REQUESTED" {
            return "exclamationmark.bubble.fill"
        }
        if onOpenPR != nil { return "arrow.triangle.pull" }
        return "arrow.triangle.branch"
    }

    private func gitBadge(
        icon: String, text: String, color: Color
    ) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text(text)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func perkupActionButton(
        systemImage: String,
        action: @escaping () -> Void,
        destructive: Bool = false,
        active: Bool = false,
        merged: Bool = false,
        highlighted: Bool = false
    ) -> some View {
        PerkupIconButton(
            systemImage: systemImage,
            active: active,
            merged: merged,
            highlighted: highlighted,
            destructive: destructive,
            action: action
        )
    }
}

private struct GitMenuPopover: View {
    let items: [(String, String, () -> Void)]
    @Binding var isPresented: Bool
    @State private var selectedIdx: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) {
                index, item in
                GitMenuItemView(
                    label: item.0,
                    icon: item.1,
                    isSelected: selectedIdx == index,
                    action: item.2
                )
            }
        }
        .padding(4)
        .onAppear { selectedIdx = 0 }
        .background(
            GitMenuKeyHandler(
                itemCount: items.count,
                selectedIdx: $selectedIdx,
                onConfirm: {
                    guard selectedIdx < items.count else { return }
                    items[selectedIdx].2()
                },
                onEscape: { isPresented = false }
            )
        )
    }
}

/// NSView-based key handler for the git menu popover
private struct GitMenuKeyHandler: NSViewRepresentable {
    let itemCount: Int
    @Binding var selectedIdx: Int
    let onConfirm: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> GitMenuKeyView {
        let view = GitMenuKeyView()
        view.handler = context.coordinator
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: GitMenuKeyView, context: Context) {
        view.handler = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator {
        var parent: GitMenuKeyHandler
        init(parent: GitMenuKeyHandler) { self.parent = parent }
    }
}

private class GitMenuKeyView: NSView {
    var handler: GitMenuKeyHandler.Coordinator?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let handler = handler else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 125: // down
            DispatchQueue.main.async {
                handler.parent.selectedIdx = min(
                    handler.parent.selectedIdx + 1,
                    handler.parent.itemCount - 1
                )
            }
        case 126: // up
            DispatchQueue.main.async {
                handler.parent.selectedIdx = max(
                    handler.parent.selectedIdx - 1, 0
                )
            }
        case 36: // return
            DispatchQueue.main.async {
                handler.parent.onConfirm()
            }
        case 53: // escape
            DispatchQueue.main.async {
                handler.parent.onEscape()
            }
        default:
            super.keyDown(with: event)
        }
    }
}

private struct GitMenuItemView: View {
    let label: String
    let icon: String
    var isSelected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundStyle(
                isSelected || hovered
                    ? Color.textPrimary : Color.textSecondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        Color.textPrimary.opacity(
                            isSelected ? 0.12
                                : hovered ? 0.08 : 0
                        )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct SpinningIcon: View {
    @State private var rotating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12))
            .foregroundStyle(Color.statusGreen)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    rotating = true
                }
            }
    }
}

private struct PerkupIconButton: View {
    let systemImage: String
    var active = false
    var merged = false
    var inQueue = false
    var highlighted = false
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9))
            .foregroundStyle(foregroundColor)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        Color.textPrimary.opacity(
                            highlighted ? 0.2
                                : hovered ? 0.12 : 0
                        )
                    )
            )
            .overlay(
                highlighted
                    ? RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.statusGreen.opacity(0.6), lineWidth: 1)
                    : nil
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture {
                action()
            }
    }

    private var foregroundColor: Color {
        if merged {
            return hovered ? .purple : .purple.opacity(0.7)
        }
        if inQueue {
            return hovered ? .orange : .orange.opacity(0.7)
        }
        if active {
            return hovered ? Color.statusGreen : Color.statusGreen.opacity(0.7)
        }
        if destructive {
            return hovered ? Color.statusPermission : Color.statusPermission.opacity(0.7)
        }
        return hovered ? Color.textPrimary : Color.textMuted
    }
}

#Preview("Working") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Bash",
            lastToolDetail: "cargo test"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Permission") {
    SessionCardView(
        session: .mock(
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Idle") {
    SessionCardView(session: .mock(status: .idle))
        .frame(width: 300).padding()
}
#Preview("Compacting") {
    SessionCardView(session: .mock(status: .compacting))
        .frame(width: 300).padding()
}
#Preview("Named Session") {
    SessionCardView(
        session: .mock(
            sessionName: "refactor auth flow", status: .working,
            lastTool: "Edit", lastToolDetail: "/src/auth.ts"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Source Badge CC") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/main.rs"
        ),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Source Badge OC") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "bash",
            lastToolDetail: "go test ./...", source: "opencode"
        ),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Navigate Badge") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/auth.ts"
        ),
        navigateIndex: 3
    )
    .frame(width: 300).padding()
}
#Preview("Navigate Attention") {
    SessionCardView(
        session: .mock(
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf"
        ),
        navigateIndex: 1
    )
    .frame(width: 300).padding()
}
#Preview("Navigate 10+") {
    SessionCardView(
        session: .mock(status: .idle),
        navigateIndex: 10
    )
    .frame(width: 300).padding()
}
#Preview("1 Subagent") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/main.rs",
            activeSubagents: [
                SubagentInfo(
                    agentId: "a1", agentType: "Explore",
                    startedAt: Date()
                )
            ]
        )
    )
    .frame(width: 300).padding()
}
#Preview("3 Subagents") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Agent",
            lastToolDetail: "Research API endpoints",
            activeSubagents: [
                SubagentInfo(
                    agentId: "a1", agentType: "Explore",
                    startedAt: Date()
                ),
                SubagentInfo(
                    agentId: "a2", agentType: "Explore",
                    startedAt: Date()
                ),
                SubagentInfo(
                    agentId: "a3", agentType: "Plan",
                    startedAt: Date()
                ),
            ]
        )
    )
    .frame(width: 300).padding()
}
