#!/bin/sh
# Builds Speed Dreams (sd-code, tag v2.4.2) for webOS TVs into build/sd, against prefix/ from
# ./build-deps.sh. Only the classic PLIB renderer (ssggraph), drawn with gl4es; no OpenSceneGraph,
# track editor or XRandR.
set -e
cd "$(dirname "$0")"
TOP=$PWD
T=${WEBOS_TOOLCHAIN:-$TOP/toolchain/arm-webos-linux-gnueabi_sdk-buildroot}
# Speed Dreams 2.4.2, with patches/speed-dreams-webos.patch, on the first run
if [ ! -d sd-code/.git ]; then
	git clone -q --branch v2.4.2 https://forge.a-lec.org/speed-dreams/speed-dreams-code.git sd-code
	git -C sd-code apply ../patches/speed-dreams-webos.patch
fi
P=$TOP/prefix
SYSROOT=$T/arm-webos-linux-gnueabi/sysroot
export TMPDIR=$TOP/build/tmp
mkdir -p "$TMPDIR"
CF="-mcpu=cortex-a55 -mfpu=neon-fp-armv8 -mfloat-abi=softfp -O2 -D_FILE_OFFSET_BITS=64"
# SD_PROFILER=1 builds in Speed Dreams' profiler: the log then gets a timing report of the race's
# steps every 30 s, and at the end
[ "${SD_PROFILER:-0}" = 1 ] && CF="$CF -DPROFILER"

# the prefix comes first, so its SDL 2.30.12 wins over the sysroot's older SDL; "/" is searched
# inside each root (an absolute prefix would be re-rooted and missed)
"$T/bin/cmake" -S sd-code -B build/sd -DCMAKE_TOOLCHAIN_FILE="$T/share/buildroot/toolchainfile.cmake" \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOP/build/install" \
	-DCMAKE_FIND_ROOT_PATH="$P;$SYSROOT" -DCMAKE_PREFIX_PATH=/ \
	-DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DOPTION_OSGGRAPH=OFF -DOPTION_TRACKEDITOR=OFF -DOPTION_XRANDR=OFF -DOPTION_OFFICIAL_ONLY=ON -DOPTION_WEBOS=ON \
	-DSD_ASSUME_DATADIR=ON >build/sd-configure.log 2>&1 || { grep -A5 'CMake Error' build/sd-configure.log | head -40; exit 1; }
"$T/bin/cmake" --build build/sd -j"$(nproc)" >build/sd-build.log 2>&1 || { grep -E 'error|Error' build/sd-build.log | head -40; exit 1; }
echo "built: build/sd"
