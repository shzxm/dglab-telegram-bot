import Foundation
import Darwin

/// Only suggests RFC1918 IPv4 hosts on active local interfaces. This never
/// silently exposes the authenticated WebSocket bridge to public networks.
enum LocalNetworkAddress {
    static func suggestedIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        var item: UnsafeMutablePointer<ifaddrs>? = head
        while let node = item {
            defer { item = node.pointee.ifa_next }
            let record = node.pointee
            guard let addr = record.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  (record.ifa_flags & UInt32(IFF_UP)) != 0,
                  (record.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let name = record.ifa_name.map({ String(cString: $0) }) else { continue }
            let ipv4 = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
            var address = ipv4.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buffer)
            let groups = text.split(separator: ".").compactMap { Int($0) }
            guard groups.count == 4,
                (groups[0] == 10 || (groups[0] == 192 && groups[1] == 168) ||
                (groups[0] == 172 && (16...31).contains(groups[1]))) else { continue }
            candidates.append((name, text))
        }
        // Prefer Wi-Fi then active Ethernet, rather than WireGuard or VPN.
        return candidates.sorted { left, right in
            let score: (String) -> Int = { $0 == "en0" ? 0 : $0.hasPrefix("en") ? 1 : 2 }
            let l = score(left.name), r = score(right.name)
            return l == r ? left.name < right.name : l < r
        }.first?.address
    }
}
