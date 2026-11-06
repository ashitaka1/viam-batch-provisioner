/// The rules for an environment's robot network, which `scripts/lib/robot-net.sh`
/// applies to `ROBOT_NET_ADDRESS` and `ROBOT_NET_PORT`.
public enum RobotNetwork {
    public static let defaultAddress = "192.168.20.1/24"
    /// `ROBOT_NET_ADDRESS` for an environment with no robot network.
    public static let none = "none"

    /// Why `address` can't be the robot network's address, or nil for an RFC 1918
    /// address (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) with a prefix.
    public static func addressProblem(_ address: String) -> String? {
        let problem = "Enter a private address with its prefix, like \(defaultAddress), in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16."
        guard let match = address.wholeMatch(
            of: /(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\/(?:0|[1-9]|[12][0-9]|3[0-2])/)
        else { return problem }
        let octets = [match.1, match.2, match.3, match.4].compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return problem }
        let (a, b) = (octets[0], octets[1])
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ? nil : problem
    }

    /// Why `port` can't name the robot-network port, or nil for a Linux interface name.
    public static func portProblem(_ port: String) -> String? {
        port.wholeMatch(of: /[A-Za-z0-9_.\-]{1,15}/) == nil
            ? "Port names are up to 15 letters, digits, ., _ and -, like enp3s0." : nil
    }
}
