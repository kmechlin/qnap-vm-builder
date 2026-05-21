#!/usr/bin/env bash
# build-seed-iso.sh — render cloud-init user-data + meta-data from templates and
# build a NoCloud seed ISO (volume label: cidata) for a Debian 13 dev box.
#
# Templates: scripts/cloud-init/user-data.tpl, scripts/cloud-init/meta-data.tpl
# (Variables expanded with envsubst: USERNAME, PWHASH, VMHOSTNAME.)
#
# Usage:
#   ./build-seed-iso.sh [-u username] [-p 'password'] [-H hostname]
#                       [-o output.iso] [-d outdir] [-t template-dir]
#
# Defaults:  -u kmechlin   -p 'Ch4ng3m3!'   -H dev-vm   -o seed.iso
#            -d $(dirname output.iso)
#            -t $(dirname "$0")/cloud-init   (legacy, used when build.sh
#                                            doesn't pass an explicit -t)
#
# Notes:
#   * Quote the password if it contains shell metacharacters, e.g. -p 'Ch4ng3m3!'
#   * SSH password auth is ENABLED and NO public key is baked in.
#   * The password is set to EXPIRE, so the first login forces a reset.
#     Do that first login over SSH (password) — sshd/PAM prompts cleanly for the
#     change. After resetting it (and adding your own SSH key) the web console is
#     the normal way in.

set -euo pipefail

USERNAME="kmechlin"
PASSWORD='Ch4ng3m3!'
VMHOSTNAME="dev-vm"
OUTPUT="seed.iso"
OUTDIR=""
TPL_DIR=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":u:p:H:o:d:t:h" opt; do
  case "$opt" in
    u) USERNAME="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    H) VMHOSTNAME="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    d) OUTDIR="$OPTARG" ;;
    t) TPL_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Default template dir kept for backwards compatibility — `build.sh` always
# passes `-t distros/<name>/cloud-init` explicitly now.
[[ -z "$TPL_DIR" ]] && TPL_DIR="$SCRIPT_DIR/cloud-init"

if [[ ! -f "$TPL_DIR/user-data.tpl" || ! -f "$TPL_DIR/meta-data.tpl" ]]; then
  echo "ERROR: templates not found in $TPL_DIR" >&2
  exit 1
fi

# Where to drop rendered user-data / meta-data alongside the ISO. Default: ISO's dir.
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$(dirname -- "$OUTPUT")"
fi
mkdir -p -- "$OUTDIR"

# --- hash the password (don't ship plaintext on the ISO) ---
if command -v openssl >/dev/null 2>&1; then
  PWHASH="$(openssl passwd -6 "$PASSWORD")"
elif command -v mkpasswd >/dev/null 2>&1; then
  PWHASH="$(mkpasswd -m sha-512 "$PASSWORD")"
else
  echo "ERROR: need 'openssl' or 'mkpasswd' to hash the password." >&2
  echo "       sudo apt-get install -y openssl" >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: need 'envsubst' (gettext-base) to render templates." >&2
  echo "       sudo apt-get install -y gettext-base" >&2
  exit 1
fi

# Render templates. envsubst only expands variables we name explicitly, so any
# stray $foo in the templates (e.g. inside shell snippets) is left intact.
export USERNAME PWHASH VMHOSTNAME
RENDERED_USERDATA="$OUTDIR/user-data"
RENDERED_METADATA="$OUTDIR/meta-data"
envsubst '${USERNAME} ${PWHASH} ${VMHOSTNAME}' < "$TPL_DIR/user-data.tpl" > "$RENDERED_USERDATA"
envsubst '${VMHOSTNAME}' < "$TPL_DIR/meta-data.tpl" > "$RENDERED_METADATA"

# --- build the ISO (label must be cidata; filenames must be user-data/meta-data) ---
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "$OUTPUT" "$RENDERED_USERDATA" "$RENDERED_METADATA"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -output "$OUTPUT" -volid cidata -rock -joliet \
    -graft-points "user-data=$RENDERED_USERDATA" "meta-data=$RENDERED_METADATA"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -output "$OUTPUT" -volid cidata -rock -joliet \
    -graft-points "user-data=$RENDERED_USERDATA" "meta-data=$RENDERED_METADATA"
else
  echo "ERROR: need cloud-image-utils (cloud-localds), genisoimage, or xorriso." >&2
  echo "       sudo apt-get install -y cloud-image-utils" >&2
  exit 1
fi

echo "Built: $OUTPUT  (label: cidata)"
echo "  user: $USERNAME   host: $VMHOSTNAME   ssh-password-auth: on   baked-key: none"
echo "  Rendered user-data: $RENDERED_USERDATA"
echo "  Rendered meta-data: $RENDERED_METADATA"
echo "  First login over SSH with the password — it will force a reset."
