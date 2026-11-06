import Foundation
@main struct TreeRPCTests {
  static func main() throws {
    let key = String(repeating: "0", count: 64)
    let nonce = String(repeating: "1", count: 32)
    let mac = TreeRPC.signature(TreeRPC.message("request", nonce, "status"), key: key).base64EncodedString()
    precondition(mac == "MTcyhmu5//SVhycQ3yfmyc04vwobW5PiLfPlxwlEYok=")
    let valid = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "op": "status", "mac": mac])
    precondition(TreeRPC.request(valid, key: key)?.op == "status")
    precondition(TreeRPC.request(valid, key: "impostor") == nil)
    let changed = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "op": "tree", "mac": mac])
    precondition(TreeRPC.request(changed, key: key) == nil)
    let wire = try TreeRPC.reply(["status": "available", "label": "文字🙂"], nonce: nonce, key: key)
    precondition(wire.last == 10)
    let envelope = try JSONSerialization.jsonObject(with: wire) as! [String: String]
    precondition(envelope["nonce"] == nonce)
    let payload = envelope["payload"]!
    precondition(envelope["mac"] == TreeRPC.signature(TreeRPC.message("response", nonce, payload), key: key).base64EncodedString())
    let decoded = try JSONSerialization.jsonObject(with: Data(base64Encoded: payload)!) as! [String: String]
    precondition(decoded["label"] == "文字🙂")
    precondition(!String(data: wire, encoding: .utf8)!.contains(key))
    print("Tree RPC: shared HMAC vector, request authentication, wrong key/op rejection, Unicode, framing and reply authentication passed")
  }
}
