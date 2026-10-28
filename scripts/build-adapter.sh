#!/bin/zsh
# Buduje MediaRemoteAdapter.framework i klienta testowego z vendor/mediaremote-adapter bez cmake.
# Wynik: build/MediaRemoteAdapter.framework, build/MediaRemoteAdapterTestClient
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/vendor/mediaremote-adapter
OUT=$ROOT/build
FW=$OUT/MediaRemoteAdapter.framework

rm -rf "$FW"
mkdir -p "$FW"

clang -dynamiclib -arch arm64 -fobjc-arc -fvisibility=default -O2 \
  -I"$SRC/include" -I"$SRC/src" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter \
  "$SRC"/src/adapter/*.m "$SRC"/src/private/MediaRemote.m "$SRC"/src/utility/*.m \
  -o "$FW/MediaRemoteAdapter"
codesign --force --sign - "$FW/MediaRemoteAdapter"

clang -arch arm64 -fobjc-arc -O2 -I"$SRC/src/test" \
  -framework Foundation -framework MediaPlayer \
  "$SRC"/src/test/main.m "$SRC"/src/test/NowPlayingTest.m \
  -o "$OUT/MediaRemoteAdapterTestClient"
codesign --force --sign - "$OUT/MediaRemoteAdapterTestClient"

cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"
echo "built $FW"
