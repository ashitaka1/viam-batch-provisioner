network:
  version: 2

  ethernets:
    eth0:
      dhcp4: true
      optional: true

  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "Viam":
          password: "checkmate"
