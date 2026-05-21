#!/usr/bin/env bash
# build.sh — multi-distro dev-VM builder for QNAP Virtualization Station 4.1.x.
#
# Pipeline:
#   1. Source distros/<name>/distro.conf for BASE_URL/BASE_IMG/OVF_OS_TYPE/etc.
#   2. Refresh the base qcow2 into cache/ (download + checksum verification).
#   3. Stage a per-VM qcow2 in out/<vm-name>/ (sparse copy, native thin).
#   4. Resize the qcow2 to the requested size (still sparse; guest grows on first boot).
#   5. Render cloud-init user-data + meta-data from distros/<name>/cloud-init/ and build seed.iso.
#   6. virt-customize the qcow2 with defensive edits (root pw, NoCloud pin).
#   7. Pack a streamOptimized vmdk + seed.iso into a single .ova.
#   8. Write a per-VM README.md with the exact QNAP VS 4.1 import steps.
#   9. Unless --all-formats, delete the loose qcow2/vmdk/seed.iso/ovf/mf —
#      they're already inside the .ova.
#
# Usage:
#   ./build.sh [--distro <name>] [--all-formats] [--refresh] [--force]
#              [-u user] [-p 'password'] [-H hostname] [-s 50G] [-n vm-name]
#              [-c cpus] [-m mib] [-R root-pw]
#
# Distros shipped:  debian-13 (default), lmde-7

set -euo pipefail

USERNAME="kmechlin"
PASSWORD='Ch4ng3m3!'
ROOT_PW=""
VMHOSTNAME=""
SIZE="50G"
VMNAME=""
CPU_COUNT="4"
MEMORY_MIB="8192"
REFRESH="0"
FORCE="0"
DISTRO="debian-13"
ALL_FORMATS="0"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$REPO_DIR/cache"
OUT_ROOT="$REPO_DIR/out"
DISTROS_DIR="$REPO_DIR/distros"

usage() {
  cat <<EOF
build.sh — build a per-VM dev-box bundle for QNAP VS 4.1.x.

Options:
  --distro NAME Distro to build (matches distros/NAME/)     (default: $DISTRO)
                Shipped: debian-13, lmde-7
  --all-formats Keep loose qcow2/vmdk/seed.iso/ovf/mf       (default: OVA only)
                alongside the .ova. Useful for debugging or
                the Create-path fallback. Without this, the
                output dir holds just the .ova, README, and
                the rendered user-data/meta-data text files.
  --refresh     Force re-download of the base qcow2 even if cached.
  --force       Overwrite an existing out/<vm-name>/ folder.
  -u USER       Linux account to create in the VM        (default: $USERNAME)
  -p PASS       Initial password (forced reset on login) (default: $PASSWORD)
  -H HOSTNAME   VM hostname                              (default: VMNAME, or dev-vm)
  -s SIZE       Resized OS disk size, e.g. 50G, 100G     (default: $SIZE)
  -n VMNAME     Per-VM folder name under out/            (default: same as hostname)
  -c CPUS       vCPU count baked into the OVF descriptor (default: $CPU_COUNT)
  -m MIB        Memory in MiB baked into the OVF         (default: $MEMORY_MIB)
  -R ROOT_PW    Root recovery password baked into the    (default: same as -p)
                qcow2 via virt-customize. Lets you log in
                as root even if cloud-init never runs.
  -h, --help    This help.

Output (default):       out/<vm-name>/{<vm-name>.ova, user-data, meta-data, README.md}
Output (--all-formats): out/<vm-name>/{<vm-name>.{ova,qcow2,vmdk,ovf,mf}, seed.iso, user-data, meta-data, README.md}
EOF
}

# getopts can't do long options cleanly; split long out first.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh)     REFRESH=1; shift ;;
    --force)       FORCE=1; shift ;;
    --all-formats) ALL_FORMATS=1; shift ;;
    --distro)      DISTRO="${2:?--distro needs a name}"; shift 2 ;;
    --distro=*)    DISTRO="${1#--distro=}"; shift ;;
    --help)        usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

while getopts ":u:p:R:H:s:n:c:m:h" opt; do
  case "$opt" in
    u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    R) ROOT_PW="$OPTARG" ;;
    H) VMHOSTNAME="$OPTARG" ;;
    s) SIZE="$OPTARG" ;;
    n) VMNAME="$OPTARG" ;;
    c) CPU_COUNT="$OPTARG" ;;
    m) MEMORY_MIB="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# --- load distro config ------------------------------------------------------
DISTRO_DIR="$DISTROS_DIR/$DISTRO"
DISTRO_CONF="$DISTRO_DIR/distro.conf"
DISTRO_CI="$DISTRO_DIR/cloud-init"
if [[ ! -f "$DISTRO_CONF" ]]; then
  echo "ERROR: unknown distro '$DISTRO' — no $DISTRO_CONF" >&2
  echo "Available distros:" >&2
  ls -1 "$DISTROS_DIR" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
if [[ ! -f "$DISTRO_CI/user-data.tpl" ]]; then
  echo "ERROR: $DISTRO_CI/user-data.tpl is missing" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$DISTRO_CONF"
: "${BASE_URL:?distro.conf must set BASE_URL}"
: "${BASE_IMG:?distro.conf must set BASE_IMG}"
: "${SHA_FILE:?distro.conf must set SHA_FILE}"
: "${SHA_TOOL:?distro.conf must set SHA_TOOL}"
: "${OVF_OS_TYPE:?distro.conf must set OVF_OS_TYPE}"

# If neither -n nor -H is set, default both to "dev-vm". Otherwise either one
# defaults to the other so `-n foo` gives you hostname foo too, and vice versa.
if [[ -z "$VMNAME" && -z "$VMHOSTNAME" ]]; then
  VMNAME="dev-vm"
  VMHOSTNAME="dev-vm"
elif [[ -z "$VMNAME" ]]; then
  VMNAME="$VMHOSTNAME"
elif [[ -z "$VMHOSTNAME" ]]; then
  VMHOSTNAME="$VMNAME"
fi

# Default root recovery password to the user-account password if -R wasn't set.
# Same secret, one thing to remember; both should be reset post-install anyway.
[[ -z "$ROOT_PW" ]] && ROOT_PW="$PASSWORD"

# --- tool checks -------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
need curl
need "$SHA_TOOL"
need qemu-img
need virt-customize
command -v cloud-localds >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1 || {
  echo "ERROR: need cloud-localds, genisoimage, or xorriso to build the seed ISO." >&2
  exit 1
}

# --- refresh base image ------------------------------------------------------
mkdir -p "$CACHE_DIR"
echo ">> Refreshing $BASE_URL/$SHA_FILE"
curl -fsSL "$BASE_URL/$SHA_FILE" -o "$CACHE_DIR/$SHA_FILE"

need_download="$REFRESH"
if [[ ! -f "$CACHE_DIR/$BASE_IMG" ]]; then
  need_download=1
else
  # Compare current cached file's checksum against the published one.
  expected_sum="$(awk -v f="$BASE_IMG" '$2 == f { print $1 }' "$CACHE_DIR/$SHA_FILE" || true)"
  if [[ -z "$expected_sum" ]]; then
    echo "ERROR: $BASE_IMG not listed in $CACHE_DIR/$SHA_FILE" >&2
    exit 1
  fi
  actual_sum="$("$SHA_TOOL" "$CACHE_DIR/$BASE_IMG" | awk '{print $1}')"
  if [[ "$expected_sum" != "$actual_sum" ]]; then
    echo ">> Cached $BASE_IMG is stale; re-downloading."
    need_download=1
  else
    echo ">> Cached $BASE_IMG matches published checksum; reusing."
  fi
fi

if [[ "$need_download" = "1" ]]; then
  echo ">> Downloading $BASE_URL/$BASE_IMG"
  curl -fL --progress-bar "$BASE_URL/$BASE_IMG" -o "$CACHE_DIR/$BASE_IMG.part"
  mv -f "$CACHE_DIR/$BASE_IMG.part" "$CACHE_DIR/$BASE_IMG"
fi

echo ">> Verifying checksum ($SHA_TOOL)"
( cd "$CACHE_DIR" && "$SHA_TOOL" -c --ignore-missing "$SHA_FILE" 2>&1 | grep -E "($BASE_IMG|FAILED)" ) \
  || { echo "ERROR: checksum verification failed." >&2; exit 1; }

# --- stage per-VM output -----------------------------------------------------
VM_DIR="$OUT_ROOT/$VMNAME"
if [[ -d "$VM_DIR" && -n "$(ls -A "$VM_DIR" 2>/dev/null)" && "$FORCE" != "1" ]]; then
  echo "ERROR: $VM_DIR exists and is not empty. Re-run with --force to overwrite." >&2
  exit 1
fi
mkdir -p "$VM_DIR"

VM_QCOW2="$VM_DIR/$VMNAME.qcow2"
echo ">> Staging $VM_QCOW2 (sparse copy)"
cp --reflink=auto --sparse=always "$CACHE_DIR/$BASE_IMG" "$VM_QCOW2"

echo ">> Resizing OS disk to $SIZE (qcow2 stays sparse)"
qemu-img resize "$VM_QCOW2" "$SIZE" >/dev/null

# --- bake recovery root password + pin NoCloud datasource --------------------
# Two defensive edits straight to the qcow2:
#   1) Set a root password so a cloud-init failure no longer = locked-out VM.
#   2) Pin the cloud-init datasource list to NoCloud (+ None as last-resort),
#      and flip ds-identify's notfound policy from "disabled" to "enabled".
#      Debian's default ds-identify gives up if it can't auto-detect the seed
#      and silently disables cloud-init — flipping these two knobs forces it
#      to run NoCloud anyway and re-look for the cidata CD.
echo ">> Baking root password + pinning NoCloud datasource via virt-customize"
# LIBGUESTFS_BACKEND=direct skips libvirt — fewer perms surprises on a workstation.
LIBGUESTFS_BACKEND=direct virt-customize -a "$VM_QCOW2" \
  --root-password "password:$ROOT_PW" \
  --write '/etc/cloud/cloud.cfg.d/99_pin_nocloud.cfg:datasource_list: [ NoCloud, None ]
' \
  --write '/etc/cloud/ds-identify.cfg:policy: enabled,found=all,maybe=all,notfound=enabled
' >/dev/null

# --- build seed ISO ----------------------------------------------------------
echo ">> Building seed.iso (from $DISTRO templates)"
"$REPO_DIR/scripts/build-seed-iso.sh" \
  -u "$USERNAME" \
  -p "$PASSWORD" \
  -H "$VMHOSTNAME" \
  -o "$VM_DIR/seed.iso" \
  -d "$VM_DIR" \
  -t "$DISTRO_CI"

# --- pack OVA (disk + seed.iso inside one tarball; VS Import accepts .ova) ---
echo ">> Building $VMNAME.ova (streamOptimized vmdk inside, osType=$OVF_OS_TYPE)"
"$REPO_DIR/scripts/build-ova.sh" \
  -n "$VMNAME" \
  -q "$VM_QCOW2" \
  -s "$VM_DIR/seed.iso" \
  -d "$VM_DIR" \
  -c "$CPU_COUNT" \
  -m "$MEMORY_MIB" \
  -O "$OVF_OS_TYPE"

# --- per-VM README -----------------------------------------------------------
# Files-list and Create-path-fallback sections are conditional on --all-formats.
# Under default (OVA-only) we only ship the .ova + text files, so we omit any
# instructions that rely on the loose qcow2/seed.iso being present.
README="$VM_DIR/README.md"

if [[ "$ALL_FORMATS" = "1" ]]; then
  FILES_LIST=$(cat <<EOF
- \`$VMNAME.ova\` — **primary import artifact**. Uncompressed tar containing
  the OVF descriptor, the OS disk (as **streamOptimized vmdk**), and the
  cidata seed.iso. Drop this into VS → Import VM.
- \`$VMNAME.qcow2\` — OS disk in qcow2 (thin/sparse). Used by the fallback
  Create path. The .ova carries a vmdk converted from this — vmdk is what
  cross-vendor OVF importers (VMware/VirtualBox/QNAP VS) accept.
- \`$VMNAME.vmdk\` — streamOptimized vmdk that's bundled inside the .ova,
  also left loose for inspection.
- \`seed.iso\` — cloud-init NoCloud \`cidata\` ISO. Already embedded as a
  CD-ROM (SCSI port 1) inside the OVA; the loose copy is for the fallback.
- \`$VMNAME.ovf\`, \`$VMNAME.mf\` — OVF descriptor + SHA-1 manifest staged
  alongside the .ova for inspection.
- \`user-data\`, \`meta-data\` — human-readable copies of what's on the ISO.
- \`README.md\` — this file.
EOF
)
  RSYNC_FALLBACK_HINT=$(cat <<EOF

If you might fall back to the Create path, ship the loose qcow2 + seed too:

\`\`\`
rsync -aS "$VMNAME.qcow2" seed.iso admin@<nas>:/share/Container/$VMNAME/
\`\`\`
EOF
)
  CREATE_PATH_SECTION=$(cat <<EOF

## Fallback path — Create + Use existing disk image

If VS rejects the OVA (e.g. qcow2-in-OVA not accepted by your VS build):

1. **Virtualization Station → Create → Create VM**.
2. **OS**: Linux → ${DISTRO_DESCRIPTION}. **Name**: \`$VMNAME\`.
3. **CPU**: $CPU_COUNT vCPU, **CPU mode = host-passthrough**.
4. **Memory**: $MEMORY_MIB MB.
5. **Boot firmware**: **UEFI (OVMF)** — matches what the OVF declares.
6. **Disk**: **Use existing disk image** →
   \`/share/Container/$VMNAME/$VMNAME.qcow2\`. Bus = **VirtIO**,
   Cache = **Writeback**. (No thick/thin toggle — qcow2 is thin inside.)
7. **CD/DVD**: add a drive, attach \`/share/Container/$VMNAME/seed.iso\`.
8. **Network**: virtio, attach to your LAN bridge.
9. **Display**: QXL + SPICE. **Input**: USB Tablet. **Channels**: QEMU Guest
   Agent **and** SPICE Agent (\`com.redhat.spice.0\`).
10. **Create**, then **Power on**.
EOF
)
else
  FILES_LIST=$(cat <<EOF
- \`$VMNAME.ova\` — **import artifact**. Uncompressed tar containing the OVF
  descriptor, the OS disk (streamOptimized vmdk), and the cidata seed.iso.
  Drop this into VS → Import VM.
- \`user-data\`, \`meta-data\` — human-readable copies of what's on the seed
  CD inside the OVA. Inspection only; not needed for import.
- \`README.md\` — this file.

> Re-run \`build.sh --all-formats\` if you also need the loose qcow2 / vmdk /
> seed.iso for the fallback Create-path import.
EOF
)
  RSYNC_FALLBACK_HINT=""
  CREATE_PATH_SECTION=""
fi

cat > "$README" <<EOF
# $VMNAME — QNAP Virtualization Station 4.1.x deploy

Generated by \`build.sh\` for distro **$DISTRO** ($DISTRO_DESCRIPTION).
The **.ova** is the one-click path through VS's *Import VM* wizard.

## Files in this folder

$FILES_LIST

## Upload to NAS

Pick any share VS can see (the conventional one is \`/share/Container/\`):

\`\`\`
rsync -aS "$VMNAME.ova" admin@<nas>:/share/Container/$VMNAME/
\`\`\`
$RSYNC_FALLBACK_HINT
\`-S\` preserves sparse holes — irrelevant for qcow2 (sparseness lives inside
the file) but harmless and useful if you ever ship a raw image.

## Import the OVA

1. **Virtualization Station → Import VM** → select
   \`/share/Container/$VMNAME/$VMNAME.ova\`.
2. The wizard parses the OVF. Confirm it shows:
   - Name: \`$VMNAME\`
   - OS: Linux / $DISTRO_DESCRIPTION
   - CPU: $CPU_COUNT vCPU, Memory: $MEMORY_MIB MB
   - Disk: $SIZE virtio-blk (qcow2)
   - CD-ROM: \`seed.iso\` (cidata)
3. Finish the wizard. **Before powering on**, *Edit* the VM and apply the bits
   OVF can't portably express:
   - **Display / Video**: **QXL** with **SPICE** protocol enabled (auto-port
     is fine). VNC works but you lose dynamic resize / clipboard / file copy.
   - **Input**: add **USB Tablet** (fixes mouse desync in the web console).
   - **Channels / Agents**: enable **QEMU Guest Agent** *and* add a
     **SPICE Agent** channel (virtio-serial port \`com.redhat.spice.0\`).
     Without the SPICE Agent channel, \`spice-vdagentd\` in the guest has
     no transport, so the web console's window-resize never propagates to
     the X server and the clipboard is one-way. The channel device is only
     attached at fresh power-on — a reboot won't add it; you have to fully
     shut the VM down first.
   - **CPU mode**: **host-passthrough** under Advanced (best perf).
   - **Disk cache mode**: **Writeback** (already in the OVF; confirm).
   - **Boot firmware**: **UEFI (OVMF)** — already declared in the OVF; the
     import wizard should pick it up. Confirm under *Edit → Boot*.
4. **Power on**. Cloud-init picks up the cidata CD-ROM and runs on first boot.
   Expect a 5–10 min run followed by an automatic reboot (cloud-init swaps
   the cloud kernel for the full one for QXL drivers, then reboots to use it).
$CREATE_PATH_SECTION

## First boot

- Open the web HTML5 console. Cloud-init runs for 5–10 minutes installing
  the desktop, full kernel, and apps from the user-data, **then the VM
  reboots itself** so the full kernel + qxl take over. The next boot lands
  you on the desktop autologin.
- **Recovery login**: a root password is baked into the qcow2 (\`virt-customize\`).
  If cloud-init never runs — e.g. seed CD not detected — you can still log in
  at the console as **root** with the password you passed to \`build.sh -R\`
  (defaults to the same value as \`-p\`). From there:
  \`cloud-init status --long\`, \`blkid\`, \`/var/log/cloud-init.log\`.
- SSH in to verify cloud-init finished:
  \`\`\`
  ssh $USERNAME@<vm-ip>          # initial password: <the one you passed to build.sh>
  \`\`\`
  PAM forces a password reset on this first login (sshd handles that cleanly;
  the desktop autologin does not — it just skips the prompt).
- After cloud-init finishes, **detach the cidata CD-ROM** in the VM editor and
  take a snapshot.
- The session pre-registers two custom xrandr modes (2560×1080 21:9 and
  2560×1440 16:9 QHD) via \`~/.xprofile\`. Pick whichever fits your monitor
  in the desktop's Display settings. Anything larger than 2560×1600 exceeds
  the QXL VRAM allocation VS gives the device and will fail to apply.

## Performance / driver sanity checks

Inside the VM:

\`\`\`
systemctl status qemu-guest-agent spice-vdagentd   # both active
lsmod | grep -E 'virtio_(net|blk|scsi|gpu)'         # virtio modules loaded
lspci | grep -i qxl                                 # QXL VGA visible
xdpyinfo | grep dimensions                          # changes when you resize the console
\`\`\`

If \`xdpyinfo\` reflects the console window when you resize it, spice-vdagent +
QXL are working together — that's the end state for max web-console performance.

## Build inputs (for the record)

- Distro: \`$DISTRO\` ($DISTRO_DESCRIPTION)
- User: \`$USERNAME\`
- Hostname: \`$VMHOSTNAME\`
- OS disk size: \`$SIZE\`
- vCPU / memory baked into OVF: $CPU_COUNT / $MEMORY_MIB MiB
- Base image: \`$BASE_URL/$BASE_IMG\` (cached in \`cache/\`, $SHA_TOOL verified)
- Built: $(date -Iseconds)
EOF

# --- post-build cleanup ------------------------------------------------------
# By default ship only the .ova (plus text seed for inspection and the README).
# The qcow2, vmdk, ovf, mf, and seed.iso are all already inside the .ova tar,
# so keeping the loose copies is just disk noise. --all-formats keeps them.
if [[ "$ALL_FORMATS" != "1" ]]; then
  rm -f -- "$VM_QCOW2" \
           "$VM_DIR/$VMNAME.vmdk" \
           "$VM_DIR/$VMNAME.ovf" \
           "$VM_DIR/$VMNAME.mf" \
           "$VM_DIR/seed.iso"
fi

# --- summary -----------------------------------------------------------------
echo
echo "=== Build complete: $VM_DIR ==="
ls -la "$VM_DIR"
if [[ -f "$VM_QCOW2" ]]; then
  echo
  echo "qcow2 thinness check:"
  qemu-img info "$VM_QCOW2" | grep -E 'virtual size|disk size'
fi
echo
echo "Next:  rsync -aS '$VM_DIR/$VMNAME.ova' admin@<nas>:/share/Container/$VMNAME/"
echo "Then:  Virtualization Station → Import VM → pick $VMNAME.ova"
echo "       (see $README for the import checklist)"
