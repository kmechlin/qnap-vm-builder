# virt_station_base

Multi-distro dev-VM builder targeting **QNAP Virtualization Station 4.1.x**.

`build.sh` picks a distro under `distros/<name>/`, downloads its base qcow2
(checksum-verified), renders that distro's cloud-init seed, customizes the
qcow2 with a root recovery password and NoCloud datasource pin, and packs
everything into a single `.ova` ready to upload to the NAS. A per-VM README
with the exact VS 4.1 import knobs lands next to it.

The OS disk is **qcow2 = natively thin**. No thick/thin toggle is needed
in VS — the file stays sparse, and the guest grows the rootfs into the
resized capacity on first boot.

## Distros shipped

- **debian-13** — Debian 13 trixie genericcloud + XFCE, full dev loadout
  (build chain, Python, Go, Node LTS, VS Code, Chrome, Claude Code).
- **lmde-7** — "Linux Mint Debian Edition 7 feel": Debian 13 base +
  Cinnamon (from Debian repos), slim app set (VS Code, Chrome, Claude
  Code only). dconf-tuned for low-latency SPICE consoles.

Both share the same Debian 13 base image (cached once under `cache/`); the
only difference between them is `cloud-init/user-data.tpl`.

## Layout

```
build.sh                       # multi-distro orchestrator
distros/
  debian-13/
    distro.conf                # BASE_URL, BASE_IMG, OVF_OS_TYPE, …
    cloud-init/
      user-data.tpl            # envsubst template ($USERNAME / $PWHASH / $VMHOSTNAME)
      meta-data.tpl
  lmde-7/
    distro.conf
    cloud-init/{user-data.tpl, meta-data.tpl}
scripts/
  build-seed-iso.sh            # cloud-init NoCloud (cidata) ISO builder
  build-ova.sh                 # qcow2 → streamOptimized vmdk → OVA tar
  ovf/vm.ovf.tpl               # OVF descriptor matching a real VS export
cache/                         # downloaded base image + checksum (gitignored)
out/<vm-name>/                 # one folder per build (gitignored)
  <vm-name>.ova                # the import artifact
  user-data, meta-data         # rendered seed, for inspection
  README.md                    # per-VM deploy steps
bootstrap.sh                   # manual-install fallback for non-cloud-init Debian
```

## Quick start

```bash
# Default: build debian-13, OVA-only output (user kmechlin, host dev-vm, 50G)
./build.sh

# Pick the LMDE 7 variant
./build.sh --distro lmde-7 -n development-LMDE7 -H development-LMDE7

# Per-build overrides
./build.sh --distro debian-13 -u alice -p 'first-login-pw' -H lab-vm -s 100G -n lab-vm

# Keep the loose qcow2/vmdk/seed.iso/ovf/mf alongside the .ova for debugging
# or the Create-path fallback in VS:
./build.sh --all-formats

# Force re-download of the base image after a new point release
./build.sh --refresh
```

Then follow `out/<vm-name>/README.md` to upload and import.

## What every guest gets (regardless of distro)

- **QXL + SPICE + virtio guest tools**: `xserver-xorg-video-qxl`,
  `spice-vdagent`, `qemu-guest-agent`.
- **Full Debian kernel**: cloud-init swaps `linux-image-cloud-amd64` (no
  qxl driver) for `linux-image-amd64` and auto-reboots. Without this the
  GUI never starts — efifb holds the device and lightdm sits idle.
- **qxl autoload** pinned via `/etc/modules-load.d/qxl.conf` so it loads
  before efifb releases the device.
- **Recovery root login** baked into the qcow2 via `virt-customize` so a
  cloud-init failure doesn't lock you out.
- **NoCloud datasource pinned** + `ds-identify notfound=enabled` so cloud-
  init still runs even when seed auto-detection fails.
- **`hashed_passwd` on the user record** so the dev user is unlocked at
  creation (the early cloud-init warning that used to leave the account
  locked is gone).
- **Custom xrandr modes** (2560×1080 21:9 + 2560×1440 16:9 QHD) registered
  in the user's `~/.xprofile` for ultrawide / QHD monitors. Anything taller
  than 2560×1600 exceeds the QXL VRAM budget VS gives the device.
- **Auto-reboot at the end of cloud-init** so the post-install state is
  the steady state.

What differs per distro lives in `distros/<name>/cloud-init/user-data.tpl`.
To change the app loadout for a distro, edit that file and re-run `build.sh`.

## Dependencies on this workstation

- `curl`, `qemu-img`, `sha512sum` (always required)
- `virt-customize` (libguestfs-tools) for the defensive qcow2 edits
- `openssl` or `mkpasswd` (password hashing)
- `gettext-base` (provides `envsubst`)
- One of `cloud-localds` (from `cloud-image-utils`), `genisoimage`, or `xorriso`

## Why qcow2, not raw

- qcow2 carries thin-provisioning inside the file. VS imports it as-is; the
  disk starts at ~325 MB and grows only as the guest writes blocks.
- Raw sparse files are fragile: scp/cp without the right flags inflates
  them to full size during transfer.
- qcow2 also supports internal snapshots and live-resize without surprises.

## Adding a new distro

1. `mkdir -p distros/<name>/cloud-init`
2. Drop `distro.conf` (set BASE_URL/BASE_IMG/SHA_FILE/SHA_TOOL/OVF_OS_TYPE).
3. Drop `user-data.tpl` and `meta-data.tpl` (copy from another distro,
   then change the package list / desktop / app installs). The
   QXL/SPICE/kernel/xrandr boilerplate is what makes the guest work on
   QNAP VS — keep that block intact.
4. `./build.sh --distro <name>` — done.
