import ActivityKit
import WidgetKit
import SwiftUI

struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(context.state.isError ? Color.red.opacity(0.2) : Color.cyan.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: context.state.isComplete
                          ? (context.state.isError ? "xmark" : "checkmark")
                          : "sparkles")
                        .foregroundStyle(context.state.isError ? Color.red : Color.cyan)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("aiity")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(context.state.phase)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !context.state.detail.isEmpty {
                        Text(context.state.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !context.state.isComplete {
                    ProgressView(value: context.state.progress)
                        .frame(width: 48)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.phase)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.isComplete {
                        ProgressView(value: context.state.progress)
                    } else {
                        Text(context.state.isError ? "Fehler" : "Fertig")
                            .font(.caption.weight(.semibold))
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isComplete
                      ? (context.state.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                      : "sparkles")
                    .foregroundStyle(context.state.isError ? .red : .cyan)
            } compactTrailing: {
                if context.state.isComplete {
                    Text(context.state.isError ? "!" : "✓")
                        .font(.caption2.weight(.bold))
                } else {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            }
        }
    }
}
