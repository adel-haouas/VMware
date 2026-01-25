#!/bin/sh
# clone_thin_progress.sh
# ESXi BusyBox-safe VM clone script:
# - clones VMDK as THIN
# - copies + renames all non-disk VM files so NONE contain the template name
# - rewrites the VMX (displayName + file references + scoreboard/log paths)
# - shows a real progress bar during vmkfstools clone
#
# Usage:
#   ./clone_thin_progress.sh <datastore_name> <src_vm_folder_name> <dst_vm_name>
# Example:
#   ./clone_thin_progress.sh datastore1 template_debian13 vm-debian13-new1
#
# Notes:
# - Run as root on ESXi shell/SSH.
# - Source VM should be powered off (recommended).
# - This script assumes the source VM folder is at /vmfs/volumes/<ds>/<src_vm_folder>
# - The main disk is detected from the .vmx (first scsi0:0.fileName or sata0:0.fileName).

set -eu

if [ $# -ne 3 ]; then
  echo "Usage: $0 <datastore_name> <src_vm_folder_name> <dst_vm_name>"
  exit 1
fi

START_TS=$(date +%s)
DS="$1"
SRC_NAME="$2"
DST_NAME="$3"

SRC_DIR="/vmfs/volumes/$DS/$SRC_NAME"
DST_DIR="/vmfs/volumes/$DS/$DST_NAME"

log() { echo "===> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# -------- Progress bar (real, based on vmkfstools output) --------
progress_bar() {
  pct="$1"
  width=40
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))

  printf "\r["
  i=0
  while [ $i -lt $filled ]; do printf "#"; i=$((i+1)); done
  i=0
  while [ $i -lt $empty ]; do printf "-"; i=$((i+1)); done
  printf "] %3d%%" "$pct"

  [ "$pct" -eq 100 ] && printf "\n"
}

# -------- Pre-flight --------
[ -d "$SRC_DIR" ] || die "Source VM folder not found: $SRC_DIR"
[ -f "$SRC_DIR/$SRC_NAME.vmx" ] || die "Source VMX not found: $SRC_DIR/$SRC_NAME.vmx"

if [ -e "$DST_DIR" ]; then
  die "Destination folder already exists: $DST_DIR"
fi

log "Creating destination folder: $DST_DIR"
mkdir -p "$DST_DIR"

# -------- Identify source VMX + disk descriptor from VMX --------
SRC_VMX="$SRC_DIR/$SRC_NAME.vmx"
DST_VMX="$DST_DIR/$DST_NAME.vmx"

# Find first disk fileName referenced in VMX: prefer scsi0:0 then sata0:0
SRC_DISK_REL="$(sed -n 's/^scsi0:0\.fileName = "\(.*\)".*$/\1/p' "$SRC_VMX" | head -n 1 || true)"
if [ -z "$SRC_DISK_REL" ]; then
  SRC_DISK_REL="$(sed -n 's/^sata0:0\.fileName = "\(.*\)".*$/\1/p' "$SRC_VMX" | head -n 1 || true)"
fi
[ -n "$SRC_DISK_REL" ] || die "Could not find scsi0:0.fileName or sata0:0.fileName in $SRC_VMX"

# If path contains slashes, take basename for our local folder layout
SRC_DISK_DESC_BASENAME="$(basename "$SRC_DISK_REL")"
SRC_DISK_DESC="$SRC_DIR/$SRC_DISK_DESC_BASENAME"
[ -f "$SRC_DISK_DESC" ] || die "Source disk descriptor not found: $SRC_DISK_DESC"

# Destination disk descriptor name (match VM name)
# Keep same extension (.vmdk) obviously
DST_DISK_DESC="$DST_DIR/$DST_NAME.vmdk"

# Determine if source uses -flat or -sesparse etc is fine; vmkfstools clones descriptor.
log "Source VMX: $SRC_VMX"
log "Source disk descriptor: $SRC_DISK_DESC"
log "Destination VMX: $DST_VMX"
log "Destination disk descriptor: $DST_DISK_DESC"

# -------- Copy non-disk VM files --------
log "Copying non-disk VM files (vmx/nvram/vmsd/scoreboard/logs if present)"

# Copy everything EXCEPT:
# - any *.vmdk (descriptor or flat) because we will re-create via vmkfstools
# - swap *.vswp (if any)
# - core dumps
# - lock files
# - ctk files (optional: they are per-disk change tracking; better to regenerate)
for f in "$SRC_DIR"/*; do
  bn="$(basename "$f")"

  # Skip directories (rare in VM folder)
  if [ -d "$f" ]; then
    continue
  fi

  case "$bn" in
    *.vmdk|*.vswp|*.lck|*.dump|*.core|*"-ctk.vmdk"|*".ctk")
      continue
      ;;
  esac

  cp -p "$f" "$DST_DIR/$bn"
done

# Also copy the source VMX (we will rewrite and rename it)
cp -p "$SRC_VMX" "$DST_DIR/$SRC_NAME.vmx"

# -------- Clone disk as THIN with progress --------
log "Cloning disk as THIN with progress (vmkfstools)"
vmkfstools -i "$SRC_DISK_DESC" "$DST_DISK_DESC" -d thin  || exit 1
#vmkfstools -i "$SRC_DISK_DESC" -d thin "$DST_DISK_DESC" 2>&1 | while IFS= read -r line; do
#  case "$line" in
#    *"Clone:"*"%"*)
#      pct="$(echo "$line" | sed -n 's/.*Clone: *\([0-9]\+\)%.*/\1/p')"
#      [ -n "$pct" ] && progress_bar "$pct"
#      ;;
#  esac
#done

# -------- Rename copied config/state files so none contain template name --------
log "Renaming copied config/state files to destination name (remove any '$SRC_NAME' in filenames)"

# First rename the copied VMX to destination name
if [ -f "$DST_DIR/$SRC_NAME.vmx" ]; then
  mv "$DST_DIR/$SRC_NAME.vmx" "$DST_VMX"
fi

# Rename any files that still contain SRC_NAME in their filename
# (scoreboard, nvram, vmsd, vmxf, logs, etc)
for f in "$DST_DIR"/*; do
  bn="$(basename "$f")"
  case "$bn" in
    *"$SRC_NAME"*)
      new_bn="$(echo "$bn" | sed "s/$SRC_NAME/$DST_NAME/g")"
      # Avoid overwriting
      if [ "$bn" != "$new_bn" ]; then
        mv "$DST_DIR/$bn" "$DST_DIR/$new_bn"
      fi
      ;;
  esac
done

# After renaming, update variables for renamed ancillary files (optional)
DST_NVRAM="$DST_DIR/$DST_NAME.nvram"
DST_VMSD="$DST_DIR/$DST_NAME.vmsd"

# -------- Rewrite VMX references --------
log "Rewriting VMX references (displayName + file references + scoreboard/logs)"

# We will:
# - set displayName
# - replace any occurrences of SRC_NAME in:
#   - nvram file
#   - vmsd file
#   - extendedConfigFile (vmxf)
#   - log.fileName
#   - scoreboard related paths (if present)
#   - disk file reference(s): point to "$DST_NAME.vmdk"
# - remove/disable UUID/MAC hard pins if present (optional but recommended):
#   - uuid.bios, uuid.location, ethernet*.address, ethernet*.generatedAddress, etc.
#   (ESXi will generate new identifiers on first power-on question "I moved it/I copied it")
#
# BusyBox sed in-place: use temp file technique.
VMX_TMP="$DST_DIR/.vmx.tmp.$$"

# 1) Replace generic references of SRC_NAME -> DST_NAME
# (this covers log file names, nvram, vmsd, vmxf, scoreboard, etc.)
sed "s/$SRC_NAME/$DST_NAME/g" "$DST_VMX" > "$VMX_TMP"

# 2) Force disk reference(s) to destination descriptor name
#   Replace scsi0:0.fileName or sata0:0.fileName lines with DST_NAME.vmdk
# We do this even if the source had a different disk filename.
sed -e "s/^scsi0:0\.fileName = \".*\"/scsi0:0.fileName = \"$DST_NAME.vmdk\"/g" \
    -e "s/^sata0:0\.fileName = \".*\"/sata0:0.fileName = \"$DST_NAME.vmdk\"/g" \
    "$VMX_TMP" > "$VMX_TMP.2"

# 3) Ensure displayName is correct (add if missing)
if grep -q '^displayName = ' "$VMX_TMP.2"; then
  sed "s/^displayName = \".*\"/displayName = \"$DST_NAME\"/g" "$VMX_TMP.2" > "$VMX_TMP.3"
else
  # append displayName at end
  cat "$VMX_TMP.2" > "$VMX_TMP.3"
  echo "displayName = \"$DST_NAME\"" >> "$VMX_TMP.3"
fi

# 4) Remove hard-pinned UUID/MAC (optional but helps avoid duplicates)
# Comment-out by deleting lines (safer in templates)
# Note: leaving these may still work; ESXi will prompt "copied/moved" and regenerate some,
# but pinned MACs/UUIDs can persist.
sed -e '/^uuid\.bios = /d' \
    -e '/^uuid\.location = /d' \
    -e '/^vc\.uuid = /d' \
    -e '/^ethernet[0-9]\+\.address = /d' \
    -e '/^ethernet[0-9]\+\.generatedAddress = /d' \
    -e '/^ethernet[0-9]\+\.generatedAddressOffset = /d' \
    "$VMX_TMP.3" > "$DST_VMX"

rm -f "$VMX_TMP" "$VMX_TMP.2" "$VMX_TMP.3"

# -------- Final sanity: ensure no files contain SRC_NAME --------
log "Sanity check: ensure no file in destination contains '$SRC_NAME' in its NAME"
if ls -1 "$DST_DIR" | grep -q "$SRC_NAME"; then
  echo "Files still containing '$SRC_NAME' in name:"
  ls -1 "$DST_DIR" | grep "$SRC_NAME" || true
  die "Destination still has filenames containing template name. Fix above and re-run."
fi

log "Clone completed successfully."
log "Register VM with:"
echo "vim-cmd solo/registervm $DST_VMX"

####
echo "===> Verifying destination disk provisioning type"

DST_VMDK="$DST_DIR/$DST_NAME.vmdk"

VMKF_OUT=$(vmkfstools -D "$DST_VMDK" 2>/dev/null)

if [ $? -ne 0 ]; then
  echo "ERROR: vmkfstools failed on $DST_VMDK"
  exit 1
fi

PREALLOC=$(echo "$VMKF_OUT" | awk '/numPreAllocBlocks/ {print $NF}')

if [ "$PREALLOC" = "0" ]; then
  echo "SUCCESS: Destination disk is THIN-provisioned"
else
  echo "ERROR: Destination disk is NOT thin-provisioned"
  echo "numPreAllocBlocks=$PREALLOC (expected 0)"
  exit 2
fi

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS=$((ELAPSED % 60))

echo "======================================"
echo "Clone finished in: ${HOURS}h ${MINUTES}m ${SECONDS}s"
echo "======================================"
