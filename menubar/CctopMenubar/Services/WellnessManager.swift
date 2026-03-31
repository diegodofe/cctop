import AppKit
import Combine
import SwiftUI
import os.log

private let logger = Logger(
    subsystem: "com.perkup.arborist",
    category: "WellnessManager"
)

@MainActor
class WellnessManager: ObservableObject {
    // MARK: - Workday State

    @Published var isWorkdayActive = false
    @Published var workdayStartTime: Date?

    // MARK: - Eye Break (20-20-20)

    /// Seconds since last eye break acknowledgment
    @Published var eyeSecondsSinceBreak: Int = 0
    /// How many eye breaks have been skipped/overdue
    var eyeUrgency: Int {
        let overdue = eyeSecondsSinceBreak - eyeBreakInterval
        if overdue <= 0 { return 0 }
        // Urgency increases every 5 minutes overdue
        return min(overdue / 300 + 1, 5)
    }

    // MARK: - Hydration

    @Published var waterCount: Int = 0
    @Published var waterSecondsSinceLast: Int = 0
    /// Target glasses for the day (8 glasses over ~8 hours)
    let waterTarget: Int = 8
    /// Where you should be by now based on elapsed time
    var waterExpected: Int {
        guard let start = workdayStartTime else { return 0 }
        let hoursWorked = Date().timeIntervalSince(start) / 3600
        // 1 glass per hour, capped at target
        return min(Int(hoursWorked) + 1, waterTarget)
    }
    /// How far behind you are
    var waterDeficit: Int {
        max(waterExpected - waterCount, 0)
    }

    // MARK: - Session Timer

    @Published var sessionSeconds: Int = 0
    @Published var isPaused = false

    // MARK: - Config

    let eyeBreakInterval: Int = 20 * 60  // 20 minutes

    private var timer: AnyCancellable?

    init() {}

    // MARK: - Workday Controls

    func startWorkday() {
        isWorkdayActive = true
        workdayStartTime = Date()
        waterCount = 0
        eyeSecondsSinceBreak = 0
        sessionSeconds = 0
        isPaused = false
        startTimer()
    }

    func endWorkday() {
        isWorkdayActive = false
        timer?.cancel()
        timer = nil
    }

    func togglePause() {
        isPaused.toggle()
    }

    private func startTimer() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard isWorkdayActive, !isPaused else { return }

        sessionSeconds += 1
        eyeSecondsSinceBreak += 1
        waterSecondsSinceLast += 1

        // Eye break due — play sound on first trigger
        if eyeSecondsSinceBreak == eyeBreakInterval {
            playSound("Tink")
        }
        // Escalating reminders every 5 minutes overdue
        if eyeSecondsSinceBreak > eyeBreakInterval
            && (eyeSecondsSinceBreak - eyeBreakInterval) % 300 == 0
        {
            playSound("Sosumi")
        }

        // Water reminder — nudge if behind by 2+ glasses
        if waterDeficit >= 2
            && sessionSeconds % 900 == 0
        {
            playSound("Purr")
        }
    }

    // MARK: - User Actions

    func acknowledgeEyeBreak() {
        eyeSecondsSinceBreak = 0
    }

    func drankWater() {
        waterCount += 1
        waterSecondsSinceLast = 0
    }

    /// Single action: took a break (resets eyes + logs water)
    func tookBreak() {
        eyeSecondsSinceBreak = 0
        waterCount += 1
        waterSecondsSinceLast = 0
    }

    func resetSession() {
        sessionSeconds = 0
    }

    // MARK: - Display

    var eyeBreakText: String {
        let remaining = eyeBreakInterval - eyeSecondsSinceBreak
        if remaining > 0 {
            let mins = remaining / 60
            let secs = remaining % 60
            return "\(mins):\(String(format: "%02d", secs))"
        }
        let overdue = -remaining
        let mins = overdue / 60
        let secs = overdue % 60
        return "+\(mins):\(String(format: "%02d", secs))"
    }

    var eyeBreakColor: Color {
        if eyeSecondsSinceBreak < eyeBreakInterval {
            // Counting down — get warmer as time approaches
            let progress = Double(eyeSecondsSinceBreak)
                / Double(eyeBreakInterval)
            if progress < 0.75 { return Color.textMuted }
            return Color.statusAttention.opacity(
                0.5 + progress * 0.5
            )
        }
        // Overdue — escalate from orange to red
        switch eyeUrgency {
        case 0: return Color.textMuted
        case 1: return Color.statusAttention
        case 2: return Color.orange
        default: return Color.statusPermission
        }
    }

    var waterText: String {
        let mins = waterSecondsSinceLast / 60
        let secs = waterSecondsSinceLast % 60
        return "\(waterCount)/\(waterTarget) \(mins):\(String(format: "%02d", secs))"
    }

    var waterColor: Color {
        if waterDeficit == 0 { return Color.blue.opacity(0.5) }
        if waterDeficit == 1 { return Color.statusAttention }
        return Color.statusPermission
    }

    var sessionText: String {
        let hours = sessionSeconds / 3600
        let mins = (sessionSeconds % 3600) / 60
        let secs = sessionSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
        }
        return "\(mins):\(String(format: "%02d", secs))"
    }

    var sessionColor: Color {
        Color.textMuted
    }

    // MARK: - Helpers

    private func playSound(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(
                fileURLWithPath: "/usr/bin/afplay"
            )
            proc.arguments = [
                "/System/Library/Sounds/\(name).aiff",
            ]
            try? proc.run()
        }
    }
}
