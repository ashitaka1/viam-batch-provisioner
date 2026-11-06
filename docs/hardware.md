# Hardware

Per-model preparation for x86 targets. Each model needs this once, with a monitor and keyboard attached. Blanks (`—`) are unverified.

## Every machine

- [ ] Note the BIOS version; update only if this page lists a newer validated one.
- [ ] Enable UEFI network boot (PXE over IPv4). Save and reboot: most firmware lists the PXE entry only after that.
- [ ] Disable Secure Boot. The PXE chain serves GRUB without shim ([#129](https://github.com/ashitaka1/viam-batch-provisioner/issues/129)).
- [ ] Boot order: disk, USB, then network, with Restore on AC Power Loss set to Power On. A machine with a blank disk installs from a stick or over PXE when plugged in; an installed machine boots its disk.
- [ ] A machine that arrives with an OS installed: boot the network once from the boot menu.
- [ ] Wake-on-LAN, where offered: Power On – Normal Boot.
- [ ] Cable the onboard port listed below to the serving network. It becomes the uplink; the next `enp*` port becomes the robot network.
- [ ] Record the cabled port's MAC. The queue identifies the machine by it.
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
| Install time | 7.5 min from PXE to `done` |

- Boot → Boot Configuration: enable UEFI PXE, save, reboot. The PXE entry then appears under Boot Option #1.
- Each port has an IPv4 and an IPv6 PXE entry.
- The installer's disk-first boot order holds.
- Wake events: Wake-on-LAN from S4/S5 and Wake System from S5 offer Stay Off, Power On – Normal Boot, Power On – PXE Boot.
- Restore on AC Power Loss: —

## System76 Meerkat (single NIC)

| | |
|---|---|
| Model / BIOS | — |
| BIOS setup | — |
| Boot menu | — (F10 on NUC firmware, Esc on System76 open firmware) |
| Network boot | — |
| NICs | 1 — |
| Port to cable | the onboard port |

- With one port, the machine has no robot network after install.
- Newer Meerkats carry an Intel BE200 with no WiFi firmware in Ubuntu 24.04 ([#3](https://github.com/ashitaka1/viam-batch-provisioner/issues/3)).

## System76 Meerkat (CRARL579, dual I226-V)

| | |
|---|---|
| BIOS setup | — |
| Boot menu | — |
| NICs | 2 × I226-V |
| Port to cable | — |

## Minisforum UM890 Pro

| | |
|---|---|
| BIOS validated | — |
| BIOS setup | Del |
| Boot menu | F7 |
| NICs | 2 × Realtek 2.5GbE |
| Port to cable | — |

- The firmware ignores the boot order the installer sets. Before or after the install, put NVMe above Network in Fixed Boot Order ([#4](https://github.com/ashitaka1/viam-batch-provisioner/issues/4)).

## Advantech MIC-770 V3

| | |
|---|---|
| BIOS validated | — |
| BIOS setup | — |
| Boot menu | — |
| NICs | 2 (I219 + I210) |
| Port to cable | — |

## AAEON CEXD-INTRBL

Installs over PXE on the HWE kernel. Port pinning and a second SSD are open in [#128](https://github.com/ashitaka1/viam-batch-provisioner/issues/128).

| | |
|---|---|
| BIOS validated | R1.8 (CRBLAM18), 07/31/2026, AMI Aptio 2.22.1299 |
| BIOS setup | Esc |
| Boot menu | F7 |
| Power button | none; it powers on when plugged in |
| NICs | 4 × I226-V (`igc`, NVM 2017:888d): `enp2s0` (PCI 1c.0), `enp3s0` (1c.5), `enp4s0` (1c.6), `enp5s0` (1c.7); PXE on `enp2s0` and `enp3s0` only |
| Port to cable | `enp2s0` or `enp3s0`; validated on `enp2s0` |
| Install time | 10.6 min from PXE to `done` |

- The firmware puts PXE back ahead of the disk after the installer sets disk-first, and its PXE ROM can take over a minute to fetch GRUB. Set the boot order by hand.
- After install: `enp2s0` uplink, `enp3s0` robot network, `enp4s0` and `enp5s0` unmanaged.
- Kernel: the installer boots 6.17 HWE; the installed system runs the current HWE kernel (7.0 as of 2026-11).
- Storage: one 256 GB NVMe on its own root port; no VMD controller. The E-key slot ships empty, so there is no WiFi.
- The NPU (`intel_vpu`, `/dev/accel0`) and IPU (`intel-ipu7`) are enabled under BIOS R1.8 and run on in-kernel drivers on the 7.0 HWE kernel, so they load under Secure Boot without a MOK.
