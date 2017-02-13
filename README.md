Purpose:
1. Build CoreOS images in docker container.

2. Build realtime kernel for CoreOS
   The stable CoreOS kernel is patched with the Linux PREEMPT_RT patchset.

3. Build tarball that can be used to build kernel modules for CoreOS

4. Create an environment where the CoreOS images can be rebuilt offline

Instruction:

1. Build docker image
   docker build -t inaetics/coreos_sdk_stage0 .

2. Build script
   docker run inaetics/coreos_sdk_stage0 ./src/third_party/inaetics/coreos_sdk.sh build_script > coreos_sdk.sh
   chmod +x coreos_sdk.sh

3. Create CoreOS SDK container
   ./coreos_sdk.sh prepare_coreos_sdk

4. Extend SDK container with all package sources needed
   ./coreos_sdk.sh build_target_online

5. Build the CoreOS image (first stage that runs without network)
   ./coreos_sdk.sh build_image

6. Optionally: build kernel modules package
   ./coreos_sdk.sh build_kernel_module_dir

Bugs
1. ./coreos_sdk.sh prepare_build_offline fails

Note: the script creates a number of very large (at most 15GB) named docker containers.
      Remove these manually

Updating to a new CoreOS release:
1. The version number is in the Dockerfile and in the resources/coreos_sdk.sh
2. Perform the steps until prepare_coreos_sdk
3. Extract the new kernel config file and add the PREEMPT_RT settings
4. Extract the ebuild files of coreos-sources and coreos-firmware from the coreos_container_stage1 image
5. Download the rt patchset that is closest to the version used in CoreOS and rename it to the same version number as CoreOS has with the rt extension.
6. Make the necessary changes in the ebuild files (version number and rt patch)


Analysing the emerge environment
1. Tests are done inside the chromite/cros_sdk environment
   Adapt src/third_party/coreos-overlay/eclass/coreos-kernel.eclass
   Add -rt10 to COREOS_SOURCE_VERSION but then also in 
   coreos-overlay/sys-kernel/coreos-sources-rt2-rt10 is needed
2. Involved are third-pary/portage/eclass/linux-info.eclass 
                third-party/coreos-overlay/eclass/coreos-kernel.eclass
   The ebuild and eclass files are not so much different from the originals but didn't create patches
   Check the lines that contain -rt10 to find the real differences
