unset LLVM
export LLVM_IAS=0

TC_DIR="$HOME/gcc-arm64"
gcc_lists=("aarch64-linux-android-" "aarch64-linux-gnu-" "aarch64-elf-" "aarch64-linux-")

for choosen in "${gcc_lists[@]}"; do
    if [ -f "$TC_DIR/bin/${choosen}gcc" ]; then
        export CROSS_COMPILE="$TC_DIR/bin/$choosen"
        export ACTIVE_COMPILER="$TC_DIR/bin/${choosen}gcc"
        break
    fi
done

# FIXME: Don't supress GCC errors/warnings
export KCFLAGS=-w

__fetch_toolchain() {
    if [ ! -d "$TC_DIR" ]; then
        cd $HOME
        msg "Downloading EVA-GCC..."
        local url="https://github.com/mvaisakh/gcc-build/releases/download/06052026/eva-gcc-arm64-06052026.xz"
        wget -q "$url" -O $HOME/gcc.tar.xz
        tar -xf gcc.tar.xz
    else
        msg "Toolchain already exists."
    fi
}
