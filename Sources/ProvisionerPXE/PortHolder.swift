#if canImport(Darwin)
import Darwin
#endif

/// A process with a UDP socket bound to a port.
public struct PortHolder: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// false when the socket itself wasn't seen and the holder is inferred from the process running.
    public let confirmed: Bool

    init(pid: Int32, name: String, confirmed: Bool = true) {
        self.pid = pid
        self.name = name
        self.confirmed = confirmed
    }

    /// The process holding UDP `port`. For port 67, when no socket is visible, a running `bootpd`:
    /// it runs as root, whose sockets an unprivileged process can't see, but its name is visible to all.
    static func holding(udp port: Int) -> PortHolder? {
        if let holder = udp(port: port) { return holder }
        guard port == 67, let pid = running(named: "bootpd") else { return nil }
        return PortHolder(pid: pid, name: "bootpd", confirmed: false)
    }

    /// The pid of a process whose command name is `name`, from `sysctl`, which lists every user's processes.
    static func running(named name: String) -> pid_t? {
        #if canImport(Darwin)
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = processes.count * stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        for process in processes.prefix(size / stride) {
            let command = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if command == name { return process.kp_proc.p_pid }
        }
        #endif
        return nil
    }

    /// The first process found with a UDP socket bound to `port`, on any local address.
    /// nil when none is visible: the kernel hides another user's sockets from a process that
    /// isn't root. Linux always returns nil.
    static func udp(port: Int) -> PortHolder? {
        #if canImport(Darwin)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(Int(max(listed, 0))) where holdsUDP(pid: pid, port: port) {
            return PortHolder(pid: pid, name: name(of: pid))
        }
        #endif
        return nil
    }

    #if canImport(Darwin)
    private static func holdsUDP(pid: pid_t, port: Int) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == MemoryLayout<socket_fdinfo>.size,
                  info.psi.soi_kind == SOCKINFO_IN, info.psi.soi_protocol == IPPROTO_UDP
            else { continue }
            // insi_lport holds the port in network byte order.
            if Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_in.insi_lport))) == port {
                return true
            }
        }
        return false
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return "pid \(pid)" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
    #endif
}
