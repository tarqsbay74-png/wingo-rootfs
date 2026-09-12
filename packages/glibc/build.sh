#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="${HOME}/glibc-build"
ROOTFS=/data/data/com.wingo/files/rootfs
GLIBC_VERSION=2.44
GLIBC_SRC="${BUILD_DIR}/glibc-${GLIBC_VERSION}"
GLIBC_BUILD="${BUILD_DIR}/glibc-build"
GLIBC_TARBALL="${BUILD_DIR}/glibc-${GLIBC_VERSION}.tar.xz"
GLIBC_ROOTFS_ARCHIVE="${BUILD_DIR}/glibc-${GLIBC_VERSION}-rootfs.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLIBC_BUILDER_DIR="$SCRIPT_DIR"

BUILD_TRIPLET=x86_64-linux-gnu
HOST_TRIPLET=aarch64-linux-gnu

PATH_PREFIX="${ROOTFS}/usr"
PATH_LIB="${ROOTFS}/usr/lib"
PATH_INCLUDE="${ROOTFS}/usr/include"
PATH_BIN="${ROOTFS}/usr/bin"
PATH_DYNAMIC_LINKER="${PATH_LIB}/ld-linux-aarch64.so.1"

mkdir -p "$BUILD_DIR"

echo "==> Cleaning previous build"

rm -rf "$GLIBC_SRC"
rm -rf "$GLIBC_BUILD"
rm -rf "$ROOTFS"
rm -f "$GLIBC_TARBALL"
rm -f "$GLIBC_ROOTFS_ARCHIVE"

echo "==> Downloading glibc ${GLIBC_VERSION}"

wget 
"https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VERSION}.tar.xz" 
-O "$GLIBC_TARBALL"

echo "==> Verifying checksum"

echo "37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667  ${GLIBC_TARBALL}" 
| sha256sum -c -

echo "==> Extracting glibc"

tar -xf 
"$GLIBC_TARBALL" 
-C "$BUILD_DIR"

echo "==> Applying patches"

cd "$GLIBC_SRC"

for patch_file in "$GLIBC_BUILDER_DIR"/*.patch; do
if [ -f "$patch_file" ]; then
echo "Applying: $patch_file"
patch -p1 < "$patch_file"
fi
done

echo "==> Disabling clone3 function"

rm 
sysdeps/unix/sysv/linux/*/clone3.S

echo "==> Disabling editing of ldd script for x86_64 arch"

rm 
sysdeps/unix/sysv/linux/x86_64/configure*

echo "==> Installing special syscall files"

cp 
"$GLIBC_BUILDER_DIR"/shm{at,ctl,dt,get}.c 
"$GLIBC_BUILDER_DIR"/mprotect.c 
"$GLIBC_BUILDER_DIR"/syscall.c 
"$GLIBC_BUILDER_DIR"/fakesyscall*.h 
"$GLIBC_BUILDER_DIR"/fake_epoll_pwait2.c 
"$GLIBC_BUILDER_DIR"/setfs{u,g}id.c 
sysdeps/unix/sysv/linux/

echo "==> Installing Android passwd/group handling"

cp 
"$GLIBC_BUILDER_DIR"/android_passwd_group.* 
"$GLIBC_BUILDER_DIR"/android_system_user_ids.h 
nss/

bash 
"$GLIBC_BUILDER_DIR/gen-android-ids.sh" 
"$BUILD_DIR" 
"$GLIBC_SRC/nss/android_ids.h" 
"$GLIBC_BUILDER_DIR/android_system_user_ids.h"

echo "==> Installing Android-compatible syslog"

cp 
"$GLIBC_BUILDER_DIR/syslog.c" 
misc/

echo "==> Installing System V shared memory emulation"

cp 
"$GLIBC_BUILDER_DIR"/shmem-android.* 
sysvipc/

echo "==> Disabling unsupported syscalls"

syscall_dir="sysdeps/unix/sysv/linux/aarch64"

mv 
"${syscall_dir}/syscall.S" 
"${syscall_dir}/syscallS.S"

header_disabled_syscall="${syscall_dir}/disabled-syscall.h"

{
for j in $(jq -r '.[] | .[]' 
"$GLIBC_BUILDER_DIR/fakesyscall.json"); do

    grep \
        "#define __NR_${j} " \
        "${syscall_dir}/arch-syscall.h" \
        || true

    sed -i \
        "/#define __NR_${j} /d" \
        "${syscall_dir}/arch-syscall.h"

done

} >> "$header_disabled_syscall"

{
echo -e "\n#define DISABLED_SYSCALL_WITH_FAKESYSCALL \"

local_ifs_backup="$IFS"
IFS=$'\n'

for j in $(jq -r \
    '. | keys | .[]' \
    "$GLIBC_BUILDER_DIR/fakesyscall.json"); do

    need_return=false

    for z in $(jq -r \
        '."'${j}'" | .[]' \
        "$GLIBC_BUILDER_DIR/fakesyscall.json"); do

        if grep -q \
            "^#define __NR_${z} " \
            "$header_disabled_syscall"
        then
            echo -e "\tcase __NR_${z}: \\"
            need_return=true

        elif [[ ${z} =~ ^[0-9]+$ ]]; then
            echo -e "\tcase ${z}: \\"
            need_return=true
        fi

    done

    [ "${need_return}" = "true" ] && \
        echo -e "\t\treturn ${j}; \\"

done

IFS="$local_ifs_backup"

} >> "$header_disabled_syscall"

sed -i 
'$ s| \||' 
"$header_disabled_syscall"

echo "==> Replacing Android-incompatible hard paths"

for i in 
/dev/stderr:/proc/self/fd/2 
/dev/stdin:/proc/self/fd/0 
/dev/stdout:/proc/self/fd/1
do

while IFS= read -r j; do
    sed -i \
        "s|${i%%:*}|${i//*:}|g" \
        "$j"
done < <(
    grep \
        -s \
        -r \
        -l \
        "${i%%:*}" \
        "$GLIBC_SRC"
)

done

echo "==> Android modifications completed"

echo "==> Preparing build directory"

mkdir -p "$GLIBC_BUILD"

cd "$GLIBC_BUILD"

echo "slibdir=${PATH_LIB}" > configparms
echo "rtlddir=${PATH_LIB}" >> configparms
echo "sbindir=${PATH_BIN}" >> configparms
echo "rootsbindir=${PATH_BIN}" >> configparms

echo "==> Configuring glibc for AArch64"

export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export AR=aarch64-linux-gnu-gcc-ar
export RANLIB=aarch64-linux-gnu-gcc-ranlib
export NM=aarch64-linux-gnu-gcc-nm
export LD=aarch64-linux-gnu-ld
export AS=aarch64-linux-gnu-as
export OBJCOPY=aarch64-linux-gnu-objcopy
export OBJDUMP=aarch64-linux-gnu-objdump
export READELF=aarch64-linux-gnu-readelf
export STRIP=aarch64-linux-gnu-strip

CFLAGS="${CFLAGS:-}"
CXXFLAGS="${CXXFLAGS:-}"

CFLAGS="${CFLAGS/-Wp,-D_FORTIFY_SOURCE=2 / }"
CFLAGS="${CFLAGS/-Werror / }"

export CFLAGS
export CXXFLAGS

echo "CC=$CC"
echo "CFLAGS=$CFLAGS"

echo "==> Running glibc configure"

CONFIGURE_FLAGS=(
--prefix="$PATH_PREFIX"
--libdir="$PATH_LIB"
--libexecdir="$PATH_LIB"
--includedir="$PATH_INCLUDE"
--host="$HOST_TRIPLET"
--build="$BUILD_TRIPLET"
--target="$HOST_TRIPLET"
--with-bugurl=https://github.com/termux-pacman/glibc-packages/issues
--with-pkgversion="GNU libc for Android"
--enable-bind-now
--enable-fortify-source
--disable-multi-arch
--enable-stack-protector=strong
--enable-systemtap
--disable-nscd
--disable-profile
--disable-werror
--disable-default-pie
--enable-memory-tagging
)

"$GLIBC_SRC/configure" 
"${CONFIGURE_FLAGS[@]}"

echo "==> Building glibc"

make -O

echo "==> Installing glibc"

make install

echo "==> Removing unwanted files"

rm -f 
"$ROOTFS/usr/etc/ld.so.cache" 
"$ROOTFS/usr/bin/tzselect" 
"$ROOTFS/usr/bin/zdump" 
"$ROOTFS/usr/bin/zic"

echo "==> Installing tmpfiles configuration"

install -dm755 
"$PATH_LIB/tmpfiles.d"

install -m644 
"$GLIBC_SRC/nscd/nscd.conf" 
"$ROOTFS/usr/etc/nscd.conf"

install -m644 
"$GLIBC_SRC/nscd/nscd.tmpfiles" 
"$PATH_LIB/tmpfiles.d/nscd.conf"

install -m644 
"$GLIBC_SRC/posix/gai.conf" 
"$ROOTFS/usr/etc/gai.conf"

echo "==> Installing locale-gen"

install -m755 
"$GLIBC_BUILDER_DIR/locale-gen" 
"$PATH_BIN"

echo "==> Installing locale.gen"

install -m644 
"$GLIBC_BUILDER_DIR/locale.gen.txt" 
"$ROOTFS/usr/etc/locale.gen"

sed 
-e '1,3d' 
-e 's|/| |g' 
-e 's|\| |g' 
-e 's|^|#|g' 
"$GLIBC_SRC/localedata/SUPPORTED" 
>> "$ROOTFS/usr/etc/locale.gen"

echo "==> Installing SUPPORTED"

sed 
-e '1,3d' 
-e 's|/| |g' 
-e 's| \||g' 
"$GLIBC_SRC/localedata/SUPPORTED" 
> "$ROOTFS/usr/share/i18n/SUPPORTED"

install -dm755 
"$PATH_LIB/locale"

echo "==> Installing locale files"

make 
-C "$GLIBC_SRC/localedata" 
objdir="$GLIBC_BUILD" 
SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" 
install-locale-files

sed -i 
'/#C.UTF-8 /d' 
"$ROOTFS/usr/etc/locale.gen"

echo "==> Installing SystemTap headers"

install -Dm644 
"$GLIBC_BUILDER_DIR/sdt.h" 
"$PATH_INCLUDE/sys/sdt.h"

install -Dm644 
"$GLIBC_BUILDER_DIR/sdt-config.h" 
"$PATH_INCLUDE/sys/sdt-config.h"

echo "==> Creating dynamic linker symlinks"

ln -sfr 
"$PATH_DYNAMIC_LINKER" 
"$PATH_BIN/ld.so"

ln -sfr 
"$PATH_DYNAMIC_LINKER" 
"$PATH_LIB/ld.so"

echo "==> Building libsyscall_without_fsc.so"

"$CC" 
"$GLIBC_BUILDER_DIR/syscall.c" 
-o "$PATH_LIB/libsyscall_without_fsc.so" 
-shared 
-DWITHOUT_FAKESYSCALL

echo "DONE"

echo "==> Verifying generated binaries"

file 
"$PATH_LIB/libc.so.6"

file 
"$PATH_DYNAMIC_LINKER"

file 
"$PATH_LIB/libsyscall_without_fsc.so"

echo "==> Checking ELF architecture"

readelf -h 
"$PATH_LIB/libc.so.6" 
| grep -E 'Class|Machine'

readelf -h 
"$PATH_DYNAMIC_LINKER" 
| grep -E 'Class|Machine'

readelf -h 
"$PATH_LIB/libsyscall_without_fsc.so" 
| grep -E 'Class|Machine'

echo "==> Creating rootfs archive"

cd /data/data/com.wingo/files

tar -cJf 
"$GLIBC_ROOTFS_ARCHIVE" 
rootfs

echo
echo "=========================================="
echo "GLIBC BUILD COMPLETED"
echo "=========================================="
echo
echo "Rootfs:"
echo "$ROOTFS"
echo
echo "Archive:"
echo "$GLIBC_ROOTFS_ARCHIVE"
echo
echo "Architecture:"
file 
"$PATH_LIB/libc.so.6"
