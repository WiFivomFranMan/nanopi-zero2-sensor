#!/usr/bin/env bash

set -euo pipefail

ARMBIAN_REPO="https://github.com/armbian/build.git"
ARMBIAN_DIR="build"
BOARD="nanopi-zero2"

# Version of the NanoPi Zero2 sensor image (WLAN Commander fork numbering)
IMAGE_VERSION="1.1.0-wc1"

# Which kernel to build. Set WC_BRANCH to override:
#   vendor        Rockchip 6.1 BSP kernel + Intel backport-iwlwifi (the 1.0.x images)
#   edge          mainline linux-7.2.y (Armbian "edge")
#   bleedingedge  mainline v7.3-rc tag (Armbian "bleedingedge")  <- default
# "current" (6.18 LTS) is refused: its iwlwifi accepts BE200 firmware up to core 99 only,
# and no such file exists any more, so the card can never come up on it.
BRANCH="${WC_BRANCH:-bleedingedge}"

# The Armbian framework is pinned PER BRANCH. The vendor image keeps the tag it was
# validated on; the mainline branches need a tag where edge=7.2 / bleedingedge=7.3
# (rockchip64_common.inc moved there on 2026-08-30; v26.5.1 still means 7.0 / 7.1, both
# EOL). Trunk tags get pruned by Armbian, so the commit SHA is what is really checked out
# and the tag is documentation.
case "${BRANCH}" in
    vendor)
        ARMBIAN_TAG="v26.5.1"
        ARMBIAN_SHA="8de11a017f7f05a82c77850f8322928cb6a3b70c"
        EXTENSIONS="iwlwifi-backport"
        EXTRAWIFI_FLAG="yes"   # Armbian default; keeps the vendor build identical to 1.0.x
        ;;
    edge | bleedingedge)
        ARMBIAN_TAG="v26.11.0-trunk.30"
        ARMBIAN_SHA="ee00ac7c8a7ef07d5f258acb787638f283c00a0a"
        EXTENSIONS="wifi7-mainline"
        # Armbian's bundled out-of-tree Wi-Fi drivers (uwe5622, rtl8852bs, rtl8723ds, rtl8189es/fs,
        # rtl8192eu, ...) have no upper kernel-version bound and fail to compile against 7.3's
        # cfg80211 API (first build, 2026-09-02). Every driver this image needs is in-tree.
        EXTRAWIFI_FLAG="no"
        ;;
    current)
        echo "ERROR: WC_BRANCH=current (6.18) cannot load the BE200 core-10x firmware; use edge or bleedingedge." >&2
        exit 1
        ;;
    *)
        echo "ERROR: unknown WC_BRANCH='${BRANCH}' (vendor|edge|bleedingedge)." >&2
        exit 1
        ;;
esac

# Armbian caches U-Boot/kernel artifacts by hash and will happily reuse a cached edge
# U-Boot for this board that once shipped with a 0-byte FDT (armbian/build#9508, open).
# Pass WC_IGNORE_CACHE=yes on the first mainline build; afterwards the offline image
# check (dumpimage -l on u-boot.itb) is the gate.
IGNORE_CACHE="${WC_IGNORE_CACHE:-no}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${SCRIPT_DIR}/${ARMBIAN_DIR}/.git" ]]; then
    echo "Cloning Armbian build repository..."
    git clone "${ARMBIAN_REPO}" "${SCRIPT_DIR}/${ARMBIAN_DIR}"
fi

cd "${SCRIPT_DIR}/${ARMBIAN_DIR}"

echo "Fetching tags and main..."
git fetch origin --tags --force
git fetch origin main

echo "Checking out ${ARMBIAN_TAG} (${ARMBIAN_SHA})..."
if git rev-parse -q --verify "refs/tags/${ARMBIAN_TAG}^{commit}" > /dev/null; then
    tag_sha="$(git rev-parse "refs/tags/${ARMBIAN_TAG}^{commit}")"
    if [[ "${tag_sha}" != "${ARMBIAN_SHA}" ]]; then
        echo "WARNING: tag ${ARMBIAN_TAG} now points at ${tag_sha}, not ${ARMBIAN_SHA}; using the SHA." >&2
    fi
else
    echo "Tag ${ARMBIAN_TAG} is gone (Armbian prunes trunk tags); checking out the SHA directly."
fi
git checkout --force "${ARMBIAN_SHA}"

echo "Copying userpatches..."
rsync -a --delete \
    "${SCRIPT_DIR}/userpatches/" \
    "${SCRIPT_DIR}/${ARMBIAN_DIR}/userpatches/"

# Never delete a previous image: the last known-good vendor image has already been lost
# once to an `rm -f` here. Move whatever is in the way into an archive directory.
OUTPUT_DIR="${SCRIPT_DIR}/${ARMBIAN_DIR}/output/images"
mkdir -p "${OUTPUT_DIR}/archive"
shopt -s nullglob
previous=("${OUTPUT_DIR}"/*.img*)
shopt -u nullglob
if (( ${#previous[@]} > 0 )); then
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${OUTPUT_DIR}/archive/${stamp}"
    echo "Archiving ${#previous[@]} previous image file(s) to archive/${stamp}/..."
    mv "${previous[@]}" "${OUTPUT_DIR}/archive/${stamp}/"
fi

echo "Starting NanoPi Zero2 build (BRANCH=${BRANCH}, extensions=${EXTENSIONS})..."
# INCLUDE_HOME_DIR=yes: Armbian excludes /home/* from the final image otherwise, which drops
# /home/pi while leaving the account in /etc/passwd (sshd: "Could not chdir to home directory").
./compile.sh \
    PREFER_DOCKER=no \
    BOARD="${BOARD}" \
    BRANCH="${BRANCH}" \
    RELEASE=trixie \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    ENABLE_EXTENSIONS="${EXTENSIONS}" \
    INCLUDE_HOME_DIR=yes \
    EXTRAWIFI="${EXTRAWIFI_FLAG}" \
    ARTIFACT_IGNORE_CACHE="${IGNORE_CACHE}"

echo "Renaming build artifacts..."
NEW_BASENAME="intuitibits-nanopi-zero2-v${IMAGE_VERSION}-${BRANCH}"

IMAGE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "*.img" -type f -printf "%T@ %p\n" \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-)

if [[ -z "${IMAGE}" ]]; then
    echo "ERROR: No image found in ${OUTPUT_DIR}."
    exit 1
fi

BASE="${IMAGE%.img}"

mv "${IMAGE}" "${OUTPUT_DIR}/${NEW_BASENAME}.img"

if [[ -f "${BASE}.img.txt" ]]; then
    mv "${BASE}.img.txt" "${OUTPUT_DIR}/${NEW_BASENAME}.img.txt"
fi

# The raw .img.sha (if any) covers the uncompressed image, which we don't
# ship (GitHub Releases caps individual assets at 2GB, well under a raw SD
# card image); it's superseded by the compressed image's own checksum below.
rm -f "${BASE}.img.sha"

# Provenance: which fork commit, which Armbian commit, which kernel branch produced this.
{
    echo "image=${NEW_BASENAME}"
    echo "fork_commit=$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "fork_dirty=$(git -C "${SCRIPT_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "armbian_tag=${ARMBIAN_TAG}"
    echo "armbian_commit=${ARMBIAN_SHA}"
    echo "branch=${BRANCH}"
    echo "extensions=${EXTENSIONS}"
    echo "extrawifi=${EXTRAWIFI_FLAG}"
    echo "artifact_ignore_cache=${IGNORE_CACHE}"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${OUTPUT_DIR}/${NEW_BASENAME}.build-info"

echo "Compressing image..."
IMAGE_PATH="${OUTPUT_DIR}/${NEW_BASENAME}.img"
COMPRESSED_PATH="${IMAGE_PATH}.xz"
TEMP_COMPRESSED_PATH="${COMPRESSED_PATH}.tmp"

# Write via stdout so xz doesn't try to copy the raw image's group ownership.
# The temporary file also prevents a failed build from leaving a partial .xz.
rm -f "${TEMP_COMPRESSED_PATH}"
xz -T0 -c "${IMAGE_PATH}" > "${TEMP_COMPRESSED_PATH}"
mv "${TEMP_COMPRESSED_PATH}" "${COMPRESSED_PATH}"
rm -f "${IMAGE_PATH}"

echo "Checksumming compressed image..."
( cd "${OUTPUT_DIR}" && sha256sum "${NEW_BASENAME}.img.xz" > "${NEW_BASENAME}.img.xz.sha" )

echo
echo "Build complete."
echo
echo "Artifacts:"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img.xz"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img.xz.sha"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img.txt"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.build-info"
