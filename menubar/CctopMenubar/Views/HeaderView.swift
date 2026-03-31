import AppKit
import SwiftUI

// MARK: - Window drag area

private func makeMoveCursor(color: NSColor) -> NSCursor {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let mid: CGFloat = 8
        let arm: CGFloat = 5
        let tip: CGFloat = 2.5

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Cross lines
        ctx.move(to: CGPoint(x: mid, y: mid - arm))
        ctx.addLine(to: CGPoint(x: mid, y: mid + arm))
        ctx.move(to: CGPoint(x: mid - arm, y: mid))
        ctx.addLine(to: CGPoint(x: mid + arm, y: mid))

        // Arrowheads: top, bottom, left, right
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
            let tipPt = CGPoint(x: mid + dx * arm, y: mid + dy * arm)
            ctx.move(to: CGPoint(x: tipPt.x - dy * tip, y: tipPt.y - dx * tip))
            ctx.addLine(to: tipPt)
            ctx.addLine(to: CGPoint(x: tipPt.x + dy * tip, y: tipPt.y + dx * tip))
        }

        ctx.strokePath()
        return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
}

private let darkMoveCursor = makeMoveCursor(color: NSColor(white: 0.15, alpha: 1))
private let lightMoveCursor = makeMoveCursor(color: NSColor(white: 0.9, alpha: 1))

private class DragCursorView: NSView {
    private var currentMoveCursor: NSCursor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? lightMoveCursor : darkMoveCursor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentMoveCursor)
    }

    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = cursorTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        currentMoveCursor.set()
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragCursorView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HeaderView: View {
    let sessions: [Session]
    var activeServerCount: Int = 0
    @ObservedObject var wellness: WellnessManager

    var body: some View {
        let counts = StatusCounts(sessions: sessions)

        HStack(spacing: 6) {
            // Left: title + servers + session statuses
            Text("Arborist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .overlay(WindowDragArea())
            if activeServerCount > 0 {
                StatusChip(
                    count: activeServerCount,
                    color: .purple,
                    iconName: "server.rack",
                    categoryLabel: "servers running"
                )
            }
            StatusChip(
                count: counts.permission,
                color: Color.statusPermission,
                iconName: "exclamationmark.triangle.fill",
                categoryLabel: "need permission"
            )
            StatusChip(
                count: counts.attention,
                color: Color.statusAttention,
                iconName: "bubble.left.fill",
                categoryLabel: "need attention"
            )
            StatusChip(
                count: counts.working,
                color: Color.statusGreen,
                iconName: "arrow.triangle.2.circlepath",
                categoryLabel: "working"
            )
            StatusChip(
                count: counts.idle,
                color: Color.textMuted,
                iconName: "moon.zzz.fill",
                categoryLabel: "idle"
            )

            Spacer()

            // Right: wellness indicators
            if wellness.isWorkdayActive {
                Image(systemName: "eye")
                    .font(.system(size: 9))
                    .foregroundStyle(wellness.eyeBreakColor)
                Image(systemName: "drop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(wellness.waterColor)
                Text(wellness.sessionText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    private func wellnessChip(
        icon: String,
        text: String,
        color: Color,
        pulse: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(text)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(pulse ? 0.15 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func headerBarColor(counts: StatusCounts) -> Color {
        // unused but kept for compatibility
        if counts.permission > 0 {
            return Color.statusPermission
        }
        if counts.attention > 0 {
            return Color.statusAttention
        }
        if counts.working > 0 {
            return Color.statusGreen.opacity(0.5)
        }
        return Color.textMuted
    }
}

private struct WellnessControlButton: View {
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(
                    hovered ? Color.textPrimary : Color.textMuted
                )
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            Color.textPrimary.opacity(
                                hovered ? 0.12 : 0
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase, wellness: WellnessManager())
        .frame(width: 320).padding()
}
