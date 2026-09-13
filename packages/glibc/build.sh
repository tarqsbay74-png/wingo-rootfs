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