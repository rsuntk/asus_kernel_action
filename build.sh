#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# --- Configuration ---
SECONDS=0
USER="rsuntk"
HOSTNAME="yukiprjkt-lab"
DEVICE_TARGET=${DEVICE_TARGET:-"X01BD"}
OUT_DIR="$(pwd)/out"
COMP_LOG="$OUT_DIR/compilation.log"
KCFLAGS_W=${KCFLAGS_W:-"false"}
DEFCONFIG="vendor/asus/${DEVICE_TARGET}_defconfig"
COMP_OPTION=${COMP_OPTION:-"llvm"}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# --- Colors ---
export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1" >&2
    exit 1
}

if [[ "$COMP_OPTION" == "llvm" ]]; then
    source $SCRIPT_DIR/env-llvm.sh
elif [[ "$COMP_OPTION" == "gcc" ]]; then
    source $SCRIPT_DIR/env-gcc.sh
else
    error "Invalid compilation option: $COMP_OPTION"
fi

# --- Telegram Notification ---
send_telegram() {
    local file="$1"
    local status="$2"
    local compiler="$3"

    if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        msg "Telegram credentials missing. Skipping upload."
        return
    fi

    local cc_version_txt=$($compiler --version 2>/dev/null | head -n 1 | sed 's/\#//g')
    local md5=$(md5sum "$file" | cut -d' ' -f1)
    local h=$((SECONDS / 3600))
    local m=$(((SECONDS % 3600) / 60))
    local s=$((SECONDS % 60))
    local cc_ver=$(echo $cc_version_txt | perl -pe 's/\(http.*?\)//gs' | sed 's/[[:space:]]*$//')

    local msg_bar="build $status in ${h}h ${m}m ${s}s
Device: <code>${DEVICE_TARGET}</code>
md5: <code>${md5}</code>
Compiler: $cc_ver"

    msg "Uploading to Telegram..."
    curl -s -F document=@"$file" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=HTML" \
        -F caption="$msg_bar"
    
    msg "Upload completed!"
}

# --- Toolchain Logic ---
setup_toolchain() {
    if [[ "${UPDATE_TOOLCHAINS:-}" == "true" ]]; then
        msg "Cleaning old toolchain..."
        rm -rf "$TC_DIR" ~/.ccache
    fi

    __fetch_toolchain;
}

# --- Build Setup ---
prepare_env() {
    export KBUILD_BUILD_USER=$USER
    export KBUILD_BUILD_HOST=$HOSTNAME

    [[ "$KCFLAGS_W" == "true" ]] && export KCFLAGS="-w"

    BUILD_ARGS=(
        O="$OUT_DIR"
        ARCH=arm64
        -j"$(nproc --all)"
    )
}

# --- Arguments Check ---
case "${1:-}" in
"--setup-deps")
    sudo apt update && sudo apt install -y aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget libssl-dev
    exit 0
    ;;
"--fetch-toolchains")
    setup_toolchain
    exit 0
    ;;
"--clean")
    msg "Cleaning..."
    rm -rf "$OUT_DIR" AnyKernel3 *.zip
    make clean mrproper
    exit 0
    ;;
esac

# Start Build Process
prepare_env
mkdir -p "$OUT_DIR"

msg "Starting compilation for $DEVICE_TARGET..."
make "${BUILD_ARGS[@]}" "$DEFCONFIG" ${EXTRA_CONFIG:-}

if make "${BUILD_ARGS[@]}" 2>&1 | tee "$COMP_LOG"; then
    msg "Build successful. Packaging..."

    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
    ZIPNAME="$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT.zip"
    IMG="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"

    git clone -q --depth=1 https://github.com/rsuntk/AnyKernel3 -b "$DEVICE_TARGET"
    cp "$IMG" AnyKernel3/
    (cd AnyKernel3 && zip -r9 "../$ZIPNAME" . -x ".git*" "README.md")

    send_telegram "$(pwd)/$ZIPNAME" "succeeded" "$ACTIVE_COMPILER"

    [[ "${DO_CLEAN:-}" == "true" ]] && rm -rf AnyKernel3 "$OUT_DIR"
    echo -e "${green}Build completed in $((SECONDS / 60)) min(s).${reset}"
else
    send_telegram "$COMP_LOG" "failed" "$ACTIVE_COMPILER"
    error "Compilation failed!"
fi
