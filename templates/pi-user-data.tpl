#cloud-config

hostname: PLACEHOLDER_HOSTNAME
manage_etc_hosts: true

users:
  - name: PLACEHOLDER_USERNAME
    gecos: PLACEHOLDER_USERNAME
    shell: /bin/bash
    groups: sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi
    lock_passwd: false
    passwd: "PLACEHOLDER_PASSWORD_HASH"
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - "PLACEHOLDER_SSH_KEY"

ssh_pwauth: true

timezone: PLACEHOLDER_TIMEZONE

keyboard:
  layout: us

write_files:
  - path: /etc/default/console-setup
    content: |
      ACTIVE_CONSOLES="/dev/tty[1-6]"
      CHARMAP="UTF-8"
      FONTFACE="Terminus"
      FONTSIZE="16x32"
      CODESET="Lat15"
    permissions: '0644'
    owner: root:root

  - path: /usr/local/bin/provisioning-phase2.sh
    content: |
      #!/bin/bash
      LOG=/var/log/provisioning.log
      echo "$(date) Phase 2: network configuration starting" >> $LOG

      # Wait for DNS
      for i in $(seq 1 60); do
          ping -c1 -W1 deb.debian.org >/dev/null 2>&1 && break
          sleep 1
      done

      # Console font
      apt-get update >> $LOG 2>&1
      apt-get install -y fonts-terminus >> $LOG 2>&1 || true
      dpkg-reconfigure -f noninteractive console-setup >> $LOG 2>&1 || true

      # Packages — list comes from config/environments/<env>.packages.txt at flash time
      apt-get install -y PLACEHOLDER_PACKAGES >> $LOG 2>&1
      echo "Packages installed" >> $LOG

      # Viam (conditional)
      if [ "PLACEHOLDER_INSTALL_VIAM" = "true" ]; then
          # Viam CLI
          curl --compressed -fsSL -o /usr/local/bin/viam \
              https://storage.googleapis.com/packages.viam.com/apps/viam-cli/viam-cli-stable-linux-arm64
          chmod 755 /usr/local/bin/viam
          echo "Viam CLI installed" >> $LOG

          # Viam Agent
          mkdir -p /opt/viam/bin
          curl -fsSL -o /opt/viam/bin/viam-agent \
              https://storage.googleapis.com/packages.viam.com/apps/viam-agent/viam-agent-stable-aarch64
          chmod 755 /opt/viam/bin/viam-agent
          printf '[Unit]\nDescription=Viam Agent\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=exec\nExecStart=/opt/viam/bin/viam-agent --config /etc/viam.json\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/viam-agent.service
          systemctl daemon-reload
          if [ -f /etc/viam.json ]; then
              systemctl enable --now viam-agent.service
              echo "Viam Agent installed and started" >> $LOG
          else
              systemctl enable viam-agent.service
              echo "Viam Agent installed (no credentials — enable manually after adding /etc/viam.json)" >> $LOG
          fi
      fi

      # Tailscale (conditional)
      if [ "PLACEHOLDER_INSTALL_TAILSCALE" = "true" ]; then
          curl -fsSL https://tailscale.com/install.sh | sh >> $LOG 2>&1
          if [ -f /etc/tailscale-authkey ]; then
              tailscale up --authkey=$(cat /etc/tailscale-authkey) --hostname=$(hostname) >> $LOG 2>&1
              rm /etc/tailscale-authkey
              echo "Tailscale joined" >> $LOG
          fi
      fi

      echo "$(date) Phase 2: provisioning complete" >> $LOG

      # Clean up
      systemctl disable provisioning-phase2.service
      rm -f /etc/systemd/system/provisioning-phase2.service
      rm -f /usr/local/bin/provisioning-phase2.sh
      systemctl daemon-reload
    permissions: '0755'
    owner: root:root

  - path: /etc/systemd/system/provisioning-phase2.service
    content: |
      [Unit]
      Description=Provisioning Phase 2 (network-dependent setup)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/provisioning-phase2.sh
      RemainAfterExit=true
      TimeoutStartSec=600

      [Install]
      WantedBy=multi-user.target
    permissions: '0644'
    owner: root:root

runcmd:
  - systemctl daemon-reload
  - systemctl enable --now ssh
  - systemctl disable NetworkManager-wait-online.service || true
  - systemctl disable systemd-networkd-wait-online.service || true
  - "[ -f /boot/firmware/viam.json ] && mv /boot/firmware/viam.json /etc/viam.json || true"
  - "[ -f /boot/firmware/tailscale-authkey ] && mv /boot/firmware/tailscale-authkey /etc/tailscale-authkey || true"
  - echo "$(date) Cloud-init runcmd complete, starting Phase 2" >> /var/log/provisioning.log
  - systemctl enable --now provisioning-phase2.service
