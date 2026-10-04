<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.viam.provisioner.bonjour</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/dns-sd</string>
        <string>-R</string>
        <string>@SERVER_NAME@</string>
        <string>_viam-provisioner._tcp</string>
        <string>local</string>
        <string>@API_PORT@</string>
        <string>api=v1</string>
    </array>
    <key>UserName</key>
    <string>@USER@</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>@REPO@/logs/bonjour.log</string>
    <key>StandardErrorPath</key>
    <string>@REPO@/logs/bonjour.log</string>
</dict>
</plist>
