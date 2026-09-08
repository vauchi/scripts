#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Provisions the RAM disk the macOS CI runner (nell) builds on.
#
# Installed on the host as /usr/local/bin/setup-ramdisk.sh and run at boot
# by the /Library/LaunchDaemons/com.gitlab-runner.ramdisk.plist daemon:
#
#   sudo install -m 755 -o root -g wheel \
#     scripts/scripts/setup-runner-ramdisk.sh /usr/local/bin/setup-ramdisk.sh
#
# Kept in the repository because the previous copy lived only on the host,
# where every variable reference had been stripped from it at some point:
# `$MOUNT_POINT`, `$DISK` and `$RAMDISK_SIZE` were all empty, and the guard
# read `if ! mount | grep -q ""`, which matches any line `mount` prints and
# therefore never ran the body. It had been a silent no-op since at least
# 2026-02, and nothing noticed because a missing RAM disk only makes builds
# slower, never louder.
set -euo pipefail

RAMDISK_SECTORS=8388608 # 4 GiB, in 512-byte sectors
VOLUME_NAME="RAMDisk"
MOUNT_POINT="/Volumes/${VOLUME_NAME}"
OWNER="gitlab-runner:staff"

if [ "$(id -u)" -ne 0 ]; then
  echo "setup-ramdisk: must run as root (it writes /Volumes)" >&2
  exit 1
fi

# A real mount, not a directory that happens to share the name. Match the
# mount point up to the " (" that opens the options field: `mount` prints
# `<dev> on <point> (<opts>)`, and a trailing-space match alone also matches
# the "${MOUNT_POINT} 1" line macOS creates when the point is occupied —
# which is exactly the broken state this script exists to repair, so it
# would report success and change nothing.
if /sbin/mount | grep -qF " on ${MOUNT_POINT} ("; then
  echo "setup-ramdisk: already mounted at ${MOUNT_POINT}"
  exit 0
fi

# A plain directory sitting on the mount point makes macOS mount the volume
# as "${MOUNT_POINT} 1" instead, so every consumer of ${MOUNT_POINT} keeps
# writing to the boot disk with no error. Move it aside rather than delete
# it: a RAM disk cannot survive a reboot, so anything found here is stale by
# construction, but the path is on the boot volume and `rm -rf` under an
# unattended root daemon is not a risk worth taking.
if [ -e "${MOUNT_POINT}" ]; then
  stale="/var/tmp/${VOLUME_NAME}.stale-$(date +%Y%m%d%H%M%S)"
  echo "setup-ramdisk: moving stale ${MOUNT_POINT} to ${stale}"
  mv "${MOUNT_POINT}" "${stale}"
fi

DISK="$(hdiutil attach -nomount "ram://${RAMDISK_SECTORS}" | tr -d '[:space:]')"
if [ -z "${DISK}" ]; then
  echo "setup-ramdisk: hdiutil returned no device" >&2
  exit 1
fi

diskutil erasevolume HFS+ "${VOLUME_NAME}" "${DISK}"
mkdir -p "${MOUNT_POINT}/builds" "${MOUNT_POINT}/cache"
chown -R "${OWNER}" "${MOUNT_POINT}"

echo "setup-ramdisk: ready at ${MOUNT_POINT} on ${DISK}"
