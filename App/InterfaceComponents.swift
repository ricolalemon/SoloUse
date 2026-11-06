import SwiftUI
import UIKit

enum SoloStyle {
  static let accent = Color(
    uiColor: UIColor {
      $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.39, green: 0.88, blue: 0.72, alpha: 1)
        : UIColor(red: 0.04, green: 0.43, blue: 0.32, alpha: 1)
    })
  static let canvas = Color(uiColor: .systemGroupedBackground)
  static let surface = Color(uiColor: .secondarySystemGroupedBackground)
  static let line = Color.primary.opacity(0.07)
}

struct SoloCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 22))
      .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(SoloStyle.line))
  }
}

struct SoloMark: View {
  var size: CGFloat = 48
  var body: some View {
    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
      .font(.system(size: size * 0.43, weight: .medium))
      .foregroundStyle(SoloStyle.accent)
      .frame(width: size, height: size)
      .background(SoloStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.29))
      .accessibilityHidden(true)
  }
}

struct StateBadge: View {
  let text: String
  var color: Color = SoloStyle.accent
  var body: some View {
    Text(L10n.text(text)).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
      .background(color.opacity(0.10), in: Capsule())
  }
}

extension TaskPhase {
  var displayColor: Color {
    switch self {
    case .failed, .interrupted: return .orange
    case .paused, .pausing, .waiting: return .orange
    case .stopped, .idle: return .secondary
    default: return SoloStyle.accent
    }
  }
  var displaySymbol: String {
    switch self {
    case .idle: return "circle.dashed"
    case .connecting: return "antenna.radiowaves.left.and.right"
    case .thinking: return "sparkles"
    case .acting: return "hand.tap"
    case .pausing, .paused: return "pause.fill"
    case .waiting: return "bubble.left.and.bubble.right.fill"
    case .completed: return "checkmark"
    case .stopped: return "stop.fill"
    case .failed, .interrupted: return "exclamationmark"
    }
  }
}

struct TaskStatusCard: View {
  let phase: TaskPhase
  let detail: String
  let modelLabel: String?
  let turns: Int
  let calls: Int
  @State private var expanded = false
  private var message: String { PhoneConnectionFailure.recognizedMessage(detail) ?? detail }
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: phase.displaySymbol).font(.system(size: 15, weight: .semibold))
        .foregroundStyle(phase.displayColor).frame(width: 34, height: 34)
        .background(phase.displayColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(L10n.text(phase.label)).font(.subheadline.weight(.semibold))
          Spacer(minLength: 0)
          if [.connecting, .thinking, .acting, .pausing].contains(phase) {
            ProgressView().controlSize(.mini).tint(phase.displayColor)
          }
        }
        if !message.isEmpty && message != phase.label {
          Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 3).textSelection(.enabled)
          if message.count > 90 {
            Button(expanded ? L10n.text("收起详情") : L10n.text("查看详情")) { expanded.toggle() }
              .font(.caption).foregroundStyle(phase.displayColor)
          }
        }
        if let modelLabel, !modelLabel.isEmpty {
          Text(L10n.text(modelLabel)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        if turns > 0 {
          Text(L10n.text("\(turns) 轮 · \(calls) 次工具调用"))
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    }.padding(14).background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 18))
      .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(phase.displayColor.opacity(0.16)))
      .accessibilityElement(children: .contain)
  }
}

struct AgentWelcomeView<Preparation: View>: View {
  let preparation: Preparation
  let onExample: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      HStack(spacing: 12) {
        SoloMark(size: 36)
        Text(L10n.text("想让手机帮你做什么？"))
          .font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
      }.padding(.top, 4)
      preparation
      VStack(alignment: .leading, spacing: 10) {
        Text(L10n.text("任务示例")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        example(
          L10n.text("查看设备信息"), detail: L10n.text("打开设置，读出系统版本"), icon: "iphone.gen3",
          prompt: L10n.text("打开设置，查看这台 iPhone 的系统版本并告诉我。"))
        example(L10n.text("整理今天的安排"), detail: L10n.text("查看日历，按时间梳理"), icon: "calendar", prompt: L10n.text("查看我今天的日历安排，按时间顺序总结给我。"))
        example(
          L10n.text("查找附近的咖啡店"), detail: L10n.text("比较评分与营业时间"), icon: "mappin.and.ellipse",
          prompt: L10n.text("帮我查找附近的咖啡店，比较评分与营业时间，先给我几个选项。"))
      }
    }
  }
  private func example(_ title: String, detail: String, icon: String, prompt: String) -> some View {
    Button {
      onExample(prompt)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 17)).foregroundStyle(SoloStyle.accent)
          .frame(width: 34, height: 38)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
      }.padding(12).background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(SoloStyle.line))
    }.buttonStyle(.plain).accessibilityHint(L10n.text("填入任务描述，由你点击开始"))
  }
}

struct QuestionPromptView: View {
  let question: String
  let choices: [String]
  let canReply: Bool
  let onChoice: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(L10n.text("需要你的回复"), systemImage: "bubble.left.and.bubble.right.fill")
        .font(.caption.weight(.semibold)).foregroundStyle(SoloStyle.accent)
      Text(question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      ForEach(choices, id: \.self) { choice in
        Button {
          onChoice(choice)
        } label: {
          HStack {
            Text(choice).font(.subheadline).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right").font(.caption)
          }.padding(12).frame(maxWidth: .infinity)
            .background(SoloStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(SoloStyle.accent).disabled(!canReply)
      }
    }
  }
}
