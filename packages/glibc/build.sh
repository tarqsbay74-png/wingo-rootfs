#!/usr/bin/env bash
set -euo pipefail

mkdir -p /build

echo "==> Installing build dependencies"

apt-get update

apt-get install -y 
build-essential 
gcc 
g++ 
binutils 
gcc-aarch64-linux-gnu 
g++-aarch64-linux-gnu 
binutils-aarch64-linux-gnu 
libc6-dev-arm64-cross 
linux-libc-dev 
make 
file 
git 
wget 
curl 
xz-utils 
bzip2 
tar 
patch 
sed 
gawk 
perl 
python3 
jq 
gettext 
texinfo 
bison 
flex 
libgmp-dev 
libmpfr-dev 
libmpc-dev

echo "==> Checking AArch64 compiler"

command -v aarch64-linux-gnu-gcc
command -v aarch64-linux-gnu-g++
command -v aarch64-linux-gnu-ld

echo "Compiler target:"
aarch64-linux-gnu-gcc -dumpmachine

echo "==> Checking AArch64 sysroot"

aarch64-linux-gnu-gcc -print-sysroot

echo "==> Checking AArch64 headers"

if [ ! -d /usr/aarch64-linux-gnu/include ]; then
echo "ERROR: /usr/aarch64-linux-gnu/include does not exist"
exit 1
fi

echo "AArch64 headers:"
ls -ld /usr/aarch64-linux-gnu/include

echo "==> Cleaning previous build"

rm -rf /build/glibc-2.44
rm -rf /build/glibc-build
rm -rf /data/data/com.wingo/files/rootfs
rm -f /build/glibc-2.44.tar.xz

echo "==> Downloading glibc 2.44"

wget 
"https://ftp.gnu.org/gnu/glibc/glibc-2.44.tar.xz" 
-O /build/glibc-2.44.tar.xz

echo "==> Verifying checksum"

echo "37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667  /build/glibc-2.44.tar.xz" 
| sha256sum -c -

echo "==> Extracting glibc"

tar -xf 
/build/glibc-2.44.tar.xz 
-C /build

echo "==> Applying patches"

cd /build/glibc-2.44

for patch_file in /workspace/packages/glibc/*.patch; do
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

cp 
/workspace/packages/glibc/shm{at,ctl,dt,get}.c 
/workspace/packages/glibc/mprotect.c 
/workspace/packages/glibc/syscall.c 
/workspace/packages/glibc/fakesyscall*.h 
/workspace/packages/glibc/fake_epoll_pwait2.c 
/workspace/packages/glibc/setfs{u,g}id.c 
sysdeps/unix/sysv/linux/

echo "==> Installing Android passwd/group handling"

cp 
/workspace/packages/glibc/android_passwd_group.* 
/workspace/packages/glibc/android_system_user_ids.h 
nss/

bash 
/workspace/packages/glibc/gen-android-ids.sh 
/build 
/build/glibc-2.44/nss/android_ids.h 
/workspace/packages/glibc/android_system_user_ids.h

echo "==> Installing Android-compatible syslog implementation"

cp 
/workspace/packages/glibc/syslog.c 
misc/

echo "==> Installing System V shared memory emulation"

cp 
/workspace/packages/glibc/shmem-android.* 
sysvipc/

echo "==> Disabling unsupported syscalls"

for i in aarch64; do

mv \
    "sysdeps/unix/sysv/linux/${i}/syscall.S" \
    "sysdeps/unix/sysv/linux/${i}/syscallS.S"

header_disabled_syscall="sysdeps/unix/sysv/linux/${i}/disabled-syscall.h"

{
    for j in $(jq -r '.[] | .[]' \
        /workspace/packages/glibc/fakesyscall.json); do

        grep \
            "#define __NR_${j} " \
            "sysdeps/unix/sysv/linux/${i}/arch-syscall.h" \
            || true

        sed -i \
            "/#define __NR_${j} /d" \
            "sysdeps/unix/sysv/linux/${i}/arch-syscall.h"

    done
} >> "$header_disabled_syscall"

{
    echo -e "\n#define DISABLED_SYSCALL_WITH_FAKESYSCALL \\"

    while IFS= read -r j; do

        need_return=false

        # IMPORTANT:
        # Do not construct a jq expression using "$j".
        # fakesyscall keys contain characters such as:
        # accept4(a0, ...)
        #
        # Use --arg + .[$key] instead.

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
            jq -r \
                --arg key "$j" \
                '.[$key][]' \
                /workspace/packages/glibc/fakesyscall.json
        )

        if [ "$need_return" = "true" ]; then
            echo -e "\t\treturn ${j}; \\"
        fi

    done < <(
        jq -r \
            '. | keys | .[]' \
            /workspace/packages/glibc/fakesyscall.json
    )

} >> "$header_disabled_syscall"

sed -i \
    '$ s| \\||' \
    "$header_disabled_syscall"

done

echo "==> Replacing hard paths that may not exist on Android"

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
    grep -s -r -l "${i%%:*}" .
)

done

echo "==> Android modifications completed"

echo "==> Preparing build directory"

mkdir -p /build/glibc-build

cd /build/glibc-build

echo "slibdir=/data/data/com.wingo/files/rootfs/usr/lib" > configparms
echo "rtlddir=/data/data/com.wingo/files/rootfs/usr/lib" >> configparms
echo "sbindir=/data/data/com.wingo/files/rootfs/usr/bin" >> configparms
echo "rootsbindir=/data/data/com.wingo/files/rootfs/usr/bin" >> configparms

echo "==> Configuring glibc for AArch64"

export BUILD_CC=gcc

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

export CFLAGS="-O2 -pipe -fno-plt -fexceptions 
-Wp,-D_FORTIFY_SOURCE=2 
-Wformat 
-Werror=format-security 
-fstack-clash-protection 
-fmarch=armv8-a 
-fstack-protector-strong"

export CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"

echo "BUILD_CC=$BUILD_CC"
echo "CC=$CC"
echo "CXX=$CXX"

echo "==> Testing AArch64 compiler"

cat > /build/test-aarch64.c <<'EOF'
int main(void)
{
return 0;
}
EOF

aarch64-linux-gnu-gcc 
-march=armv8-a 
-c 
/build/test-aarch64.c 
-o /build/test-aarch64.o

file /build/test-aarch64.o

rm -f 
/build/test-aarch64.c 
/build/test-aarch64.o

echo "==> Running glibc configure"

../glibc-2.44/configure 
CC="$CC" 
BUILD_CC="$BUILD_CC" 
AR="$AR" 
RANLIB="$RANLIB" 
NM="$NM" 
LD="$LD" 
AS="$AS" 
OBJCOPY="$OBJCOPY" 
OBJDUMP="$OBJDUMP" 
READELF="$READELF" 
--prefix=/data/data/com.wingo/files/rootfs/usr 
--libdir=/data/data/com.wingo/files/rootfs/usr/lib 
--libexecdir=/data/data/com.wingo/files/rootfs/usr/lib 
--includedir=/data/data/com.wingo/files/rootfs/usr/include 
--host=aarch64-linux-gnu 
--build=x86_64-linux-gnu 
--target=aarch64-linux-gnu 
--with-headers=/usr/aarch64-linux-gnu/include 
--with-bugurl=https://github.com/termux-pacman/glibc-packages/issues 
--with-pkgversion="GNU libc for Android" 
--enable-bind-now 
--enable-fortify-source 
--disable-multi-arch 
--enable-memory-tagging 
--enable-stack-protector=strong 
--enable-systemtap 
--disable-nscd 
--disable-profile 
--disable-werror 
--disable-default-pie

echo "==> Building glibc"

make -O

echo "==> Creating rootfs"

mkdir -p /data/data/com.wingo/files/rootfs

echo "==> Installing glibc"

make install

echo "==> Removing unwanted files"

rm -f 
/data/data/com.wingo/files/rootfs/usr/etc/ld.so.cache 
/data/data/com.wingo/files/rootfs/usr/bin/tzselect 
/data/data/com.wingo/files/rootfs/usr/bin/zdump 
/data/data/com.wingo/files/rootfs/usr/bin/zic

echo "==> Installing tmpfiles configuration"

install -dm755 
/data/data/com.wingo/files/rootfs/usr/lib/tmpfiles.d

install -m644 
/build/glibc-2.44/nscd/nscd.conf 
/data/data/com.wingo/files/rootfs/usr/etc/nscd.conf

install -m644 
/build/glibc-2.44/nscd/nscd.tmpfiles 
/data/data/com.wingo/files/rootfs/usr/lib/tmpfiles.d/nscd.conf

echo "==> Installing gai.conf"

install -m644 
/build/glibc-2.44/posix/gai.conf 
/data/data/com.wingo/files/rootfs/usr/etc/gai.conf

echo "==> Installing locale-gen"

install -m755 
/workspace/packages/glibc/locale-gen 
/data/data/com.wingo/files/rootfs/usr/bin/locale-gen

echo "==> Installing locale.gen"

install -m644 
/workspace/packages/glibc/locale.gen.txt 
/data/data/com.wingo/files/rootfs/usr/etc/locale.gen

sed 
-e '1,3d' 
-e 's|/| |g' 
-e 's|\| |g' 
-e 's|^|#|g' 
/build/glibc-2.44/localedata/SUPPORTED 
>> /data/data/com.wingo/files/rootfs/usr/etc/locale.gen

echo "==> Installing SUPPORTED"

sed 
-e '1,3d' 
-e 's|/| |g' 
-e 's| \||g' 
/build/glibc-2.44/localedata/SUPPORTED 
> /data/data/com.wingo/files/rootfs/usr/share/i18n/SUPPORTED

install -dm755 
/data/data/com.wingo/files/rootfs/usr/lib/locale

echo "==> Installing locale files"

make 
-C /build/glibc-2.44/localedata 
objdir=/build/glibc-build 
SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" 
DESTDIR=/data/data/com.wingo/files/rootfs 
install-locale-files

sed -i 
'/#C.UTF-8 /d' 
/data/data/com.wingo/files/rootfs/usr/etc/locale.gen

echo "==> Installing SystemTap headers"

install -Dm644 
/workspace/packages/glibc/sdt.h 
/data/data/com.wingo/files/rootfs/usr/include/sys/sdt.h

install -Dm644 
/workspace/packages/glibc/sdt-config.h 
/data/data/com.wingo/files/rootfs/usr/include/sys/sdt-config.h

echo "==> Creating dynamic linker symlinks"

ln -sfr 
/data/data/com.wingo/files/rootfs/usr/lib/ld-linux-aarch64.so.1 
/data/data/com.wingo/files/rootfs/usr/bin/ld.so

ln -sfr 
/data/data/com.wingo/files/rootfs/usr/lib/ld-linux-aarch64.so.1 
/data/data/com.wingo/files/rootfs/usr/lib/ld.so

echo "==> Building libsyscall_without_fsc.so"

aarch64-linux-gnu-gcc 
/workspace/packages/glibc/syscall.c 
-o /data/data/com.wingo/files/rootfs/usr/lib/libsyscall_without_fsc.so 
-shared 
-DWITHOUT_FAKESYSCALL

echo "DONE"

echo "==> Verifying generated binaries"

file 
/data/data/com.wingo/files/rootfs/usr/lib/libc.so.6

file 
/data/data/com.wingo/files/rootfs/usr/lib/ld-linux-aarch64.so.1

file 
/data/data/com.wingo/files/rootfs/usr/lib/libsyscall_without_fsc.so

echo "==> Checking ELF architecture"

readelf -h 
/data/data/com.wingo/files/rootfs/usr/lib/libc.so.6 
| grep -E 'Class|Machine'

readelf -h 
/data/data/com.wingo/files/rootfs/usr/lib/ld-linux-aarch64.so.1 
| grep -E 'Class|Machine'

echo "==> Creating rootfs archive"

cd /data/data/com.wingo/files

tar -cJf 
/build/glibc-2.44-rootfs.tar.xz 
rootfs

echo
echo "=========================================="
echo "GLIBC BUILD COMPLETED"
echo "=========================================="
echo
echo "Rootfs:"
echo "/data/data/com.wingo/files/rootfs"
echo
echo "Archive:"
echo "/build/glibc-2.44-rootfs.tar.xz"
echo
echo "Architecture:"

file 
/data/data/com.wingo/files/rootfs/usr/lib/libc.so.6
