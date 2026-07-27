import Foundation

/// Detects whether a loopback dev-VPN (LocalDevVPN/StosVPN) tunnel is
/// currently up, by scanning real network interfaces — not a guess or a
/// static placeholder. LocalDevVPN brings up a `utun*` interface with an
/// IPv4 address (observed: 10.7.0.0) whose subnet's first address
/// (10.7.0.1) is where lockdownd is actually reachable.
enum TunnelDetector {
    struct Tunnel {
        let interfaceName: String
        /// This device's own address on the tunnel.
        let address: String
        /// First address in the tunnel's subnet — not necessarily
        /// `ifa_dstaddr` (observed to alias the device's own address on
        /// this interface type), but derived from address & netmask.
        /// This is where LocalDevVPN exposes lockdownd.
        let gatewayAddress: String?
    }

    /// Scans `getifaddrs` for a `utun` interface carrying an IPv4 address.
    /// This is the same mechanism `ifconfig`/Network Utility use — no
    /// entitlements required, just enumerating what the OS already exposes.
    static func activeTunnel() -> Tunnel? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }

            guard let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let ip = numericHost(of: addr), ip != "0.0.0.0" else { continue }

            var gateway: String? = nil
            if let mask = interface.pointee.ifa_netmask, mask.pointee.sa_family == UInt8(AF_INET) {
                gateway = firstSubnetAddress(address: addr, netmask: mask)
            }

            return Tunnel(interfaceName: name, address: ip, gatewayAddress: gateway)
        }
        return nil
    }

    /// Computes (address & netmask) | 1 — the conventional "gateway" address
    /// at the start of the subnet, in network-address form.
    private static func firstSubnetAddress(address: UnsafeMutablePointer<sockaddr>, netmask: UnsafeMutablePointer<sockaddr>) -> String? {
        let addrIn = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let maskIn = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

        let addr32 = addrIn.sin_addr.s_addr
        let mask32 = maskIn.sin_addr.s_addr
        let network = addr32 & mask32
        let hostOne: UInt32 = UInt32(1).bigEndian
        let gateway = network | (hostOne & ~mask32)

        var gatewayAddr = in_addr(s_addr: gateway)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &gatewayAddr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func numericHost(of addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                  &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return String(cString: host)
    }
}
