# virt_station_base

One-command Debian 13 dev-VM builder targeting **QNAP Virtualization Station 4.1.x**.

`build.sh` downloads the latest Debian 13 (`trixie`) `genericcloud` qcow2 from
`cloud.debian.org`, verifies SHA-512, drops a per-VM bundle into `out/<vm-name>/`
ready to upload to the NAS, and generates a deploy README with the exact VS 4.1
import knobs (QXL video, SPICE guest tools, virtio bus + NIC, tablet mouse,
guest-agent channel).

The OS disk is **qcow2 = natively thin**. No thick/thin toggle is needed in VS —
the file stays sparse, and the guest grows the rootfs into the resized capacity
on first boot.

## Layout

```
build.sh                       # top-level orchestrator
scripts/
  build-seed-iso.sh            # cloud-init NoCloud (cidata) ISO builder
  cloud-init/
    user-data.tpl              # envsubst template ($USERNAME / $PWHASH / $VMHOSTNAME)
    meta-data.tpl
cache/                         # downloaded base image + SHA512SUMS (gitignored)
out/<vm-name>/                 # one folder per build (gitignored)
  <vm-name>.qcow2              # thin OS disk
  seed.iso                     # cidata ISO
  user-data, meta-data         # rendered, for inspection
  README.md                    # per-VM deploy steps
bootstrap.sh                   # manual-install fallback for non-cloud-init Debian
```

## Quick start

```bash
# Build a dev VM bundle (defaults: user kmechlin, host dev-vm, 50G disk)
./build.sh

# Override
./build.sh -u alice -p 'first-login-pw' -H lab-vm -s 100G -n lab-vm

# Force re-download of the base image (e.g. after a new Debian point release)
./build.sh --refresh
```

Then follow `out/<vm-name>/README.md` to upload and import.

## What the guest gets (via cloud-init on first boot)

- **Desktop for the web console**: XFCE + LightDM autologin (so the QNAP HTML5
  console lands you on a graphical desktop, not a black screen).
- **VS-console performance**: `xserver-xorg-video-qxl`, `spice-vdagent`,
  `qemu-guest-agent`. virtio kernel modules are already in Debian's stock kernel.
- **Editors / browsers**: VS Code (Microsoft repo), Google Chrome, Claude Code
  (native installer, per-user).
- **Dev base chain**: `build-essential`, `git`, `make`, `pkg-config`, `unzip`.
- **Language runtimes**: Python 3 + venv + pip + pipx, Go (Debian repo),
  Node.js LTS via NodeSource.

To change what's installed, edit `scripts/cloud-init/user-data.tpl` and re-run
`./build.sh`.

## Dependencies on this workstation

- `curl`, `qemu-img`, `sha512sum` (always required)
- `openssl` or `mkpasswd` (password hashing)
- `gettext-base` (provides `envsubst`)
- One of `cloud-localds` (from `cloud-image-utils`), `genisoimage`, or `xorriso`

## Why qcow2, not raw

- qcow2 carries thin-provisioning inside the file. VS imports it as-is; the disk
  starts at ~325 MB and grows only as the guest writes blocks.
- Raw sparse files are fragile: scp/cp without the right flags inflates them to
  full size during transfer.
- qcow2 also supports internal snapshots and live-resize without surprises.
