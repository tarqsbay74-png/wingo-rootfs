#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Wingo Glibc
###############################################################################

PACKAGE_NAME="glibc"
PACKAGE_VERSION="2.44"

PACKAGE_URL="https://ftp.gnu.org/gnu/libc/glibc-${PACKAGE_VERSION}.tar.xz"
PACKAGE_SHA256="37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667"

TARGET="aarch64-linux-gnu"
BUILD="x86_64-linux-gnu"

###############################################################################
# Directories
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WINGO_ROOT="${WINGO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

WINGO_BUILD_DIR="${WINGO_BUILD_DIR:-$WINGO_ROOT/build}"
WINGO_STAGING_DIR="${WINGO_STAGING_DIR:-$WINGO_ROOT/staging}"
WINGO_OUTPUT_DIR="${WINGO_OUTPUT_DIR:-$WINGO_ROOT/output}"

SOURCE_ARCHIVE="$WINGO_BUILD_DIR/glibc-${PACKAGE_VERSION}.tar.xz"
SOURCE_DIR="$WINGO_BUILD_DIR/glibc-${PACKAGE_VERSION}"
BUILD_DIR="$WINGO_BUILD_DIR/glibc-build"
STAGING_DIR="$WINGO_STAGING_DIR/glibc"

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

require_command() {
	command -v "$1" >/dev/null 2>&1 ||
		die "Required command not found: $1"
}

###############################################################################
# Prepare
###############################################################################

prepare() {
	log "Preparing Glibc ${PACKAGE_VERSION}"

	mkdir -p "$WINGO_BUILD_DIR"

	require_command curl
	require_command sha256sum
	require_command tar

	if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
		log "Downloading Glibc"

		curl \
			--fail \
			--location \
			--retry 5 \
			--retry-delay 3 \
			--output "$SOURCE_ARCHIVE" \
			"$PACKAGE_URL"
	else
		echo "Using existing archive:"
		echo "$SOURCE_ARCHIVE"
	fi

	log "Checking SHA256"

	echo "${PACKAGE_SHA256}  ${SOURCE_ARCHIVE}" |
		sha256sum --check -

	log "Extracting source"

	rm -rf "$SOURCE_DIR"

	tar \
		-xf "$SOURCE_ARCHIVE" \
		-C "$WINGO_BUILD_DIR"

	[[ -d "$SOURCE_DIR" ]] ||
		die "Glibc source directory was not created."

	printf '%s\n' "$SOURCE_DIR" > "$WINGO_BUILD_DIR/source-dir"

	echo
	echo "Glibc source:"
	echo "$SOURCE_DIR"
}

###############################################################################
# Package-local files
#
# Patches are NOT applied here.
# build.yml applies every *.patch before this phase.
###############################################################################

install_source_modifications() {
	local src="$1"

	log "Installing package source modifications"

	############################################################################
	# Linux syscall modifications
	############################################################################

	mkdir -p "$src/sysdeps/unix/sysv/linux"

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
		if [[ -f "$SCRIPT_DIR/$file" ]]; then
			cp \
				"$SCRIPT_DIR/$file" \
				"$src/sysdeps/unix/sysv/linux/$file"
		fi
	done

	for file in "$SCRIPT_DIR"/fakesyscall*.h; do
		[[ -f "$file" ]] || continue

		cp \
			"$file" \
			"$src/sysdeps/unix/sysv/linux/$(basename "$file")"
	done

	############################################################################
	# Android-compatible NSS files
	############################################################################

	if compgen -G "$SCRIPT_DIR/android_passwd_group.*" >/dev/null; then
		mkdir -p "$src/nss"

		for file in "$SCRIPT_DIR"/android_passwd_group.*; do
			[[ -f "$file" ]] || continue

			cp \
				"$file" \
				"$src/nss/$(basename "$file")"
		done
	fi

	if [[ -f "$SCRIPT_DIR/android_system_user_ids.h" ]]; then
		mkdir -p "$src/nss"

		cp \
			"$SCRIPT_DIR/android_system_user_ids.h" \
			"$src/nss/android_system_user_ids.h"
	fi

	if [[ -f "$SCRIPT_DIR/gen-android-ids.sh" ]]; then
		mkdir -p "$src/nss"

		cp \
			"$SCRIPT_DIR/gen-android-ids.sh" \
			"$src/nss/gen-android-ids.sh"

		chmod +x \
			"$src/nss/gen-android-ids.sh"
	fi

	############################################################################
	# Android-compatible syslog
	############################################################################

	if [[ -f "$SCRIPT_DIR/syslog.c" ]]; then
		mkdir -p "$src/misc"

		cp \
			"$SCRIPT_DIR/syslog.c" \
			"$src/misc/syslog.c"
	fi

	############################################################################
	# Android shared-memory implementation
	############################################################################

	for file in "$SCRIPT_DIR"/shmem-android.*; do
		[[ -f "$file" ]] || continue

		mkdir -p "$src/sysvipc"

		cp \
			"$file" \
			"$src/sysvipc/$(basename "$file")"
	done

	############################################################################
	# fakesyscall configuration
	############################################################################

	if [[ -f "$SCRIPT_DIR/fakesyscall.json" ]]; then
		cp \
			"$SCRIPT_DIR/fakesyscall.json" \
			"$src/fakesyscall.json"
	fi

	log "Source modifications installed"
}

###############################################################################
# Generate disabled-syscall headers
#
# This preserves the logic of the original Termux builder.
###############################################################################

configure_fake_syscalls() {
	local src="$1"
	local json="$SCRIPT_DIR/fakesyscall.json"

	[[ -f "$json" ]] || {
		echo "fakesyscall.json not found; skipping fake syscall generation."
		return
	}

	require_command jq

	log "Configuring fake syscalls"

	for arch in aarch64 arm i386 x86_64; do

		local arch_dir="$src/sysdeps/unix/sysv/linux/$arch"

		[[ -d "$arch_dir" ]] || continue

		if [[ -f "$arch_dir/syscall.S" ]]; then
			mv \
				"$arch_dir/syscall.S" \
				"$arch_dir/syscallS.S"
		fi

		local disabled_header="$arch_dir/disabled-syscall.h"

		: > "$disabled_header"

		{
			for syscall_name in $(jq -r '.[] | .[]' "$json"); do

				grep \
					"#define __NR_${syscall_name} " \
					"$arch_dir/arch-syscall.h" ||
					true

				sed \
					-i \
					"/#define __NR_${syscall_name} /d" \
					"$arch_dir/arch-syscall.h"

			done
		} >> "$disabled_header"

		{
			echo
			echo '#define DISABLED_SYSCALL_WITH_FAKESYSCALL \'

			local IFS=$'\n'

			for fake_function in $(jq -r '. | keys | .[]' "$json"); do

				local need_return=false

				for syscall_name in \
					$(jq -r '."'${fake_function}'" | .[]' "$json")
				do

					if grep \
						-q \
						"^#define __NR_${syscall_name} " \
						"$disabled_header"
					then
						echo \
							-e "\tcase __NR_${syscall_name}: \\"

						need_return=true

					elif [[ "$syscall_name" =~ ^[0-9]+$ ]]; then

						echo \
							-e "\tcase ${syscall_name}: \\"

						need_return=true
					fi

				done

				if [[ "$need_return" == "true" ]]; then
					echo \
						-e "\t\treturn ${fake_function}; \\"
				fi

			done

			unset IFS

		} >> "$disabled_header"

		sed \
			-i \
			'$ s| \\||' \
			"$disabled_header"
	done
}

###############################################################################
# Remove/disable files from original Termux logic
###############################################################################

apply_source_changes() {
	local src="$1"

	log "Applying source changes"

	############################################################################
	# Disable clone3 implementation.
	############################################################################

	find \
		"$src/sysdeps/unix/sysv/linux" \
		-type f \
		-name 'clone3.S' \
		-delete

	############################################################################
	# Termux removes the x86_64 ldd configure override.
	# It is harmless to perform the same operation when the file exists.
	############################################################################

	find \
		"$src/sysdeps/unix/sysv/linux/x86_64" \
		-maxdepth 1 \
		-type f \
		-name 'configure*' \
		-delete 2>/dev/null ||
		true

	############################################################################
	# Android device paths.
	############################################################################

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
			"$src" 2>/dev/null ||
			true
	)
}

###############################################################################
# Configure
###############################################################################

configure_glibc() {
	log "Configuring Glibc"

	require_command aarch64-linux-gnu-gcc
	require_command aarch64-linux-gnu-g++
	require_command aarch64-linux-gnu-ar
	require_command aarch64-linux-gnu-ranlib
	require_command aarch64-linux-gnu-ld

	rm -rf "$BUILD_DIR"
	mkdir -p "$BUILD_DIR"

	local kernel_headers="${WINGO_KERNEL_HEADERS:-}"

	if [[ -z "$kernel_headers" ]]; then
		kernel_headers="/usr/aarch64-linux-gnu/include"
	fi

	if [[ ! -d "$kernel_headers" ]]; then
		die "Linux kernel headers not found: $kernel_headers"
	fi

	cd "$BUILD_DIR"

	############################################################################
	# Glibc configparms.
	#
	# The final Wingo runtime root is the root of the package.
	#
	# Therefore:
	#
	#   libraries -> /lib
	#   binaries  -> /bin
	#
	############################################################################

	cat > configparms <<EOF
slibdir=/lib
rtlddir=/lib
sbindir=/bin
rootsbindir=/bin
EOF

	############################################################################
	# Cross compiler.
	############################################################################

	export CC="aarch64-linux-gnu-gcc"
	export CXX="aarch64-linux-gnu-g++"
	export AR="aarch64-linux-gnu-ar"
	export AS="aarch64-linux-gnu-as"
	export LD="aarch64-linux-gnu-ld"
	export NM="aarch64-linux-gnu-nm"
	export RANLIB="aarch64-linux-gnu-ranlib"
	export READELF="aarch64-linux-gnu-readelf"
	export OBJCOPY="aarch64-linux-gnu-objcopy"
	export OBJDUMP="aarch64-linux-gnu-objdump"
	export STRIP="aarch64-linux-gnu-strip"

	export BUILD_CC="gcc"

	############################################################################
	# Compiler flags.
	############################################################################

	CFLAGS="${CFLAGS:-}"

	CFLAGS="${CFLAGS/-Wp,-D_FORTIFY_SOURCE=2 / }"
	CFLAGS="${CFLAGS/-Werror / }"

	CFLAGS+=" -O2"
	CFLAGS+=" -fstack-protector-strong"

	export CFLAGS

	############################################################################
	# Configure.
	############################################################################

	"$SOURCE_DIR/configure" \
		--prefix=/ \
		--libdir=/lib \
		--libexecdir=/lib \
		--includedir=/include \
		--build="$BUILD" \
		--host="$TARGET" \
		--target="$TARGET" \
		--with-headers="$kernel_headers" \
		--with-pkgversion="GNU libc for Wingo" \
		--with-bugurl="https://github.com/tarqsbay74-png/glibc-packages/issues" \
		--enable-bind-now \
		--enable-fortify-source \
		--disable-multi-arch \
		--enable-stack-protector=strong \
		--enable-systemtap \
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
		-O \
		-j"$(nproc)"
}

###############################################################################
# Install
###############################################################################

install_glibc() {
	log "Installing Glibc into staging"

	rm -rf "$STAGING_DIR"

	mkdir -p "$STAGING_DIR"

	cd "$BUILD_DIR"

	make \
		install \
		DESTDIR="$STAGING_DIR"

	############################################################################
	# Remove generated loader cache.
	############################################################################

	rm -f \
		"$STAGING_DIR/etc/ld.so.cache"

	############################################################################
	# Remove utilities we don't want in Wingo runtime.
	############################################################################

	rm -f \
		"$STAGING_DIR/bin/tzselect" \
		"$STAGING_DIR/bin/zdump" \
		"$STAGING_DIR/bin/zic"

	############################################################################
	# Remove generated GNU include directory as in original builder.
	############################################################################

	rm -rf \
		"$STAGING_DIR/include/gnu"
}

###############################################################################
# Runtime files
###############################################################################

install_runtime_files() {
	log "Installing runtime configuration"

	mkdir -p \
		"$STAGING_DIR/etc" \
		"$STAGING_DIR/lib/tmpfiles.d" \
		"$STAGING_DIR/lib/locale"

	############################################################################
	# nscd configuration
	############################################################################

	if [[ -f "$SOURCE_DIR/nscd/nscd.conf" ]]; then
		install \
			-m644 \
			"$SOURCE_DIR/nscd/nscd.conf" \
			"$STAGING_DIR/etc/nscd.conf"
	fi

	if [[ -f "$SOURCE_DIR/nscd/nscd.tmpfiles" ]]; then
		install \
			-m644 \
			"$SOURCE_DIR/nscd/nscd.tmpfiles" \
			"$STAGING_DIR/lib/tmpfiles.d/nscd.conf"
	fi

	############################################################################
	# gai.conf
	############################################################################

	if [[ -f "$SOURCE_DIR/posix/gai.conf" ]]; then
		install \
			-m644 \
			"$SOURCE_DIR/posix/gai.conf" \
			"$STAGING_DIR/etc/gai.conf"
	fi

	############################################################################
	# locale-gen
	############################################################################

	if [[ -f "$SCRIPT_DIR/locale-gen" ]]; then

		install \
			-Dm755 \
			"$SCRIPT_DIR/locale-gen" \
			"$STAGING_DIR/bin/locale-gen"

		sed \
			-i \
			"s|@TERMUX_PREFIX@|/data/data/com.wingo/files/rootfs|g; \
			 s|@TERMUX_PREFIX_CLASSICAL@|/data/data/com.wingo/files/rootfs|g" \
			"$STAGING_DIR/bin/locale-gen"
	fi

	############################################################################
	# locale.gen
	############################################################################

	if [[ -f "$SCRIPT_DIR/locale.gen.txt" ]]; then

		install \
			-Dm644 \
			"$SCRIPT_DIR/locale.gen.txt" \
			"$STAGING_DIR/etc/locale.gen"

		if [[ -f "$SOURCE_DIR/localedata/SUPPORTED" ]]; then

			sed \
				-e '1,3d' \
				-e 's|/| |g' \
				-e 's|\\| |g' \
				-e 's|^|#|g' \
				"$SOURCE_DIR/localedata/SUPPORTED" \
				>> "$STAGING_DIR/etc/locale.gen"

		fi
	fi

	############################################################################
	# SUPPORTED locale list
	############################################################################

	if [[ -f "$SOURCE_DIR/localedata/SUPPORTED" ]]; then

		mkdir -p \
			"$STAGING_DIR/share/i18n"

		sed \
			-e '1,3d' \
			-e 's|/| |g' \
			-e 's| \\||g' \
			"$SOURCE_DIR/localedata/SUPPORTED" \
			> "$STAGING_DIR/share/i18n/SUPPORTED"

	fi

	############################################################################
	# Locale files.
	############################################################################

	if [[ -d "$SOURCE_DIR/localedata" ]]; then

		make \
			-C "$SOURCE_DIR/localedata" \
			objdir="$BUILD_DIR" \
			SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" \
			install-locale-files

	fi

	if [[ -f "$STAGING_DIR/etc/locale.gen" ]]; then

		sed \
			-i \
			'/#C\.UTF-8 /d' \
			"$STAGING_DIR/etc/locale.gen"

	fi

	############################################################################
	# SystemTap headers.
	############################################################################

	if [[ -f "$SCRIPT_DIR/sdt.h" ]]; then

		install \
			-Dm644 \
			"$SCRIPT_DIR/sdt.h" \
			"$STAGING_DIR/include/sys/sdt.h"

	fi

	if [[ -f "$SCRIPT_DIR/sdt-config.h" ]]; then

		install \
			-Dm644 \
			"$SCRIPT_DIR/sdt-config.h" \
			"$STAGING_DIR/include/sys/sdt-config.h"

	fi
}

###############################################################################
# syscall helper
###############################################################################

build_syscall_without_fsc() {
	local syscall_source="$SCRIPT_DIR/syscall.c"
	local output="$STAGING_DIR/lib/libsyscall_without_fsc.so"

	if [[ ! -f "$syscall_source" ]]; then
		echo "syscall.c not found; skipping helper."
		return
	fi

	log "Building libsyscall_without_fsc.so"

	mkdir -p \
		"$STAGING_DIR/lib"

	"$CC" \
		"$syscall_source" \
		-o "$output" \
		-shared \
		-fPIC \
		-DWITHOUT_FAKESYSCALL
}

###############################################################################
# Dynamic linker aliases
###############################################################################

create_loader_links() {
	log "Creating loader links"

	local loader

	loader="$(find "$STAGING_DIR/lib" \
		-maxdepth 1 \
		-type f \
		-name 'ld-linux-aarch64.so.1' \
		-print -quit)"

	if [[ -z "$loader" ]]; then
		echo "ld-linux-aarch64.so.1 not found; skipping loader aliases."
		return
	fi

	ln -sfn \
		"/lib/$(basename "$loader")" \
		"$STAGING_DIR/bin/ld.so"

	ln -sfn \
		"/lib/$(basename "$loader")" \
		"$STAGING_DIR/lib/ld.so"
}

###############################################################################
# Package
###############################################################################

package_glibc() {
	log "Creating package"

	local package_name
	local archive

	package_name="${PACKAGE_NAME}-${PACKAGE_VERSION}-armv8-a"
	archive="$WINGO_OUTPUT_DIR/${package_name}.tar.zst"

	mkdir -p "$WINGO_OUTPUT_DIR"

	rm -f "$archive"

	############################################################################
	# Package contains the rootfs contents directly:
	#
	# /bin
	# /etc
	# /include
	# /lib
	# /share
	############################################################################

	tar \
		-C "$STAGING_DIR" \
		-cf - \
		. |
		zstd \
			-T0 \
			-19 \
			-o "$archive"

	[[ -s "$archive" ]] ||
		die "Package was not created."

	echo
	echo "Package:"
	echo "$archive"
}

###############################################################################
# Validation
###############################################################################

validate() {
	log "Validating staging"

	[[ -d "$STAGING_DIR/lib" ]] ||
		die "Missing /lib"

	[[ -d "$STAGING_DIR/include" ]] ||
		die "Missing /include"

	[[ -e "$STAGING_DIR/lib/libc.so.6" ]] ||
		die "Missing libc.so.6"

	[[ -e "$STAGING_DIR/lib/ld-linux-aarch64.so.1" ]] ||
		die "Missing AArch64 dynamic loader"

	echo
	echo "Validation successful."

	echo
	echo "Important files:"

	find \
		"$STAGING_DIR" \
		-maxdepth 3 \
		-type f \
		\( \
			-name 'libc.so.6' \
			-o -name 'ld-linux-aarch64.so.1' \
			-o -name 'libsyscall_without_fsc.so' \
		\) \
		-print
}

###############################################################################
# Main
###############################################################################

case "$PHASE" in

	prepare)
		prepare
		;;

	build)

		[[ -n "${WINGO_SRC_DIR:-}" ]] ||
			die "WINGO_SRC_DIR is not set."

		SOURCE_DIR="$WINGO_SRC_DIR"

		[[ -d "$SOURCE_DIR" ]] ||
			die "Source directory does not exist: $SOURCE_DIR"

		install_source_modifications
		apply_source_changes
		configure_fake_syscalls

		configure_glibc
		build_glibc
		install_glibc

		install_runtime_files
		build_syscall_without_fsc
		create_loader_links

		validate
		package_glibc
		;;

	*)
		die "Unknown WINGO_PHASE: $PHASE"
		;;

esac