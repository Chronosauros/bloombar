#!/bin/zsh
# Buduje build/bloombar.app samym swiftc (bez Xcode) i wklada do niej mediaremote-adapter.
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/build
APP=$OUT/bloombar.app

[[ -f $OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter ]] || "$ROOT/scripts/build-adapter.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/adapter"
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  "$ROOT"/app/Sources/*.swift -o "$APP/Contents/MacOS/bloombar"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"

# Logowanie do TIDAL-a: app/tidal.local.env (poza gitem) -> klucze w Info.plist zbudowanej aplikacji.
# Linie: TIDAL_CLIENT_ID=..., TIDAL_REDIRECT_URI=... (domyslnie tidalbar://callback), TIDAL_SCOPES=... (opcjonalnie).
# Brak pliku = budowa przechodzi, a serduszko mowi, ze logowanie nie jest skonfigurowane.
ENVFILE=$ROOT/app/tidal.local.env
if [[ -f $ENVFILE ]]; then
  setopt extended_glob
  while IFS='=' read -r key value || [[ -n $key ]]; do
    key=${key//[[:space:]]/}
    value=${value//$'\r'/}
    value=${value##[[:space:]]#}
    value=${value%%[[:space:]]#}
    value=${value#[\"\']}
    value=${value%[\"\']}
    [[ -z $key || $key == \#* || -z $value ]] && continue
    case $key in
      TIDAL_CLIENT_ID) plist_key=TIDALClientID ;;
      TIDAL_REDIRECT_URI) plist_key=TIDALRedirectURI ;;
      TIDAL_SCOPES) plist_key=TIDALScopes ;;
      *) continue ;;
    esac
    plutil -insert "$plist_key" -string "$value" "$APP/Contents/Info.plist"
  done < "$ENVFILE"
  echo "TIDAL login configured from app/tidal.local.env"
else
  echo "no app/tidal.local.env - TIDAL login not configured"
fi

cp -R "$OUT/MediaRemoteAdapter.framework" "$OUT/mediaremote-adapter.pl" "$APP/Contents/Resources/adapter/"
codesign --force --sign - "$APP"
echo "built $APP"
