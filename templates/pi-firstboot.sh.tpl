#!/bin/bash
set -e

LOG=/var/log/provisioning.log
echo "$(date) Provisioning first boot starting" >> $LOG

# --- Hostname ---
HOSTNAME="PLACEHOLDER_HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
echo "Hostname set to $HOSTNAME" >> $LOG

# --- User ---
if id -u viam >/dev/null 2>&1; then
    echo "User viam already exists" >> $LOG
else
    useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi viam
    echo "User viam created" >> $LOG
fi
echo 'viam:PLACEHOLDER_PASSWORD_HASH' | chpasswd -e
echo "viam ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/010_viam-nopasswd
chmod 0440 /etc/sudoers.d/010_viam-nopasswd

# --- SSH ---
systemctl enable ssh
mkdir -p /home/viam/.ssh
echo "PLACEHOLDER_SSH_KEY" > /home/viam/.ssh/authorized_keys
chmod 700 /home/viam/.ssh
chmod 600 /home/viam/.ssh/authorized_keys
chown -R viam:viam /home/viam/.ssh
echo "SSH configured" >> $LOG

# --- Timezone ---
timedatectl set-timezone America/New_York 2>/dev/null || \
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "Timezone set" >> $LOG

# --- WiFi ---
WIFI_IFACE=$(ip -o link show | awk '$2 ~ /^wl/ {gsub(/:/, "", $2); print $2; exit}')
if [ -n "$WIFI_IFACE" ]; then
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<WPAEOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="Viam"
    psk="checkmate"
    key_mgmt=WPA-PSK
}
WPAEOF
    rfkill unblock wifi 2>/dev/null || true
    echo "WiFi configured on $WIFI_IFACE" >> $LOG
else
    echo "No WiFi interface found" >> $LOG
fi

# --- Console font ---
apt-get install -y fonts-terminus 2>> $LOG || true
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup 2>/dev/null
sed -i 's/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup 2>/dev/null
dpkg-reconfigure -f noninteractive console-setup 2>> $LOG || true
echo "Console font configured" >> $LOG

# --- Packages ---
apt-get update >> $LOG 2>&1
apt-get install -y curl jq net-tools mosh speedtest-cli unattended-upgrades >> $LOG 2>&1
echo "Packages installed" >> $LOG

# --- Viam credentials ---
if [ -f /boot/firmware/viam.json ]; then
    cp /boot/firmware/viam.json /etc/viam.json
    rm /boot/firmware/viam.json
    echo "viam.json installed" >> $LOG
elif [ -f /boot/viam.json ]; then
    cp /boot/viam.json /etc/viam.json
    rm /boot/viam.json
    echo "viam.json installed" >> $LOG
else
    echo "WARNING: no viam.json found on boot partition" >> $LOG
fi

# --- Viam CLI ---
curl --compressed -fsSL -o /usr/local/bin/viam \
    https://storage.googleapis.com/packages.viam.com/apps/viam-cli/viam-cli-stable-linux-arm64
chmod 755 /usr/local/bin/viam
echo "Viam CLI installed" >> $LOG

# --- Viam Agent ---
mkdir -p /opt/viam/bin
curl -fsSL -o /opt/viam/bin/viam-agent \
    https://storage.googleapis.com/packages.viam.com/apps/viam-agent/viam-agent-stable-aarch64
chmod 755 /opt/viam/bin/viam-agent

cat > /etc/systemd/system/viam-agent.service <<'UNIT'
[Unit]
Description=Viam Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/opt/viam/bin/viam-agent --config /etc/viam.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable viam-agent.service
echo "Viam Agent installed" >> $LOG

# --- Tailscale ---
curl -fsSL https://tailscale.com/install.sh | sh >> $LOG 2>&1

TSKEY=""
if [ -f /boot/firmware/tailscale.key ]; then
    TSKEY=$(cat /boot/firmware/tailscale.key)
    rm /boot/firmware/tailscale.key
elif [ -f /boot/tailscale.key ]; then
    TSKEY=$(cat /boot/tailscale.key)
    rm /boot/tailscale.key
fi

if [ -n "$TSKEY" ]; then
    cat > /etc/systemd/system/tailscale-join.service <<TSUNIT
[Unit]
Description=Tailscale first-boot join
After=network-online.target tailscaled.service
Wants=network-online.target
ConditionPathExists=/etc/tailscale-authkey

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'tailscale up --authkey=\$(cat /etc/tailscale-authkey) --hostname=\$(hostname) && rm /etc/tailscale-authkey'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
TSUNIT
    echo "$TSKEY" > /etc/tailscale-authkey
    systemctl enable tailscale-join.service
    echo "Tailscale configured" >> $LOG
else
    echo "WARNING: no tailscale key found" >> $LOG
fi

# --- Disable wait-online services ---
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

# --- Clean up ---
echo "$(date) Provisioning first boot complete" >> $LOG

# Remove this script so it doesn't run again
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh
