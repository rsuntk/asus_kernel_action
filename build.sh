#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# --- Configuration ---
SECONDS=0
USER="${USER:-rsuntk}"
HOSTNAME="${HOSTNAME:-github}"
DEVICE_TARGET=${DEVICE_TARGET:-"X01BD"}
TC_DIR="$HOME/clang-22"
OUT_DIR="$(pwd)/out"
COMP_LOG="$OUT_DIR/compilation.log"
KCFLAGS_W=${KCFLAGS_W:-"false"}
APPLY_WORKAROUND=${APPLY_WORKAROUND:-"false"}
DEFCONFIG="vendor/asus/${DEVICE_TARGET}_defconfig"

# --- Colors ---
export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() { echo -e "${red}ERROR: ${reset}$1" >&2; exit 1; }

# --- Config Manipulation ---
disable_thermal_configs() {
    local target_config="arch/arm64/configs/$1"
    
    if [ ! -f "$target_config" ]; then
        error "Defconfig $target_config not found!"
    fi

    msg "Applying thermal config patches to $1..."
    
    local configs=(
        CONFIG_QCOM_SPMI_TEMP_ALARM
        CONFIG_QTI_ADC_TM
        CONFIG_QTI_VIRTUAL_SENSOR
    )

    for cfg in "${configs[@]}"; do
        # Comment out the config if enabled
        sed -i "s/^$cfg=[ym]/# $cfg is not set/g" "$target_config"
    done
    msg "Thermal configs disabled."
}

# --- Telegram Notification ---
send_telegram() {
    local file="$1"
    local status="$4"
    
    if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        msg "Telegram credentials missing. Skipping upload."
        return
    fi

    local md5=$(md5sum "$file" | cut -d' ' -f1)
    local h=$((SECONDS / 3600)), m=$(( (SECONDS % 3600) / 60 )), s=$((SECONDS % 60))
    local cc_ver=$("$5" -v 2>&1 | grep -o 'clang version [0-9.]*' || echo "Unknown")

    local caption="Build <b>$status</b> in ${h}h ${m}m ${s}s%0ADevice: <code>$DEVICE_TARGET</code>%0Amd5: <code>$md5</code>%0ACompiler: $cc_ver"

    msg "Uploading to Telegram..."
    curl -s -F document=@"$file" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F "parse_mode=HTML" \
        -F "caption=$caption" > /dev/null
}

# --- Toolchain Logic ---
setup_toolchain() {
    if [[ "${UPDATE_TOOLCHAINS:-}" == "true" ]]; then
        msg "Cleaning old toolchain..."
        rm -rf "$TC_DIR" ~/.ccache
    fi

    if [ ! -d "$TC_DIR" ]; then
        msg "Downloading AOSP-LLVM..."
        mkdir -p "$TC_DIR"
        local url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/9b144befdfd93b90e02c663504fb9f4b95f9faf8/clang-r596125.tar.gz"
        curl -Ls "$url" | tar -xz -C "$TC_DIR"
    else
        msg "Toolchain already exists."
    fi
}

# --- Build Setup ---
prepare_env() {
    export KBUILD_BUILD_USER=$USER
    export KBUILD_BUILD_HOST=$HOSTNAME
    export PATH="$TC_DIR/bin:$PATH"
    export LD_LIBRARY_PATH="$TC_DIR/lib:$TC_DIR/lib64:${LD_LIBRARY_PATH:-}"
    export LLVM=1
    export LLVM_IAS=1
    
    [[ "$KCFLAGS_W" == "true" ]] && export KCFLAGS="-w"
    
    BUILD_ARGS=(
        O="$OUT_DIR"
        ARCH=arm64
        CC=clang
        NM=llvm-nm
        OBJCOPY=llvm-objcopy
        OBJDUMP=llvm-objdump
        STRIP=llvm-strip
        -j"$(nproc --all)"
    )
}

# --- Arguments Check ---
case "${1:-}" in
    "--setup-deps")
        sudo apt update && sudo apt install -y aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget libssl-dev
        exit 0 ;;
    "--fetch-toolchains")
        setup_toolchain
        exit 0 ;;
    "--clean")
        msg "Cleaning..."
        rm -rf "$OUT_DIR" AnyKernel3 *.zip
        make clean mrproper
        exit 0 ;;
esac

# Start Build Process
prepare_env
mkdir -p "$OUT_DIR"

# Apply the Thermal Disabler if requested
if [[ "$APPLY_WORKAROUND" == "true" ]]; then
    disable_thermal_configs "$DEFCONFIG"
fi

msg "Starting compilation for $DEVICE_TARGET..."
make "${BUILD_ARGS[@]}" "$DEFCONFIG" "${EXTRA_CONFIG:-}"

if make "${BUILD_ARGS[@]}" 2>&1 | tee "$COMP_LOG"; then
    msg "Build successful. Packaging..."
    
    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
    ZIPNAME="rsuntk_$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT.zip"
    IMG="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"

    git clone -q --depth=1 https://github.com/rsuntk/AnyKernel3 -b "$DEVICE_TARGET"
    cp "$IMG" AnyKernel3/
    (cd AnyKernel3 && zip -r9 "../$ZIPNAME" . -x ".git*" "README.md")
    
    send_telegram "$(pwd)/$ZIPNAME" "" "" "succeeded" "$TC_DIR/bin/clang"
    
    [[ "${DO_CLEAN:-}" == "true" ]] && rm -rf AnyKernel3 "$OUT_DIR"
    echo -e "${green}Build completed in $((SECONDS / 60)) min(s).${reset}"
else
    send_telegram "$COMP_LOG" "" "" "failed" "$TC_DIR/bin/clang"
    error "Compilation failed!"
fi
