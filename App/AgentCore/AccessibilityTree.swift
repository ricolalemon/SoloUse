import Foundation

/// Preserve the real hierarchy and source geometry. Additional pixel rectangles
/// refer to the returned image, not the device's native screenshot resolution.
enum AccessibilityTree {
  static func mapped(_ tree: JSONValue, width: Double, height: Double) -> JSONValue {
    guard tree["status"].string == "available", var result = tree.object else { return tree }
    let viewport = tree["viewport"]
    guard let w = viewport["width"].number, let h = viewport["height"].number,
      w.isFinite, h.isFinite, w > 0, h > 0,
      width.isFinite, height.isFinite, width > 0, height > 0,
      abs(w / h - width / height) < 0.02
    else {
      result["pixel_geometry_available"] = .bool(false)
      return .object(result)
    }
    func visit(_ node: JSONValue) -> JSONValue {
      guard var fields = node.object else { return node }
      let rect = node["rect"]
      if let x = rect["x"].number, let y = rect["y"].number,
        let rw = rect["width"].number, let rh = rect["height"].number,
        [x, y, rw, rh].allSatisfy(\.isFinite), rw > 0, rh > 0 {
        let left = max(0, x), top = max(0, y)
        let right = min(w, x + rw), bottom = min(h, y + rh)
        let onScreen = right > left && bottom > top
        fields["intersects_screen"] = .bool(onScreen)
        if onScreen {
          fields["pixel_rect"] = .object([
            "x": .number(left / w * width), "y": .number(top / h * height),
            "width": .number((right - left) / w * width),
            "height": .number((bottom - top) / h * height),
          ])
        }
      }
      if let children = node["children"].array { fields["children"] = .array(children.map(visit)) }
      return .object(fields)
    }
    result["applications"] = .array((tree["applications"].array ?? []).map { app in
      var fields = app.object ?? [:]
      fields["root"] = visit(app["root"])
      return .object(fields)
    })
    result["pixel_geometry_available"] = .bool(true)
    result["observation_note"] = .string("Tree and screenshot are consecutive observations, not an atomic snapshot. Intersecting the screen does not prove visibility or hittability; compare with the image before tapping.")
    return .object(result)
  }
}
