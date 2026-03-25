import Combine
import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    static let layoutChanged = Notification.Name("layoutChanged")
    static let sessionNeedsAttention = Notification.Name("sessionNeedsAttention")
}

enum PopupTab {
    case active, inReview, recent
}

private let overlayAnimationDuration: TimeInterval = 0.2

struct PopupView: View {
    let sessions: [Session]
    var recentProjects: [RecentProject] = []
    @ObservedObject var updater: UpdaterBase
    var pluginManager: PluginManager?
    var navigate: NavigateController?
    @ObservedObject var overlayController: OverlayController = OverlayController()
    @ObservedObject var worktreeManager: WorktreeManager = WorktreeManager()
    var isFocused = false
    var onRefreshSessions: (() -> Void)?
    var initialTab: PopupTab = .active
    @State private var selectedTab: PopupTab = .active
    @State private var selectedIndex: Int?
    @State private var gearHovered = false
    @State private var versionHovered = false
    @State private var shortcutHovered = false
    @State private var ocBannerInstalled = false
    @State private var lastFocusTime: Date = .distantPast
    @State private var piBannerInstalled = false
    @State private var showNewWorktreeInput = false
    @State private var newBranchName = ""
    @State private var newWorktreeHovered = false
    @State private var shipSessionPath: String?
    @State private var refreshHovered = false
    @State private var isRefreshing = false
    @AppStorage("ocBannerDismissed") private var ocBannerDismissed = false
    @AppStorage("piBannerDismissed") private var piBannerDismissed = false

    private var showOcBanner: Bool {
        pluginManager.map { $0.ocConfigExists && !$0.ocInstalled && !ocBannerDismissed } ?? false
    }
    private var showPiBanner: Bool {
        pluginManager.map { $0.piConfigExists && !$0.piInstalled && !piBannerDismissed } ?? false
    }

    private var showTabs: Bool { true }

    private var perkupSessions: [Session] {
        sessions.filter {
            WorktreeManager.isPerkupWorktree($0.projectPath)
        }
    }

    private var inReviewSessions: [Session] {
        Session.sorted(
            sessions.filter { session in
                WorktreeManager.isPerkupWorktree(session.projectPath)
                    && worktreeManager.openPRs[session.branch] != nil
            }
        )
    }

    private var activeSessions: [Session] {
        sessions.filter { session in
            // Only show perkup worktree sessions
            guard WorktreeManager.isPerkupWorktree(session.projectPath) else {
                return false
            }
            // Perkup sessions move to In Review if they have a PR
            return worktreeManager.openPRs[session.branch] == nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                sessions: perkupSessions,
                activeServerCount: perkupSessions.filter {
                    worktreeManager.isServerRunning(for: $0.projectPath)
                }.count
            )
            if let error = worktreeManager.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 10))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        worktreeManager.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.statusPermission)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.statusPermission.opacity(0.1))
            }
            Divider()
            if showTabs {
                tabPicker
                Divider()
            }
            ZStack(alignment: .top) {
                Group {
                    switch selectedTab {
                    case .active: activeContent
                    case .inReview: inReviewContent
                    case .recent: recentContent
                    }
                }
                .opacity(overlayController.hideContent ? 0 : 1)
                .animation(.none, value: overlayController.hideContent)
                if let overlay = overlayController.active {
                    overlayPanel {
                        switch overlay {
                        case .settings:
                            SettingsSection(
                                updater: updater,
                                pluginManager: pluginManager ?? PluginManager()
                            )
                        case .about:
                            AboutView()
                        }
                    }
                }
            }
            .clipped()
            .animation(.easeInOut(duration: overlayAnimationDuration), value: overlayController.active)
            shipReviewerPicker
            newWorktreeInputBar
            Divider()
            footerBar
        }
        .onReceive(navigate?.didActivateSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            selectedIndex = nil
            if selectedTab == .recent { selectedTab = .active }
            if overlayController.active != nil { closeOverlay(animated: false) }
        }
        .onReceive(navigate?.navActionSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { action in
            guard overlayController.active == nil else { return }
            handleNavAction(action)
        }
        .onChange(of: selectedTab) { _ in selectedIndex = nil }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sessionNeedsAttention
            )
        ) { notification in
            guard let path = notification.userInfo?["projectPath"]
                as? String else { return }
            // Switch to whichever tab contains this session
            let isInReview = inReviewSessions.contains {
                $0.projectPath == path
            }
            let targetTab: PopupTab = isInReview ? .inReview : .active
            if selectedTab != targetTab {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = targetTab
                }
            }
        }
        .onAppear {
            selectedTab = initialTab
            worktreeManager.refreshPRs()
            worktreeManager.refreshGitSync(sessions: sessions)
            worktreeManager.refreshExternalServers(sessions: sessions)
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { _ in
            worktreeManager.refreshPRs()
            worktreeManager.refreshGitSync(sessions: sessions)
        }
        .onReceive(
            Timer.publish(every: 3, on: .main, in: .common).autoconnect()
        ) { _ in
            worktreeManager.refreshExternalServers(sessions: sessions)
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 6) {
            tabButton(
                "Active",
                count: activeSessions.count,
                tab: .active,
                hasUrgent: activeSessions.contains { $0.status == .waitingPermission }
            )
            tabButton(
                "In Review",
                count: inReviewSessions.count,
                tab: .inReview,
                hasUrgent: inReviewSessions.contains { $0.status == .waitingPermission }
            )
            Spacer()
            if isFocused {
                Text("[]: tabs  ↑↓: select  1-9: jump")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabButton(_ label: String, count: Int, tab: PopupTab, hasUrgent: Bool = false) -> some View {
        TabButtonView(label: label, count: count, isSelected: selectedTab == tab, hasUrgent: hasUrgent) {
            if overlayController.active != nil { closeOverlay(animated: true) }
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            notifyLayoutChanged()
        }
    }
    // MARK: - Shared session list

    private func sessionListView(
        sessions list: [Session],
        emptyIcon: String = "tray",
        emptyText: String = "No sessions"
    ) -> some View {
        Group {
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: emptyIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.textMuted)
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(list.enumerated()),
                                id: \.element.id
                            ) { index, session in
                                if index > 0 {
                                    Divider()
                                        .padding(.horizontal, 16)
                                }
                                sessionCard(
                                    session: session, index: index
                                )
                                .id(session.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 290)
                    .onChange(of: selectedIndex) { newIndex in
                        guard let idx = newIndex,
                              idx < list.count else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(list[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func sessionCard(
        session: Session, index: Int
    ) -> some View {
        SessionCardView(
            session: session,
            navigateIndex: isFocused ? index + 1 : nil,
            showSourceBadge: hasMultipleSources,
            isSelected: selectedIndex == index,
            isPerkupWorktree: WorktreeManager.isPerkupWorktree(
                session.projectPath
            ),
            onOpenCursor: {
                worktreeManager.openCursor(
                    projectPath: session.projectPath
                )
            },
            onOpenChrome: perkupChromeAction(for: session),
            onToggleServer: perkupToggleServerAction(for: session),
            isServerRunning: perkupIsDevRunning(for: session),
            isServerLoading: worktreeManager.serverLoadingPaths
                .contains(session.projectPath),
            onOpenPR: perkupPRAction(for: session),
            prMerged: worktreeManager.openPRs[session.branch]?.merged ?? false,
            prReviewDecision: worktreeManager.openPRs[session.branch]?.reviewDecision ?? "",
            gitAhead: worktreeManager.gitSyncStatus[session.projectPath]?.ahead ?? 0,
            gitBehind: worktreeManager.gitSyncStatus[session.projectPath]?.behind ?? 0,
            gitUnpushed: worktreeManager.gitSyncStatus[session.projectPath]?.unpushed ?? false,
            onShip: perkupShipAction(for: session),
            isShipping: worktreeManager.shippingPaths
                .contains(session.projectPath),
            onRemove: perkupRemoveAction(for: session),
            isRemoving: worktreeManager.removingPaths
                .contains(session.projectPath)
        )
        .contextMenu {
            Button {
                worktreeManager.openCursor(
                    projectPath: session.projectPath
                )
            } label: {
                Label("Open in Cursor", systemImage: "terminal")
            }
            if perkupPort(for: session) != nil {
                Button {
                    worktreeManager.openWeb(
                        projectPath: session.projectPath
                    )
                } label: {
                    Label("Open in Chrome", systemImage: "globe")
                }
            }
            Button {
                openInFinder(path: session.projectPath)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            Button { copyPath(session.projectPath) } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if WorktreeManager.isPerkupWorktree(session.projectPath) {
                Divider()
                Button(role: .destructive) {
                    worktreeManager.removeWorktree(
                        projectPath: session.projectPath
                    )
                } label: {
                    Label("Remove Worktree", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Active tab
    private var activeContent: some View {
        sessionListView(
            sessions: sortedSessions,
            emptyIcon: "tray",
            emptyText: "No active sessions"
        )
    }

    // MARK: - In Review tab
    private var inReviewContent: some View {
        sessionListView(
            sessions: inReviewSessions,
            emptyIcon: "arrow.triangle.pull",
            emptyText: "No branches with open PRs"
        )
    }

    // MARK: - Recent tab
    @ViewBuilder
    private var recentContent: some View {
        if recentProjects.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.textMuted)
                Text("Recent projects will appear here\nafter sessions end")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recentProjects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                            recentCard(project, isSelected: selectedIndex == index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 290)
                .onChange(of: selectedIndex) { newIndex in
                    guard selectedTab == .recent,
                          let idx = newIndex, idx < recentProjects.count else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(recentProjects[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func recentCard(_ project: RecentProject, isSelected: Bool = false) -> some View {
        RecentProjectCardView(project: project, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture { openInEditor(project: project); NSApp.deactivate() }
            .contextMenu {
                Button { openInEditor(project: project); NSApp.deactivate() } label: {
                    Label("Open in Editor", systemImage: "macwindow")
                }
                Button { openInFinder(path: project.projectPath) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Button { copyPath(project.projectPath) } label: {
                    Label("Copy Project Path", systemImage: "doc.on.doc")
                }
            }
            .help("Click to open in \(project.lastEditor ?? "editor")")
    }

}

// MARK: - Overlay & Footer

extension PopupView {
    func overlayPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content().padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.panelBackground)
        .transition(.asymmetric(
            insertion: .move(edge: .top),
            removal: .modifier(
                active: RollUpEffect(progress: 0),
                identity: RollUpEffect(progress: 1)
            )
        ))
    }

    var footerBar: some View {
        HStack {
            QuitButton()
            versionButton
            footerShortcutHints
            Spacer()
            refreshButton
            newWorktreeButton
            settingsGearButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var refreshButton: some View {
        Button {
            isRefreshing = true
            worktreeManager.refreshPRs()
            worktreeManager.refreshGitSync(sessions: sessions)
            onRefreshSessions?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                isRefreshing = false
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    refreshHovered
                        ? Color.textPrimary : Color.textSecondary
                )
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.6) : .default,
                    value: isRefreshing
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            Color.textPrimary.opacity(
                                refreshHovered ? 0.1 : 0
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { refreshHovered = $0 }
        .help("Refresh PR status")
    }

    private var newWorktreeButton: some View {
        Button { showNewWorktreeInput.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    newWorktreeHovered
                        ? Color.textPrimary : Color.textSecondary
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            Color.textPrimary.opacity(
                                newWorktreeHovered ? 0.1 : 0
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { newWorktreeHovered = $0 }
    }

    @ViewBuilder
    private var newWorktreeInputBar: some View {
        if showNewWorktreeInput {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("eng-12700-feature-name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit {
                            guard !newBranchName.isEmpty else { return }
                            worktreeManager.createWorktree(
                                branch: newBranchName
                            )
                            newBranchName = ""
                            showNewWorktreeInput = false
                        }
                    Button {
                        guard !newBranchName.isEmpty else { return }
                        worktreeManager.createWorktree(
                            branch: newBranchName
                        )
                        newBranchName = ""
                        showNewWorktreeInput = false
                    } label: {
                        Text("Create")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.statusGreen)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        newBranchName.isEmpty || worktreeManager.isCreating
                    )
                    Button {
                        showNewWorktreeInput = false
                        newBranchName = ""
                        worktreeManager.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                if worktreeManager.isCreating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Creating worktree...")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted)
                        Spacer()
                    }
                }
                if let error = worktreeManager.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.statusPermission)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
        }
    }

    @ViewBuilder
    private var shipReviewerPicker: some View {
        if let path = shipSessionPath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            VStack(spacing: 6) {
                HStack {
                    Text("Ship \(name)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Button {
                        shipSessionPath = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                Text("Select reviewer (+ Cameron)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                HStack(spacing: 8) {
                    Button {
                        worktreeManager.ship(
                            projectPath: path, reviewer: "connor"
                        )
                        shipSessionPath = nil
                    } label: {
                        Text("Connor")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.statusGreen)
                            )
                    }
                    .buttonStyle(.plain)
                    Button {
                        worktreeManager.ship(
                            projectPath: path, reviewer: "dyego"
                        )
                        shipSessionPath = nil
                    } label: {
                        Text("Dyego")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.statusGreen)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
        }
    }

    private var versionButton: some View {
        let isActive = overlayController.active == .about
        let color: Color = isActive ? .amber : (versionHovered ? .primary : .textMuted)
        return Button { toggleOverlay(.about) } label: {
            Text("v\(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(color)
                .underline(versionHovered && !isActive)
        }
        .buttonStyle(.plain)
        .onHover { versionHovered = $0 }
    }

    private var settingsGearButton: some View {
        Button { toggleOverlay(.settings) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(overlayController.active == .settings ? Color.amber : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.textPrimary.opacity(gearHovered ? 0.1 : 0))
                )
                .overlay(alignment: .topTrailing) {
                    if updater.pendingUpdateVersion != nil && overlayController.active != .settings {
                        Circle().fill(Color.amber).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
    }

    // MARK: - Helpers

    @ViewBuilder private var footerShortcutHints: some View {
        if let sc = KeyboardShortcuts.getShortcut(for: .navigate) {
            Button { toggleOverlay(.settings) } label: {
                Text("\(sc.description) navigate")
                    .font(.system(size: 10))
                    .foregroundStyle(shortcutHovered ? Color.primary : Color.textSecondary)
                    .underline(shortcutHovered)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { shortcutHovered = $0 }
        } else { EmptyView() }
    }
    private var isNavigateActive: Bool { navigate?.isActive ?? false }
    private var hasMultipleSources: Bool { Set(sessions.map(\.sourceLabel)).count > 1 }
    private var sortedSessions: [Session] {
        Session.sorted(activeSessions)
    }

    private func focusSession(_ session: Session) {
        guard Date().timeIntervalSince(lastFocusTime) > 0.5 else { return }
        lastFocusTime = Date()
        focusTerminal(session: session)
    }

    private func toggleOverlay(_ overlay: PopupOverlay) {
        if overlayController.active == overlay {
            closeOverlay(animated: true)
        } else {
            overlayController.active = nil
            overlayController.hideContent = true
            overlayController.active = overlay
            notifyLayoutChanged()
        }
    }
    private func closeOverlay(animated: Bool) {
        overlayController.active = nil
        notifyLayoutChanged()
        guard animated else { overlayController.hideContent = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayAnimationDuration) { overlayController.hideContent = false }
    }

    private func notifyLayoutChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .layoutChanged, object: nil) }
    }
    // MARK: - PerkUp helpers

    private func perkupPort(for session: Session) -> Int? {
        guard WorktreeManager.isPerkupWorktree(session.projectPath) else {
            return nil
        }
        return WorktreeManager.readPort(from: session.projectPath)
    }

    private func perkupChromeAction(
        for session: Session
    ) -> (() -> Void)? {
        guard WorktreeManager.isPerkupWorktree(session.projectPath) else {
            return nil
        }
        return {
            worktreeManager.openWeb(projectPath: session.projectPath)
            NSApp.deactivate()
        }
    }

    private func perkupIsDevRunning(for session: Session) -> Bool {
        worktreeManager.isServerRunning(for: session.projectPath)
    }

    private func perkupToggleServerAction(
        for session: Session
    ) -> (() -> Void)? {
        guard WorktreeManager.isPerkupWorktree(session.projectPath) else {
            return nil
        }
        return {
            if worktreeManager.isServerRunning(for: session.projectPath) {
                worktreeManager.stopDevServer(projectPath: session.projectPath)
            } else {
                worktreeManager.startDevServer(projectPath: session.projectPath)
            }
        }
    }

    private func perkupPRAction(
        for session: Session
    ) -> (() -> Void)? {
        guard worktreeManager.openPRs[session.branch] != nil else {
            return nil
        }
        let name = URL(fileURLWithPath: session.projectPath).lastPathComponent
        return {
            // Use pw pr command
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [
                    "-l", "-c",
                    "\(self.worktreeManager.pwPath) pr \(name)",
                ]
                try? proc.run()
            }
            NSApp.deactivate()
        }
    }

    private func perkupShipAction(
        for session: Session
    ) -> (() -> Void)? {
        guard WorktreeManager.isPerkupWorktree(session.projectPath),
              worktreeManager.openPRs[session.branch] == nil,
              !worktreeManager.shippingPaths.contains(session.projectPath)
        else {
            return nil
        }
        return {
            shipSessionPath = session.projectPath
        }
    }

    private func perkupRemoveAction(
        for session: Session
    ) -> (() -> Void)? {
        guard WorktreeManager.isPerkupWorktree(session.projectPath) else {
            return nil
        }
        return { worktreeManager.removeWorktree(projectPath: session.projectPath) }
    }

    private func openInFinder(path: String) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func handleNavAction(_ action: PanelNavAction) {
        switch action {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .confirm: confirmSelection()
        case .escape, .reset: selectedIndex = nil
        case .toggleTab, .previousTab, .nextTab: switchTab(to: action)
        case .jumpTo(let index): jumpToDisplayedSession(index: index)
        }
    }

    private func jumpToDisplayedSession(index: Int) {
        let list = currentTabSessions
        guard index < list.count else { return }
        worktreeManager.openCursor(
            projectPath: list[index].projectPath
        )
        selectedIndex = nil
        // Re-show panel after Cursor steals focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: .sessionNeedsAttention, object: nil
            )
        }
    }

    private var currentTabSessions: [Session] {
        switch selectedTab {
        case .active: return sortedSessions
        case .inReview: return inReviewSessions
        case .recent: return []
        }
    }

    private func moveSelection(by delta: Int) {
        let count = currentTabSessions.count
        guard count > 0 else { return }
        selectedIndex = selectedIndex.map {
            ($0 + delta + count) % count
        } ?? (delta > 0 ? 0 : count - 1)
    }

    private func confirmSelection() {
        guard let index = selectedIndex,
              index < currentTabSessions.count else { return }
        worktreeManager.openCursor(
            projectPath: currentTabSessions[index].projectPath
        )
        selectedIndex = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: .sessionNeedsAttention, object: nil
            )
        }
    }

    private func switchTab(to action: PanelNavAction) {
        guard showTabs else { return }
        let newTab: PopupTab = action == .previousTab ? .active : action == .nextTab ? .inReview
            : (selectedTab == .active ? .inReview : .active)
        guard newTab != selectedTab else { return }
        if overlayController.active != nil { closeOverlay(animated: true) }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = newTab }
        notifyLayoutChanged()
    }
}
