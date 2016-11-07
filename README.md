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
