import Foundation

@main struct SessionRoutingTests {
  static func main() throws {
    var routing = ModelSessionRouting()
    var http = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
    var socket = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/codex/responses")!)
    routing.apply(to: &http); routing.apply(to: &socket)
    precondition(http.value(forHTTPHeaderField: "session-id") == routing.cacheKey)
    precondition(socket.value(forHTTPHeaderField: "session-id") == routing.cacheKey)
    precondition(http.value(forHTTPHeaderField: "thread-id") == socket.value(forHTTPHeaderField: "thread-id"))
    precondition(ModelSessionRouting().cacheKey != routing.cacheKey)
    var login = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
    routing.apply(to: &login)
    precondition(login.allHTTPHeaderFields?.isEmpty != false)
    print("PASS stable HTTP/WebSocket task identity, isolated tasks and endpoint scope")
    func response(_ state: String, code: Int = 200) -> HTTPURLResponse {
      HTTPURLResponse(url: http.url!, statusCode: code, httpVersion: nil,
        headerFields: ["x-codex-turn-state": state])!
    }
    routing.receive(response("untrusted-error", code: 401))
    precondition(routing.turnState == nil)
    routing.receive(response("opaque-fixture")); routing.receive(response("replacement"))
    routing.apply(to: &http); routing.apply(to: &socket)
    precondition(http.value(forHTTPHeaderField: "x-codex-turn-state") == "opaque-fixture")
    precondition(socket.value(forHTTPHeaderField: "x-codex-turn-state") == nil)
    routing.resetTurnState()
    var next = URLRequest(url: http.url!); routing.apply(to: &next)
    precondition(next.value(forHTTPHeaderField: "x-codex-turn-state") == nil)
    routing.receive(response(String(repeating: "x", count: 16_385)))
    precondition(routing.turnState == nil)
    print("PASS bounded server state, first receipt preservation and reset")
  }
}
