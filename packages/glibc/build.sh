#!/usr/bin/env bash

set -euo pipefail

apt-get update

apt-get install -y \
    build-essential \
    bison \
    flex \
    gawk \
    gettext \
    texinfo \
    python3 \
    perl \
    rsync \
    wget \
    xz-utils \
    file \
    patch \
    jq \
    binutils

mkdir -p /packages/glibc/source
mkdir -p /packages/glibc/build
mkdir -p /packages/glibc/rootfs

cd /packages/glibc/source

wget -O glibc-2.44.tar.xz \
    https://ftp.gnu.org/gnu/glibc/glibc-2.44.tar.xz

echo "37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667  glibc-2.44.tar.xz" \
    | sha256sum -c -

tar -xf glibc-2.44.tar.xz

cd /packages/glibc/source/glibc-2.44

# Apply patches immediately after extracting the source.
for patch_file in /packages/glibc/*.patch; do
    [ -f "$patch_file" ] || continue
    patch -p1 < "$patch_file"
done

# Disable clone3.
rm -f sysdeps/unix/sysv/linux/*/clone3.S

# Disable editing of ldd for x86_64.
rm -f sysdeps/unix/sysv/linux/x86_64/configure*

# Install special syscall implementations.
cp /packages/glibc/{shmat.c,shmctl.c,shmdt.c,shmget.c,mprotect.c,syscall.c,fakesyscall*.h,fake_epoll_pwait2.c,setfs{u,g}id.c} \
    sysdeps/unix/sysv/linux/

# Install Android passwd/group support.
cp /packages/glibc/{android_passwd_group.*,android_system_user_ids.h} \
    nss/

bash /packages/glibc/gen-android-ids.sh \
    /packages \
    nss/android_ids.h \
    /packages/glibc/android_system_user_ids.h

# Install Android-compatible syslog implementation.
cp /packages/glibc/syslog.c \
    misc/

# Install Android System V shared-memory implementation.
cp /packages/glibc/shmem-android.* \
    sysvipc/

# Rename syscall.S so the normal implementation is disabled.
for arch in aarch64 arm i386 x86_64; do
    syscall_file="sysdeps/unix/sysv/linux/$arch/syscall.S"

    if [ -f "$syscall_file" ]; then
        mv "$syscall_file" \
            "sysdeps/unix/sysv/linux/$arch/syscallS.S"
    fi
done

# Generate disabled syscall headers.
for arch in aarch64 arm i386 x86_64; do
    disabled_header="sysdeps/unix/sysv/linux/$arch/disabled-syscall.h"

    : > "$disabled_header"

    while read -r syscall; do
        grep "#define __NR_${syscall} " \
            "sysdeps/unix/sysv/linux/$arch/arch-syscall.h" \
            || true

        sed -i \
            "/#define __NR_${syscall} /d" \
            "sysdeps/unix/sysv/linux/$arch/arch-syscall.h"
    done < <(
        jq -r '.[] | .[]' \
            /packages/glibc/fakesyscall.json
    )

    {
        echo
        echo '#define DISABLED_SYSCALL_WITH_FAKESYSCALL \'

        while read -r function; do
            need_return=false

            while read -r syscall; do
                if grep -q \
                    "^#define __NR_${syscall} " \
                    "$disabled_header"
                then
                    echo -e "\tcase __NR_${syscall}: \\"
                    need_return=true

                elif [[ "$syscall" =~ ^[0-9]+$ ]]; then
                    echo -e "\tcase ${syscall}: \\"
                    need_return=true
                fi

            done < <(
                jq -r \
                    --arg function "$function" \
                    '.[$function][]' \
                    /packages/glibc/fakesyscall.json
            )

            if [ "$need_return" = "true" ]; then
                echo -e "\t\treturn ${function}; \\"
            fi

        done < <(
            jq -r '. | keys | .[]' \
                /packages/glibc/fakesyscall.json
        )
    } >> "$disabled_header"

    sed -i '$ s| \\||' "$disabled_header"
done

# Replace hard-coded device paths.
for path in \
    /dev/stderr:/proc/self/fd/2 \
    /dev/stdin:/proc/self/fd/0 \
    /dev/stdout:/proc/self/fd/1
do
    old="${path%%:*}"
    new="${path#*:}"

    while read -r file; do
        sed -i "s|${old}|${new}|g" "$file"
    done < <(
        grep -s -r -l "$old" . || true
    )
done

# Prepare clean build directory.
rm -rf /packages/glibc/build/*
cd /packages/glibc/build

# Configure glibc for the native QEMU environment.
../source/glibc-2.44/configure \
    --prefix=/usr \
    --libdir=/usr/lib \
    --libexecdir=/usr/lib \
    --includedir=/usr/include \
    --host=aarch64-linux-gnu \
    --build=aarch64-linux-gnu \
    --target=aarch64-linux-gnu \
    --with-bugurl=https://github.com/termux-pacman/glibc-packages/issues \
    --with-pkgversion="GNU libc for Android" \
    --enable-bind-now \
    --enable-fortify-source \
    --disable-multi-arch \
    --enable-stack-protector=strong \
    --enable-systemtap \
    --disable-nscd \
    --disable-profile \
    --disable-werror \
    --disable-default-pie

# Build.
make -O"$(nproc)"

# Install into the custom rootfs.
make DESTDIR=/packages/glibc/rootfs install

# Remove files that should not be included.
rm -f /packages/glibc/rootfs/usr/etc/ld.so.cache
rm -f /packages/glibc/rootfs/usr/bin/tzselect
rm -f /packages/glibc/rootfs/usr/bin/zdump
rm -f /packages/glibc/rootfs/usr/bin/zic

# Install tmpfiles configuration.
install -dm755 \
    /packages/glibc/rootfs/usr/lib/tmpfiles.d

install -m644 \
    ../source/glibc-2.44/nscd/nscd.conf \
    /packages/glibc/rootfs/usr/etc/nscd.conf

install -m644 \
    ../source/glibc-2.44/nscd/nscd.tmpfiles \
    /packages/glibc/rootfs/usr/lib/tmpfiles.d/nscd.conf

install -m644 \
    ../source/glibc-2.44/posix/gai.conf \
    /packages/glibc/rootfs/usr/etc/gai.conf

echo
echo "========================================"
echo "glibc 2.44 build completed successfully"
echo "========================================"
echo
echo "Installed rootfs:"
echo "/packages/glibc/rootfs"
echo
echo "glibc:"
ls -l /packages/glibc/rootfs/usr/lib/libc.so* 2>/dev/null || true
echo
echo "Dynamic linker:"
find /packages/glibc/rootfs/usr/lib \
    -maxdepth 1 \
    -name 'ld-linux*' \
    -print
