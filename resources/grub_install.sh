#!/bin/bash

# Copyright (c) 2014 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Replacement script for 'grub-install' which does not detect drives
# properly when partitions are mounted via individual loopback devices.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

# Flags.
DEFINE_string board "${DEFAULT_BOARD}" \
  "The name of the board"
DEFINE_string target "" \
  "The GRUB target to install such as i386-pc or x86_64-efi"
DEFINE_string disk_image "" \
  "The disk image containing the EFI System partition."
DEFINE_boolean verity ${FLAGS_FALSE} \
  "Indicates that boot commands should enable dm-verity."
DEFINE_string copy_efi_grub "" \
  "Copy the EFI GRUB image to the specified path."
DEFINE_string copy_shim "" \
  "Copy the shim image to the specified path."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# must be sourced after flags are parsed.
. "${BUILD_LIBRARY_DIR}/toolchain_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1

# Our GRUB lives under coreos/grub so new pygrub versions cannot find grub.cfg
GRUB_DIR="coreos/grub/${FLAGS_target}"

# GRUB install location inside the SDK
GRUB_SRC="/usr/lib/grub/${FLAGS_target}"

# Modules required to boot a standard CoreOS configuration
CORE_MODULES=( normal search test fat part_gpt search_fs_uuid gzio search_part_label terminal gptprio configfile memdisk tar echo read )

# Name of the core image, depends on target
CORE_NAME=

# Whether the SDK's grub or the board root's grub is used. Once amd64 is
# fixed up the board root's grub will always be used.
BOARD_GRUB=0

case "${FLAGS_target}" in
    i386-pc)
        CORE_MODULES+=( biosdisk serial )
        CORE_NAME="core.img"
        ;;
    x86_64-efi)
	CORE_MODULES+=( serial linuxefi efi_gop getenv smbios efinet verify http tftp )
        CORE_NAME="core.efi"
        ;;
    x86_64-xen)
        CORE_NAME="core.elf"
        ;;
    arm64-efi)
        CORE_MODULES+=( serial linux efi_gop getenv smbios efinet verify http tftp )
        CORE_NAME="core.efi"
        BOARD_GRUB=1
        ;;
    *)
        die_notrace "Unknown GRUB target ${FLAGS_target}"
        ;;
esac

if [[ $BOARD_GRUB -eq 1 ]]; then
    info "Updating GRUB in ${BOARD_ROOT}"
    emerge-${BOARD} --nodeps --select -qugKN sys-boot/grub
    GRUB_SRC="${BOARD_ROOT}/usr/lib/grub/${FLAGS_target}"
fi
[[ -d "${GRUB_SRC}" ]] || die "GRUB not installed at ${GRUB_SRC}"

# In order for grub-setup-bios to properly detect the layout of the disk
# image it expects a normal partitioned block device. For most of the build
# disk_util maps individual loop devices to each partition in the image so
# the kernel can automatically detach the loop devices on unmount. When
# using a single loop device with partitions there is no such cleanup.
# That's the story of why this script has all this goo for loop and mount.
ESP_DIR=
#LOOP_DEV=
LOOP_DEV0=
LOOP_DEV1=

cleanup() {
    if [[ -d "${ESP_DIR}" ]]; then
        if mountpoint -q "${ESP_DIR}"; then
            sudo umount "${ESP_DIR}"
        fi
        rm -rf "${ESP_DIR}"
    fi
    # Be careful: original patch does it differently, see iamyaw coreos-build/build-with-gentoo-docker.md
    if [[ -b "${LOOP_DEV0}" ]]; then
        sudo losetup --detach "${LOOP_DEV1}"
    fi
    if [[ -b "${LOOP_DEV1}" ]]; then
        sudo losetup --detach "${LOOP_DEV0}"
    fi

    if [[ -n "${GRUB_TEMP_DIR}" && -e "${GRUB_TEMP_DIR}" ]]; then
      rm -r "${GRUB_TEMP_DIR}"
    fi
}
trap cleanup EXIT

info "Installing GRUB ${FLAGS_target} in ${FLAGS_disk_image##*/}"
LOOP_DEV0=$(sudo losetup --find --show "${FLAGS_disk_image}")
echo "Loopdev0: ${LOOP_DEV0}"
losetup -f
PART1_OFFSET=`expr $(partx -gn 1 -o START "${FLAGS_disk_image}") \* 512`
# Not sure if the -o flag is needed
LOOP_DEV1=$(sudo losetup --find --show -o ${PART1_OFFSET} ${LOOP_DEV0})
echo "Loopdev1: ${LOOP_DEV1}"

ESP_DIR=$(mktemp --directory)

sudo mount -t vfat "${LOOP_DEV1}" "${ESP_DIR}"
sudo mkdir -p "${ESP_DIR}/${GRUB_DIR}"

info "Compressing modules in ${GRUB_DIR}"
for file in "${GRUB_SRC}"/*{.lst,.mod}; do
    out="${ESP_DIR}/${GRUB_DIR}/${file##*/}"
    gzip --best --stdout "${file}" | sudo_clobber "${out}"
done

info "Generating ${GRUB_DIR}/load.cfg"
# Include a small initial config in the core image to search for the ESP
# by filesystem ID in case the platform doesn't provide the boot disk.
# The existing $root value is given as a hint so it is searched first.

ESP_FSID=$(sudo grub-probe -t fs_uuid -d "${LOOP_DEV1}")

sudo_clobber "${ESP_DIR}/${GRUB_DIR}/load.cfg" <<EOF
search.fs_uuid ${ESP_FSID} root \$root
set prefix=(memdisk)
set
EOF

# Generate a memdisk containing the appropriately generated grub.cfg. Doing
# this because we need conflicting default behaviors between verity and
# non-verity images.
GRUB_TEMP_DIR=$(mktemp -d)
if [[ ! -f "${ESP_DIR}/coreos/grub/grub.cfg.tar" ]]; then
    info "Generating grub.cfg memdisk"

    if [[ ${FLAGS_verity} -eq ${FLAGS_TRUE} ]]; then
      # use dm-verity for /usr
      cat "${BUILD_LIBRARY_DIR}/grub.cfg" | \
        sed 's/@@MOUNTUSR@@/mount.usr=\/dev\/mapper\/usr verity.usr/' > \
        "${GRUB_TEMP_DIR}/grub.cfg"
    else
      # uses standard systemd /usr mount
      cat "${BUILD_LIBRARY_DIR}/grub.cfg" | \
        sed 's/@@MOUNTUSR@@/mount.usr/' > "${GRUB_TEMP_DIR}/grub.cfg"
    fi

    sudo tar cf "${ESP_DIR}/coreos/grub/grub.cfg.tar" \
	 -C "${GRUB_TEMP_DIR}" "grub.cfg"
fi

info "Generating ${GRUB_DIR}/${CORE_NAME}"
sudo grub-mkimage \
    --compression=auto \
    --format "${FLAGS_target}" \
    --directory "${GRUB_SRC}" \
    --config "${ESP_DIR}/${GRUB_DIR}/load.cfg" \
    --memdisk "${ESP_DIR}/coreos/grub/grub.cfg.tar" \
    --output "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
    "${CORE_MODULES[@]}"

# Now target specific steps to make the system bootable
case "${FLAGS_target}" in
    i386-pc)
        info "Installing MBR and the BIOS Boot partition."
        sudo cp "${GRUB_SRC}/boot.img" "${ESP_DIR}/${GRUB_DIR}"
        sudo grub-bios-setup --device-map=/dev/null \
            --directory="${ESP_DIR}/${GRUB_DIR}" "${LOOP_DEV0}"
        # boot.img gets manipulated by grub-bios-setup so it alone isn't
        # sufficient to restore the MBR boot code if it gets corrupted.
        sudo dd bs=448 count=1 if="${LOOP_DEV0}" \
            of="${ESP_DIR}/${GRUB_DIR}/mbr.bin"
        ;;
    x86_64-efi)
        info "Installing default x86_64 UEFI bootloader."
        sudo mkdir -p "${ESP_DIR}/EFI/boot"
	# Use the test keys for signing unofficial builds
	if [[ ${COREOS_OFFICIAL:-0} -ne 1 ]]; then
            sudo sbsign --key /usr/share/sb_keys/DB.key \
		--cert /usr/share/sb_keys/DB.crt \
                    "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}"
            sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}.signed" \
                "${ESP_DIR}/EFI/boot/grub.efi"
            sudo sbsign --key /usr/share/sb_keys/DB.key \
                 --cert /usr/share/sb_keys/DB.crt \
                 --output "${ESP_DIR}/EFI/boot/bootx64.efi" \
                 "/usr/lib/shim/shim.efi"
        else
            sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
                "${ESP_DIR}/EFI/boot/grub.efi"
            sudo cp "/usr/lib/shim/shim.efi" \
                "${ESP_DIR}/EFI/boot/bootx64.efi"
	fi
        # copying from vfat so ignore permissions
        if [[ -n "${FLAGS_copy_efi_grub}" ]]; then
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/grub.efi" \
                "${FLAGS_copy_efi_grub}"
        fi
        if [[ -n "${FLAGS_copy_shim}" ]]; then
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/bootx64.efi" \
                "${FLAGS_copy_shim}"
        fi
        ;;
    x86_64-xen)
        info "Installing default x86_64 Xen bootloader."
        sudo mkdir -p "${ESP_DIR}/xen" "${ESP_DIR}/boot/grub"
        sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
            "${ESP_DIR}/xen/pvboot-x86_64.elf"
        sudo cp "${BUILD_LIBRARY_DIR}/menu.lst" \
            "${ESP_DIR}/boot/grub/menu.lst"
        ;;
    arm64-efi)
        info "Installing default arm64 UEFI bootloader."
        sudo mkdir -p "${ESP_DIR}/EFI/boot"
        #FIXME(andrejro): shim not ported to aarch64
        sudo cp "${ESP_DIR}/${GRUB_DIR}/${CORE_NAME}" \
            "${ESP_DIR}/EFI/boot/bootaa64.efi"
        if [[ -n "${FLAGS_copy_efi_grub}" ]]; then
            # copying from vfat so ignore permissions
            cp --no-preserve=mode "${ESP_DIR}/EFI/boot/bootaa64.efi" \
                "${FLAGS_copy_efi_grub}"
        fi
        ;;
esac

cleanup
trap - EXIT
command_completed
