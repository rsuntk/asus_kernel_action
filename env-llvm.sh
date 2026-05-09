export LLVM=1
export LLVM_IAS=1

TC_DIR="$HOME/clang-22"
ACTIVE_COMPILER="$TC_DIR/bin/clang"
export PATH="$TC_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$TC_DIR/lib:$TC_DIR/lib64:${LD_LIBRARY_PATH:-}"

__fetch_toolchain() {
    if [ ! -d "$TC_DIR" ]; then
        msg "Downloading AOSP-LLVM..."
        mkdir -p "$TC_DIR"
        local url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/9b144befdfd93b90e02c663504fb9f4b95f9faf8/clang-r596125.tar.gz"
        curl -Ls "$url" | tar -xz -C "$TC_DIR"
    else
        msg "Toolchain already exists."
    fi
}
