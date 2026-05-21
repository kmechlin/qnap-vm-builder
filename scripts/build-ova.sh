#!/usr/bin/env bash
# build-ova.sh — wrap a per-VM qcow2 + seed.iso into an OVF 1.x descriptor and
# tar them into a single .ova that QNAP Virtualization Station 4.1.x's Import
# wizard accepts.
#
# The OVF is shaped to match what VS itself emits on export (see
# sample-debian-13/Sample-debian-13.ovf) so the import wizard treats the OVA
# as native: vmx-08 VirtualSystemType, lsilogic SCSI controller with the
# cidata CD attached at port 1, PCNet32 NIC on a "bridged" network, EFI
# firmware, plus a trailing vbox:Machine block. The OS disk is always
# streamOptimized vmdk — that's the format real VS exports use, and the only
# one its Import wizard reliably accepts.
#
# Layout produced inside <vm-name>.ova (uncompressed ustar; OVF first, then
# disks, then manifest — order is required by the OVA spec):
#
#   <vm-name>.ovf   — OVF descriptor
#   <vm-name>.vmdk  — OS disk (streamOptimized), referenced as a SCSI HardDisk
#   seed.iso        — cloud-init cidata, referenced as a SCSI CD-ROM at port 1
#   <vm-name>.mf    — SHA-1 manifest of the OVF and both data files
#
# Usage:
#   build-ova.sh -n VMNAME -q DISK.qcow2 -s SEED.iso -d OUTDIR
#                [-c CPU] [-m MIB]
#
# Defaults: -c 4 -m 8192

set -euo pipefail

VMNAME=""
QCOW2=""
SEED=""
OUTDIR=""
CPU_COUNT="4"
MEMORY_MIB="8192"
OVF_OS_TYPE="debian13"   # default keeps existing behaviour; build.sh passes -O explicitly

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":n:q:s:d:c:m:O:h" opt; do
  case "$opt" in
    n) VMNAME="$OPTARG" ;;
    q) QCOW2="$OPTARG" ;;
    s) SEED="$OPTARG" ;;
    d) OUTDIR="$OPTARG" ;;
    c) CPU_COUNT="$OPTARG" ;;
    m) MEMORY_MIB="$OPTARG" ;;
    O) OVF_OS_TYPE="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

if [[ -z "$VMNAME" || -z "$QCOW2" || -z "$SEED" || -z "$OUTDIR" ]]; then
  echo "ERROR: -n, -q, -s, and -d are required." >&2
  usage
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
need qemu-img
need envsubst
need sha1sum
need tar
need stat
need uuidgen

[[ -f "$QCOW2" ]] || { echo "ERROR: qcow2 not found: $QCOW2" >&2; exit 1; }
[[ -f "$SEED"  ]] || { echo "ERROR: seed.iso not found: $SEED" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/ovf/vm.ovf.tpl"
[[ -f "$TPL" ]] || { echo "ERROR: template not found: $TPL" >&2; exit 1; }

SEED_FILENAME="$(basename -- "$SEED")"

# Virtual size = qcow2 capacity (what the guest sees post-resize). The vmdk
# we convert below preserves the same capacity.
DISK_CAPACITY_BYTES="$(qemu-img info --output=json -- "$QCOW2" \
  | sed -n 's/.*"virtual-size":[[:space:]]*\([0-9]\+\).*/\1/p' \
  | head -n1)"
if [[ -z "$DISK_CAPACITY_BYTES" ]]; then
  echo "ERROR: couldn't read virtual-size from $QCOW2" >&2
  exit 1
fi
SEED_FILE_SIZE="$(stat -c %s -- "$SEED")"

# Stage everything in OUTDIR so tar can run with -C and produce clean paths
# without a leading directory component.
mkdir -p -- "$OUTDIR"

OVF_OUT="$OUTDIR/$VMNAME.ovf"
MF_OUT="$OUTDIR/$VMNAME.mf"
OVA_OUT="$OUTDIR/$VMNAME.ova"

# Bring seed into OUTDIR if it isn't already there. Hardlink to avoid a copy;
# fall back to a reflink/sparse cp if the source is on a different filesystem.
ensure_in_outdir() {
  local src="$1" name="$2"
  local dst="$OUTDIR/$name"
  if [[ "$(readlink -f -- "$src")" == "$(readlink -f -- "$dst" 2>/dev/null)" ]]; then
    return 0
  fi
  rm -f -- "$dst"
  ln -- "$src" "$dst" 2>/dev/null \
    || cp --reflink=auto --sparse=always -- "$src" "$dst"
}
ensure_in_outdir "$SEED" "$SEED_FILENAME"

# --- materialize the OS disk as streamOptimized vmdk --------------------------
DISK_FILENAME="$VMNAME.vmdk"
DISK_OUT="$OUTDIR/$DISK_FILENAME"
echo ">> Converting qcow2 -> streamOptimized vmdk: $DISK_OUT"
rm -f -- "$DISK_OUT"
qemu-img convert -p -O vmdk -o subformat=streamOptimized -- "$QCOW2" "$DISK_OUT"
DISK_FILE_SIZE="$(stat -c %s -- "$DISK_OUT")"

# --- per-build identifiers (UUIDs, MAC, timestamp) ---------------------------
DISK_UUID="$(uuidgen)"
VBOX_MACHINE_UUID="$(uuidgen)"
# Locally-administered MAC in the QEMU OUI 52:54:00:xx:xx:xx (matches sample).
MAC_ADDR="$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
OVF_CREATION_TS="$(date -u '+%Y-%m-%d %H:%M:%S.%6N')"

echo ">> Rendering OVF: $OVF_OUT"
export VMNAME DISK_FILENAME SEED_FILENAME DISK_FILE_SIZE SEED_FILE_SIZE \
       DISK_CAPACITY_BYTES CPU_COUNT MEMORY_MIB \
       DISK_UUID VBOX_MACHINE_UUID MAC_ADDR OVF_CREATION_TS OVF_OS_TYPE
envsubst \
  '${VMNAME} ${DISK_FILENAME} ${SEED_FILENAME} ${DISK_FILE_SIZE} ${SEED_FILE_SIZE} ${DISK_CAPACITY_BYTES} ${CPU_COUNT} ${MEMORY_MIB} ${DISK_UUID} ${VBOX_MACHINE_UUID} ${MAC_ADDR} ${OVF_CREATION_TS} ${OVF_OS_TYPE}' \
  < "$TPL" > "$OVF_OUT"

# Optional well-formed-XML sanity check.
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$OVF_OUT" || { echo "ERROR: rendered OVF is not well-formed XML." >&2; exit 1; }
fi

echo ">> Writing manifest: $MF_OUT"
# ESXi 5.x ovftool wrote SHA-1 manifests. VS 4.1.1 expects an ESXi 5.0/5.5
# style OVA, so match that — SHA-256 might trip strict importers.
( cd -- "$OUTDIR" && \
  sha1sum -- "$VMNAME.ovf" "$DISK_FILENAME" "$SEED_FILENAME" \
    | awk '{ printf "SHA1(%s)= %s\n", $2, $1 }' \
    > "$VMNAME.mf"
)

echo ">> Packing OVA: $OVA_OUT"
# OVA = uncompressed ustar tar. OVF MUST be the first entry. We list disks
# next, then the manifest. -C avoids any directory prefix on the entries.
( cd -- "$OUTDIR" && \
  tar --format=ustar -cf "$VMNAME.ova" \
    "$VMNAME.ovf" "$DISK_FILENAME" "$SEED_FILENAME" "$VMNAME.mf"
)

echo "Built: $OVA_OUT"
echo "  Disk (vmdk streamOptimized): $DISK_FILENAME"
echo "  Disk capacity (guest view):  $DISK_CAPACITY_BYTES bytes"
echo "  Disk on-tar size:            $DISK_FILE_SIZE bytes"
echo "  seed.iso size:               $SEED_FILE_SIZE bytes"
echo "  CPUs / memory:               $CPU_COUNT vCPU / $MEMORY_MIB MiB"
echo "  MAC / disk UUID:             $MAC_ADDR / $DISK_UUID"
