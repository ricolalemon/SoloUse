import Foundation

@main struct ConnectionFailureTests {
  static func main() throws {
    let raw =
      "start_audio: device returned an error: Dictionary({\"userInfoWithNSSecureCoding\": Data([98, 112, 108]), \"code\": Integer(9022), \"userinfo\": Dictionary({\"NSLocalizedDescription\": String(\"A phone or VoIP call is currently in progress on the device.\")}), \"domain\": String(\"com.apple.dt.CoreDeviceError\")})"
    let message = PhoneConnectionFailure.displayMessage(raw)
    precondition(message.contains("手机正在通话") && message.contains("手动开始任务"))
    precondition(!message.contains("Data([") && message.count < 80)
    precondition(PhoneConnectionFailure.recognizedMessage("手机连接已结束：" + raw) == message)
    precondition(PhoneConnectionFailure.displayMessage(message) == message)
    precondition(PhoneConnectionFailure.recognizedMessage(message) == message)
    let occupied = PhoneConnectionFailure.displayMessage("An existing display session is active")
    precondition(PhoneConnectionFailure.recognizedMessage(occupied) == occupied)
    precondition(PhoneConnectionFailure.recognizedMessage("start_audio: timeout after 15s") == nil)
    precondition(PhoneConnectionFailure.recognizedMessage("Integer(9022)") == nil)
    precondition(
      PhoneConnectionFailure.displayMessage("Some error: Dictionary({Data([1, 2, 3])})").contains(
        "调试记录"))
    precondition(
      PhoneConnectionFailure.displayMessage(String(repeating: "x", count: 1000)).count < 100)
    precondition(
      PhoneConnectionFailure.displayMessage("Cancelled by user or system")
        == "Cancelled by user or system")
    print(
      "PASS explicit call reason, concise presentation, legacy wrapping, idempotence and no false call diagnosis"
    )

    // The production privacy filter retains the native error in the debug event.
    let event = DebugPrivacy.value(.object(["message": .string(raw)]))
    precondition(event["message"].string == raw)
    print("PASS original native error remains available in privacy-filtered diagnostics")
  }
}
