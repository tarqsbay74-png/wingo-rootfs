#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Wingo Glibc package
###############################################################################

PACKAGE_NAME="glibc"
PACKAGE_VERSION="2.44"

PACKAGE_URL="https://ftp.gnu.org/gnu/libc/glibc-${PACKAGE_VERSION}.tar.xz"
PACKAGE_SHA256="37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667"

TARGET="aarch64-linux-gnu"
BUILD="x86_64-linux-gnu"

PREFIX="/usr"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WINGO_ROOT="${WINGO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WINGO_BUILD_DIR="${WINGO_BUILD_DIR:-$WINGO_ROOT/build}"
WINGO_STAGING_DIR="${WINGO_STAGING_DIR:-$WINGO_ROOT/staging}"
WINGO_OUTPUT_DIR="${WINGO_OUTPUT_DIR:-$WINGO_ROOT/output}"

SOURCE_ARCHIVE="$WINGO_BUILD_DIR/glibc-${PACKAGE_VERSION}.tar.xz"
SOURCE_ROOT="$WINGO_BUILD_DIR/glibc-${PACKAGE_VERSION}"
BUILD_DIR="$WINGO_BUILD_DIR/glibc-build"
STAGING_ROOT="$WINGO_STAGING_DIR/glibc"

PHASE="${WINGO_PHASE:-build}"

###############################################################################
# Helpers
###############################################################################

die() {
	echo "ERROR: $*" >&2
	exit 1
}

log() {
	echo
	echo "============================================================"
	echo "$*"
	echo "============================================================"
}

require_file() {
	local file="$1"

	[[ -f "$file" ]] || die "Required file does not exist: $file"
}

require_command() {
	local command_name="$1"

	command -v "$command_name" >/dev/null 2>&1 ||
		die "Required command not found: $command_name"
}

###############################################################################
# Environment
###############################################################################

require_command curl
require_command sha256sum
require_command tar
require_command patch
require_command make
require_command gcc
require_command aarch64-linux-gnu-gcc
require_command aarch64-linux-gnu-ld
require_command zstd

mkdir -p \
	"$WINGO_BUILD_DIR" \
	"$WINGO_STAGING_DIR" \
	"$WINGO_OUTPUT_DIR"

###############################################################################
# Prepare
###############################################################################

prepare_source() {
	log "Downloading Glibc ${PACKAGE_VERSION}"

	if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
		curl \
			--fail \
			--location \
			--retry 5 \
			--retry-delay 3 \
			--output "$SOURCE_ARCHIVE" \
			"$PACKAGE_URL"
	else
		echo "Archive already exists:"
		echo "$SOURCE_ARCHIVE"
	fi

	log "Verifying Glibc checksum"

	echo "${PACKAGE_SHA256}  ${SOURCE_ARCHIVE}" | sha256sum --check -

	log "Extracting Glibc source"

	rm -rf "$SOURCE_ROOT"

	tar \
		-xf "$SOURCE_ARCHIVE" \
		-C "$WINGO_BUILD_DIR"

	[[ -d "$SOURCE_ROOT" ]] ||
		die "Expected source directory was not created: $SOURCE_ROOT"

	printf '%s\n' "$SOURCE_ROOT" > "$WINGO_BUILD_DIR/source-dir"

	echo
	echo "Source directory:"
	echo "$SOURCE_ROOT"
}

###############################################################################
# Package-local source modifications
#
# Patches are deliberately NOT handled here.
# The GitHub Actions workflow applies every *.patch before this phase.
###############################################################################

install_package_files() {
	local source="$1"

	log "Installing package-specific source files"

	############################################################################
	# The files below live next to this build.sh.
	#
	# Only files that actually exist are copied.
	#
	# The exact destination paths correspond to the modifications from the
	# original Termux Glibc package.
	############################################################################

	if [[ -f "$SCRIPT_DIR/syscall.c" ]]; then
		mkdir -p \
			"$source/sysdeps/unix/sysv/linux"

		cp \
			"$SCRIPT_DIR/syscall.c" \
			"$source/sysdeps/unix/sysv/linux/syscall.c"
	fi

	for file in \
		shm_at.c \
		shmctl.c \
		shmdt.c \
		shmget.c \
		mprotect.c \
		fake_epoll_pwait2.c \
		setfsuid.c \
		setfsgid.c
	do
		if [[ -f "$SCRIPT_DIR/$file" ]]; then
			cp \
				"$SCRIPT_DIR/$file" \
				"$source/sysdeps/unix/sysv/linux/$file"
		fi
	done

	for file in "$SCRIPT_DIR"/fakesyscall*.h; do
		[[ -f "$file" ]] || continue

		cp \
			"$file" \
			"$source/sysdeps/unix/sysv/linux/$(basename "$file")"
	done

	if [[ -f "$SCRIPT_DIR/fakesyscall.json" ]]; then
		cp \
			"$SCRIPT_DIR/fakesyscall.json" \
			"$source/fakesyscall.json"
	fi

	for file in \
		android_passwd_group.c \
		android_passwd_group.h
	do
		if [[ -f "$SCRIPT_DIR/$file" ]]; then
			mkdir -p "$source/nss"

			cp \
				"$SCRIPT_DIR/$file" \
				"$source/nss/$file"
		fi
	done

	if [[ -f "$SCRIPT_DIR/android_system_user_ids.h" ]]; then
		mkdir -p "$source/nss"

		cp \
			"$SCRIPT_DIR/android_system_user_ids.h" \
			"$source/nss/android_system_user_ids.h"
	fi

	if [[ -f "$SCRIPT_DIR/gen-android-ids.sh" ]]; then
		cp \
			"$SCRIPT_DIR/gen-android-ids.sh" \
			"$source/nss/gen-android-ids.sh"

		chmod +x \
			"$source/nss/gen-android-ids.sh"
	fi

	if [[ -f "$SCRIPT_DIR/syslog.c" ]]; then
		mkdir -p "$source/misc"

		cp \
			"$SCRIPT_DIR/syslog.c" \
			"$source/misc/syslog.c"
	fi

	for file in "$SCRIPT_DIR"/shmem-android.*; do
		[[ -f "$file" ]] || continue

		mkdir -p "$source/sysvipc"

		cp \
			"$file" \
			"$source/sysvipc/$(basename "$file")"
	done

	log "Package-specific files installed"
}

###############################################################################
# Configure
###############################################################################

configure_glibc() {
	log "Configuring Glibc"

	rm -rf "$BUILD_DIR"
	mkdir -p "$BUILD_DIR"

	local sysroot

	sysroot="$(aarch64-linux-gnu-gcc -print-sysroot)"

	if [[ -z "$sysroot" || "$sysroot" == "/" ]]; then
		sysroot="/usr/aarch64-linux-gnu"
	fi

	[[ -d "$sysroot" ]] ||
		die "AArch64 sysroot not found: $sysroot"

	echo "Build:      $BUILD"
	echo "Host:       $TARGET"
	echo "Sysroot:    $sysroot"
	echo "Prefix:     $PREFIX"

	cd "$BUILD_DIR"

	CFLAGS="${CFLAGS:-}"
	CFLAGS+=" -O2"
	CFLAGS+=" -fstack-protector-strong"

	CXXFLAGS="${CXXFLAGS:-}"
	CXXFLAGS+=" -O2"

	export CC="aarch64-linux-gnu-gcc"
	export CXX="aarch64-linux-gnu-g++"
	export AR="aarch64-linux-gnu-ar"
	export AS="aarch64-linux-gnu-as"
	export LD="aarch64-linux-gnu-ld"
	export RANLIB="aarch64-linux-gnu-ranlib"
	export STRIP="aarch64-linux-gnu-strip"

	export CFLAGS
	export CXXFLAGS

	"$SOURCE_ROOT/configure" \
		--prefix="$PREFIX" \
		--build="$BUILD" \
		--host="$TARGET" \
		--target="$TARGET" \
		--with-headers="$sysroot/usr/include" \
		--enable-bind-now \
		--enable-fortify-source \
		--enable-stack-protector=strong \
		--disable-multi-arch \
		--disable-nscd \
		--disable-profile \
		--disable-werror \
		--disable-default-pie
}

###############################################################################
# Build
###############################################################################

build_glibc() {
	log "Building Glibc"

	cd "$BUILD_DIR"

	make \
		-Oline \
		-j"$(nproc)"
}

###############################################################################
# Install
###############################################################################

install_glibc() {
	log "Installing Glibc into staging"

	rm -rf "$STAGING_ROOT"
	mkdir -p "$STAGING_ROOT"

	cd "$BUILD_DIR"

	make \
		install \
		DESTDIR="$STAGING_ROOT"

	############################################################################
	# The staging tree is:
	#
	#   staging/glibc/usr/...
	#
	# It is intentionally NOT:
	#
	#   /data/data/com.wingo/files/rootfs
	#
	# Wingo will install the package into its runtime rootfs later.
	############################################################################

	rm -f \
		"$STAGING_ROOT/usr/etc/ld.so.cache"

	if [[ -d "$STAGING_ROOT/usr/bin" ]]; then
		rm -f \
			"$STAGING_ROOT/usr/bin/tzselect" \
			"$STAGING_ROOT/usr/bin/zdump" \
			"$STAGING_ROOT/usr/bin/zic"
	fi
}

###############################################################################
# Additional Wingo files
###############################################################################

install_wingo_files() {
	log "Installing Wingo-specific runtime files"

	local usr="$STAGING_ROOT/usr"

	mkdir -p \
		"$usr/lib/tmpfiles.d" \
		"$usr/etc"

	if [[ -f "$SOURCE_ROOT/nscd/nscd.conf" ]]; then
		install \
			-m644 \
			"$SOURCE_ROOT/nscd/nscd.conf" \
			"$usr/etc/nscd.conf"
	fi

	if [[ -f "$SOURCE_ROOT/nscd/nscd.tmpfiles" ]]; then
		install \
			-m644 \
			"$SOURCE_ROOT/nscd/nscd.tmpfiles" \
			"$usr/lib/tmpfiles.d/nscd.conf"
	fi

	if [[ -f "$SOURCE_ROOT/posix/gai.conf" ]]; then
		install \
			-m644 \
			"$SOURCE_ROOT/posix/gai.conf" \
			"$usr/etc/gai.conf"
	fi

	if [[ -f "$SCRIPT_DIR/locale-gen" ]]; then
		install \
			-Dm755 \
			"$SCRIPT_DIR/locale-gen" \
			"$usr/bin/locale-gen"
	fi

	if [[ -f "$SCRIPT_DIR/locale.gen.txt" ]]; then
		install \
			-Dm644 \
			"$SCRIPT_DIR/locale.gen.txt" \
			"$usr/etc/locale.gen"
	fi

	if [[ -f "$SCRIPT_DIR/sdt.h" ]]; then
		install \
			-Dm644 \
			"$SCRIPT_DIR/sdt.h" \
			"$usr/include/sys/sdt.h"
	fi

	if [[ -f "$SCRIPT_DIR/sdt-config.h" ]]; then
		install \
			-Dm644 \
			"$SCRIPT_DIR/sdt-config.h" \
			"$usr/include/sys/sdt-config.h"
	fi
}

###############################################################################
# Syscall helper
###############################################################################

build_syscall_without_fsc() {
	if [[ ! -f "$SCRIPT_DIR/syscall.c" ]]; then
		echo "syscall.c not present; skipping syscall helper."
		return
	fi

	log "Building libsyscall_without_fsc.so"

	mkdir -p "$STAGING_ROOT/usr/lib"

	aarch64-linux-gnu-gcc \
		-shared \
		-fPIC \
		-DWITHOUT_FAKESYSCALL \
		"$SCRIPT_DIR/syscall.c" \
		-o "$STAGING_ROOT/usr/lib/libsyscall_without_fsc.so"
}

###############################################################################
# Package
###############################################################################

package_glibc() {
	log "Creating Wingo package"

	local package_name
	local package_root
	local package_archive

	package_name="${PACKAGE_NAME}-${PACKAGE_VERSION}-aarch64-linux-gnu"
	package_root="$WINGO_OUTPUT_DIR/$package_name"
	package_archive="$WINGO_OUTPUT_DIR/${package_name}.tar.zst"

	rm -rf "$package_root"
	mkdir -p "$package_root"

	cp -a \
		"$STAGING_ROOT/." \
		"$package_root/"

	[[ -d "$package_root/usr" ]] ||
		die "Staging is empty: $package_root"

	tar \
		-C "$package_root" \
		-cf - \
		. |
		zstd \
			-T0 \
			-19 \
			-o "$package_archive"

	rm -rf "$package_root"

	log "Package created"

	echo
	echo "Output:"
	echo "$package_archive"
}

###############################################################################
# Validation
###############################################################################

validate_package() {
	log "Validating package"

	local libc
	local loader

	libc="$STAGING_ROOT/usr/lib/libc.so.6"
	loader="$STAGING_ROOT/usr/lib/ld-linux-aarch64.so.1"

	if [[ ! -e "$libc" ]]; then
		echo "WARNING: libc.so.6 was not found at:"
		echo "         $libc"
	else
		echo "Found:"
		echo "  $libc"
	fi

	if [[ ! -e "$loader" ]]; then
		echo "WARNING: ld-linux-aarch64.so.1 was not found at:"
		echo "         $loader"
	else
		echo "Found:"
		echo "  $loader"
	fi

	if [[ ! -d "$STAGING_ROOT/usr/include" ]]; then
		die "Glibc headers were not installed."
	fi

	if [[ ! -d "$STAGING_ROOT/usr/lib" ]]; then
		die "Glibc libraries were not installed."
	fi

	echo
	echo "Staging validation completed."
}

###############################################################################
# Main
###############################################################################

case "$PHASE" in
	prepare)
		prepare_source
		;;

	build)
		[[ -n "${WINGO_SRC_DIR:-}" ]] ||
			die "WINGO_SRC_DIR is not set."

		SOURCE_ROOT="$WINGO_SRC_DIR"

		[[ -d "$SOURCE_ROOT" ]] ||
			die "Source directory does not exist: $SOURCE_ROOT"

		install_package_files "$SOURCE_ROOT"
		configure_glibc
		build_glibc
		install_glibc
		install_wingo_files
		build_syscall_without_fsc
		validate_package
		package_glibc
		;;

	*)
		die "Unknown WINGO_PHASE: $PHASE"
		;;
esac
