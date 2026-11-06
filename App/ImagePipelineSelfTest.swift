#if DEBUG
import CryptoKit
import UIKit

@MainActor enum ImagePipelineSelfTest {
  static func run() async {
    var report: [String: Any] = ["kind": "image_pipeline_check", "model_calls": 0, "phone_commands": 0]
    var trials: [[String: Any]] = []
    do {
      for dimensions in [CGSize(width: 1320, height: 2868), CGSize(width: 721, height: 1568)] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let png = UIGraphicsImageRenderer(size: dimensions, format: format).image { context in
          UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: dimensions))
          for i in 0..<36 {
            UIColor(hue: CGFloat(i)/36, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 25 + i * 35, width: 300, height: 20))
            ("SoloUse 屏幕 0123456789 / \(i)" as NSString).draw(at: CGPoint(x: 340, y: 25 + i * 35),
              withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.white])
          }
        }.pngData()!
        let metadata = JSONValue.object(["frame_id": .string(UUID().uuidString),
          "width": .number(Double(dimensions.width)), "height": .number(Double(dimensions.height))])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-fixture-\(UUID()).png")
        try png.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let source = UIImage(contentsOfFile: file.path)!
        let scale = min(1, 1568 / max(dimensions.width, dimensions.height))
        let size = CGSize(width: floor(dimensions.width * scale), height: floor(dimensions.height * scale))
        let legacy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
          source.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.85)!
        let image = try await PhoneImagePreparation.prepare(png: png, metadata: metadata, includeImage: true, saveImage: true)
        guard image.jpeg == legacy, image.metadata["width"].number == Double(size.width),
          image.metadata["height"].number == Double(size.height),
          image.dataURL == "data:image/jpeg;base64," + legacy.base64EncodedString() else {
          throw AgentLoopError.protocolError("Image bytes or coordinates differ from the old path")
        }
        let silent = try await PhoneImagePreparation.prepare(png: png, metadata: metadata, includeImage: false, saveImage: false)
        guard silent.jpeg == nil, silent.dataURL == nil, silent.metadata == image.metadata else {
          throw AgentLoopError.protocolError("Metadata-only observation changed geometry")
        }
        let debug = try await PhoneImagePreparation.prepare(png: png, metadata: metadata, includeImage: false, saveImage: true)
        guard debug.jpeg == legacy, debug.dataURL == nil else { throw AgentLoopError.protocolError("Debug image preservation failed") }
        trials.append(["width": Int(dimensions.width), "height": Int(dimensions.height),
          "same_jpeg_bytes": true, "same_geometry": true,
          "full_processing_ms": image.elapsedMS, "metadata_processing_ms": silent.elapsedMS])
      }
      var rejected = false
      do {
        _ = try await PhoneImagePreparation.prepare(png: Data([0, 1, 2]),
          metadata: .object(["width": .number(721), "height": .number(1568)]), includeImage: false, saveImage: false)
      } catch { rejected = true }
      guard rejected else { throw AgentLoopError.protocolError("Malformed image was accepted") }
      report["status"] = "passed"; report["invalid_image_rejected"] = true
    } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    report["trials"] = trials
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: documents.appendingPathComponent("image-pipeline-check.json"), options: .atomic)
    }
  }
}
#endif
