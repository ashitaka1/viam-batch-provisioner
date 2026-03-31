#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  timezone: America/New_York

  identity:
    hostname: provisioning
    username: viam
    password: "${PASSWORD_HASH}"

  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - "${SSH_PUBLIC_KEY}"

  storage:
    layout:
      name: lvm
      sizing-policy: all

  packages:
    - openssh-server
    - curl
    - jq
    - net-tools
    - network-manager
    - unattended-upgrades
    - mosh
    - speedtest-cli

  late-commands:
    # Set timezone
    - curtin in-target -- timedatectl set-timezone America/New_York

    # Headless mode
    - curtin in-target -- systemctl set-default multi-user.target

    # Larger console font for readability on high-DPI displays
    - curtin in-target -- apt-get install -y fonts-terminus
    - curtin in-target -- bash -c 'sed -i "s/^FONTFACE=.*/FONTFACE=\"Terminus\"/" /etc/default/console-setup && sed -i "s/^FONTSIZE=.*/FONTSIZE=\"16x32\"/" /etc/default/console-setup'
    - curtin in-target -- dpkg-reconfigure -f noninteractive console-setup
    - curtin in-target -- update-initramfs -u

    # Disable unneeded services
    - curtin in-target -- systemctl disable gdm3 || true
    - curtin in-target -- systemctl disable bluetooth || true
    - curtin in-target -- systemctl disable cups || true
    - curtin in-target -- systemctl disable NetworkManager-wait-online.service || true
    - curtin in-target -- systemctl disable systemd-networkd-wait-online.service || true

    # Set boot order: disk first, so this machine won't PXE boot again
    - |
      DISK_ENTRY=$(efibootmgr | grep -iE 'ubuntu|hard drive|ssd|nvme' | head -1 | grep -oP '^\w+\K\d{4}')
      if [ -n "$DISK_ENTRY" ]; then
        BOOT_ORDER=$(efibootmgr | grep BootOrder | sed 's/BootOrder: //')
        NEW_ORDER="${DISK_ENTRY},$(echo "$BOOT_ORDER" | sed "s/${DISK_ENTRY},\?//;s/,$//")"
        efibootmgr -o "$NEW_ORDER"
      fi

    # Discover ethernet NICs and write netplan config
    # WiFi is handled by a first-boot service (firmware not available in installer)
    - |
      LOG=/target/var/log/provisioning.log
      UPLINK_IFACE=$(ip -o -4 addr show | awk '/dynamic/ {print $2; exit}')
      ROBOTNET_IFACE=$(ip -o link show | awk -v up="$UPLINK_IFACE" '$2 ~ /^enp/ && $2 !~ up {gsub(/:/, "", $2); print $2; exit}')
      echo "NIC discovery: uplink=$UPLINK_IFACE robotnet=$ROBOTNET_IFACE" >> $LOG
      cat > /target/etc/netplan/99-netplan.yaml <<NETPLAN
      network:
        version: 2
        ethernets:
          ${UPLINK_IFACE}:
            dhcp4: true
            dhcp6: true
      NETPLAN
      if [ -n "$ROBOTNET_IFACE" ]; then
        cat >> /target/etc/netplan/99-netplan.yaml <<NETPLAN
          ${ROBOTNET_IFACE}:
            addresses:
              - 192.168.20.1/24
            dhcp4: false
      NETPLAN
      fi

    # WiFi setup as a first-boot service (Intel WiFi firmware isn't in the installer)
    - |
      cat > /target/etc/systemd/system/wifi-setup.service <<'WIFIUNIT'
      [Unit]
      Description=Configure WiFi on first boot
      After=network-pre.target
      Before=network.target
      ConditionPathExists=!/etc/netplan/99-wifi.yaml

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/wifi-setup.sh
      RemainAfterExit=true

      [Install]
      WantedBy=multi-user.target
      WIFIUNIT
      cat > /target/usr/local/bin/wifi-setup.sh <<'WIFISCRIPT'
      #!/bin/bash
      WIFI_IFACE=$(ip -o link show | awk '$2 ~ /^wl/ {gsub(/:/, "", $2); print $2; exit}')
      if [ -n "$WIFI_IFACE" ]; then
        cat > /etc/netplan/99-wifi.yaml <<NETPLAN
      network:
        version: 2
        wifis:
          ${WIFI_IFACE}:
            access-points:
              "Viam":
                password: "checkmate"
            dhcp4: true
      NETPLAN
        netplan apply
        echo "WiFi configured on $WIFI_IFACE" >> /var/log/provisioning.log
      else
        echo "No WiFi interface found" >> /var/log/provisioning.log
      fi
      WIFISCRIPT
      chmod 755 /target/usr/local/bin/wifi-setup.sh
    - curtin in-target -- systemctl enable wifi-setup.service

    # Fetch per-machine identity from PXE server by MAC address
    - |
      LOG=/target/var/log/provisioning.log
      UPLINK_IFACE=$(ip -o -4 addr show | awk '/dynamic/ {print $2; exit}')
      MAC=$(ip link show "$UPLINK_IFACE" | awk '/ether/ {print $2}' | tr '[:upper:]' '[:lower:]')
      echo "Identity fetch: MAC=$MAC from http://${PXE_SERVER}" >> $LOG
      if curl -sf http://${PXE_SERVER}/machines/${MAC}/hostname -o /tmp/assigned-hostname; then
        HOSTNAME=$(cat /tmp/assigned-hostname)
        echo "${HOSTNAME}" > /target/etc/hostname
        sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /target/etc/hosts
        echo "Hostname set to ${HOSTNAME}" >> $LOG
      else
        echo "FAILED to fetch hostname for MAC $MAC" >> $LOG
      fi
      if curl -sf http://${PXE_SERVER}/machines/${MAC}/viam.json -o /target/etc/viam.json; then
        echo "viam.json installed" >> $LOG
      else
        echo "FAILED to fetch viam.json for MAC $MAC" >> $LOG
      fi

    # Install Viam CLI
    - curtin in-target -- curl --compressed -fsSL -o /usr/local/bin/viam https://storage.googleapis.com/packages.viam.com/apps/viam-cli/viam-cli-stable-linux-amd64
    - chmod 755 /target/usr/local/bin/viam

    # Install viam-agent
    - mkdir -p /target/opt/viam/bin
    - curtin in-target -- curl -fsSL -o /opt/viam/bin/viam-agent https://storage.googleapis.com/packages.viam.com/apps/viam-agent/viam-agent-stable-x86_64
    - chmod 755 /target/opt/viam/bin/viam-agent
    - |
      cat > /target/etc/systemd/system/viam-agent.service <<'UNIT'
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
    - curtin in-target -- systemctl enable viam-agent.service

    # Install Tailscale and set up first-boot join
    - curtin in-target -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
    - |
      LOG=/target/var/log/provisioning.log
      if curl -sf http://${PXE_SERVER}/config/tailscale.key -o /target/etc/tailscale-authkey; then
        echo "Tailscale key installed" >> $LOG
      else
        echo "FAILED to fetch Tailscale key" >> $LOG
      fi
    - |
      cat > /target/etc/systemd/system/tailscale-join.service <<'TSUNIT'
      [Unit]
      Description=Tailscale first-boot join
      After=network-online.target tailscaled.service
      Wants=network-online.target
      ConditionPathExists=/etc/tailscale-authkey

      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c 'tailscale up --authkey=$(cat /etc/tailscale-authkey) --hostname=$(hostname) && rm /etc/tailscale-authkey'
      RemainAfterExit=true

      [Install]
      WantedBy=multi-user.target
      TSUNIT
    - curtin in-target -- systemctl enable tailscale-join.service
