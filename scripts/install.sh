#!/bin/zsh
# Buduje bloombar, podmienia /Applications/bloombar.app i uruchamia nowa wersje.
# Usuwa tez kopie spod nazwy roboczej (/Applications/TidalBar.app): ten sam bundle ID, wiec ustawienia i logowanie zostaja.
set -euo pipefail

ROOT=${0:A:h:h}
"$ROOT/scripts/build-app.sh"

for name in bloombar TidalBar; do
  if pgrep -x $name >/dev/null; then
    osascript -e "quit app \"$name\""
    for _ in {1..20}; do pgrep -x $name >/dev/null || break; /usr/bin/perl -e 'select undef,undef,undef,0.25'; done
  fi
done

rm -rf /Applications/bloombar.app /Applications/TidalBar.app
ditto "$ROOT/build/bloombar.app" /Applications/bloombar.app
open /Applications/bloombar.app
echo "installed /Applications/bloombar.app"
