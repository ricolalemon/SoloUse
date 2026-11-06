import Foundation

@main struct AccessibilityTreeTests {
  @MainActor static func main() async throws {
    let original = try JSONValue([
      "status": "available", "viewport": ["width": 440, "height": 956],
      "applications": [["app_id": "fixture", "root": ["id": "n0", "children": [
        ["id": "n1", "label": "中 English", "rect": ["x": 20, "y": 100, "width": 200, "height": 40]],
        ["id": "n2", "rect": ["x": -20, "y": 900, "width": 100, "height": 100]],
        ["id": "n3", "rect": ["x": 0, "y": 1000, "width": 100, "height": 30]],
      ]]]], "truncated": true,
    ])
    let tree = AccessibilityTree.mapped(original, width: 660, height: 1434)
    let nodes = tree["applications"].array![0]["root"]["children"].array!
    precondition(nodes[0]["pixel_rect"]["x"].number == 30)
    precondition(nodes[0]["pixel_rect"]["y"].number == 150)
    precondition(nodes[0]["rect"]["x"].number == 20)
    precondition(nodes[0]["label"].string == "中 English")
    precondition(nodes[1]["pixel_rect"]["x"].number == 0)
    precondition(abs(nodes[1]["pixel_rect"]["height"].number! - 84) < 0.0001)
    precondition(nodes[2]["intersects_screen"].bool == false)
    precondition(nodes[2]["pixel_rect"].object == nil)
    precondition(tree["truncated"].bool == true)
    let diagnostic = DebugPrivacy.value(.object(["accessibility": original]))
    precondition(diagnostic["accessibility"]["applications"].array == nil)
    precondition(diagnostic["accessibility"]["status"].string == "available")
    let rotated = AccessibilityTree.mapped(original, width: 1434, height: 660)
    precondition(rotated["pixel_geometry_available"].bool == false)
    let unavailable = try JSONValue(["status": "unavailable", "reason": "missing_companion"])
    precondition(AccessibilityTree.mapped(unavailable, width: 660, height: 1434) == unavailable)
    let driver = TreeDriver()
    let dispatcher = PhoneToolDispatcher(driver: driver, minimumObservationDelay: 0) { _ in "fixture" }
    let removed = try await dispatcher.execute(.init(id: "old-tree-call", name: "phone_read_tree", arguments: "{}"))
    precondition(driver.actions.isEmpty)
    precondition(removed.content.compactMap { $0["text"].string }.joined().contains("invalid_arguments"))
    for readOnly in [false, true] {
      let definitions = try JSONValue.array(PhoneTools.definitions(readOnly: readOnly)).text()
      precondition(!definitions.contains("phone_read_tree") && !definitions.contains("readTree"))
    }
    precondition(!PhoneTools.instructions.contains("phone_read_tree"))
    let observation = try await dispatcher.execute(.init(id: "screen", name: "phone_observe", arguments: "{}"))
    precondition(!observation.needsAttention && driver.actions.count == 1)
    let tap = try await dispatcher.execute(.init(id: "tap", name: "phone_tap",
      arguments: "{\"x\":100,\"y\":200,\"frame_id\":\"tree-frame\"}"))
    precondition(!tap.needsAttention)
    precondition(driver.actions[1]["op"].string == "tap")
    precondition(abs(driver.actions[1]["x"].number! - 100 / 659.0) < 0.0001)
    precondition(driver.actions[2]["op"].string == "observe")
    do {
      _ = try PhoneTools.parse(.init(id: "bad", name: "phone_batch", arguments: "{\"actions\":[{\"op\":\"read_tree\"}]}"))
      preconditionFailure("Tree must not be mixed into action-only batches")
    } catch {}
    print("Accessibility tree mapping: scaling, clipped/offscreen nodes, hierarchy, truncation, orientation and unavailable state passed")
    print("Screenshot default: removed direct/batch tree calls rejected before driver; read-only/full schemas exclude tree; screenshot coordinate binding passed")
  }
}

@MainActor final class TreeDriver: PhoneDriver {
  var actions: [JSONValue] = []
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    actions.append(action)
    if action["op"].string == "observe" {
      return .init(status: "executed", value: try JSONValue([
        "frame_id": "tree-frame", "width": 660, "height": 1434,
      ]))
    }
    return .init(status: "executed", value: .object([:]))
  }
}
