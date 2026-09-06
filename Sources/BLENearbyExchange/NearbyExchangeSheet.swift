import SwiftUI

struct NearbyExchangeSheet: View {
  let presenter: NearbyExchangePresenter

  var body: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 0)

      VStack(spacing: 24) {
        icon

        VStack(spacing: 8) {
          Text(title)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .keyframeAnimator(initialValue: 0.0, trigger: isFailed) { content, offset in
        content.offset(x: offset)
      } keyframes: { _ in
        KeyframeTrack {
          SpringKeyframe(isFailed ? -14 : 0, duration: 0.08)
          SpringKeyframe(isFailed ? 14 : 0, duration: 0.08)
          SpringKeyframe(isFailed ? -9 : 0, duration: 0.08)
          SpringKeyframe(isFailed ? 9 : 0, duration: 0.08)
          SpringKeyframe(0, duration: 0.12)
        }
      }

      Spacer(minLength: 0)

      Button("Cancel") {
        presenter.cancel()
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .opacity(presenter.isFinished ? 0 : 1)
      .disabled(presenter.isFinished)
    }
    .padding(32)
    .frame(maxWidth: .infinity)
    .presentationDetents([.medium])
    .presentationDragIndicator(.hidden)
    .sensoryFeedback(trigger: isFailed) { _, failed in
      failed ? .error : nil
    }
  }

  private var icon: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.12))

      Circle()
        .trim(from: 0, to: presenter.progress)
        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.smooth(duration: 0.5), value: presenter.progress)

      Image(systemName: iconName)
        .font(.system(size: 52))
        .foregroundStyle(accent)
        .symbolEffect(.variableColor.iterative.reversing, isActive: isSearching)
    }
    .frame(width: 120, height: 120)
    .animation(.smooth(duration: 0.3), value: accent)
  }

  private var isSearching: Bool {
    switch presenter.phase {
    case .searching, .exchanging:
      return true
    default:
      return false
    }
  }

  private var isFailed: Bool {
    if case .failed = presenter.phase {
      true
    } else {
      false
    }
  }

  private var accent: Color {
    switch presenter.phase {
    case .completed: .green
    case .failed: .red
    default: .accentColor
    }
  }

  private var iconName: String {
    switch presenter.phase {
    case .searching: "dot.radiowaves.left.and.right"
    case .approaching: "arrow.down.forward.and.arrow.up.backward"
    case .exchanging: "arrow.left.arrow.right"
    case .completed: "checkmark"
    case .failed: "exclamationmark"
    }
  }

  private var title: String {
    switch presenter.phase {
    case .searching: "Looking for a device"
    case .approaching(nil): "Device connected"
    case .approaching: "Move closer"
    case .exchanging: "Exchanging"
    case .completed: "Exchange complete"
    case .failed: "Failure"
    }
  }

  private var subtitle: String {
    switch presenter.phase {
    case .searching: "Hold your iPhone near the other device."
    case .approaching(nil): "Measuring the distance."
    case .approaching: "Bring the devices together until they touch."
    case .exchanging: "Keep the devices together."
    case .completed: "You can put your devices down."
    case let .failed(error): error.message
    }
  }
}
