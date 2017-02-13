From fedora:latest
Maintainer ThalesNetherlands

RUN dnf install -y \
    bzip2 \
    curl \
    findutils \
    git \
    /usr/sbin/ip \
    python2 \
    sudo \
    tar \
    wget \
    which \
    xz

RUN groupadd -g 500 core; useradd -u 500 -g 500 -G wheel core; chown -R core:core /home
RUN echo "%core ALL=(ALL)  NOPASSWD: ALL" >> /etc/sudoers

USER core 

RUN mkdir /home/bin; curl https://storage.googleapis.com/git-repo-downloads/repo > /home/bin/repo; chmod a+x /home/bin/repo
RUN mkdir /home/coreos 
WORKDIR   /home/coreos 

RUN git config --global core.email "develop@thales.com"; git config --global core.name "Developer"
RUN /home/bin/repo init -u https://github.com/coreos/manifest.git --manifest-branch=build-1248 --manifest-name=release.xml
RUN /home/bin/repo sync

RUN mkdir -p  /home/coreos/src/third_party/inaetics/linux_rt

#RUN cd /home/coreos/src/third_party/inaetics/linux_rt; wget https://www.kernel.org/pub/linux/kernel/projects/rt/4.6/older/patch-4.6.5-rt9.patch.gz; gunzip patch-4.6.5-rt9.patch.gz
#Note: The above patch needed an update in i915_gem_shrinker.c

ADD resources/coreos_sdk.sh /home/coreos/src/third_party/inaetics
# With Fedora24 as base image we run into an issue that was solved on the master branch of CoreOS
# cros_sdk: improve curl output parsing #21
ADD resources/cros_sdk.py /home/coreos/chromite/scripts/cros_sdk.py
# In docker the losetup command is not usable as is.
# From github.com/iamyam/coreos-build/blob/master/build-within-gentoo-docker.md got the following patch
ADD resources/grub_install.sh /home/coreos/src/scripts/build_library/grub_install.sh
RUN sudo chmod +x /home/coreos/src/scripts/build_library/grub_install.sh
# Add real-time linux patchset changes
ADD resources/linux_rt/* /home/coreos/src/third_party/inaetics/linux_rt/

RUN for i in `seq 2 4`; do sudo mknod /dev/loop$i b 7 $i; sudo chmod g+x /dev/loop$i; done


# Following needs --privileged due to mounting of /sys/fs/cgroup

#ENTRYPOINT ["/home/coreos/chromite/bin/cros_sdk"]
#RUN ./chromite/bin/cros_sdk --enter; ./set_shared_user_password.sh core; ./setup_board --default --board=amd64-usr


