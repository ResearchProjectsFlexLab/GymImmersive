import SwiftUI

/// LED-style board on the gym's front wall: workout time left, the current round and the
/// time of day (the same local clock the time log uses).
struct WallTimerBoard: View {
    var controller: SessionController

    var body: some View {
        VStack(spacing: 4) {
            Text(controller.sessionCountdownText)
                .font(.system(size: 120, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.12))
                .shadow(color: .orange.opacity(0.8), radius: 12)
            Text(controller.status == .ready ? "PRESS START" : controller.setTitle.uppercased())
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
        .background(.black.opacity(0.9), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.gray.opacity(0.6), lineWidth: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workout time left \(controller.sessionCountdownText), \(controller.setTitle)")
    }
}
