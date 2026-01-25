#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration ---
SECONDS=0
USER="rsuntk"
HOSTNAME="kernel-worker"
DEVICE_TARGET=${DEVICE_TARGET:-"X01BD"}
TC_DIR="$HOME/gcc-14.2.0-nolibc"
OUT_DIR="$(pwd)/out"

# Colors for output
export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1"
    exit 1
}

# --- Telegram Function ---
send_telegram() {
    local file="$1"
    local md5="$2"
    local time="$(($3 / 60))"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        msg "Telegram credentials missing. Skipping upload."
        return
    fi

    local msg_bar="Device: ${DEVICE_TARGET}
MD5: ${md5}

Build success in ${time} minutes"

    msg "Uploading to Telegram..."
    curl -s -F document=@$file "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=markdownv2" \
        -F caption="$msg_bar"
    msg "Upload completed!"
}

# --- Config Manipulation ---
disable_thermal_configs() {
    local defconfig_path="arch/arm64/configs/$1"
    msg "Applying thermal config patches to $1..."

    # List of configs to disable
    local configs=(
        CONFIG_QCOM_SPMI_TEMP_ALARM
        CONFIG_QTI_ADC_TM
        CONFIG_QTI_VIRTUAL_SENSOR
    )

    for cfg in "${configs[@]}"; do
        # Use sed to replace 'CONFIG_X=y' or 'CONFIG_X=m' with '# CONFIG_X is not set'
        sed -i "s/$cfg=y/# $cfg is not set/g" "$defconfig_path"
        sed -i "s/$cfg=m/# $cfg is not set/g" "$defconfig_path"
    done
    msg "Thermal configs disabled successfully."
}

# --- Dependencies Setup ---
setup_deps() {
    local deps_lists=(aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget)
    sudo apt update -y
    sudo apt install "${deps_lists[@]}" -y
    sudo aptitude install libssl-dev -y
}

# --- Toolchain Setup ---
setup_toolchain() {
    if [ ! -d "$TC_DIR" ]; then
        msg "Downloading GCC 14.2.0..."
        wget -q https://www.kernel.org/pub/tools/crosstool/files/bin/x86_64/14.2.0/x86_64-gcc-14.2.0-nolibc-aarch64-linux.tar.gz -O /tmp/gcc.tar.gz
        tar -xzf /tmp/gcc.tar.gz -C "$HOME"
        rm /tmp/gcc.tar.gz
        msg "Toolchain extracted to $TC_DIR"
    else
        msg "Toolchain already exists."
    fi
}

# --- Arguments Check ---
case "$1" in
"--setup-deps")
    setup_deps
    exit 0
    ;;
"--fetch-toolchains")
    setup_toolchain
    exit 0
    ;;
"--clean")
    msg "Cleaning..."
    rm -rf "$OUT_DIR" AnyKernel3
    make clean mrproper
    exit 0
    ;;
esac

[ -z "$DEVICE_TARGET" ] && error "DEVICE_TARGET cannot be empty!"

# --- Build Environment ---
export KBUILD_BUILD_USER=$USER
export KBUILD_BUILD_HOST=$HOSTNAME
export CROSS_COMPILE="$TC_DIR/aarch64-linux/bin/aarch64-linux-"
export LD_LIBRARY_PATH="$TC_DIR/aarch64-linux/lib"
export KCFLAGS="-w"
export LLVM_IAS=0
unset LLVM
DEFCONFIG="vendor/asus/${DEVICE_TARGET}_defconfig"

# --- Apply Config Patches ---
[ "$APPLY_WORKAROUND" = "true" ] && disable_thermal_configs "$DEFCONFIG"

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
ZIPNAME="rsuntk_$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT_HASH.zip"
BUILD_FLAGS="O=$OUT_DIR ARCH=arm64 -j$(nproc --all)"

# --- Build Process ---
if [ "$1" = "--regen-defconfig" ]; then
    mkdir -p "$OUT_DIR"
    make $BUILD_FLAGS "$DEFCONFIG"
    mv "$OUT_DIR/.config" "$OUT_DIR/defconfig"
    msg "Regen successful!"
    exit 0
fi

mkdir -p "$OUT_DIR"
msg "Starting compilation for $DEVICE_TARGET..."
make $BUILD_FLAGS "$DEFCONFIG"
make $BUILD_FLAGS Image.gz-dtb

# --- Packaging & Upload ---
if [ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]; then
    msg "Kernel compiled successfully! Packaging..."
    rm -rf AnyKernel3
    git clone -q https://github.com/rsuntk/AnyKernel3 --single-branch -b "$DEVICE_TARGET"
    cp "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" AnyKernel3/

    cd AnyKernel3
    zip -r9 "../$ZIPNAME" * -x '.git*' README.md '*placeholder'
    cd ..

    MD5_CHECK=$(md5sum "$ZIPNAME" | cut -d' ' -f1)

    # Trigger Telegram Upload
    send_telegram "$(pwd)/$ZIPNAME" "$MD5_CHECK" "$SECONDS"

    [ "$DO_CLEAN" = "true" ] && rm -rf AnyKernel3 "$OUT_DIR/arch/arm64/boot"

    echo -e "\n${green}Build completed in $((SECONDS / 60)) minute(s)!${reset}"
    msg "Output Zip: $ZIPNAME (md5: $MD5_CHECK)"
else
    error "Compilation failed!"
fi
