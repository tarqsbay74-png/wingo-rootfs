#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GLIBC_DIR="$REPO_DIR/packages/glibc"
BUILD_DIR="$REPO_DIR/build"
SRC_ARCHIVE="$BUILD_DIR/glibc-2.44.tar.xz"
SRC_DIR="$BUILD_DIR/glibc-2.44"
PREFIX="/usr"

mkdir -p "$BUILD_DIR"

echo "==> Downloading glibc 2.44"

curl -L \
    "https://ftp.gnu.org/gnu/glibc/glibc-2.44.tar.xz" \
    -o "$SRC_ARCHIVE"

echo "==> Verifying source"

echo "37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667  $SRC_ARCHIVE" \
    | sha256sum -c -

echo "==> Extracting source"

rm -rf "$SRC_DIR"

tar -xf "$SRC_ARCHIVE" -C "$BUILD_DIR"

cd "$SRC_DIR"

echo "==> Applying patches immediately after extraction"

if compgen -G "$GLIBC_DIR/*.patch" > /dev/null; then
    for patch_file in "$GLIBC_DIR"/*.patch; do
        echo "Applying $(basename "$patch_file")"
        patch -p1 < "$patch_file"
    done
fi

echo "==> Installing Android-specific source files"

rm -f sysdeps/unix/sysv/linux/*/clone3.S
rm -f sysdeps/unix/sysv/linux/x86_64/configure*

cp "$GLIBC_DIR"/shm{at,ctl,dt,get}.c \
   "$GLIBC_DIR"/mprotect.c \
   "$GLIBC_DIR"/syscall.c \
   "$GLIBC_DIR"/fakesyscall*.h \
   "$GLIBC_DIR"/fake_epoll_pwait2.c \
   "$GLIBC_DIR"/setfs{u,g}id.c \
   sysdeps/unix/sysv/linux/

cp "$GLIBC_DIR"/android_passwd_group.* \
   "$GLIBC_DIR"/android_system_user_ids.h \
   nss/

bash "$GLIBC_DIR/gen-android-ids.sh" \
    "$REPO_DIR" \
    nss/android_ids.h \
    "$GLIBC_DIR/android_system_user_ids.h"

cp "$GLIBC_DIR/syslog.c" misc/

cp "$GLIBC_DIR"/shmem-android.* sysvipc/

for arch in aarch64 arm i386 x86_64/64; do
    linux_arch="${arch%%/*}"

    mv \
        "sysdeps/unix/sysv/linux/$linux_arch/syscall.S" \
        "sysdeps/unix/sysv/linux/$linux_arch/syscallS.S"

    disabled_header="sysdeps/unix/sysv/linux/$arch/disabled-syscall.h"

    {
        for syscall_name in $(jq -r '.[] | .[]' "$GLIBC_DIR/fakesyscall.json"); do
            grep \
                "#define __NR_${syscall_name} " \
                "sysdeps/unix/sysv/linux/$arch/arch-syscall.h" \
                || true

            sed -i \
                "/#define __NR_${syscall_name} /d" \
                "sysdeps/unix/sysv/linux/$arch/arch-syscall.h"
        done
    } >> "$disabled_header"

    {
        echo -e "\n#define DISABLED_SYSCALL_WITH_FAKESYSCALL \\"

        IFS=$'\n'

        for fake_syscall in $(jq -r '. | keys | .[]' "$GLIBC_DIR/fakesyscall.json"); do
            need_return=false

            for syscall_name in $(jq -r '."'${fake_syscall}'" | .[]' "$GLIBC_DIR/fakesyscall.json"); do
                if grep -q \
                    "^#define __NR_${syscall_name} " \
                    "$disabled_header"; then

                    echo -e "\tcase __NR_${syscall_name}: \\"
                    need_return=true

                elif [[ "$syscall_name" =~ ^[0-9]+$ ]]; then

                    echo -e "\tcase ${syscall_name}: \\"
                    need_return=true
                fi
            done

            if [ "$need_return" = "true" ]; then
                echo -e "\t\treturn ${fake_syscall}; \\"
            fi
        done

        unset IFS
    } >> "$disabled_header"

    sed -i '$ s| \\||' "$disabled_header"
done

echo "==> Replacing Android paths"

for replacement in \
    "/dev/stderr:/proc/self/fd/2" \
    "/dev/stdin:/proc/self/fd/0" \
    "/dev/stdout:/proc/self/fd/1"
do
    old_path="${replacement%%:*}"
    new_path="${replacement#*:}"

    while IFS= read -r file; do
        sed -i "s|${old_path}|${new_path}|g" "$file"
    done < <(grep -s -r -l "$old_path" "$SRC_DIR" || true)
done

echo "==> Creating build directory"

rm -rf "$BUILD_DIR/build"
mkdir -p "$BUILD_DIR/build"

cd "$BUILD_DIR/build"

echo "==> Configuring glibc"

"$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib \
    --libexecdir=/usr/lib \
    --includedir=/usr/include \
    --host=aarch64-linux-gnu \
    --build=x86_64-linux-gnu \
    --target=aarch64-linux-gnu \
    --enable-bind-now \
    --enable-fortify-source \
    --disable-multi-arch \
    --enable-stack-protector=strong \
    --disable-nscd \
    --disable-profile \
    --disable-werror \
    --disable-default-pie

echo "==> Building glibc"

make -j"$(nproc)"

echo "==> Installing glibc"

make install DESTDIR="$BUILD_DIR/root"

echo "==> Installing additional syscall library"

gcc \
    "$GLIBC_DIR/syscall.c" \
    -o "$BUILD_DIR/root/usr/lib/libsyscall_without_fsc.so" \
    -shared \
    -DWITHOUT_FAKESYSCALL

echo "==> Creating runtime linker symlinks"

mkdir -p "$BUILD_DIR/root/usr/bin"
mkdir -p "$BUILD_DIR/root/usr/lib"

if [ "$(uname -m)" = "aarch64" ]; then
    DYNAMIC_LINKER="ld-linux-aarch64.so.1"
elif [ "$(uname -m)" = "x86_64" ]; then
    DYNAMIC_LINKER="ld-linux-x86-64.so.2"
elif [ "$(uname -m)" = "armv7l" ]; then
    DYNAMIC_LINKER="ld-linux-armhf.so.3"
else
    DYNAMIC_LINKER="ld-linux.so.2"
fi

ln -sf \
    "/usr/lib/$DYNAMIC_LINKER" \
    "$BUILD_DIR/root/usr/bin/ld.so"

ln -sf \
    "/usr/lib/$DYNAMIC_LINKER" \
    "$BUILD_DIR/root/usr/lib/ld.so"

echo "==> Creating tarball"

cd "$BUILD_DIR/root"

tar -cJf "$REPO_DIR/glibc-2.44-rootfs.tar.xz" .

echo "==> Done"

echo "$REPO_DIR/glibc-2.44-rootfs.tar.xz"
