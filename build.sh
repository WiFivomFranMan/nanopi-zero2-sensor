#!/usr/bin/env bash

set -euo pipefail

ARMBIAN_REPO="https://github.com/armbian/build.git"
ARMBIAN_DIR="build"
ARMBIAN_TAG="v26.5.1"

# Version of the Intuitibits NanoPi Zero2 sensor image
IMAGE_VERSION="1.0.0"

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

if [[ -f "${BASE}.img.sha" ]]; then
    mv "${BASE}.img.sha" "${OUTPUT_DIR}/${NEW_BASENAME}.img.sha"
    # The checksum file records the pre-rename filename internally; fix it up
    # so `shasum -c` works against the renamed .img without extra steps.
    sed -i.bak -E "s/[^ ]+\.img\$/${NEW_BASENAME}.img/" "${OUTPUT_DIR}/${NEW_BASENAME}.img.sha"
    rm -f "${OUTPUT_DIR}/${NEW_BASENAME}.img.sha.bak"
fi

if [[ -f "${BASE}.img.txt" ]]; then
    mv "${BASE}.img.txt" "${OUTPUT_DIR}/${NEW_BASENAME}.img.txt"
fi

echo
echo "Build complete."
echo
echo "Artifacts:"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img.sha"
echo "  ${OUTPUT_DIR}/${NEW_BASENAME}.img.txt"
