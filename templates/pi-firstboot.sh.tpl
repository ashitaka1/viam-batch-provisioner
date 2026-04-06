#!/bin/bash
# Phase 1: Offline configuration (runs early via systemd.run= kernel param)
# No network required. Sets up user, SSH, hostname, WiFi, timezone.
# Installs a Phase 2 service for network-dependent tasks.

LOG=/var/log/provisioning.log
echo "$(date) Phase 1: offline configuration starting" >> $LOG

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

# --- Viam credentials (from boot partition, no network needed) ---
BOOT_FW="/boot/firmware"
BOOT="/boot"
for dir in "$BOOT_FW" "$BOOT"; do
    [ -f "$dir/viam.json" ] && cp "$dir/viam.json" /etc/viam.json && rm "$dir/viam.json" && echo "viam.json installed" >> $LOG && break
done
[ -f /etc/viam.json ] || echo "WARNING: no viam.json found on boot partition" >> $LOG

# --- Tailscale key (from boot partition) ---
for dir in "$BOOT_FW" "$BOOT"; do
    [ -f "$dir/tailscale.key" ] && cp "$dir/tailscale.key" /etc/tailscale-authkey && rm "$dir/tailscale.key" && echo "Tailscale key staged" >> $LOG && break
done

# --- Disable wait-online services ---
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

# --- Install Phase 2 service (runs after network is up) ---
cat > /usr/local/bin/provisioning-phase2.sh <<'PHASE2'
#!/bin/bash
LOG=/var/log/provisioning.log
echo "$(date) Phase 2: network configuration starting" >> $LOG

# Wait for DNS to work (up to 60 seconds)
for i in $(seq 1 60); do
    if host deb.debian.org >/dev/null 2>&1 || ping -c1 -W1 deb.debian.org >/dev/null 2>&1; then
        echo "Network available after ${i}s" >> $LOG
        break
    fi
    sleep 1
done

# --- Console font ---
apt-get update >> $LOG 2>&1
apt-get install -y fonts-terminus >> $LOG 2>&1 || true
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup 2>/dev/null
sed -i 's/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup 2>/dev/null
dpkg-reconfigure -f noninteractive console-setup >> $LOG 2>&1 || true
echo "Console font configured" >> $LOG

# --- Packages ---
apt-get install -y curl jq net-tools mosh speedtest-cli unattended-upgrades >> $LOG 2>&1
echo "Packages installed" >> $LOG

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
systemctl start viam-agent.service
echo "Viam Agent installed and started" >> $LOG

# --- Tailscale ---
curl -fsSL https://tailscale.com/install.sh | sh >> $LOG 2>&1
if [ -f /etc/tailscale-authkey ]; then
    tailscale up --authkey=$(cat /etc/tailscale-authkey) --hostname=$(hostname) >> $LOG 2>&1
    rm /etc/tailscale-authkey
    echo "Tailscale joined" >> $LOG
else
    echo "No Tailscale key found, skipping join" >> $LOG
fi

echo "$(date) Phase 2: provisioning complete" >> $LOG

# Disable this service so it doesn't run again
systemctl disable provisioning-phase2.service
PHASE2
chmod 755 /usr/local/bin/provisioning-phase2.sh

cat > /etc/systemd/system/provisioning-phase2.service <<'P2UNIT'
[Unit]
Description=Provisioning Phase 2 (network-dependent setup)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/bin/provisioning-phase2.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/provisioning-phase2.sh
RemainAfterExit=true
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
P2UNIT
systemctl enable provisioning-phase2.service

echo "$(date) Phase 1: complete, Phase 2 will run after reboot with network" >> $LOG

# Remove this script
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh
