import Darwin
import Foundation

// Discover only a service whose advertised address belongs to this iPhone.
// The actual connection still uses the fixed local VPN endpoint and saved pairing.
// Foundation delivers these delegates on the run loop where browsing/resolution starts (main).
@MainActor final class LocalDeveloperEndpoint: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var waiter: CheckedContinuation<UInt16?, Never>?
  private var timeout: Task<Void, Never>?
  private var ownAddresses = Set<Data>()
  private(set) var servicesFound = 0
  private(set) var servicesResolved = 0

  func discover() async -> UInt16? {
    guard !Task.isCancelled else { return nil }
    ownAddresses = Self.localAddresses()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiter = continuation
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        timeout = Task {
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          finish(nil)
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(nil) }
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard waiter != nil else { return }
    servicesFound += 1
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 4)
  }
  func netServiceDidResolveAddress(_ sender: NetService) {
    servicesResolved += 1
    if let port = Self.matchingPort(sender.port, addresses: sender.addresses ?? [], ownAddresses: ownAddresses) {
      finish(port)
    }
  }
  static func matchingPort(_ servicePort: Int, addresses: [Data], ownAddresses: Set<Data>) -> UInt16? {
    guard let port = UInt16(exactly: servicePort), port > 0 else { return nil }
    let matches = addresses.contains { data in
      data.withUnsafeBytes { raw -> Bool in
        guard raw.count >= MemoryLayout<sockaddr>.size, let base = raw.baseAddress else { return false }
        let address = base.assumingMemoryBound(to: sockaddr.self)
        guard Int(address.pointee.sa_len) <= raw.count,
          let key = Self.addressKey(address) else { return false }
        return ownAddresses.contains(key)
      }
    }
    return matches ? port : nil
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    finish(nil)
  }
  private func finish(_ port: UInt16?) {
    guard let continuation = waiter else { return }
    waiter = nil
    timeout?.cancel(); timeout = nil
    browser.stop(); browser.delegate = nil
    for service in services { service.stop(); service.delegate = nil }
    services = []
    continuation.resume(returning: port)
  }
  private static func addressKey(_ address: UnsafePointer<sockaddr>) -> Data? {
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
      guard Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in>.size else { return nil }
      var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
      return Data([4]) + withUnsafeBytes(of: &ip) { Data($0) }
    case AF_INET6:
      guard Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { return nil }
      var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
      return Data([6]) + withUnsafeBytes(of: &ip) { Data($0) }
    default: return nil
    }
  }
  private static func localAddresses() -> Set<Data> {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var addresses = Set<Data>()
    var next = head
    while let item = next {
      next = item.pointee.ifa_next
      if let address = item.pointee.ifa_addr, let key = addressKey(address) {
        addresses.insert(key)
      }
    }
    return addresses
  }
}
