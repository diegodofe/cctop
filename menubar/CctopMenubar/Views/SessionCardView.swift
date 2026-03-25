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
    var gitAhead: Int = 0
    var gitBehind: Int = 0
    var gitUnpushed = false
    var onShip: (() -> Void)?
    var isShipping = false
    var onRemove: (() -> Void)?
    var isRemoving = false
    @State private var isHovered = false
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
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            session.status == .idle
                                ? Color.textDimmed : Color.textPrimary
                        )

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
                        HStack(spacing: 2) {
                            if let prAction = onOpenPR {
                                perkupActionButton(
                                    systemImage: prMerged
                                        ? "checkmark.circle.fill"
                                        : "arrow.triangle.pull",
                                    action: prAction,
                                    destructive:
                                        prReviewDecision == "CHANGES_REQUESTED",
                                    active: prReviewDecision == "APPROVED",
                                    merged: prMerged
                                )
                            }
                            if isShipping {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            } else if let shipAction = onShip {
                                perkupActionButton(
                                    systemImage: "paperplane.fill",
                                    action: shipAction
                                )
                            }
                            if let cursorAction = onOpenCursor {
                                perkupActionButton(
                                    systemImage: "chevron.left.forwardslash.chevron.right",
                                    action: cursorAction
                                )
                            }
                            if let chromeAction = onOpenChrome {
                                perkupActionButton(
                                    systemImage: "globe",
                                    action: chromeAction
                                )
                            }
                            if isServerLoading {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            } else if let serverAction = onToggleServer {
                                perkupActionButton(
                                    systemImage: isServerRunning
                                        ? "stop.fill" : "play.fill",
                                    action: serverAction,
                                    destructive: isServerRunning,
                                    active: !isServerRunning
                                )
                            }
                            if isRemoving {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            } else if let removeAction = onRemove {
                                perkupActionButton(
                                    systemImage: "trash",
                                    action: removeAction,
                                    destructive: true
                                )
                            }
                        }
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
                        if !gitUnpushed && gitAhead == 0
                            && gitBehind == 0
                        {
                            gitBadge(
                                icon: "checkmark",
                                text: "synced",
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
        merged: Bool = false
    ) -> some View {
        PerkupIconButton(
            systemImage: systemImage,
            active: active,
            merged: merged,
            destructive: destructive,
            action: action
        )
    }
}

private struct SpinningIcon: View {
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
                    .fill(Color.textPrimary.opacity(hovered ? 0.12 : 0))
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
