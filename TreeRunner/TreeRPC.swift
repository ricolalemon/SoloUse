import CryptoKit
import Foundation

/// Authenticate both directions without sending the session secret to a socket
/// that another local app might have bound before the companion started.
enum TreeRPC {
  static func message(_ direction: String, _ nonce: String, _ content: String) -> Data {
    Data("\(direction)\n\(nonce)\n\(content)".utf8)
  }
  static func signature(_ data: Data, key: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(key.utf8))))
  }
  static func request(_ data: Data, key: String) -> (op: String, nonce: String)? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
      Set(object.keys) == ["op", "nonce", "mac"], let op = object["op"],
      ["status", "tree", "stop"].contains(op), let nonce = object["nonce"],
      nonce.count == 32, nonce.allSatisfy({ "0123456789abcdef".contains($0) }),
      let mac = object["mac"].flatMap({ Data(base64Encoded: $0) }),
      HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message("request", nonce, op),
        using: SymmetricKey(data: Data(key.utf8))) else { return nil }
    return (op, nonce)
  }
  static func reply(_ value: [String: Any], nonce: String, key: String) throws -> Data {
    var content = try JSONSerialization.data(withJSONObject: value)
    if content.count > 2_000_000 {
      content = try JSONSerialization.data(withJSONObject: ["status": "unavailable", "reason": "tree_too_large"])
    }
    let payload = content.base64EncodedString()
    let mac = signature(message("response", nonce, payload), key: key).base64EncodedString()
    var wire = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "payload": payload, "mac": mac])
    wire.append(10)
    return wire
  }
}
