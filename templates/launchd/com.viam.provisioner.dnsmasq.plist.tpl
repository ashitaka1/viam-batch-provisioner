<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.viam.provisioner.dnsmasq</string>
    <key>ProgramArguments</key>
    <array>
        <string>@DNSMASQ@</string>
        <string>--keep-in-foreground</string>
        <string>--user=root</string>
        <string>--conf-file=@REPO@/netboot/dnsmasq.conf</string>
        <string>--dhcp-range=@DHCP_RANGE@</string>
        <string>--tftp-root=@REPO@/netboot</string>
        <string>--log-facility=@REPO@/logs/dnsmasq.log</string>
        <string>--pid-file=@REPO@/logs/dnsmasq.pid</string>
    </array>
    <key>WorkingDirectory</key>
    <string>@REPO@</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardErrorPath</key>
    <string>@REPO@/logs/dnsmasq.err</string>
</dict>
</plist>
