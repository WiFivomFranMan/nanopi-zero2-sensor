#!/usr/bin/env bash
#
# Builds Intel backport-iwlwifi (BE200 support) inside the Armbian chroot.
# Enable with: ENABLE_EXTENSIONS=iwlwifi-backport

function extension_prepare_config__iwlwifi_backport() {
	IWLWIFI_BACKPORT_REPOSITORY="${IWLWIFI_BACKPORT_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/backport-iwlwifi.git}"
	IWLWIFI_BACKPORT_REF="${IWLWIFI_BACKPORT_REF:-release/core105}"
	IWLWIFI_FIRMWARE_REPOSITORY="${IWLWIFI_FIRMWARE_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/linux-firmware.git}"
	IWLWIFI_FIRMWARE_REF="${IWLWIFI_FIRMWARE_REF:-}"
	IWLWIFI_BUILD_JOBS="${IWLWIFI_BUILD_JOBS:-${CTHREADS:-$(nproc)}}"
	display_alert \
		"Intel BE200 support enabled" \
		"backport-iwlwifi will be compiled in-chroot (ref: ${IWLWIFI_BACKPORT_REF})" \
		"info"
}

# Translate a plain branch name / commit hash (our own env var convention)
# into Armbian's fetch_from_repo ref DSL ("branch:x", "commit:x", "head").
function _iwlwifi_fetch_ref() {
	local raw="$1"
	if [[ -z "${raw}" ]]; then
		echo "head"
	elif [[ "${raw}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
		echo "commit:${raw}"
	else
		echo "branch:${raw}"
	fi
}

function extension_finish_config__install_kernel_headers_for_iwlwifi_backport() {
	INSTALL_HEADERS=yes
}

# Vendor defconfig ships CFG80211/MAC80211 built-in; force them to modules
# so backport-iwlwifi's own cfg80211.ko/mac80211.ko can link without a
# "exported twice" modpost conflict against vmlinux.
function custom_kernel_config__iwlwifi_backport_wifi_as_modules() {
	opts_m+=("CFG80211")
	opts_m+=("MAC80211")
}

function post_install_kernel_debs__500_iwlwifi_backport() {
	display_alert \
		"Building Intel BE200 driver (backport-iwlwifi)" \
		"" \
		"info"
	[[ -d "${SDCARD}" ]] || exit_with_error \
		"Target root filesystem is unavailable" \
		"SDCARD=${SDCARD:-unset}"

	local target_kernel_version
	target_kernel_version="$(
		find "${SDCARD}/lib/modules" \
			-mindepth 1 \
			-maxdepth 1 \
			-type d \
			-printf '%f\n' |
			sort -V |
			tail -n 1
	)"
	[[ -n "${target_kernel_version}" ]] || exit_with_error \
		"Could not find an installed kernel" \
		"${SDCARD}/lib/modules/* is empty -- did the kernel deb actually install?"
	display_alert "Target kernel" "${target_kernel_version}" "info"

	if [[ ! -e "${SDCARD}/lib/modules/${target_kernel_version}/build" ]]; then
		display_alert \
			"Kernel headers symlink not present yet" \
			"will attempt to self-heal inside chroot" \
			"warn"
	fi

	# Fetch (or update) backport-iwlwifi and linux-firmware into Armbian's
	# persistent host-side source cache (${SRC}/cache/sources/...), instead
	# of cloning them from the network on every build. fetch_from_repo only
	# re-fetches when the remote ref has actually moved.
	local build_dir="${SDCARD}/tmp/iwlwifi-build"
	rm -rf "${build_dir}"
	mkdir -p "${build_dir}"

	display_alert "Fetching backport-iwlwifi (cached)" "${IWLWIFI_BACKPORT_REF}" "info"
	fetch_from_repo "${IWLWIFI_BACKPORT_REPOSITORY}" "iwlwifi-backport" \
		"$(_iwlwifi_fetch_ref "${IWLWIFI_BACKPORT_REF}")" "no"
	rsync -a "${SRC}/cache/sources/iwlwifi-backport/" "${build_dir}/backport-iwlwifi/"

	display_alert "Fetching linux-firmware (cached)" "${IWLWIFI_FIRMWARE_REF:-head}" "info"
	fetch_from_repo "${IWLWIFI_FIRMWARE_REPOSITORY}" "linux-firmware" \
		"$(_iwlwifi_fetch_ref "${IWLWIFI_FIRMWARE_REF}")" "no"

	# Only copy the BE200 firmware files into the chroot, not the whole
	# (multi-gigabyte) linux-firmware working tree.
	mkdir -p "${build_dir}/linux-firmware"
	find "${SRC}/cache/sources/linux-firmware" \
		-type f \( -name 'iwlwifi-gl-c0-fm-c0-*.ucode' -o -name 'iwlwifi-gl-c0-fm-c0*.pnvm' \) \
		-exec cp -a {} "${build_dir}/linux-firmware/" \;

	local target_script="${SDCARD}/tmp/build-iwlwifi-backport.sh"
	cat > "${target_script}" <<'IWLWIFI_TARGET_SCRIPT'
set -euo pipefail

echo "Building for kernel: ${TARGET_KERNEL_VERSION}"
kernel_modules_dir="/lib/modules/${TARGET_KERNEL_VERSION}"
kernel_build_dir="${kernel_modules_dir}/build"

echo "Installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	git build-essential bc flex bison \
	libssl-dev libelf-dev pkg-config \
	kmod rsync dwarves pahole ca-certificates

# Self-heal: headers postinst can no-op if gcc/make weren't installed yet.
if [[ ! -f "${kernel_build_dir}/Makefile" ]]; then
	echo "Kernel headers build dir incomplete; retrying headers postinst"
	dpkg --configure -a || true
	if [[ ! -f "${kernel_build_dir}/Makefile" ]]; then
		headers_src_dir="$(find /usr/src -maxdepth 1 -type d -iname "linux-headers-${TARGET_KERNEL_VERSION}*" | head -n1)"
		if [[ -n "${headers_src_dir}" ]]; then
			echo "Falling back to manual: make -C ${headers_src_dir} scripts modules_prepare"
			make -C "${headers_src_dir}" -s scripts modules_prepare
			[[ -e "${kernel_build_dir}" ]] || ln -s "${headers_src_dir}" "${kernel_build_dir}"
		fi
	fi
fi
[[ -f "${kernel_build_dir}/Makefile" ]] || {
	echo "Could not find target kernel headers at ${kernel_build_dir}" >&2
	exit 1
}

BUILD_DIR="/tmp/iwlwifi-build"
BACKPORT_DIR="${BUILD_DIR}/backport-iwlwifi"
FIRMWARE_DIR="${BUILD_DIR}/linux-firmware"

# Sources are already fetched (from a persistent host-side cache) and
# copied in here by the host-side half of this hook, before chroot_sdcard.
[[ -d "${BACKPORT_DIR}/.git" ]] || {
	echo "backport-iwlwifi sources missing at ${BACKPORT_DIR}" >&2
	exit 1
}

cd "${BACKPORT_DIR}"
echo "Using backport-iwlwifi commit:"
git rev-parse HEAD

# Stable 6.1.y backported timer_delete(), but backport-iwlwifi still guards its
# own shim with LINUX_VERSION_IS_LESS(6,2,0). It carries LINUX_VERSION_IN_RANGE
# exclusions for the sibling timer_delete_sync (5.4.x/5.10.x/5.15.x) but none for
# 6.1.y, so against such a kernel every compilation unit fails with:
#   error: static declaration of 'timer_delete' follows non-static declaration
# Probe the kernel headers instead of hardcoding a stable version, so this
# adapts to whatever Armbian ships.
if grep -qE '^[[:space:]]*extern[[:space:]]+int[[:space:]]+timer_delete[[:space:]]*\(' \
	"${kernel_build_dir}/include/linux/timer.h" 2>/dev/null; then
	echo "Kernel declares timer_delete(); disabling backport shim"
	TIMER_H="${BACKPORT_DIR}/backport-include/linux/timer.h"
	awk '
	{ L[NR] = $0 }
	END {
		decl = 0
		for (i = 1; i <= NR; i++)
			if (L[i] ~ /^static inline int timer_delete\(struct timer_list/) { decl = i; break }
		if (decl == 0) { for (i = 1; i <= NR; i++) print L[i]; exit }
		g = 0
		for (i = decl - 1; i >= 1; i--) {
			t = L[i]; sub(/^[ \t]+/, "", t)
			if (t ~ /^#if /) { g = i; break }
		}
		for (i = 1; i <= NR; i++) {
			if (i == g) {
				print "/* Kernel provides timer_delete(); shim disabled by the image build. */"
				print "#if 0"
			} else if (i > g && i < decl) {
				continue
			} else print L[i]
		}
	}' "${TIMER_H}" > "${TIMER_H}.new" && mv "${TIMER_H}.new" "${TIMER_H}"
fi

make defconfig-iwlwifi-public \
	KLIB="${kernel_modules_dir}" \
	KLIB_BUILD="${kernel_build_dir}"

# Diagnostic: confirm CFG80211/MAC80211 actually ended up as modules in
# the kernel this was built against, before wasting time on a build
# that's doomed to hit the "exported twice" modpost conflict again.
echo "---- CFG80211/MAC80211 in ${kernel_build_dir}/.config ----"
grep -E '^CONFIG_(CFG80211|MAC80211)=' "${kernel_build_dir}/.config" || echo "(no match found)"
echo "-----------------------------------------------------------"
if grep -qE '^CONFIG_(CFG80211|MAC80211)=y' "${kernel_build_dir}/.config" 2>/dev/null; then
	echo "CFG80211 and/or MAC80211 are built into vmlinux (=y), not modules." >&2
	echo "The custom_kernel_config hook did not take effect for this kernel build." >&2
	exit 1
fi

# del_timer_sync() was renamed timer_delete_sync() in v6.2; detect which
# name(s) this kernel's headers actually declare rather than guessing
# from the version number (vendor kernels backport APIs selectively).
timer_header="${kernel_build_dir}/include/linux/timer.h"
has_old_name="no"
has_new_name="no"
[[ -f "${timer_header}" ]] && grep -q '\bdel_timer_sync\b' "${timer_header}" && has_old_name="yes"
[[ -f "${timer_header}" ]] && grep -q '\btimer_delete_sync\b' "${timer_header}" && has_new_name="yes"
patch_from=""
patch_to=""
if [[ "${has_old_name}" == "yes" && "${has_new_name}" == "yes" ]]; then
	echo "Target kernel provides both del_timer_sync() and timer_delete_sync(); no timer API patch needed"
elif [[ "${has_new_name}" == "yes" && "${has_old_name}" == "no" ]]; then
	echo "Target kernel only provides timer_delete_sync(); patching del_timer_sync() call sites"
	patch_from='del_timer_sync'
	patch_to='timer_delete_sync'
elif [[ "${has_old_name}" == "yes" && "${has_new_name}" == "no" ]]; then
	echo "Target kernel only provides del_timer_sync(); patching timer_delete_sync() call sites"
	patch_from='timer_delete_sync'
	patch_to='del_timer_sync'
else
	echo "Could not determine timer API from ${timer_header}; skipping timer patch (build may fail)" >&2
fi
if [[ -n "${patch_from}" ]]; then
	mapfile -d '' timer_files < <(
		grep -RIlZ --exclude-dir=.git --include='*.c' --include='*.h' "\\b${patch_from}\\b" . || true
	)
	if (( ${#timer_files[@]} > 0 )); then
		printf 'Patching %d file(s): %s -> %s\n' "${#timer_files[@]}" "${patch_from}" "${patch_to}"
		sed -i "s/\\b${patch_from}(/${patch_to}(/g" "${timer_files[@]}"
		if grep -RIn --exclude-dir=.git --include='*.c' --include='*.h' "\\b${patch_from}\\b" .; then
			echo "${patch_from} patch did not apply completely" >&2
			exit 1
		fi
	else
		echo "No ${patch_from} references found; no patch required"
	fi
fi
# Strip backport's own compat shim where it redefines a symbol the
# target kernel already declares natively.
backport_timer_header="backport-include/linux/timer.h"
if [[ -f "${backport_timer_header}" ]]; then
	for sym in timer_delete timer_delete_sync timer_shutdown timer_shutdown_sync; do
		if grep -qE "\\bextern\\b.*\\b${sym}\\s*\\(" "${timer_header}" 2>/dev/null &&
			grep -qE "static inline .*\\b${sym}\\s*\\(" "${backport_timer_header}" 2>/dev/null; then
			echo "Target kernel already declares ${sym}() natively; removing backport-iwlwifi's conflicting compat wrapper"
			sed -i "/static inline [a-zA-Z_ ]*\\b${sym}\\s*(/,/^}/d" "${backport_timer_header}"
		fi
	done
fi

echo "Building backport-iwlwifi for ${TARGET_KERNEL_VERSION}"
make clean KLIB="${kernel_modules_dir}" KLIB_BUILD="${kernel_build_dir}"
make -j"${IWLWIFI_BUILD_JOBS}" \
	KLIB="${kernel_modules_dir}" \
	KLIB_BUILD="${kernel_build_dir}"
# KLIB="/" here, not kernel_modules_dir: backport's install rule appends
# /lib/modules/<version> onto KLIB itself, so passing kernel_modules_dir
# (which already ends in /lib/modules/<version>) doubles the path.
#
# backport's install rule also calls depmod directly under bare `uname -r`,
# which inside the chroot resolves to the build host's kernel, not the
# target's, and fails. Neither DEPMOD=true nor a PATH shadow intercepted
# it, meaning it's called by absolute path -- so replace the actual
# depmod binary(ies) on disk for the duration of `make install`, then
# restore them and run our own explicit depmod with the correct version.
# Resolve to canonical real paths first and dedup on that -- on
# usr-merged systems /sbin/depmod and /usr/sbin/depmod are the same
# physical file via a directory symlink, and backing it up twice would
# back up the already-stubbed copy the second time, losing the original.
declare -a real_depmod_paths=()
for p in /sbin/depmod /usr/sbin/depmod /usr/bin/depmod "$(command -v depmod 2>/dev/null || true)"; do
	[[ -n "${p}" ]] || continue
	rp="$(readlink -f "${p}" 2>/dev/null || true)"
	[[ -n "${rp}" && -f "${rp}" ]] || continue
	dup=0
	for seen in "${real_depmod_paths[@]:-}"; do [[ "${seen}" == "${rp}" ]] && dup=1 && break; done
	(( dup )) || real_depmod_paths+=("${rp}")
done
for rp in "${real_depmod_paths[@]}"; do
	cp -a "${rp}" "${rp}.iwlwifi-real"
	printf '#!/bin/sh\nexit 0\n' > "${rp}"
	chmod +x "${rp}"
done
make install \
	KLIB="/" \
	KLIB_BUILD="${kernel_build_dir}"
for rp in "${real_depmod_paths[@]}"; do
	mv -f "${rp}.iwlwifi-real" "${rp}"
done
depmod -a "${TARGET_KERNEL_VERSION}"

mkdir -p /lib/firmware
mapfile -d '' firmware_files < <(find "${FIRMWARE_DIR}" -type f -name 'iwlwifi-gl-c0-fm-c0-*.ucode' -print0)
(( ${#firmware_files[@]} > 0 )) || { echo "No BE200 ucode files found in linux-firmware" >&2; exit 1; }
mapfile -d '' pnvm_files < <(find "${FIRMWARE_DIR}" -type f -name 'iwlwifi-gl-c0-fm-c0*.pnvm' -print0)
cp -av "${firmware_files[@]}" /lib/firmware/
(( ${#pnvm_files[@]} > 0 )) && cp -av "${pnvm_files[@]}" /lib/firmware/

echo "Verifying install"
find "${kernel_modules_dir}" -name 'iwlwifi.ko*' | grep -q . || { echo "iwlwifi.ko not found after install" >&2; exit 1; }
find "${kernel_modules_dir}" -name 'iwlmvm.ko*' | grep -q . || { echo "iwlmvm.ko not found after install" >&2; exit 1; }
find /lib/firmware -name 'iwlwifi-gl-c0-fm-c0-*.ucode' | grep -q . || { echo "BE200 firmware not found after install" >&2; exit 1; }

echo "Removing build tooling"
apt-get purge -y \
	git build-essential bc flex bison \
	libssl-dev libelf-dev pkg-config dwarves pahole
apt-get autoremove -y
rm -rf "${BUILD_DIR}" /var/lib/apt/lists/*

echo "backport-iwlwifi build complete for ${TARGET_KERNEL_VERSION}"
IWLWIFI_TARGET_SCRIPT

	chroot_sdcard "TARGET_KERNEL_VERSION=${target_kernel_version} \
		IWLWIFI_BUILD_JOBS=${IWLWIFI_BUILD_JOBS} \
		bash /tmp/build-iwlwifi-backport.sh" ||
		exit_with_error \
			"Failed to build Intel BE200 support" \
			"${target_kernel_version}"

	rm -f "${target_script}"
	display_alert "Intel BE200 driver built and installed" "${target_kernel_version}" "info"
}
