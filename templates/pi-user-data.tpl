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

      # Wait for NTP sync. The Pi has no RTC, so first-boot clock starts at the
      # image build date. Stale-clock apt-get update fails sqv signature
      # verification ("Not live until <future date>"), and Tailscale's
      # install.sh fails silently for the same reason.
      for i in $(seq 1 60); do
          [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
          sleep 1
      done
      echo "$(date) Phase 2: clock synchronized" >> $LOG

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
          printf '[Unit]\nDescription=Viam Agent\nAfter=network-online.target\nWants=network-online.target\nStartLimitIntervalSec=0\n\n[Service]\nType=exec\nUser=root\nExecStart=/opt/viam/bin/viam-agent --config /etc/viam.json\nRestart=always\nRestartSec=5\nTimeoutSec=240\nKillMode=mixed\nFinalKillSignal=SIGKILL\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/viam-agent.service
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
          if ! command -v tailscale >/dev/null 2>&1; then
              echo "ERROR: Tailscale install failed (tailscale binary not found)" >> $LOG
          elif [ -f /etc/tailscale-authkey ]; then
              if tailscale up --authkey="$(cat /etc/tailscale-authkey)" --hostname="$(hostname)" >> $LOG 2>&1; then
                  rm -f /etc/tailscale-authkey
                  echo "Tailscale joined" >> $LOG
              else
                  echo "ERROR: tailscale up failed (auth key invalid or network issue)" >> $LOG
              fi
          else
              echo "Tailscale installed (no auth key — run 'tailscale up' manually)" >> $LOG
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
  # Pi OS rfkill-blocks the WiFi radio until a regulatory country is set.
  - "if [ -n 'PLACEHOLDER_WIFI_COUNTRY' ]; then iw reg set 'PLACEHOLDER_WIFI_COUNTRY'; rfkill unblock wifi; nmcli radio wifi on; fi || true"
  - "[ -f /boot/firmware/viam.json ] && mv /boot/firmware/viam.json /etc/viam.json || true"
  - "[ -f /boot/firmware/tailscale-authkey ] && mv /boot/firmware/tailscale-authkey /etc/tailscale-authkey || true"
  - echo "$(date) Cloud-init runcmd complete, starting Phase 2" >> /var/log/provisioning.log
  - systemctl enable --now provisioning-phase2.service
