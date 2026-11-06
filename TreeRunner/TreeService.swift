import Foundation
import Network
import XCTest

// Companion test runner is read-only. It exposes no app launching, input,
// arbitrary selector, filesystem, model, clipboard or shell endpoint.
final class TreeService: XCTestCase {
  func testServe() throws {
    continueAfterFailure = true
    func report(_ stage: String) {
      let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tree-status.json")
      try? JSONSerialization.data(withJSONObject: ["stage": stage, "time": Date().timeIntervalSince1970]).write(to: url, options: .atomic)
    }
    report("test_entered")
    let environment = ProcessInfo.processInfo.environment
    guard let token = environment["SOLOUSE_TREE_TOKEN"], token.count >= 32 else {
      report("missing_token")
      throw NSError(domain: "SoloUseTree", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing session token"])
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 49281)
    let listener: NWListener
    do { listener = try NWListener(using: parameters) }
    catch { report("listener_create_error: \(error.localizedDescription)"); throw error }
    let queue = DispatchQueue(label: "dev.solouse.tree.socket")
    var running = true
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      Self.receive(connection, token: token) { running = false }
    }
    listener.stateUpdateHandler = { state in
      switch state { case .ready: report("listener_ready_\(listener.port?.rawValue ?? 0)"); case .failed: report("listener_failed"); default: break }
    }
    listener.start(queue: queue)
    defer { listener.cancel() }
    // XCTest snapshots need its normal main-thread run loop. The requester
    // explicitly ends the session; losing testmanagerd also ends the runner.
    while running { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
  }
  private static func receive(_ connection: NWConnection, token: String, buffer: Data = Data(), finish: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
      guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
      let accumulated = buffer + data
      guard accumulated.count <= 4096 else { connection.cancel(); return }
      guard let newline = accumulated.firstIndex(of: 10) else {
        receive(connection, token: token, buffer: accumulated, finish: finish)
        return
      }
      guard newline == accumulated.index(before: accumulated.endIndex),
        let request = TreeRPC.request(Data(accumulated[..<newline]), key: token) else { connection.cancel(); return }
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        let reply: [String: Any]
        switch request.op {
        case "status": reply = ["status": "ready", "protocol": 2]
        case "tree": reply = SoloReadAccessibilityTree() as! [String: Any]
        case "stop": reply = ["status": "stopped"]
        default: reply = ["status": "unsupported"]
        }
        guard let bytes = try? TreeRPC.reply(reply, nonce: request.nonce, key: token) else { connection.cancel(); return }
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
          connection.cancel()
          if request.op == "stop" {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, finish)
            CFRunLoopWakeUp(CFRunLoopGetMain())
          }
        })
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }
}
