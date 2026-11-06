import SwiftUI

struct ChatHistoryView: View {
  @ObservedObject var model: PhoneAgentModel
  var onOpen: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var deletion: ChatHistorySummary?
  private var entries: [ChatHistorySummary] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.historyEntries.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    NavigationStack {
      List {
        if !model.canSwitchChat {
          Text(L10n.text("任务运行中，停止后可切换聊天。")).font(.footnote).foregroundStyle(.secondary)
        }
        if !model.storageStatus.isEmpty {
          Text(L10n.text(model.storageStatus)).font(.footnote).foregroundStyle(.orange)
        }
        if entries.isEmpty {
          ContentUnavailableView(search.isEmpty ? L10n.text("还没有历史聊天") : L10n.text("没有找到聊天"),
            systemImage: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
            .listRowBackground(Color.clear)
        }
        ForEach(entries) { entry in
          Button {
            if model.openHistory(entry.id) { onOpen(); dismiss() }
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 4)
                if entry.id == model.runID {
                  Image(systemName: "checkmark.circle.fill").foregroundStyle(SoloStyle.accent)
                    .accessibilityLabel(L10n.text("当前聊天"))
                }
              }
              if !entry.preview.isEmpty {
                Text((entry.hasDraft ? L10n.text("草稿 · ") : "") + entry.preview)
                  .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
              }
              HStack {
                Text(entry.updatedAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text(entry.phase == .idle ? L10n.text("未发送") : L10n.text(entry.phase.label))
              }.font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6).contentShape(Rectangle())
          }
          .buttonStyle(.plain).disabled(!model.canSwitchChat)
          .listRowBackground(SoloStyle.surface)
          .swipeActions {
            Button(L10n.text("删除"), role: .destructive) { deletion = entry }.disabled(!model.canSwitchChat)
          }
          .contextMenu {
            Button(L10n.text("删除聊天"), role: .destructive) { deletion = entry }.disabled(!model.canSwitchChat)
          }
        }
      }
      .scrollContentBackground(.hidden).background(SoloStyle.canvas)
      .navigationTitle(L10n.text("历史聊天")).navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: L10n.text("搜索聊天标题或摘要"))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.text("新聊天"), systemImage: "square.and.pencil") {
            if model.newChat() { onOpen(); dismiss() }
          }.disabled(!model.canSwitchChat)
        }
        ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { dismiss() } }
      }
      .confirmationDialog(L10n.text("删除这段聊天及其本机上下文？"), isPresented: Binding(
        get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
        Button(L10n.text("删除聊天"), role: .destructive) {
          if let deletion { _ = model.deleteHistory(deletion.id) }
          deletion = nil
        }
        Button(L10n.text("取消"), role: .cancel) { deletion = nil }
      }
      .task { model.refreshHistory() }
    }.presentationDetents([.large])
  }
}
