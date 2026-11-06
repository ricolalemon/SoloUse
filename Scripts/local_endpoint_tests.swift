import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
}
private func ipv4(_ value: String) -> Data {
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = UInt16(12345).bigEndian
  _ = value.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
  return withUnsafeBytes(of: &address) { Data($0) }
}
@main struct EndpointTests {
  @MainActor static func main() {
    let own: Set<Data> = [Data([4, 192, 0, 2, 10])]
    let local = ipv4("192.0.2.10"), other = ipv4("192.0.2.20")
    require(LocalDeveloperEndpoint.matchingPort(65139, addresses: [local], ownAddresses: own) == 65139,
      "Own dynamically advertised port rejected")
    require(LocalDeveloperEndpoint.matchingPort(65139, addresses: [other], ownAddresses: own) == nil,
      "Another device's service was accepted")
    require(LocalDeveloperEndpoint.matchingPort(65139, addresses: [other, local], ownAddresses: own) == 65139,
      "Multiple advertised addresses lost the self match")
    for port in [-1, 0, 65536] {
      require(LocalDeveloperEndpoint.matchingPort(port, addresses: [local], ownAddresses: own) == nil,
        "Invalid service port accepted")
    }
    require(LocalDeveloperEndpoint.matchingPort(65139, addresses: [Data([255, 2])], ownAddresses: own) == nil,
      "Truncated sockaddr accepted")
    var invalid = local; invalid[0] = 255
    require(LocalDeveloperEndpoint.matchingPort(65139, addresses: [invalid], ownAddresses: own) == nil,
      "Claimed sockaddr length exceeded buffer")
    print("PASS dynamic self port, other-device rejection, multiple addresses, invalid port and truncated address")
  }
}
