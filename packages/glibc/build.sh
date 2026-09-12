#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=/build
ROOTFS=/data/data/com.wingo/files/rootfs
GLIBC_VERSION=2.44
GLIBC_SRC="${BUILD_DIR}/glibc-${GLIBC_VERSION}"
GLIBC_BUILD="${BUILD_DIR}/glibc-build"
GLIBC_TARBALL="${BUILD_DIR}/glibc-${GLIBC_VERSION}.tar.xz"
GLIBC_ROOTFS_ARCHIVE="${BUILD_DIR}/glibc-${GLIBC_VERSION}-rootfs.tar.xz"
GLIBC_BUILDER_DIR=/workspace/packages/glibc

mkdir -p "$BUILD_DIR"

echo "==> Installing build dependencies"

apt-get update

apt-get install -y \
    build-essential \
    gcc \
    g++ \
    binutils \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    libc6-dev-arm64-cross \
    make \
    file \
    git \
    wget \
    curl \
    xz-utils \
    bzip2 \
    tar \
    patch \
    sed \
    gawk \
    perl \
    python3 \
    jq \
    gettext \
    texinfo \
    bison \
    flex \
    libgmp-dev \
    libmpfr-dev \
    libmpc-dev \
    linux-libc-dev

echo "==> Checking AArch64 compiler"

command -v aarch64-linux-gnu-gcc
command -v aarch64-linux-gnu-g++
command -v aarch64-linux-gnu-ld

echo "Compiler target:"
aarch64-linux-gnu-gcc -dumpmachine

echo "==> Cleaning previous build"

rm -rf "$GLIBC_SRC"
rm -rf "$GLIBC_BUILD"
rm -rf "$ROOTFS"
rm -f "$GLIBC_TARBALL"
rm -f "$GLIBC_ROOTFS_ARCHIVE"

echo "==> Downloading glibc ${GLIBC_VERSION}"

wget \
    "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VERSION}.tar.xz" \
    -O "$GLIBC_TARBALL"

echo "==> Verifying checksum"

echo "37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667  ${GLIBC_TARBALL}" \
    | sha256sum -c -

echo "==> Extracting glibc"

tar -xf "$GLIBC_TARBALL" -C "$BUILD_DIR"

echo "==> Applying patches"

cd "$GLIBC_SRC"

for patch_file in "$GLIBC_BUILDER_DIR"/*.patch; do
    if [ -f "$patch_file" ]; then
        echo "Applying: $patch_file"
        patch -p1 < "$patch_file"
    fi
done

echo "==> Applying Android modifications"

echo "==> Disabling clone3 function"

rm -f sysdeps/unix/sysv/linux/*/clone3.S

echo "==> Disabling editing of ldd script for x86_64"

rm -f sysdeps/unix/sysv/linux/x86_64/configure*

echo "==> Installing special syscall files"

cp \
    "$GLIBC_BUILDER_DIR"/shm{at,ctl,dt,get}.c \
    "$GLIBC_BUILDER_DIR"/mprotect.c \
    "$GLIBC_BUILDER_DIR"/syscall.c \
    "$GLIBC_BUILDER_DIR"/fakesyscall*.h \
    "$GLIBC_BUILDER_DIR"/fake_epoll_pwait2.c \
    "$GLIBC_BUILDER_DIR"/setfs{u,g}id.c \
    sysdeps/unix/sysv/linux/

echo "==> Installing Android passwd/group handling"

cp \
    "$GLIBC_BUILDER_DIR"/android_passwd_group.* \
    "$GLIBC_BUILDER_DIR"/android_system_user_ids.h \
    nss/

bash \
    "$GLIBC_BUILDER_DIR/gen-android-ids.sh" \
    "$BUILD_DIR" \
    "$GLIBC_SRC/nss/android_ids.h" \
    "$GLIBC_BUILDER_DIR/android_system_user_ids.h"

echo "==> Installing Android-compatible syslog"

cp \
    "$GLIBC_BUILDER_DIR/syslog.c" \
    misc/

echo "==> Installing System V shared memory emulation"

cp \
    "$GLIBC_BUILDER_DIR"/shmem-android.* \
    sysvipc/

echo "==> Disabling unsupported syscalls"

for i in aarch64; do

    syscall_dir="sysdeps/unix/sysv/linux/${i}"

    mv \
        "${syscall_dir}/syscall.S" \
        "${syscall_dir}/syscallS.S"

    header_disabled_syscall="${syscall_dir}/disabled-syscall.h"

    : > "$header_disabled_syscall"

    {
        for j in $(jq -r '.[] | .[]' \
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
        echo
        echo '#define DISABLED_SYSCALL_WITH_FAKESYSCALL \'

        while IFS= read -r j; do

            need_return=false

            while IFS= read -r z; do

                if grep -q \
                    "^#define __NR_${z} " \
                    "$header_disabled_syscall"
                then
                    echo -e "\tcase __NR_${z}: \\"
                    need_return=true

                elif [[ "$z" =~ ^[0-9]+$ ]]; then
                    echo -e "\tcase ${z}: \\"
                    need_return=true
                fi

            done < <(
                jq -r --arg key "$j" \
                    '.[$key][]' \
                    "$GLIBC_BUILDER_DIR/fakesyscall.json"
            )

            if [ "$need_return" = "true" ]; then
                echo -e "\t\treturn ${j}; \\"
            fi

        done < <(
            jq -r \
                '. | keys | .[]' \
                "$GLIBC_BUILDER_DIR/fakesyscall.json"
        )

    } >> "$header_disabled_syscall"

    sed -i '$ s| \\||' "$header_disabled_syscall"

done

echo "==> Replacing Android-incompatible hard paths"

for i in \
    /dev/stderr:/proc/self/fd/2 \
    /dev/stdin:/proc/self/fd/0 \
    /dev/stdout:/proc/self/fd/1
do

    old_path="${i%%:*}"
    new_path="${i#*:}"

    while IFS= read -r j; do
        sed -i "s|${old_path}|${new_path}|g" "$j"
    done < <(
        grep -s -r -l "$old_path" .
    )

done

echo "==> Android modifications completed"

echo "==> Preparing build directory"

mkdir -p "$GLIBC_BUILD"

cd "$GLIBC_BUILD"

cat > configparms <<EOF
slibdir=${ROOTFS}/usr/lib
rtlddir=${ROOTFS}/usr/lib
sbindir=${ROOTFS}/usr/bin
rootsbindir=${ROOTFS}/usr/bin
EOF

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

export CFLAGS="-O2 -pipe -fno-plt -fexceptions \
-Wp,-D_FORTIFY_SOURCE=2 \
-Wformat \
-Werror=format-security \
-fstack-clash-protection \
-fmarch=armv8-a \
-fstack-protector-strong"

export CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"

echo "CC=$CC"
echo "CFLAGS=$CFLAGS"

echo "==> Testing cross compiler"

cat > "$GLIBC_BUILD/test.c" <<'EOF'
int main(void)
{
    return 0;
}
EOF

"$CC" "$GLIBC_BUILD/test.c" -o "$GLIBC_BUILD/test"

file "$GLIBC_BUILD/test"

rm -f \
    "$GLIBC_BUILD/test.c" \
    "$GLIBC_BUILD/test"

echo "==> Running glibc configure"

"$GLIBC_SRC/configure" \
    --prefix="${ROOTFS}/usr" \
    --libdir="${ROOTFS}/usr/lib" \
    --libexecdir="${ROOTFS}/usr/lib" \
    --includedir="${ROOTFS}/usr/include" \
    --host=aarch64-linux-gnu \
    --build=x86_64-linux-gnu \
    --target=aarch64-linux-gnu \
    --with-bugurl=https://github.com/termux-pacman/glibc-packages/issues \
    --with-pkgversion="GNU libc for Android" \
    --enable-bind-now \
    --enable-fortify-source \
    --disable-multi-arch \
    --enable-memory-tagging \
    --enable-stack-protector=strong \
    --enable-systemtap \
    --disable-nscd \
    --disable-profile \
    --disable-werror \
    --disable-default-pie

echo "==> Building glibc"

make -O

echo "==> Creating rootfs"

mkdir -p "$ROOTFS"

echo "==> Installing glibc"

make install

echo "==> Removing unwanted files"

rm -f \
    "$ROOTFS/usr/etc/ld.so.cache" \
    "$ROOTFS/usr/bin/tzselect" \
    "$ROOTFS/usr/bin/zdump" \
    "$ROOTFS/usr/bin/zic"

echo "==> Installing tmpfiles configuration"

install -dm755 \
    "$ROOTFS/usr/lib/tmpfiles.d"

install -m644 \
    "$GLIBC_SRC/nscd/nscd.conf" \
    "$ROOTFS/usr/etc/nscd.conf"

install -m644 \
    "$GLIBC_SRC/nscd/nscd.tmpfiles" \
    "$ROOTFS/usr/lib/tmpfiles.d/nscd.conf"

echo "==> Installing gai.conf"

install -m644 \
    "$GLIBC_SRC/posix/gai.conf" \
    "$ROOTFS/usr/etc/gai.conf"

echo "==> Installing locale-gen"

install -m755 \
    "$GLIBC_BUILDER_DIR/locale-gen" \
    "$ROOTFS/usr/bin/locale-gen"

echo "==> Installing locale.gen"

install -m644 \
    "$GLIBC_BUILDER_DIR/locale.gen.txt" \
    "$ROOTFS/usr/etc/locale.gen"

sed \
    -e '1,3d' \
    -e 's|/| |g' \
    -e 's|\\| |g' \
    -e 's|^|#|g' \
    "$GLIBC_SRC/localedata/SUPPORTED" \
    >> "$ROOTFS/usr/etc/locale.gen"

echo "==> Installing SUPPORTED"

sed \
    -e '1,3d' \
    -e 's|/| |g' \
    -e 's| \\||g' \
    "$GLIBC_SRC/localedata/SUPPORTED" \
    > "$ROOTFS/usr/share/i18n/SUPPORTED"

install -dm755 \
    "$ROOTFS/usr/lib/locale"

echo "==> Installing locale files"

make \
    -C "$GLIBC_SRC/localedata" \
    objdir="$GLIBC_BUILD" \
    SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" \
    DESTDIR="$ROOTFS" \
    install-locale-files

sed -i \
    '/#C\.UTF-8 /d' \
    "$ROOTFS/usr/etc/locale.gen"

echo "==> Installing SystemTap headers"

install -Dm644 \
    "$GLIBC_BUILDER_DIR/sdt.h" \
    "$ROOTFS/usr/include/sys/sdt.h"

install -Dm644 \
    "$GLIBC_BUILDER_DIR/sdt-config.h" \
    "$ROOTFS/usr/include/sys/sdt-config.h"

echo "==> Creating dynamic linker symlinks"

ln -sfr \
    "$ROOTFS/usr/lib/ld-linux-aarch64.so.1" \
    "$ROOTFS/usr/bin/ld.so"

ln -sfr \
    "$ROOTFS/usr/lib/ld-linux-aarch64.so.1" \
    "$ROOTFS/usr/lib/ld.so"

echo "==> Building libsyscall_without_fsc.so"

"$CC" \
    "$GLIBC_BUILDER_DIR/syscall.c" \
    -o "$ROOTFS/usr/lib/libsyscall_without_fsc.so" \
    -shared \
    -DWITHOUT_FAKESYSCALL

echo "DONE"

echo "==> Verifying generated binaries"

file \
    "$ROOTFS/usr/lib/libc.so.6"

file \
    "$ROOTFS/usr/lib/ld-linux-aarch64.so.1"

file \
    "$ROOTFS/usr/lib/libsyscall_without_fsc.so"

echo "==> Checking ELF architecture"

readelf -h \
    "$ROOTFS/usr/lib/libc.so.6" \
    | grep -E 'Class|Machine'

readelf -h \
    "$ROOTFS/usr/lib/ld-linux-aarch64.so.1" \
    | grep -E 'Class|Machine'

readelf -h \
    "$ROOTFS/usr/lib/libsyscall_without_fsc.so" \
    | grep -E 'Class|Machine'

echo "==> Creating rootfs archive"

cd /data/data/com.wingo/files

tar -cJf \
    "$GLIBC_ROOTFS_ARCHIVE" \
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
file \
    "$ROOTFS/usr/lib/libc.so.6"
