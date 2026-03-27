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
    - viam

  late-commands:
    # Set timezone
    - curtin in-target -- timedatectl set-timezone America/New_York

    # Headless mode
    - curtin in-target -- systemctl set-default multi-user.target

    # Disable unneeded services (ignore errors if not present)
    - curtin in-target -- systemctl disable gdm3 || true
    - curtin in-target -- systemctl disable bluetooth || true
    - curtin in-target -- systemctl disable cups || true

    # Set boot order: disk first, so this machine won't PXE boot again
    - |
      DISK_ENTRY=$(efibootmgr | grep -iE 'ubuntu|hard drive|ssd|nvme' | head -1 | grep -oP '^\w+\K\d{4}')
      if [ -n "$DISK_ENTRY" ]; then
        BOOT_ORDER=$(efibootmgr | grep BootOrder | sed 's/BootOrder: //')
        NEW_ORDER="${DISK_ENTRY},$(echo "$BOOT_ORDER" | sed "s/${DISK_ENTRY},\?//;s/,$//")"
        efibootmgr -o "$NEW_ORDER"
      fi

    # Discover NIC roles and write netplan config
    # The PXE-booting interface has a DHCP lease — that's the uplink.
    # Any other ethernet interface is robotnet.
    - |
      UPLINK_IFACE=$(ip -o -4 addr show | awk '/dynamic/ {print $2; exit}')
      ROBOTNET_IFACE=$(ip -o link show | awk -v up="$UPLINK_IFACE" '$2 ~ /^enp/ && $2 !~ up {gsub(/:/, "", $2); print $2; exit}')
      WIFI_IFACE=$(ip -o link show | awk '$2 ~ /^wl/ {gsub(/:/, "", $2); print $2; exit}')
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
      if [ -n "$WIFI_IFACE" ]; then
        cat >> /target/etc/netplan/99-netplan.yaml <<NETPLAN
        wifis:
          ${WIFI_IFACE}:
            access-points:
              "Viam":
                password: "checkmate"
            dhcp4: true
      NETPLAN
      fi

    # Fetch per-machine identity from PXE server by MAC address
    - |
      UPLINK_IFACE=$(ip -o -4 addr show | awk '/dynamic/ {print $2; exit}')
      MAC=$(ip link show "$UPLINK_IFACE" | awk '/ether/ {print $2}' | tr '[:upper:]' '[:lower:]')
      curl -sf http://${PXE_SERVER}:8080/machines/${MAC}/hostname -o /tmp/assigned-hostname
      HOSTNAME=$(cat /tmp/assigned-hostname)
      echo "${HOSTNAME}" > /target/etc/hostname
      sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /target/etc/hosts
      curl -sf http://${PXE_SERVER}:8080/machines/${MAC}/viam.json -o /target/etc/viam.json

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
    - curl -sf http://${PXE_SERVER}:8080/config/tailscale.key -o /target/etc/tailscale-authkey
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
