# Checks for the robot-network settings in config/site.env. Both values are
# substituted into the installer config's shell, so anything else is refused.
# ProvisionerKit's RobotNetwork applies the same rules in the app.

ROBOT_NET_DEFAULT_ADDRESS="192.168.20.1/24"

# ROBOT_NET_ADDRESS: `none`, or an RFC 1918 address with a prefix
# (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16).
valid_robot_net_address() {
    [[ "$1" == none ]] && return 0
    local octet='(0|[1-9][0-9]{0,2})'
    [[ "$1" =~ ^${octet}\.${octet}\.${octet}\.${octet}/(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}

# ROBOT_NET_PORT: blank, or a Linux interface name starting with a letter or
# digit, so `.` and `..` can't pass the installer's /sys/class/net check.
valid_robot_net_port() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]]
}
