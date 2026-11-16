#!/bin/sh
# Cross-compiles the libraries Speed Dreams needs that neither webOS nor the toolchain's sysroot has,
# into prefix/, for 32-bit ARM (Cortex-A55, softfp, like webOS's userland). Libraries the TV already
# has (libpng16, libjpeg 62, zlib, expat, curl 4, ogg, freetype) come from the sysroot instead.
# - SDL 2.30.12 for webOS (webosbrew's build, the one RetroArch and ioquake3 ship), unpacked as is;
# - gl4es: desktop OpenGL 2.1 on the TV's OpenGL ES 2, the context made by SDL (NOEGL, NOX11);
# - PLIB 1.8.5 (sg, ul, ssg, ssgAux, sl), OpenAL Soft with only its SDL2 backend, libvorbis,
#   SDL2_mixer (WAV and Ogg Vorbis), ENet, cJSON, minizip (from zlib's contrib) and RHash.
set -e
cd "$(dirname "$0")"
TOP=$PWD
T=${WEBOS_TOOLCHAIN:-$TOP/toolchain/arm-webos-linux-gnueabi_sdk-buildroot}
TC_URL=https://github.com/openlgtv/buildroot-nc4/releases/download/2026.08-webos/arm-webos-linux-gnueabi_sdk-buildroot-x86_64.tar.gz
# the openlgtv webOS toolchain, downloaded on the first run
if [ ! -x "$T/bin/cmake" ]; then
	mkdir -p toolchain
	curl -fL "$TC_URL" | tar -xz -C toolchain
	"$T/relocate-sdk.sh"
fi
TC=$T/bin/arm-webos-linux-gnueabi
SYSROOT=$T/arm-webos-linux-gnueabi/sysroot
P=$TOP/prefix
B=$TOP/build/deps
D=$TOP/downloads
export TMPDIR=$TOP/build/tmp
mkdir -p "$P/lib" "$P/include" "$B" "$D" "$TMPDIR"
ARCH="-mcpu=cortex-a55 -mfpu=neon-fp-armv8 -mfloat-abi=softfp"
CF="$ARCH -O2 -fPIC -D_FILE_OFFSET_BITS=64"
J=$(nproc)

fetch() { # url sha256 [name]
	f=$D/${3:-$(basename "$1")}
	[ -f "$f" ] || curl -fL -o "$f" "$1"
	echo "$2  $f" | sha256sum -c - >/dev/null || { echo "checksum mismatch: $f" >&2; exit 1; }
	echo "$f"
}
unpack() { # tarball dir
	rm -rf "$B/$2"; mkdir -p "$B/$2"; tar -xzf "$1" -C "$B/$2" --strip-components=1
}
cm() { # srcdir builddir [cmake args...]
	s=$1 b=$2; shift 2
	"$T/bin/cmake" -S "$s" -B "$b" -DCMAKE_TOOLCHAIN_FILE="$T/share/buildroot/toolchainfile.cmake" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
		-DCMAKE_FIND_ROOT_PATH="$P;$SYSROOT" -DCMAKE_PREFIX_PATH="$P" \
		-DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" >"$b.log" 2>&1 ||
		{ tail -30 "$b.log"; exit 1; }
	"$T/bin/cmake" --build "$b" -j"$J" >>"$b.log" 2>&1 || { tail -30 "$b.log"; exit 1; }
	"$T/bin/cmake" --install "$b" >>"$b.log" 2>&1
}
step() { [ -f "$B/.done-$1" ] && { echo "= $1 (done)"; return 1; }; echo "= $1"; }
done_() { touch "$B/.done-$1"; }

if step sdl2; then
	f=$(fetch https://github.com/webosbrew/SDL-webOS/releases/download/release-2.30.12-webos.1/SDL2-2.30.12-webos-abi.tar.gz \
		b43c05b26c0a0431a2b26a9b7036a24d8a34989441aeb87dd2825c1b50cbe83b)
	tar -xzf "$f" -C "$P"
	# its config points at the build machine's prefix; make it relative to where it now lies
	sed -i "s|^prefix=.*|prefix=$P|" "$P/lib/pkgconfig/sdl2.pc"
	done_ sdl2
fi

if step gl4es; then
	[ -d gl4es/.git ] || git clone -q https://github.com/ptitSeb/gl4es.git gl4es
	git -C gl4es checkout -q 8b1a3da
	cm gl4es "$B/gl4es-build" -DNOX11=ON -DNOEGL=ON -DDEFAULT_ES=2 -DNO_INIT_CONSTRUCTOR=ON -DUSE_CLOCK=ON \
		-DCMAKE_C_FLAGS="$CF -ftree-vectorize -fsingle-precision-constant -ffast-math"
	cp gl4es/lib/libGL.so.1 "$P/lib/"
	ln -sf libGL.so.1 "$P/lib/libGL.so"
	mkdir -p "$P/include/GL"
	cp -r gl4es/include/GL/. "$P/include/GL/"
	cp gl4es/include/gl4esinit.h gl4es/include/gl4eshint.h "$P/include/"
	done_ gl4es
fi

if step glu; then
	# SGI's GLU as ptitSeb keeps it for gl4es; Speed Dreams uses gluScaleImage and gluErrorString
	[ -d glu/.git ] || git clone -q https://github.com/ptitSeb/GLU.git glu
	git -C glu checkout -q 2fed2bd
	rm -rf "$B/glu"; cp -r glu "$B/glu"; rm -rf "$B/glu/.git"
	(cd "$B/glu" &&
		PATH="$T/bin:$PATH" ./configure --host=arm-webos-linux-gnueabi --prefix="$P" --disable-static \
			CC="$TC-gcc" CXX="$TC-g++" CFLAGS="$CF" CXXFLAGS="$CF" CPPFLAGS="-I$P/include" \
			LDFLAGS="-L$P/lib" LIBS="-lGL" >"$B/glu.log" 2>&1 &&
		PATH="$T/bin:$PATH" make -j"$J" >>"$B/glu.log" 2>&1 && PATH="$T/bin:$PATH" make install >>"$B/glu.log" 2>&1) ||
		{ tail -30 "$B/glu.log"; exit 1; }
	done_ glu
fi

if step plib; then
	f=$(fetch https://plib.sourceforge.net/dist/plib-1.8.5.tar.gz 485b22bf6fdc0da067e34ead5e26f002b76326f6371e2ae006415dea6a380a32)
	unpack "$f" plib
	# webOS has no glX: CONSOLE skips ssg's glXGetCurrentContext check (the context is SDL's)
	sed -i 's|^#  include <GL/glx.h>|#  ifndef CONSOLE\n#  include <GL/glx.h>\n#  endif|' "$B/plib/src/ssg/ssg.cxx"
	(cd "$B/plib" &&
		PATH="$T/bin:$PATH" ./configure --host=arm-webos-linux-gnueabi --prefix="$P" --disable-pw \
			--disable-net --disable-pui --disable-puaux --disable-fnt --disable-psl ac_cv_lib_GL_glNewList=yes \
			CC="$TC-gcc" CXX="$TC-g++" CFLAGS="$CF -DCONSOLE" CXXFLAGS="$CF -DCONSOLE" CPPFLAGS="-I$P/include" LDFLAGS="-L$P/lib" \
			>"$B/plib.log" 2>&1 &&
		PATH="$T/bin:$PATH" make -j"$J" >>"$B/plib.log" 2>&1 && PATH="$T/bin:$PATH" make install >>"$B/plib.log" 2>&1) || { tail -30 "$B/plib.log"; exit 1; }
	done_ plib
fi

if step vorbis; then
	f=$(fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab)
	unpack "$f" vorbis
	cm "$B/vorbis" "$B/vorbis-build" -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
	done_ vorbis
fi

if step openal; then
	f=$(fetch https://github.com/kcat/openal-soft/archive/refs/tags/1.23.1.tar.gz \
		dfddf3a1f61059853c625b7bb03de8433b455f2f79f89548cbcbd5edca3d4a4a openal-soft-1.23.1.tar.gz)
	unpack "$f" openal
	# GCC 13 and later no longer get uint8_t and friends through other headers, which 1.23 relies on
	cm "$B/openal" "$B/openal-build" -DCMAKE_CXX_FLAGS="$CF -include cstdint" -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
		-DALSOFT_INSTALL_CONFIG=OFF -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
		-DALSOFT_BACKEND_SDL2=ON -DALSOFT_REQUIRE_SDL2=ON -DALSOFT_BACKEND_ALSA=OFF -DALSOFT_BACKEND_OSS=OFF \
		-DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_PIPEWIRE=OFF -DALSOFT_BACKEND_JACK=OFF \
		-DALSOFT_BACKEND_PORTAUDIO=OFF -DALSOFT_BACKEND_SNDIO=OFF -DALSOFT_BACKEND_SOLARIS=OFF \
		-DALSOFT_BACKEND_WAVE=OFF -DALSOFT_CPUEXT_NEON=ON -DALSOFT_EMBED_HRTF_DATA=OFF -DALSOFT_NO_CONFIG_UTIL=ON
	done_ openal
fi

if step sdl2_mixer; then
	f=$(fetch https://github.com/libsdl-org/SDL_mixer/releases/download/release-2.8.0/SDL2_mixer-2.8.0.tar.gz \
		1cfb34c87b26dbdbc7afd68c4f545c0116ab5f90bbfecc5aebe2a9cb4bb31549)
	unpack "$f" sdl2_mixer
	cm "$B/sdl2_mixer" "$B/sdl2_mixer-build" -DBUILD_SHARED_LIBS=ON -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF \
		-DSDL2MIXER_VORBIS=STB -DSDL2MIXER_OPUS=OFF -DSDL2MIXER_FLAC=OFF -DSDL2MIXER_MOD=OFF -DSDL2MIXER_MIDI=OFF \
		-DSDL2MIXER_MP3=OFF -DSDL2MIXER_WAVPACK=OFF -DSDL2MIXER_GME=OFF -DSDL2MIXER_CMD=OFF -DSDL2MIXER_WAVE=ON
	done_ sdl2_mixer
fi

if step enet; then
	f=$(fetch https://github.com/lsalzman/enet/archive/refs/tags/v1.3.18.tar.gz \
		28603c895f9ed24a846478180ee72c7376b39b4bb1287b73877e5eae7d96b0dd enet-1.3.18.tar.gz)
	unpack "$f" enet
	cm "$B/enet" "$B/enet-build"
	cp "$B/enet-build/libenet.a" "$P/lib/"
	mkdir -p "$P/include/enet"
	cp "$B"/enet/include/enet/*.h "$P/include/enet/"
	done_ enet
fi

if step cjson; then
	f=$(fetch https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.18.tar.gz \
		3aa806844a03442c00769b83e99970be70fbef03735ff898f4811dd03b9f5ee5 cJSON-1.7.18.tar.gz)
	unpack "$f" cjson
	cm "$B/cjson" "$B/cjson-build" -DBUILD_SHARED_LIBS=OFF -DENABLE_CJSON_TEST=OFF -DENABLE_CJSON_UTILS=OFF \
		-DENABLE_CUSTOM_COMPILER_FLAGS=OFF
	done_ cjson
fi

if step minizip; then
	f=$(fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz \
		9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23)
	unpack "$f" zlib
	m=$B/zlib/contrib/minizip
	(cd "$m" && for c in ioapi unzip zip; do "$TC-gcc" $CF -DIOAPI_NO_64 -c $c.c -o $c.o || exit 1; done &&
		"$TC-ar" rcs "$P/lib/libminizip.a" ioapi.o unzip.o zip.o)
	mkdir -p "$P/include/minizip"
	cp "$m"/ioapi.h "$m"/unzip.h "$m"/zip.h "$P/include/minizip/"
	done_ minizip
fi

if step rhash; then
	f=$(fetch https://github.com/rhash/RHash/archive/refs/tags/v1.4.5.tar.gz \
		6db837e7bbaa7c72c5fd43ca5af04b1d370c5ce32367b9f6a1f7b49b2338c09a RHash-1.4.5.tar.gz)
	unpack "$f" rhash
	(cd "$B/rhash/librhash" && rm -f ./*.o && for c in *.c; do
		case $c in test_*) continue ;; esac
		"$TC-gcc" $CF -DNDEBUG -DRHASH_XVERSION=0x01040500 -c "$c" -o "${c%.c}.o" || exit 1
	done && rm -f "$P/lib/librhash.a" && "$TC-ar" rcs "$P/lib/librhash.a" ./*.o)
	cp "$B"/rhash/librhash/rhash.h "$P/include/"
	done_ rhash
fi

echo "prefix ready: $P"
ls "$P/lib"
