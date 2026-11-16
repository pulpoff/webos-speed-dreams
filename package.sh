#!/bin/sh
# Packages the build (./build-deps.sh, ./build-sd.sh) into output/<id>_<version>_all.ipk, in the
# layout ares-package produces. The app folder holds:
# - speed-dreams-2, the game itself (appinfo.json's main), with its rpath on lib/;
# - lib/: Speed Dreams' own libraries and FreeSOLID, and what the TV lacks or has too old:
#   webosbrew's SDL 2.30.12, gl4es (as libGL), GLU, OpenAL Soft, SDL2_mixer, libjpeg 8, and the
#   toolchain's libstdc++ and libgcc_s (the TV's libstdc++ is GCC 8's);
# - modules/ and drivers/ (the robots), and data/, speed-dreams-data's installed files.
set -e
cd "$(dirname "$0")"
TOP=$PWD
T=${WEBOS_TOOLCHAIN:-$TOP/toolchain/arm-webos-linux-gnueabi_sdk-buildroot}
# Speed Dreams' data 2.4.2, with patches/speed-dreams-data-webos.patch, on the first run
if [ ! -d sd-data/.git ]; then
	git clone -q --branch v2.4.2 https://forge.a-lec.org/speed-dreams/speed-dreams-data.git sd-data
	git -C sd-data apply ../patches/speed-dreams-data-webos.patch
fi
TC=$T/bin/arm-webos-linux-gnueabi
SYSROOT=$T/arm-webos-linux-gnueabi/sysroot
P=$TOP/prefix
export TMPDIR=$TOP/build/tmp
mkdir -p "$TMPDIR"
ID=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' app/appinfo.json)
VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' app/appinfo.json)

# the game and the data, installed afresh
rm -rf build/install build/data-install
"$T/bin/cmake" --install build/sd --prefix "$TOP/build/install" >build/sd-install.log
if [ ! -f build/sd-data/CMakeCache.txt ]; then
	"$T/bin/cmake" -S sd-data -B build/sd-data >build/sd-data.log
fi
"$T/bin/cmake" --install build/sd-data --prefix "$TOP/build/data-install" >>build/sd-data.log
I=build/install
SDL=$I/lib/games/speed-dreams-2

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=$W/data/usr/palm/applications/$ID
mkdir -p "$D/lib" "$W/data/usr/palm/packages/$ID" "$W/control"
cp app/appinfo.json app/icon.png app/largeIcon.png "$D/"
# The game runs as its own user, and the app folder is root's: home/ holds the settings, results
# and replays (when no USB drive has a speed-dreams folder), so anyone may write it.
mkdir -p "$D/home"
chmod 777 "$D/home"
cp sd-code/COPYING.txt "$D/COPYING.txt" 2>/dev/null || cp sd-code/LICENSE "$D/COPYING.txt"
cp "$I/games/speed-dreams-2" "$D/"
cp "$SDL"/lib/*.so "$I"/lib/*.so "$D/lib/"
cp -r "$SDL/modules" "$SDL/drivers" "$D/"
cp -r build/data-install/share/games/speed-dreams-2 "$D/data"
for l in libSDL2-2.0.so.0 libGL.so.1 libGLU.so.1 libopenal.so.1 libSDL2_mixer-2.0.so.0; do
	cp -L "$P/lib/$l" "$D/lib/"
done
cp -L "$SYSROOT/usr/lib/libjpeg.so.8" "$SYSROOT/usr/lib/libstdc++.so.6" "$SYSROOT/lib/libgcc_s.so.1" "$D/lib/"
find "$D" -type f \( -name '*.so' -o -name '*.so.*' -o -name speed-dreams-2 \) | while read -r f; do
	"$TC-strip" --strip-unneeded "$f"
	chmod 755 "$f"
done

# every library an ELF file needs must be in lib/ or on the TV (build/tv-libs.txt, a listing of
# the TV's /lib and /usr/lib, made once over ssh)
if [ -f build/tv-libs.txt ]; then
	missing=$(find "$D" -type f \( -name '*.so' -o -name '*.so.*' -o -name speed-dreams-2 \) -exec "$TC-readelf" -d {} + 2>/dev/null |
		sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort -u | while read -r l; do
			[ -f "$D/lib/$l" ] || grep -qx "$l" build/tv-libs.txt || echo "$l"
		done)
	[ -z "$missing" ] || { echo "not on the TV nor in lib/: $missing" >&2; exit 1; }
fi
# and every symbol they use must be defined there: an older library of the same name may lack one,
# which only fails when the code runs. Needs a copy of the TV's libraries (tools/fetch-tv-libs.sh).
if [ -d build/tv-root ]; then
	python3 tools/check-symbols.py "$TC-readelf" "$D" build/tv-root
fi

printf '{\n  "id": "%s",\n  "version": "%s",\n  "app": "%s"\n}\n' "$ID" "$VER" "$ID" > "$W/data/usr/palm/packages/$ID/packageinfo.json"
SIZE=$(du -sb "$W/data" | cut -f1)
cat > "$W/control/control" <<EOF
Package: $ID
Version: $VER
Section: misc
Priority: optional
Architecture: all
Installed-Size: $SIZE
Maintainer: N/A <nobody@example.com>
Description: This is a webOS application.
webOS-Package-Format-Version: 2
webOS-Packager-Version: x.y.x
EOF
printf '2.0\n' > "$W/debian-binary"
(cd "$W/control" && tar --owner=0 --group=0 -czf ../control.tar.gz control)
(cd "$W/data" && tar --owner=0 --group=0 -czf ../data.tar.gz usr)
mkdir -p output
OUT=output/${ID}_${VER}_all.ipk
rm -f "$OUT"
# webOS rejects GNU ar output (error -5), so write the ar container as ares-package does.
python3 - "$OUT" "$W/debian-binary" "$W/control.tar.gz" "$W/data.tar.gz" <<'PY'
import os, sys, time
out = open(sys.argv[1], 'wb'); out.write(b'!<arch>\n')
for p in sys.argv[2:]:
    data = open(p, 'rb').read()
    hdr = '%-16s%-12d%-6d%-6d%-8s%-10d`\n' % (os.path.basename(p), int(time.time()), 0, 0, '100644', len(data))
    out.write(hdr.encode()); out.write(data)
    if len(data) % 2: out.write(b'\n')
out.close()
PY
# The Homebrew Channel manifest; the release publishes it next to the IPK.
python3 - "$OUT" app/appinfo.json "output/$ID.manifest.json" <<'PY'
import hashlib, json, os, sys
ipk, info, out = sys.argv[1:]
a = json.load(open(info))
m = {
    "id": a["id"], "version": a["version"], "type": a["type"], "title": a["title"],
    "appDescription": "An open motorsport sim: race cars on tracks against the computer's drivers",
    "iconUri": "https://raw.githubusercontent.com/pulpoff/webos-speed-dreams/main/app/largeIcon.png",
    "sourceUrl": "https://github.com/pulpoff/webos-speed-dreams",
    "rootRequired": False,
    "ipkUrl": os.path.basename(ipk),
    "ipkHash": {"sha256": hashlib.sha256(open(ipk, "rb").read()).hexdigest()},
}
json.dump(m, open(out, "w"), indent=2); open(out, "a").write("\n")
PY
echo "installed size: $((SIZE / 1048576)) MB"
ls -la "$OUT" "output/$ID.manifest.json"
