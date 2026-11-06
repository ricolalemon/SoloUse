import SwiftUI

@MainActor final class LanguageSettings: ObservableObject {
  static let shared = LanguageSettings()
  @Published private(set) var preference: AppLanguage
  init() {
    preference = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? "system") ?? .system
  }
  func select(_ language: AppLanguage) {
    guard language != preference else { return }
    UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey)
    preference = language
    TaskNotifications.shared.configure()
  }
}

struct LanguageSettingsView: View {
  @ObservedObject private var settings = LanguageSettings.shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        ForEach(AppLanguage.allCases, id: \.rawValue) { language in
          Button {
            settings.select(language)
            dismiss()
          } label: {
            HStack {
              Text(label(language)).foregroundStyle(.primary)
              Spacer()
              if settings.preference == language {
                Image(systemName: "checkmark").foregroundStyle(SoloStyle.accent)
              }
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
      .navigationTitle(L10n.text("界面语言")).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
    }
  }
  private func label(_ language: AppLanguage) -> String {
    switch language {
    case .system: L10n.text("跟随系统")
    case .chinese: "简体中文"
    case .english: "English"
    }
  }
}
