#!/bin/bash
# Thanks to docker-raspberry-pi-cross-compiler "RPXC"

INPUT=$@

# Helpers
err() {
    echo -e >&2 ERROR: $@\\n
}

die() {
    err $@
    exit 1
}

has() {
    local kind=$1
    local name=$2
    
     type -t $kind:$name | grep -q function
}

add_user_in_container() {
    BUILDER_USER=inaetics-user
    BUILDER_GROUP=inaetics-group

    groupadd -o -g $BUILDER_GID $BUILDER_GROUP 2> /dev/null
    useradd -o -g $BUILDER_GID -u $BUILDER_UID $BUILDER_USER 2> /dev/null

}

# Command handlers
command:help() {
    echo "In command:help"
    if [[ $# != 0 ]]; then
        if ! has command $1; then
            err \"$1\" is not a supported command
            command:help
        elif ! has help $1; then
            err "No help found for \"$1\""
        else
            help:$1
        fi
    else
        cat >&2 <<ENDHELP
usage: docker run inaetics/coreos_sdk <command> <args> or
       coreos_sdk.sh <command> <args>

Built-in commands coreos_sdk.sh:
     build_script            - create coreos_sdk.sh (Actually the only command that should
                               be called by the user as docker run option)
     prepare_coreos_sdk	     - builds sdk environment
     prepare_build_offline   - fails on fetchonly
     build_target_online     - download all packages of the distro
     build_image             - build kernel and initrd image
     build_kernel_module_dir - build tarball that can be used to build kernel modules
ENDHELP
    fi 
}

command:build_script() {
    cat /home/coreos/src/third_party/inaetics/coreos_sdk.sh
    exit 0
}

command:prepare_coreos_sdk() {
     echo "build_coreos_sdk"
     docker run --name coreos_sdk_container_stage1 --privileged --net=host inaetics/coreos_sdk_stage0 ./src/third_party/inaetics/coreos_sdk.sh prepare_chroot
    docker commit coreos_sdk_container_stage1 inaetics/coreos_sdk_stage1 
    docker run --name coreos_sdk_container_stage2 --privileged --net=host inaetics/coreos_sdk_stage1 ./src/third_party/inaetics/coreos_sdk.sh download_sdk     
     docker commit coreos_sdk_container_stage2 inaetics/coreos_sdk_stage2
    # #  download the sdk
    docker run --name coreos_sdk_container_stage3 --privileged --net=host inaetics/coreos_sdk_stage2 ./chromite/bin/cros_sdk --download    
    docker commit coreos_sdk_container_stage3 inaetics/coreos_sdk_stage3
}

command:prepare_build_offline() {
# download all binary packages
    echo "This always fails"
    docker run --name coreos_sdk_container_stage4 --privileged --net=host inaetics/coreos_sdk_stage3 ./chromite/bin/cros_sdk -- ./build_packages --fetchonly
}

#command:copy_modules_ebuild() {
#    cp ./src/third_party/inaetics/linux_rt/coreos-modules-4.8.11-r2.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/.
#}

command:build_target_online() {
    docker run --privileged -v `pwd`:/tmp --net=host --name coreos_sdk_container_stage4 inaetics/coreos_sdk_stage3 ./src/third_party/inaetics/coreos_sdk.sh compile_online
    #docker run --privileged -v `pwd`:/tmp --net=host --name coreos_sdk_container_test inaetics/coreos_sdk_stage3 /tmp/coreos_sdk.sh copy_modules_ebuild
    #docker commit coreos_sdk_container_test inaetics/coreos_sdk_test
    #docker run --privileged -v `pwd`:/tmp --net=host --name coreos_sdk_container_stage4 inaetics/coreos_sdk_test /tmp/coreos_sdk.sh compile_online
    docker commit coreos_sdk_container_stage4 inaetics/coreos_sdk_stage4
}


# Following command is unfortunately the only one that runs offline for now
command:build_image() {
    # Needs at least 3 loop back devices
    docker run --privileged --name coreos_sdk_container_stage5 inaetics/coreos_sdk_stage4 ./src/third_party/inaetics/coreos_sdk.sh build_offline
    docker commit coreos_sdk_container_stage5 inaetics/coreos_sdk_stage5
    docker run -v `pwd`:/tmp inaetics/coreos_sdk_stage5 ./src/third_party/inaetics/coreos_sdk.sh get_images
}

command:build_kernel_module_dir() {
    docker run --privileged --name coreos_sdk_container_modules -v `pwd`:/tmp inaetics/coreos_sdk_stage5 ./src/third_party/inaetics/coreos_sdk.sh build_modules_dir
}

#===============================================================================
command:prepare_chroot() {
    echo "prepare_chroot"
#    ./chromite/bin/cros_sdk --sdk-version=1068.8.0 --create
#    ./chromite/bin/cros_sdk --sdk-version=1248.4.0 --create
#    ./chromite/bin/cros_sdk --sdk-version=1298.7.0 --create
    ./chromite/bin/cros_sdk --sdk-version=1353.7.0 --create
    ./chromite/bin/cros_sdk ./set_shared_user_password.sh core
    ./chromite/bin/cros_sdk -- bash -c "echo amd64-usr > .default_board"
}

command:compile_online() {
    echo "In compile_online before first build_packages"
    ./chromite/bin/cros_sdk -- ./build_packages --nousepkg --skip_chroot_upgrade --skip_toolchain_update
    echo "After build_packages, sometimes!? it fails on compiling rkt"
    ./chromite/bin/cros_sdk -- emerge-amd64-usr rkt
    echo "Rebuild kernel to be sure RT patches are used"
    ./chromite/bin/cros_sdk -- yes Y | emerge-amd64-usr -Ca coreos-kernel
    ./chromite/bin/cros_sdk -- yes Y | emerge-amd64-usr -Ca coreos-sources
    ./chromite/bin/cros_sdk -- emerge-amd64-usr coreos-sources
    ./chromite/bin/cros_sdk -- emerge-amd64-usr coreos-kernel
     echo "Second build_packages, merge everything together"
    ./chromite/bin/cros_sdk -- ./build_packages --nousepkg --skip_chroot_upgrade --skip_toolchain_update
}

command:build_offline() {
    set -e
#    # Assure at least 5 loopback devices exist before next step
    sudo mknod /dev/loop0 b 7 0 || true
    sudo mknod /dev/loop1 b 7 1 || true
    sudo mknod /dev/loop2 b 7 2 || true
    sudo mknod /dev/loop3 b 7 3 || true
    sudo mknod /dev/loop4 b 7 4 || true
    sudo mknod /dev/loop5 b 7 5 || true
    ./chromite/bin/cros_sdk -- ./build_image prod --group production
    ./chromite/bin/cros_sdk -- ./image_to_vm.sh --prod_image --format pxe
    ./chromite/bin/cros_sdk ../third_party/inaetics/coreos_sdk.sh build_disk_image
}


command:download_sdk_1068() {
    echo "prepare_sdk, downloads sdk environment"
    cp ./src/third_party/inaetics/linux_rt/patch-4.6.5-rt9.patch ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/files/4.6/.
    cp ./src/third_party/inaetics/linux_rt/coreos-sources-4.6.3.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/.
    cp ./src/third_party/inaetics/linux_rt/amd64_defconfig-4.6 ./src/third_party/coreos-overlay/sys-kernel/coreos-kernel/files/amd64_defconfig-4.6
    cp ./src/third_party/inaetics/linux_rt/coreos-firmware-20160331.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-firmware/.
    cp ./src/third_party/inaetics/linux_rt/coreos-modules-4.8.11-r2.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/.
    ./chromite/bin/cros_sdk ./setup_board 
}
command:download_sdk_1248() {
    echo "prepare_sdk, downloads sdk environment"
    cp ./src/third_party/inaetics/linux_rt/patch-4.8.11-rt10.patch ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/files/4.8/.
    cp ./src/third_party/inaetics/linux_rt/coreos-sources-4.8.11-r2.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/.
    cp ./src/third_party/inaetics/linux_rt/amd64_defconfig-4.8 ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-4.8
    cp ./src/third_party/inaetics/linux_rt/coreos-modules-4.8.11-r2.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/.
    cp ./src/third_party/inaetics/linux_rt/coreos-kernel.eclass ./src/third_party/coreos-overlay/eclass/.
    cp ./src/third_party/inaetics/linux_rt/coreos-firmware-20160331-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-firmware/.
    ./chromite/bin/cros_sdk ./setup_board 
}
command:download_sdk_1298() {
    echo "prepare_sdk, downloads sdk environment"
    cp ./src/third_party/inaetics/linux_rt/patch-4.9.20-rt16.patch ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/files/4.9/.
    cp ./src/third_party/inaetics/linux_rt/coreos-sources-4.9.16-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/.
    cp ./src/third_party/inaetics/linux_rt/amd64_defconfig-4.9 ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-4.9
    cp ./src/third_party/inaetics/linux_rt/coreos-modules-4.9.16-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/.
    cp ./src/third_party/inaetics/linux_rt/coreos-kernel.eclass ./src/third_party/coreos-overlay/eclass/.
    cp ./src/third_party/inaetics/linux_rt/coreos-firmware-20160331-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-firmware/.
    ./chromite/bin/cros_sdk ./setup_board 
}
command:download_sdk() {
    echo "prepare_sdk, downloads sdk environment"
    cp ./src/third_party/inaetics/linux_rt/z000-patch-4.9.24-rt20.patch ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/files/4.9/.
    cp ./src/third_party/inaetics/linux_rt/coreos-sources-4.9.24.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-sources/.
    cp ./src/third_party/inaetics/linux_rt/amd64_defconfig-4.9 ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/files/amd64_defconfig-4.9
#    cp ./src/third_party/inaetics/linux_rt/coreos-modules-4.9.16-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-modules/.
    cp ./src/third_party/inaetics/linux_rt/coreos-kernel.eclass ./src/third_party/coreos-overlay/eclass/.
    cp ./src/third_party/inaetics/linux_rt/coreos-firmware-20160331-r1.ebuild ./src/third_party/coreos-overlay/sys-kernel/coreos-firmware/.
    ./chromite/bin/cros_sdk ./setup_board 
}

command:build_disk_image() {
    echo "build_disk_image() function"
    cd `./get_latest_image.sh`
    echo "directory is " `pwd`
    lbzip2 --compress --keep coreos_production_image.bin
}

command:get_images() {
    echo "in function get_images()"
    FILE=`find src -name *vmlinuz | head -n1`
    DIR=`dirname ${FILE}`
    sudo cp ${FILE} /tmp/.
    sudo cp ${DIR}/coreos_production_pxe_image.cpio.gz /tmp/.
    sudo cp ${DIR}/coreos_production_image.bin.bz2 /tmp/.
}

command:build_modules_dir() {
    sudo cp /tmp/coreos_sdk.sh ./src/third_party/inaetics/coreos_sdk.sh
    ./chromite/bin/cros_sdk ../third_party/inaetics/coreos_sdk.sh build_modules_dir_in_chroot
    sudo cp chroot/build/amd64-usr/usr/src/coreos_linux.tgz /tmp/.
}
command:build_modules_dir_in_chroot_1298() {
    sudo cp /tmp/coreos_sdk.sh ./src/third_party/inaetics/coreos_sdk.sh
    ./chromite/bin/cros_sdk ../third_party/inaetics/coreos_sdk.sh build_modules_dir_in_chroot
    sudo cp chroot/build/amd64-usr/usr/src/coreos_linux.tgz /tmp/.
}

command:build_modules_dir_in_chroot_1068() {
    cd /build/amd64-usr/usr/src/linux-4.6.3-coreos;
    sudo cp /mnt/host/source/src/third_party/inaetics/linux_rt/amd64_defconfig-4.6 .; 
    sudo make olddefconfig; 
    sudo make modules_prepare; 
    sudo make
    sudo make clean
    cd ..
    sudo tar czf coreos_linux.tgz linux-4.6.3-coreos;
}
command:build_modules_dir_in_chroot_1248() {
    cd /build/amd64-usr/usr/src/linux-4.8.11-coreos-r2;
    sudo cp /mnt/host/source/src/third_party/inaetics/linux_rt/amd64_defconfig-4.8 .; 
    sudo make olddefconfig; 
    sudo make modules_prepare;
    sudo make
    sudo make clean 
    cd ..
    sudo tar czf coreos_linux.tgz linux-4.8.11-coreos-r2;
}
command:build_modules_dir_in_chroot_1298() {
    cd /build/amd64-usr/usr/src/linux-4.9.16-coreos-r1;
    sudo cp /mnt/host/source/src/third_party/inaetics/linux_rt/amd64_defconfig-4.9 .; 
    sudo make olddefconfig; 
    sudo make modules_prepare;
    sudo make
    sudo make clean 
    cd ..
    sudo tar czf coreos_linux.tgz linux-4.9.16-coreos-r1;
}
command:build_modules_dir_in_chroot() {
    cd /build/amd64-usr/usr/src/linux-4.9.24-coreos;
    sudo cp /mnt/host/source/src/third_party/inaetics/linux_rt/amd64_defconfig-4.9 .; 
    sudo make olddefconfig; 
    sudo make modules_prepare;
    sudo make
    sudo make clean 
    cd ..
    sudo tar czf coreos_linux.tgz linux-4.9.24-coreos;
}

FINAL_IMAGE="inaetics/coreos_sdk"
BUILDER_UID="${BUILDER_UID:-$( id -u )}"
BUILDER_GID="${BUILDER_GID:-$( id -g )}"
USER_IDS="-e BUILDER_UID=$( id -u ) -e BUILDER_GID=$( id -g )"

CURRENT_DIR=$PWD


# Command-line processing
if [[ $# == 0 ]]; then
    command:help
    exit 1 
fi

case $1 in
    --)
       shift;
       ;;
    
    *)
      if has command $1; then
          command:$1 "${@:2}" # skip first element array
          exit $?
      else
           command:help
#          docker run --rm --privileged -i -t -v $PWD:/build --entrypoint=$1 inaetics/coreos_sdk_stage0 ${@:2}
      fi
      ;;
esac

#########################################################################3
##
## Problem with ./build_packages --fetchonly
##
##
##[binary  N     ]   virtual/libudev-208:0/1::portage-stable to /build/amd64-usr/ USE="(-static-libs)" 0 KiB
##[nomerge       ] sys-auth/polkit-0.113-r3::coreos to /build/amd64-usr/ USE="introspection pam systemd -examples -gtk -jit -kde -nls -selinux {-test}" 
##
##* Error: circular dependencies:
##
##(sys-apps/systemd-229-r108:0/2::coreos, ebuild scheduled for merge to '/build/amd64-usr/') depends on
## (sys-apps/util-linux-2.27.1:0/0::portage-stable, binary scheduled for merge to '/build/amd64-usr/') (buildtime_slot_op)
##  (sys-apps/systemd-229-r108:0/2::coreos, ebuild scheduled for merge to '/build/amd64-usr/') (runtime)
##
## * Note that circular dependencies can often be avoided by temporarily
## * disabling USE flags that trigger optional dependencies.
##
##!!! The following binary packages have been ignored due to non matching USE:
##
##    =sys-apps/systemd-229-r108 cryptsetup # for /build/amd64-usr/
##
##NOTE: The --binpkg-respect-use=n option will prevent emerge
##      from ignoring these binary packages if possible.
##      Using --binpkg-respect-use=y will silence this warning.
##[binary  N     ]  sys-auth/pambase-20120417-r6::coreos to /build/amd64-usr/ USE="sha512 systemd (-consolekit) -cracklib -debug -gnome-keyring -minimal -mktemp -pam_krb5 -pam_ssh -passwdqc -selinux" 0 KiB
##[ebuild  N     ]   sys-apps/systemd-229-r108:0/2::coreos to /build/amd64-usr/ USE="audit curl gcrypt http importd kmod lzma nat pam policykit seccomp selinux symlink-usr (sysv-utils) (vanilla) -acl (-apparmor) -cryptsetup -elfutils -gnuefi -idn (-kdbus) -lz4 -man -profiling -qrcode (-ssl) {-test} -xkb" 0 KiB
##
##Total: 14 packages (14 new, 13 binaries), Size of downloads: 5722 KiB
##Running ['/home/coreos/src/scripts/sdk_lib/enter_chroot.sh', '--chroot', '/home/coreos/chroot', '--cache_dir', '/home/coreos/.cache', '--', './build_packages', '--fetchonly'] failed with exit code 1
##

