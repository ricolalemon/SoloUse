import Foundation

// A SoloUse-owned identifier, stable for one task. This is cache affinity, not
// authentication or an assertion that the client is Codex Desktop.
struct ModelSessionRouting {
  let id: UUID
  private(set) var turnState: String?
  init(id: UUID = UUID()) { self.id = id }
  var cacheKey: String { id.uuidString }
  func apply(to request: inout URLRequest) {
    guard request.url?.host == "chatgpt.com",
      request.url?.path == "/backend-api/codex/responses" else { return }
    request.setValue(cacheKey, forHTTPHeaderField: "session-id")
    request.setValue(cacheKey, forHTTPHeaderField: "thread-id")
    request.setValue(cacheKey, forHTTPHeaderField: "x-client-request-id")
    // Turn state is opaque, server-issued and never persisted or logged.
    if request.url?.scheme == "https", let turnState {
      request.setValue(turnState, forHTTPHeaderField: "x-codex-turn-state")
    }
  }
  mutating func receive(_ response: HTTPURLResponse) {
    guard response.url?.host == "chatgpt.com",
      response.url?.path == "/backend-api/codex/responses",
      (200...299).contains(response.statusCode), turnState == nil,
      let value = response.value(forHTTPHeaderField: "x-codex-turn-state"),
      !value.isEmpty, value.utf8.count <= 16_384,
      value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return }
    turnState = value
  }
  mutating func resetTurnState() { turnState = nil }
}
