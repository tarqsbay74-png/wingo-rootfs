
#!/usr/bin/bash

set -e

PKG_VERSION=2.44
PKG_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
PKG_SHA256="37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667"

SRC="${GITHUB_WORKSPACE}/packages/glibc/glibc-${PKG_VERSION}"
BUILD="${GITHUB_WORKSPACE}/packages/glibc/build"
ROOTFS="${GITHUB_WORKSPACE}/packages/glibc/rootfs"

PREFIX="/usr"
LIBDIR="/usr/lib"
HOST="aarch64-linux-gnu"

GLIBC_TARBALL="${GITHUB_WORKSPACE}/packages/glibc/glibc-${PKG_VERSION}.tar.xz"
PACKAGE_DIR="${GITHUB_WORKSPACE}/packages/glibc"

mkdir -p \
    "$PACKAGE_DIR" \
    "$BUILD" \
    "$ROOTFS"

rm -rf "$BUILD"/*
rm -rf "$ROOTFS"/*

# Download and extract source.

if [ ! -d "$SRC" ]; then
    curl -L \
        "$PKG_URL" \
        -o "$GLIBC_TARBALL"

    echo "${PKG_SHA256}  ${GLIBC_TARBALL}" | sha256sum -c -

    tar -xf \
        "$GLIBC_TARBALL" \
        -C "$PACKAGE_DIR"
fi

# Apply patches.

cd "$SRC"

shopt -s nullglob

PATCHES=(
    "$PACKAGE_DIR"/*.patch
    "$PACKAGE_DIR"/*.patch64
)

IFS=$'\n'
PATCHES=( $(printf '%s\n' "${PATCHES[@]}" | sort) )
unset IFS

for patch_file in "${PATCHES[@]}"; do
    echo "Applying patch: $(basename "$patch_file")"
    patch --silent -p1 < "$patch_file"
done

shopt -u nullglob

# Generate android_ids.h.

bash \
    "$PACKAGE_DIR/gen-android-ids.sh" \
    "$SRC/nss/android_ids.h" \
    "$PACKAGE_DIR/android_system_user_ids.h"

# GNU glibc AArch64 modifications.

rm -f "$SRC/sysdeps/unix/sysv/linux/"*/clone3.S
rm -f "$SRC/sysdeps/unix/sysv/linux/x86_64/configure"*

cp \
    "$PACKAGE_DIR"/{shm{at,ctl,dt,get}.c,mprotect.c,syscall.c,fakesyscall*.h,fake_epoll_pwait2.c,setfs{u,g}id.c} \
    "$SRC/sysdeps/unix/sysv/linux/"

cp \
    "$PACKAGE_DIR"/{android_passwd_group.*,android_system_user_ids.h} \
    "$SRC/nss/"

cp \
    "$PACKAGE_DIR/syslog.c" \
    "$SRC/misc/"

cp \
    "$PACKAGE_DIR"/shmem-android.* \
    "$SRC/sysvipc/"

mv \
    "$SRC/sysdeps/unix/sysv/linux/aarch64/syscall.S" \
    "$SRC/sysdeps/unix/sysv/linux/aarch64/syscallS.S"

HEADER="$SRC/sysdeps/unix/sysv/linux/aarch64/disabled-syscall.h"

{
    for syscall in $(jq -r '.[] | .[]' "$PACKAGE_DIR/fakesyscall.json"); do

        grep \
            "#define __NR_${syscall} " \
            "$SRC/sysdeps/unix/sysv/linux/aarch64/arch-syscall.h" \
            || true

        sed -i \
            "/#define __NR_${syscall} /d" \
            "$SRC/sysdeps/unix/sysv/linux/aarch64/arch-syscall.h"
    done
} >> "$HEADER"

{
    echo
    echo '#define DISABLED_SYSCALL_WITH_FAKESYSCALL \'

    IFS=$'\n'

    for function in $(jq -r '. | keys | .[]' "$PACKAGE_DIR/fakesyscall.json"); do

        need_return=false

        for syscall in $(jq -r '."'${function}'" | .[]' "$PACKAGE_DIR/fakesyscall.json"); do

            if grep -q \
                "^#define __NR_${syscall} " \
                "$HEADER"; then

                echo -e "\tcase __NR_${syscall}: \\"
                need_return=true

            elif [[ "$syscall" =~ ^[0-9]+$ ]]; then

                echo -e "\tcase ${syscall}: \\"
                need_return=true
            fi
        done

        [ "$need_return" = true ] &&
            echo -e "\t\treturn ${function}; \\"
    done

    unset IFS
} >> "$HEADER"

sed -i '$ s| \\||' "$HEADER"

# Replace hard paths.

for path in \
    /dev/stderr:/proc/self/fd/2 \
    /dev/stdin:/proc/self/fd/0 \
    /dev/stdout:/proc/self/fd/1; do

    while IFS= read -r file; do
        sed -i \
            "s|${path%%:*}|${path//*:}|g" \
            "$file"
    done < <(
        grep -s -r -l "${path%%:*}" "$SRC" || true
    )
done

# Configure.

cd "$BUILD"

echo "slibdir=${LIBDIR}" > configparms
echo "rtlddir=${LIBDIR}" >> configparms
echo "sbindir=${PREFIX}/bin" >> configparms
echo "rootsbindir=${PREFIX}/bin" >> configparms

CFLAGS="${CFLAGS/-Wp,-D_FORTIFY_SOURCE=2 / }"
CFLAGS="${CFLAGS/-Werror / }"

export CFLAGS

"$SRC/configure" \
    --prefix="$PREFIX" \
    --libdir="$LIBDIR" \
    --libexecdir="$LIBDIR" \
    --includedir="${PREFIX}/include" \
    --host="$HOST" \
    --build="$(gcc -dumpmachine)" \
    --target="$HOST" \
    --with-bugurl="https://www.gnu.org/software/libc/" \
    --with-pkgversion="GNU libc AArch64" \
    --enable-shared \
    --enable-bind-now \
    --enable-stack-protector=strong \
    --enable-fortify-source \
    --disable-multi-arch \
    --disable-systemtap \
    --disable-build-nscd \
    --disable-nscd \
    --disable-profile \
    --disable-default-pie \
    --disable-timezone-tools \
    --disable-pt_chown \
    --disable-sframe \
    --disable-werror

# Build.

make -O

# Install.

rm -rf "$ROOTFS"

mkdir -p "$ROOTFS"

STAGE="$BUILD/glibc-stage"

rm -rf "$STAGE"
mkdir -p "$STAGE"

make \
    DESTDIR="$STAGE" \
    elf/ldso_install \
    install-lib

cp \
    "$BUILD/libc.so" \
    "$STAGE/usr/lib/libc.so.6"

mkdir -p "$ROOTFS/usr/lib"

cp -r \
    "$STAGE/usr/lib/"* \
    "$ROOTFS/usr/lib/"

make \
    DESTDIR="$ROOTFS" \
    install

rm -f "$ROOTFS/etc/ld.so.cache"

rm -f \
    "$ROOTFS/usr/bin/tzselect" \
    "$ROOTFS/usr/bin/zdump" \
    "$ROOTFS/usr/bin/zic"

mkdir -p "$ROOTFS/usr/lib/locale"

make \
    -C "$SRC/localedata" \
    objdir="$BUILD" \
    SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" \
    DESTDIR="$ROOTFS" \
    install-locale-files

sed -i \
    '/#C\.UTF-8 /d' \
    "$ROOTFS/etc/locale.gen"

# Build syscall library.

echo "Compiling libsyscall_without_fsc.so..."

"$CC" \
    "$PACKAGE_DIR/syscall.c" \
    -o "$ROOTFS/usr/lib/libsyscall_without_fsc.so" \
    -shared \
    -DWITHOUT_FAKESYSCALL

echo "DONE"

# Compress rootfs.

ROOTFS_ARCHIVE="${PACKAGE_DIR}/glibc-${PKG_VERSION}-aarch64-rootfs.tar.xz"

rm -f "$ROOTFS_ARCHIVE"

tar -cJf \
    "$ROOTFS_ARCHIVE" \
    -C "$ROOTFS" \
    .

echo
echo "=========================================="
echo "glibc AArch64 build completed"
echo "=========================================="
echo
echo "Rootfs : $ROOTFS"
echo "Archive: $ROOTFS_ARCHIVE"