#!/bin/bash

# This script bootstraps Ubuntu QEMU image

set -euo pipefail

UBUNTU_PATH=/tmp/ubuntu
KERNEL=6.8.0-45-generic

apt-get update
apt-get install -y --no-install-recommends guestfs-tools zstd linux-headers-$KERNEL wget

mkdir -p /opt

# Kernel modules
mkdir -p /tmp/modules
cd /tmp/modules
apt-get download linux-modules-$KERNEL
ar vx *.deb
tar -xf data.tar
mkdir /opt/kernel-modules
mv boot lib /opt/kernel-modules/
cd -

# Kernel itself
mkdir -p /tmp/kernel
cd /tmp/kernel
apt-get download linux-image-$KERNEL
ar vx *.deb
tar -I unzstd -xf data.tar.zst
mv boot/vmlinuz-$KERNEL /opt/
chmod 666 /opt/vmlinuz-$KERNEL
cd -

rm -rf /tmp/modules /tmp/kernel

mkdir -p $UBUNTU_PATH
cd $UBUNTU_PATH

# Ubuntu Minimal
wget -q http://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz -P /tmp/

# http://cloud-images.ubuntu.com/minimal/releases/jammy/release/
# It will complain about mknod failures, just skip them
tar xJf /tmp/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz 2>/dev/null || true

# Set up DNS. Yandex is chosen because Russian external internet connectivity is unstable
mkdir -p $UBUNTU_PATH/etc/resolvconf/resolv.conf.d
echo "nameserver 77.88.8.8" > $UBUNTU_PATH/etc/resolvconf/resolv.conf.d/head

# Enable autologin on ttyS0
mkdir -p $UBUNTU_PATH/etc/systemd/system/serial-getty@ttyS0.service.d
cat > $UBUNTU_PATH/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin root %I \$TERM
Type=idle
EOF

# No network configuration built-in, so we add some
cat > $UBUNTU_PATH/etc/netplan/config.yaml << EOF
network:
    version: 2
    renderer: networkd
    ethernets:
        ens3:
            dhcp4: true
EOF

# Build modules.dep
depmod -b /opt/kernel-modules $KERNEL

cp -frauT /opt/kernel-modules/boot $UBUNTU_PATH/boot
cp -frauT /opt/kernel-modules/lib $UBUNTU_PATH/usr/lib

# Fix: we don't have this label on our drive
sed -i 's/LABEL=cloudimg-rootfs/\/dev\/sda/' $UBUNTU_PATH/etc/fstab

# Add drive with test files
mkdir $UBUNTU_PATH/place
echo -e '/dev/sdb\t/place\text4\tdiscard,errors=remount-ro\t0 1' >> $UBUNTU_PATH/etc/fstab

# Add test code
cat > $UBUNTU_PATH/root/.bashrc << EOF
function retry {
  local retries=\$1
  shift

  local count=0
  until "\$@"; do
    exit=\$?
    wait=\$((2 ** \$count))
    if [[ \$count -lt \$retries ]]; then
      count=\$((count + 1))
      sleep \$wait
    else
      echo "Command exited with code \$exit, no more retries left."
      return \$exit
    fi
  done
  return 0
}

echo -n "Command line: "
cat /proc/cmdline
dmesg -W &

(xargs -n1 -a /proc/cmdline | grep gtest_debug > /dev/null)
export debug=\$?
if [[ \$debug -eq 0 ]]; then
    set -x
fi

if retry 5 curl -fsS http://nerc.itmo.ru/teaching/os/networkfs/check; then
    cd /place
    ./networkfs_test \$(xargs -n1 -a /proc/cmdline | grep gtest_args | tail -c +12)
    echo "networkfs_test exited with code \$?"
else
    echo "Try to restart the tests or report this issue to your teacher."
    echo "Debug information:"
    ip a
    resolvectl status
fi

if [[ \$debug -eq 0 ]]; then
    poweroff
else
    poweroff -f -f -d --no-wall > /dev/null 2> /dev/null
fi
EOF

# Get rid of excess logs
rm -rf $UBUNTU_PATH/etc/update-motd.d

# Pack everything into raw image
# https://libguestfs.org/guestfs-faq.1.html#broken-kernel-or-trying-a-different-kernel
export SUPERMIN_KERNEL_VERSION=$KERNEL
export SUPERMIN_KERNEL=/opt/vmlinuz-$KERNEL
export SUPERMIN_MODULES=/opt/kernel-modules/lib/modules/$KERNEL
virt-make-fs --format=raw --type=ext4 $UBUNTU_PATH /opt/ubuntu.img --size=1G

chmod 666 /opt/ubuntu.img
