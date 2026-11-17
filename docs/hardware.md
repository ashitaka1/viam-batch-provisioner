# Hardware

This page describes the preparation that each x86 target model needs. Each model needs it once, with a monitor and keyboard attached. A blank (`—`) means the value is unverified.

## Every machine

- [ ] Note the BIOS version. Update it only if this page lists a newer validated one.
- [ ] Enable UEFI network boot (PXE over IPv4). Save and reboot. Most firmware lists the PXE entry only after that.
- [ ] Disable Secure Boot. The PXE chain serves GRUB without shim (issue [Boot through shim so Secure Boot can stay on (#129)](https://github.com/ashitaka1/viam-batch-provisioner/issues/129)).
- [ ] Set the boot order to disk, USB, then network, and set Restore on AC Power Loss to Power On. A machine with a blank disk installs from a stick or over PXE when plugged in, and an installed machine boots its disk.
- [ ] If a machine arrives with an OS installed, boot the network once from the boot menu.
- [ ] Where Wake-on-LAN is offered, set it to Power On – Normal Boot.
- [ ] Cable the onboard port listed below to the serving network. That port becomes the uplink. Without `ROBOT_NET_PORT`, the next `enp*` port becomes the robot network. With `ROBOT_NET_PORT` set to the model's robot-network port below, that port carries the robot network and any other port can be cabled.
- [ ] Record the MAC of the cabled port. The queue identifies the machine by that MAC.
- [ ] To reinstall a machine that already boots its disk, set a one-time network boot from its running OS: `sudo efibootmgr` lists the entries, and `sudo efibootmgr --bootnext <PXE entry> && sudo reboot` boots the network once and leaves the order alone.

## ASUS NUC

| | |
|---|---|
| BIOS validated | GDPTL579.0039 |
| BIOS setup | F2 |
| Boot menu | F10 |
| Network boot | F12, once Boot → Boot Display Config → "Display F12 for Network Boot" is on |
| BIOS update | F7 |
| NICs | 2 × I226-V: `enp86s0` (PCI 1c.0), `enp87s0` (PCI 1c.3) |
| Port to cable | — (validated with `enp87s0` as the uplink) |
| Robot-network port | `enp86s0` |
| Install time | 7.5 min from PXE to `done` |

- Under Boot → Boot Configuration, enable UEFI PXE, save, and reboot. The PXE entry then appears under Boot Option #1.
- Each port has an IPv4 and an IPv6 PXE entry.
- The disk-first boot order that the installer sets stays in effect.
- The Wake-on-LAN from S4/S5 and Wake System from S5 settings offer Stay Off, Power On – Normal Boot, Power On – PXE Boot.
- The Restore on AC Power Loss setting is unverified (`—`).

## System76 Meerkat (single NIC)

| | |
|---|---|
| Model / BIOS | — |
| BIOS setup | — |
| Boot menu | — (F10 on NUC firmware, Esc on System76 open firmware) |
| Network boot | — |
| NICs | 1 — |
| Port to cable | the onboard port |
| Robot-network port | none: set `ROBOT_NET_ADDRESS=none`, or leave `ROBOT_NET_PORT` unset |

- With one port, the machine has no robot network after install.
- Newer Meerkats have an Intel BE200, which has no WiFi firmware in Ubuntu 24.04 (issue [WiFi fails on newer Intel chips (BE200/7740) — missing firmware (#3)](https://github.com/ashitaka1/viam-batch-provisioner/issues/3)).

## System76 Meerkat (CRARL579, dual I226-V)

| | |
|---|---|
| BIOS setup | — |
| Boot menu | — |
| NICs | 2 × I226-V |
| Port to cable | — |
| Robot-network port | — |

## Minisforum UM890 Pro

| | |
|---|---|
| BIOS validated | — |
| BIOS setup | Del |
| Boot menu | F7 |
| NICs | 2 × Realtek 2.5GbE |
| Port to cable | — |
| Robot-network port | — |

- The firmware ignores the boot order that the installer sets. Before or after the install, put NVMe above Network in Fixed Boot Order (issue [Minisforum UM890 BIOS ignores efibootmgr boot order (#4)](https://github.com/ashitaka1/viam-batch-provisioner/issues/4)).

## Advantech MIC-770 V3

| | |
|---|---|
| BIOS validated | — |
| BIOS setup | — |
| Boot menu | — |
| NICs | 2 (I219 + I210) |
| Port to cable | — |
| Robot-network port | — |

## AAEON CEXD-INTRBL

The machine installs over PXE on the HWE kernel. Port pinning and a second SSD are open in [Provision the AAEON CEXD-INTRBL (#128)](https://github.com/ashitaka1/viam-batch-provisioner/issues/128).

| | |
|---|---|
| BIOS validated | R1.8 (CRBLAM18), 07/31/2026, AMI Aptio 2.22.1299 |
| BIOS setup | Esc |
| Boot menu | F7 |
| Power button | none; it powers on when plugged in |
| NICs | 4 × I226-V (`igc`, NVM 2017:888d), one controller per port: `enp2s0` (PCI 1c.0), `enp3s0` (1c.5), `enp4s0` (1c.6), `enp5s0` (1c.7); PXE on `enp2s0` and `enp3s0` only |
| Jacks (2 × 2 block) | upper right `enp2s0`, lower right `enp3s0`, lower left `enp5s0`, upper left `enp4s0` |
| Boot menu PXE entries | two, both named for the I226-V: the first is `enp2s0`, the second `enp3s0` |
| Port to cable | `enp2s0` or `enp3s0`; validated on both |
| Robot-network port | `enp3s0` |
| Install time | 10.6 min from PXE to `done` |

- The firmware puts PXE back ahead of the disk after the installer sets disk first, and its PXE ROM can take over a minute to fetch GRUB. Set the boot order by hand.
- After an install without `ROBOT_NET_PORT`, `enp2s0` is the uplink, `enp3s0` is the robot network, and `enp4s0` and `enp5s0` are unmanaged and administratively down, so their link lights stay off. With `ROBOT_NET_PORT=enp3s0`, `enp3s0` is the robot network and the other three ports use DHCP.
- The robot-network address appears on `enp3s0` only while it has link; `networkctl status enp3s0` reads `no-carrier (configured)` without one.
- The installer boots the 6.17 HWE kernel, and the installed system runs the current HWE kernel (7.0 as of 2026-11).
- The machine has one 256 GB NVMe on its own root port and no VMD controller. The E-key slot ships empty, so there is no WiFi.
- The NPU (`intel_vpu`, `/dev/accel0`) and IPU (`intel-ipu7`) are enabled under BIOS R1.8 and run on in-kernel drivers on the 7.0 HWE kernel, so they load under Secure Boot without a MOK (machine owner key).
