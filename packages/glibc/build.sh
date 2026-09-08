#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Wingo Glibc
###############################################################################

PACKAGE_NAME="glibc"
PACKAGE_VERSION="2.44"

SOURCE_URL="https://ftp.gnu.org/gnu/libc/glibc-${PACKAGE_VERSION}.tar.xz"
SOURCE_SHA256="37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667"

TARGET="aarch64-linux-gnu"
BUILD="x86_64-linux-gnu"

###############################################################################
# Paths
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ROOT_DIR="${WINGO_ROOT:?WINGO_ROOT is required}"
BUILD_ROOT="${WINGO_BUILD_DIR:-$ROOT_DIR/build}"
STAGING_ROOT="${WINGO_STAGING_DIR:-$ROOT_DIR/staging}"
OUTPUT_ROOT="${WINGO_OUTPUT_DIR:-$ROOT_DIR/output}"

SOURCE_ARCHIVE="$BUILD_ROOT/glibc-${PACKAGE_VERSION}.tar.xz"
SOURCE_DIR="$BUILD_ROOT/glibc-${PACKAGE_VERSION}"
BUILD_DIR="$BUILD_ROOT/glibc-build"
STAGING_DIR="$STAGING_ROOT/$PACKAGE_NAME"

###############################################################################
# Helpers
###############################################################################

log() {
	echo
	echo "==> $*"
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 ||
		die "Missing command: $1"
}

###############################################################################
# Download
###############################################################################

download_source() {
	log "Downloading Glibc ${PACKAGE_VERSION}"

	mkdir -p "$BUILD_ROOT"

	if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
		curl \
			--fail \
			--location \
			--retry 5 \
			--retry-delay 3 \
			--output "$SOURCE_ARCHIVE" \
			"$SOURCE_URL"
	fi

	echo "${SOURCE_SHA256}  ${SOURCE_ARCHIVE}" |
		sha256sum --check -
}

###############################################################################
# Extract
###############################################################################

extract_source() {
	log "Extracting source"

	rm -rf "$SOURCE_DIR"

	tar \
		-xf "$SOURCE_ARCHIVE" \
		-C "$BUILD_ROOT"

	[[ -d "$SOURCE_DIR" ]] ||
		die "Source directory not found: $SOURCE_DIR"
}

###############################################################################
# Wingo source files
###############################################################################

install_wingo_files() {
	log "Installing Wingo source files"

	mkdir -p "$SOURCE_DIR/sysdeps/unix/sysv/linux"

	for file in \
		shm_at.c \
		shmctl.c \
		shmdt.c \
		shmget.c \
		mprotect.c \
		syscall.c \
		fake_epoll_pwait2.c \
		setfsuid.c \
		setfsgid.c
	do
		[[ -f "$SCRIPT_DIR/$file" ]] || continue

		cp \
			"$SCRIPT_DIR/$file" \
			"$SOURCE_DIR/sysdeps/unix/sysv/linux/$file"
	done

	for file in "$SCRIPT_DIR"/fakesyscall*.h; do
		[[ -f "$file" ]] || continue

		cp \
			"$file" \
			"$SOURCE_DIR/sysdeps/unix/sysv/linux/$(basename "$file")"
	done

	if [[ -f "$SCRIPT_DIR/android_passwd_group.c" ]]; then
		mkdir -p "$SOURCE_DIR/nss"

		cp \
			"$SCRIPT_DIR/android_passwd_group.c" \
			"$SOURCE_DIR/nss/"
	fi

	if [[ -f "$SCRIPT_DIR/android_passwd_group.h" ]]; then
		mkdir -p "$SOURCE_DIR/nss"

		cp \
			"$SCRIPT_DIR/android_passwd_group.h" \
			"$SOURCE_DIR/nss/"
	fi

	if [[ -f "$SCRIPT_DIR/android_system_user_ids.h" ]]; then
		mkdir -p "$SOURCE_DIR/nss"

		cp \
			"$SCRIPT_DIR/android_system_user_ids.h" \
			"$SOURCE_DIR/nss/"
	fi

	if [[ -f "$SCRIPT_DIR/syslog.c" ]]; then
		mkdir -p "$SOURCE_DIR/misc"

		cp \
			"$SCRIPT_DIR/syslog.c" \
			"$SOURCE_DIR/misc/"
	fi

	for file in "$SCRIPT_DIR"/shmem-android.*; do
		[[ -f "$file" ]] || continue

		mkdir -p "$SOURCE_DIR/sysvipc"

		cp \
			"$file" \
			"$SOURCE_DIR/sysvipc/$(basename "$file")"
	done
}

###############################################################################
# Source cleanup
###############################################################################

prepare_source() {
	log "Preparing source"

	find \
		"$SOURCE_DIR/sysdeps/unix/sysv/linux" \
		-type f \
		-name 'clone3.S' \
		-delete

	if [[ -d "$SOURCE_DIR/sysdeps/unix/sysv/linux/x86_64" ]]; then
		find \
			"$SOURCE_DIR/sysdeps/unix/sysv/linux/x86_64" \
			-maxdepth 1 \
			-type f \
			-name 'configure*' \
			-delete
	fi

	while IFS= read -r -d '' file; do
		sed \
			-i \
			-e 's|/dev/stderr|/proc/self/fd/2|g' \
			-e 's|/dev/stdin|/proc/self/fd/0|g' \
			-e 's|/dev/stdout|/proc/self/fd/1|g' \
			"$file"
	done < <(
		grep \
			-rlZ \
			-e '/dev/stderr' \
			-e '/dev/stdin' \
			-e '/dev/stdout' \
			"$SOURCE_DIR" 2>/dev/null || true
	)
}

###############################################################################
# Fake syscalls
###############################################################################

configure_fake_syscalls() {
	local json="$SCRIPT_DIR/fakesyscall.json"

	[[ -f "$json" ]] || return 0

	log "Configuring fake syscalls"

	for arch in aarch64 arm i386 x86_64; do
		local dir="$SOURCE_DIR/sysdeps/unix/sysv/linux/$arch"

		[[ -d "$dir" ]] || continue

		if [[ -f "$dir/syscall.S" ]]; then
			mv \
				"$dir/syscall.S" \
				"$dir/syscallS.S"
		fi

		[[ -f "$dir/arch-syscall.h" ]] || continue

		local disabled="$dir/disabled-syscall.h"

		: > "$disabled"

		while IFS= read -r syscall; do
			[[ -n "$syscall" ]] || continue

			sed \
				-i \
				"/#define __NR_${syscall} /d" \
				"$dir/arch-syscall.h"

		done < <(
			jq -r '.[] | .[]' "$json"
		)

		echo '#define DISABLED_SYSCALL_WITH_FAKESYSCALL \' >> "$disabled"

		while IFS= read -r function; do
			while IFS= read -r syscall; do
				if [[ "$syscall" =~ ^[0-9]+$ ]]; then
					echo -e "\tcase ${syscall}: \\" >> "$disabled"
				else
					echo -e "\tcase __NR_${syscall}: \\" >> "$disabled"
				fi

				echo -e "\t\treturn ${function}; \\" >> "$disabled"
			done < <(
				jq -r --arg name "$function" '.[$name][]' "$json"
			)
		done < <(
			jq -r 'keys[]' "$json"
		)

		sed -i '$ s/ \\$//' "$disabled"
	done
}

###############################################################################
# Configure
###############################################################################

configure() {
	log "Configuring Glibc"

	need aarch64-linux-gnu-gcc
	need aarch64-linux-gnu-g++
	need aarch64-linux-gnu-ar
	need aarch64-linux-gnu-as
	need aarch64-linux-gnu-ld
	need aarch64-linux-gnu-nm
	need aarch64-linux-gnu-ranlib
	need aarch64-linux-gnu-readelf
	need aarch64-linux-gnu-strip
	need make

	local kernel_headers="${WINGO_KERNEL_HEADERS:-/usr/aarch64-linux-gnu/include}"

	[[ -d "$kernel_headers" ]] ||
		die "Kernel headers not found: $kernel_headers"

	rm -rf "$BUILD_DIR"
	mkdir -p "$BUILD_DIR"

	cd "$BUILD_DIR"

	cat > configparms <<EOF
slibdir=/lib
rtlddir=/lib
sbindir=/bin
rootsbindir=/bin
EOF

	export CC=aarch64-linux-gnu-gcc
	export CXX=aarch64-linux-gnu-g++
	export AR=aarch64-linux-gnu-ar
	export AS=aarch64-linux-gnu-as
	export LD=aarch64-linux-gnu-ld
	export NM=aarch64-linux-gnu-nm
	export RANLIB=aarch64-linux-gnu-ranlib
	export READELF=aarch64-linux-gnu-readelf
	export STRIP=aarch64-linux-gnu-strip
	export BUILD_CC=gcc

	"$SOURCE_DIR/configure" \
		--prefix=/ \
		--libdir=/lib \
		--libexecdir=/lib \
		--includedir=/include \
		--build="$BUILD" \
		--host="$TARGET" \
		--with-headers="$kernel_headers" \
		--with-pkgversion="GNU libc for Wingo" \
		--with-bugurl="https://github.com/tarqsbay74-png/glibc-packages/issues" \
		--enable-bind-now \
		--enable-fortify-source \
		--disable-multi-arch \
		--enable-stack-protector=strong \
		--disable-nscd \
		--disable-profile \
		--disable-werror \
		--disable-default-pie
}

###############################################################################
# Build
###############################################################################

build() {
	log "Building Glibc"

	cd "$BUILD_DIR"

	make \
		-O \
		-j"$(nproc)"
}

###############################################################################
# Install
###############################################################################

install() {
	log "Installing Glibc"

	rm -rf "$STAGING_DIR"
	mkdir -p "$STAGING_DIR"

	cd "$BUILD_DIR"

	make \
		install \
		DESTDIR="$STAGING_DIR"

	rm -f "$STAGING_DIR/etc/ld.so.cache"

	rm -f \
		"$STAGING_DIR/bin/tzselect" \
		"$STAGING_DIR/bin/zdump" \
		"$STAGING_DIR/bin/zic"

	rm -rf "$STAGING_DIR/include/gnu"
}

###############################################################################
# Package
###############################################################################

package() {
	log "Creating package"

	need tar
	need zstd

	mkdir -p "$OUTPUT_ROOT"

	local output="$OUTPUT_ROOT/${PACKAGE_NAME}-${PACKAGE_VERSION}-${TARGET}.tar.zst"

	rm -f "$output"

	tar \
		-C "$STAGING_DIR" \
		-cf - \
		. |
		zstd \
			-T0 \
			-o "$output"

	echo
	echo "Package created:"
	echo "$output"
}

###############################################################################
# Main
###############################################################################

main() {
	need curl
	need sha256sum
	need tar
	need jq

	download_source
	extract_source
	install_wingo_files
	prepare_source
	configure_fake_syscalls
	configure
	build
	install
	package

	log "Wingo Glibc build completed"
}

main "$@"