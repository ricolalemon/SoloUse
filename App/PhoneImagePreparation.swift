import CryptoKit
import Foundation
import ImageIO
import UIKit

struct PreparedPhoneImage: Sendable {
  let jpeg: Data?
  let dataURL: String?
  let metadata: JSONValue
  let elapsedMS: Double
}

enum PhoneImagePreparation {
  // Serial to bound memory; UIKit views are never read from this worker.
  private static let queue = DispatchQueue(label: "dev.solouse.image-preparation", qos: .userInitiated)
  static func prepare(png: Data, metadata: JSONValue, includeImage: Bool, saveImage: Bool) async throws -> PreparedPhoneImage {
    try Task.checkCancellation()
    let result: PreparedPhoneImage = try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          let prepared = try autoreleasepool {
            try prepareSynchronously(png: png, metadata: metadata, includeImage: includeImage, saveImage: saveImage)
          }
          continuation.resume(returning: prepared)
        } catch { continuation.resume(throwing: error) }
      }
    }
    try Task.checkCancellation()
    return result
  }
  static func prepareSynchronously(png: Data, metadata: JSONValue, includeImage: Bool, saveImage: Bool) throws -> PreparedPhoneImage {
    let started = ProcessInfo.processInfo.systemUptime
    let width = metadata["width"].number ?? 0
    let height = metadata["height"].number ?? 0
    guard width > 0, height > 0, width <= 20_000, height <= 20_000 else {
      throw AgentLoopError.protocolError("截图尺寸无效")
    }
    guard let sourceInfo = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetStatus(sourceInfo) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(sourceInfo, 0, nil) as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue == width,
      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue == height else {
      throw AgentLoopError.protocolError("截图内容与尺寸不一致")
    }
    let scale = min(1, 1568 / max(width, height))
    let size = CGSize(width: floor(width * scale), height: floor(height * scale))
    var fields = metadata.object ?? [:]
    fields.removeValue(forKey: "file")
    fields.removeValue(forKey: "frame_buffer")
    fields["source_width"] = metadata["width"]
    fields["source_height"] = metadata["height"]
    fields["width"] = .number(Double(size.width))
    fields["height"] = .number(Double(size.height))
    fields["coordinate_unit"] = .string("image_pixels")
    if fields["accessibility"] != nil {
      fields["accessibility"] = AccessibilityTree.mapped(metadata["accessibility"], width: Double(size.width), height: Double(size.height))
    }
    // Tree metadata is reserved for explicit native diagnostics. Ordinary
    // screenshots do not advertise an agent capability that is not exposed.
    if fields["accessibility"] != nil {
      fields["accessibility_status"] = fields["accessibility"]?["status"]
      fields["accessibility_available"] = .bool(fields["accessibility"]?["status"].string == "available")
    } else {
      fields.removeValue(forKey: "accessibility_status")
      fields.removeValue(forKey: "accessibility_available")
    }
    var jpeg: Data?
    if includeImage || saveImage {
      guard let source = UIImage(data: png) else { throw AgentLoopError.protocolError("截图无法读取") }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        source.draw(in: CGRect(origin: .zero, size: size))
      }
      guard let data = rendered.jpegData(compressionQuality: 0.85), data.count < 2_000_000 else {
        throw AgentLoopError.protocolError("截图超过输入限制")
      }
      jpeg = data
    }
    return PreparedPhoneImage(
      jpeg: jpeg, dataURL: includeImage ? jpeg.map { "data:image/jpeg;base64," + $0.base64EncodedString() } : nil,
      metadata: .object(fields), elapsedMS: (ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
}
