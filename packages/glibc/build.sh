#!/usr/bin/env bash
# ==============================================================================
# Wingo / Standalone Glibc Cross-Build Script (x86_64 -> aarch64)
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# 1. Environment & Variable Configuration
# ------------------------------------------------------------------------------
PREFIX="${PREFIX:-/data/data/com.wingo/files/rootfs}"
PREFIX_CLASSICAL="${PREFIX_CLASSICAL:-${PREFIX}}"
LIBDIR="${LIBDIR:-${PREFIX}/lib}"
INCLUDEDIR="${INCLUDEDIR:-${PREFIX}/include}"
BINDIR="${BINDIR:-${PREFIX}/bin}"
APP_PACKAGE="${APP_PACKAGE:-com.wingo}"

PKG_NAME="glibc"
PKG_VERSION="2.44"
PKG_SRCURL="https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz"

# Target & Host Architecture Definitions
TARGET_ARCH="aarch64"
HOST_PLATFORM="aarch64-linux-gnu"
BUILD_PLATFORM="$(gcc -dumpmachine)"

# Toolchain Definitions for Cross-Compilation from x86_64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CC="${CC:-${CROSS_COMPILE}gcc}"
CXX="${CXX:-${CROSS_COMPILE}g++}"
AR="${AR:-${CROSS_COMPILE}ar}"
RANLIB="${RANLIB:-${CROSS_COMPILE}ranlib}"

# Working Directories
BUILDER_DIR="${BUILDER_DIR:-$(pwd)}"
SRCDIR="${SRCDIR:-${BUILDER_DIR}/src/glibc-${PKG_VERSION}}"
BUILDDIR="${BUILDDIR:-${BUILDER_DIR}/build}"
PATCHES_DIR="${BUILDER_DIR}"

# ------------------------------------------------------------------------------
# Step 0: Download Package
# ------------------------------------------------------------------------------
download_package_step() {
	echo "[+] Downloading ${PKG_NAME} ${PKG_VERSION}..."
	mkdir -p "${BUILDER_DIR}/downloads"
	local tarball="${BUILDER_DIR}/downloads/${PKG_NAME}-${PKG_VERSION}.tar.xz"

	if [ ! -f "${tarball}" ]; then
		if command -v wget &>/dev/null; then
			wget -O "${tarball}" "${PKG_SRCURL}"
		elif command -v curl &>/dev/null; then
			curl -sSL -o "${tarball}" "${PKG_SRCURL}"
		else
			echo "[-] Error: Neither wget nor curl is installed!"
			return 1
		fi
	else
		echo "[!] Tarball already downloaded: ${tarball}"
	fi
}

# ------------------------------------------------------------------------------
# Step 1: Extract Package
# ------------------------------------------------------------------------------
extract_package_step() {
	echo "[+] Extracting ${PKG_NAME} ${PKG_VERSION}..."
	local tarball="${BUILDER_DIR}/downloads/${PKG_NAME}-${PKG_VERSION}.tar.xz"

	if [ ! -f "${tarball}" ]; then
		echo "[-] Error: Tarball '${tarball}' not found!"
		return 1
	fi

	mkdir -p "${BUILDER_DIR}/src"
	if [ ! -d "${SRCDIR}" ]; then
		tar -xf "${tarball}" -C "${BUILDER_DIR}/src"
		echo "[+] Extracted to ${SRCDIR}"
	else
		echo "[!] Source directory already exists: ${SRCDIR}"
	fi
}

# ------------------------------------------------------------------------------
# Step 2: Patch Package
# ------------------------------------------------------------------------------
patch_package_step() {
	echo "[+] Running Patch Step for ${PKG_NAME} (Target: ${TARGET_ARCH})..."

	if [ ! -d "${SRCDIR}" ]; then
		echo "[-] Error: Source directory '${SRCDIR}' does not exist!"
		return 1
	fi

	cd "${SRCDIR}"

	shopt -s nullglob
	local patch_files=("${PATCHES_DIR}"/*.patch "${PATCHES_DIR}"/*.patch64)
	shopt -u nullglob

	if [ ${#patch_files[@]} -eq 0 ]; then
		echo "[!] No patches found matching architecture in ${PATCHES_DIR}."
		return 0
	fi

	for patch in "${patch_files[@]}"; do
		if [ -f "$patch" ]; then
			echo "[+] Applying patch: $(basename "$patch")"
			patch -p1 --silent < "$patch" || echo "[!] Warning: Failed to apply $(basename "$patch") cleanly."
		fi
	done
}

# ------------------------------------------------------------------------------
# Step 3: Pre-Configure Step
# ------------------------------------------------------------------------------
pre_configure_step() {
	echo "[+] Running Pre-Configure Step for ${PKG_NAME} ${PKG_VERSION}..."

	# 1. Disabling clone3 function & x86_64 ldd configure
	rm -f ${SRCDIR}/sysdeps/unix/sysv/linux/*/clone3.S 2>/dev/null || true
	rm -f ${SRCDIR}/sysdeps/unix/sysv/linux/x86_64/configure* 2>/dev/null || true

	# 2. Installing special scripts for system calls
	cp -f ${PATCHES_DIR}/{shm{at,ctl,dt,get}.c,mprotect.c,syscall.c,fakesyscall*.h,fake_epoll_pwait2.c,setfs{u,g}id.c} \
		${SRCDIR}/sysdeps/unix/sysv/linux/ 2>/dev/null || true

	# 3. Installing and configuring scripts for parsing users/groups (Android standard)
	cp -f ${PATCHES_DIR}/{android_passwd_group.*,android_system_user_ids.h} \
		${SRCDIR}/nss/ 2>/dev/null || true

	if [ -f "${PATCHES_DIR}/gen-android-ids.sh" ]; then
		echo "[+] Generating Android IDs header..."
		bash ${PATCHES_DIR}/gen-android-ids.sh "${PREFIX}" \
			"${SRCDIR}/nss/android_ids.h" \
			"${PATCHES_DIR}/android_system_user_ids.h" || true
	fi

	# 4. Installing syslog script for Android log system
	cp -f ${PATCHES_DIR}/syslog.c ${SRCDIR}/misc/ 2>/dev/null || true

	# 5. Installing shmem-android scripts for System V shared memory emulation
	cp -f ${PATCHES_DIR}/shmem-android.* ${SRCDIR}/sysvipc/ 2>/dev/null || true

	# 6. Process fakesyscall.json using JQ to inject disabled-syscall.h
	if [ -f "${PATCHES_DIR}/fakesyscall.json" ] && command -v jq &>/dev/null; then
		echo "[+] Processing fakesyscall.json with JQ..."
		for i in aarch64 arm i386 x86_64/64; do
			local arch_dir="${SRCDIR}/sysdeps/unix/sysv/linux/${i///*/}"
			if [ -f "${arch_dir}/syscall.S" ]; then
				mv "${arch_dir}/syscall.S" "${arch_dir}/syscallS.S"
			fi

			local header_disabled="${SRCDIR}/sysdeps/unix/sysv/linux/${i}/disabled-syscall.h"
			mkdir -p "$(dirname "${header_disabled}")"
			echo "" > "${header_disabled}"

			{
				for j in $(jq -r '.[] | .[]' ${PATCHES_DIR}/fakesyscall.json); do
					grep "#define __NR_${j} " ${SRCDIR}/sysdeps/unix/sysv/linux/${i}/arch-syscall.h 2>/dev/null || true
					sed -i "/#define __NR_${j} /d" ${SRCDIR}/sysdeps/unix/sysv/linux/${i}/arch-syscall.h 2>/dev/null || true
				done
			} >> "${header_disabled}"

			{
				echo -e "\n#define DISABLED_SYSCALL_WITH_FAKESYSCALL \\"
				local IFS=$'\n'
				for j in $(jq -r '. | keys | .[]' ${PATCHES_DIR}/fakesyscall.json); do
					local need_return=false
					for z in $(jq -r '."'${j}'" | .[]' ${PATCHES_DIR}/fakesyscall.json); do
						if grep -q "^#define __NR_${z} " "${header_disabled}" 2>/dev/null; then
							echo -e "\tcase __NR_${z}: \\"
							need_return=true
						elif [[ ${z} =~ ^[0-9]+$ ]]; then
							echo -e "\tcase ${z}: \\"
							need_return=true
						fi
					done
					[ "${need_return}" = "true" ] && echo -e "\t\treturn ${j}; \\"
				done
				unset IFS
			} >> "${header_disabled}"

			sed -i '$ s| \\||' "${header_disabled}"
		done
	fi

	# 7. Replacing hard paths
	echo "[+] Updating device path mappings..."
	for i in /dev/stderr:/proc/self/fd/2 \
		/dev/stdin:/proc/self/fd/0 \
		/dev/stdout:/proc/self/fd/1; do
		for j in $(grep -s -r -l "${i%%:*}" "${SRCDIR}" 2>/dev/null); do
			sed -i "s|${i%%:*}|${i//*:}|g" "${j}"
		done
	done

	# 8. Adding version info to version.h
	if [ -f "${SRCDIR}/version.h" ]; then
		sed -i "s/${PKG_VERSION}/${PKG_VERSION}-${APP_PACKAGE}/" "${SRCDIR}/version.h" 2>/dev/null || true
	fi
}

# ------------------------------------------------------------------------------
# Step 4: Configure Step
# ------------------------------------------------------------------------------
configure_step() {
	echo "[+] Running Configure Step (Host: ${BUILD_PLATFORM} -> Target: ${HOST_PLATFORM})..."
	mkdir -p "${BUILDDIR}"
	cd "${BUILDDIR}"

	echo "slibdir=${LIBDIR}" > configparms
	echo "rtlddir=${LIBDIR}" >> configparms
	echo "sbindir=${BINDIR}" >> configparms
	echo "rootsbindir=${BINDIR}" >> configparms

	local _configure_flags=()
	case "${TARGET_ARCH}" in
		"aarch64") _configure_flags+=(--enable-memory-tagging --enable-fortify-source);;
		"arm"|"i686") _configure_flags+=(--enable-fortify-source);;
		"x86_64") _configure_flags+=(--enable-cet);;
	esac

	local _pkgversion="GNU libc for Wingo Android"
	if [ -n "${APP_PACKAGE}" ]; then
		_pkgversion+="/${APP_PACKAGE}"
	fi

	CFLAGS="${CFLAGS/-Wp,-D_FORTIFY_SOURCE=2 / }"
	CFLAGS="${CFLAGS/-Werror / }"

	CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" \
	${SRCDIR}/configure \
		--prefix="${PREFIX}" \
		--libdir="${LIBDIR}" \
		--libexecdir="${LIBDIR}" \
		--includedir="${INCLUDEDIR}" \
		--host="${HOST_PLATFORM}" \
		--build="${BUILD_PLATFORM}" \
		--target="${HOST_PLATFORM}" \
		--with-pkgversion="${_pkgversion}" \
		--enable-bind-now \
		--enable-fortify-source \
		--disable-multi-arch \
		--enable-stack-protector=strong \
		--enable-systemtap \
		--disable-nscd \
		--disable-profile \
		--disable-werror \
		--disable-default-pie \
		"${_configure_flags[@]}"
}

# ------------------------------------------------------------------------------
# Step 5: Compile Step
# ------------------------------------------------------------------------------
make_step() {
	echo "[+] Compiling Glibc using cross-compiler ${CC}..."
	cd "${BUILDDIR}"
	make -j$(nproc) -O
}

# ------------------------------------------------------------------------------
# Helper Function: Build libsyscall_without_fsc.so
# ------------------------------------------------------------------------------
make_syscall_without_fsc() {
	local libname="libsyscall_without_fsc.so"
	local target_lib_dir="${DESTDIR:-}${LIBDIR}"
	echo "[+] Compiling '${libname}'..."
	if [ -f "${PATCHES_DIR}/syscall.c" ]; then
		mkdir -p "${target_lib_dir}"
		${CC} "${PATCHES_DIR}/syscall.c" -o "${target_lib_dir}/${libname}" \
			-shared -fPIC -DWITHOUT_FAKESYSCALL || echo "[!] Failed to compile ${libname}"
		echo "[+] '${libname}' compiled successfully."
	fi
}

# ------------------------------------------------------------------------------
# Step 6: Install Step
# ------------------------------------------------------------------------------
install_step() {
	echo "[+] Installing Glibc to ${PREFIX}..."
	cd "${BUILDDIR}"

	rm -rf "${DESTDIR:-}${INCLUDEDIR}/gnu"

	make install DESTDIR="${DESTDIR:-}"

	rm -f "${DESTDIR:-}${PREFIX}/etc/ld.so.cache"
	rm -f "${DESTDIR:-}${BINDIR}/"{tzselect,zdump,zic}

	install -dm755 "${DESTDIR:-}${LIBDIR}/tmpfiles.d"
	[ -f "${SRCDIR}/nscd/nscd.conf" ] && install -m644 "${SRCDIR}/nscd/nscd.conf" "${DESTDIR:-}${PREFIX}/etc/nscd.conf"
	[ -f "${SRCDIR}/nscd/nscd.tmpfiles" ] && install -m644 "${SRCDIR}/nscd/nscd.tmpfiles" "${DESTDIR:-}${LIBDIR}/tmpfiles.d/nscd.conf"
	[ -f "${SRCDIR}/posix/gai.conf" ] && install -m644 "${SRCDIR}/posix/gai.conf" "${DESTDIR:-}${PREFIX}/etc/gai.conf"

	if [ -f "${PATCHES_DIR}/locale-gen" ]; then
		install -m755 "${PATCHES_DIR}/locale-gen" "${DESTDIR:-}${BINDIR}/locale-gen"
	fi

	if [ -f "${PATCHES_DIR}/locale.gen.txt" ]; then
		install -m644 "${PATCHES_DIR}/locale.gen.txt" "${DESTDIR:-}${PREFIX}/etc/locale.gen"
		if [ -f "${SRCDIR}/localedata/SUPPORTED" ]; then
			sed -e '1,3d' -e 's|/| |g' -e 's|\\| |g' -e 's|^|#|g' \
				"${SRCDIR}/localedata/SUPPORTED" >> "${DESTDIR:-}${PREFIX}/etc/locale.gen"
		fi
	fi

	if [ -f "${SRCDIR}/localedata/SUPPORTED" ]; then
		mkdir -p "${DESTDIR:-}${PREFIX}/share/i18n"
		sed -e '1,3d' -e 's|/| |g' -e 's| \\||g' \
			"${SRCDIR}/localedata/SUPPORTED" > "${DESTDIR:-}${PREFIX}/share/i18n/SUPPORTED"
	fi

	install -dm755 "${DESTDIR:-}${LIBDIR}/locale"
	if [ -d "${SRCDIR}/localedata" ]; then
		make -C "${SRCDIR}/localedata" objdir="${BUILDDIR}" \
			SUPPORTED-LOCALES="C.UTF-8/UTF-8 en_US.UTF-8/UTF-8" install-locale-files DESTDIR="${DESTDIR:-}" || true
		sed -i '/#C\.UTF-8 /d' "${DESTDIR:-}${PREFIX}/etc/locale.gen" 2>/dev/null || true
	fi

	[ -f "${PATCHES_DIR}/sdt.h" ] && install -Dm644 "${PATCHES_DIR}/sdt.h" "${DESTDIR:-}${INCLUDEDIR}/sys/sdt.h"
	[ -f "${PATCHES_DIR}/sdt-config.h" ] && install -Dm644 "${PATCHES_DIR}/sdt-config.h" "${DESTDIR:-}${INCLUDEDIR}/sys/sdt-config.h"

	local ld_so_path
	ld_so_path=$(find "${DESTDIR:-}${LIBDIR}" -name "ld-linux*.so*" | head -n 1)
	if [ -n "$ld_so_path" ]; then
		ln -sfr "$ld_so_path" "${DESTDIR:-}${BINDIR}/ld.so"
		ln -sfr "$ld_so_path" "${DESTDIR:-}${LIBDIR}/ld.so"
	fi

	make_syscall_without_fsc

	echo "[+] Installation completed successfully!"
}

# ------------------------------------------------------------------------------
# Step 7: Compression Step
# ------------------------------------------------------------------------------
compress_step() {
	echo "[+] Compiling and compressing rootfs archive..."
	local archive_name="${BUILDER_DIR}/wingo-rootfs-${TARGET_ARCH}.tar.xz"

	local target_dir="${DESTDIR:-}${PREFIX}"
	if [ ! -d "${target_dir}" ]; then
		echo "[-] Error: Directory '${target_dir}' does not exist for compression."
		return 1
	fi

	cd "${target_dir}"
	tar -cJf "${archive_name}" .

	echo "[+] RootFS compressed successfully: ${archive_name}"
}

# ------------------------------------------------------------------------------
# Execution Pipeline
# ------------------------------------------------------------------------------
download_package_step
extract_package_step
patch_package_step
pre_configure_step
configure_step
make_step
install_step
compress_step
