#!/usr/bin/env bash

set -euo pipefail

ARMBIAN_REPO="https://github.com/armbian/build.git"
ARMBIAN_DIR="build"
ARMBIAN_TAG="v26.5.1"

# Version of the Intuitibits NanoPi Zero2 sensor image
IMAGE_VERSION="1.0.1"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${SCRIPT_DIR}/${ARMBIAN_DIR}/.git" ]]; then
    echo "Cloning Armbian build repository..."
    git clone "${ARMBIAN_REPO}" "${SCRIPT_DIR}/${ARMBIAN_DIR}"
fi

cd "${SCRIPT_DIR}/${ARMBIAN_DIR}"

echo "Fetching tags..."
git fetch origin --tags --force

echo "Checking out ${ARMBIAN_TAG}..."
git checkout --force "${ARMBIAN_TAG}"

echo "Copying userpatches..."
rsync -a --delete \
    "${SCRIPT_DIR}/userpatches/" \
    "${SCRIPT_DIR}/${ARMBIAN_DIR}/userpatches/"

echo "Cleaning previous images..."
rm -f "${SCRIPT_DIR}/${ARMBIAN_DIR}/output/images/"*.img*

echo "Starting NanoPi Zero2 build..."
./compile.sh \
    BOARD=nanopi-zero2 \
    BRANCH=vendor \
    RELEASE=trixie \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    ENABLE_EXTENSIONS=iwlwifi-backport \
    INCLUDE_HOME_DIR=yes

echo "Renaming build artifacts..."
OUTPUT_DIR="${SCRIPT_DIR}/${ARMBIAN_DIR}/output/images"
NEW_BASENAME="intuitibits-nanopi-zero2-v${IMAGE_VERSION}"

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
