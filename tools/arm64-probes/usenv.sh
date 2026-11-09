#!/bin/bash
# usenv.sh: launch an app or game on the NVIDIA GPU. Inserts libusenv.dylib (next to this script) so the process's
# "system default" Metal device is the NVMTLDevice. Works for ad-hoc signed or unsigned apps (most Steam games);
# a hardened-runtime app ignores the insertion and stays on the Apple GPU.
#   usenv.sh /path/To/Game.app [steam-app-id] [args...]
# For a Steam game, start the Steam client first and pass its app id (from steamapps/appmanifest_<id>.acf), or set
# the game's launch options in Steam to:  DYLD_INSERT_LIBRARIES=<this folder>/libusenv.dylib %command%
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:?usage: usenv.sh /path/To/App.app [steam-app-id] [args...]}; shift
APPID=""; [[ "${1:-}" =~ ^[0-9]+$ ]] && { APPID=$1; shift; }
case "$APP" in
  *.app) EXE=$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist" 2>/dev/null); BIN="$APP/Contents/MacOS/$EXE"
         [ -x "$BIN" ] || BIN=$(find "$APP/Contents/MacOS" -maxdepth 1 -type f -perm -u+x | head -1);;
  *) BIN=$APP;;
esac
[ -x "$BIN" ] || { echo "usenv: no executable in $APP"; exit 2; }
codesign -dvv "$BIN" 2>&1 | grep -q "flags=0x10000(runtime)" && echo "usenv: NOTE: $BIN has the hardened runtime; the insertion will be ignored and the app stays on the Apple GPU"
BINDIR=${BIN%/*}   # computed before the insertion is exported: any system tool run after it (dirname, say) is arm64e and would be killed by dyld
cd "$BINDIR" || exit 2
export DYLD_INSERT_LIBRARIES="$HERE/libusenv.dylib"
[ -n "$APPID" ] && export SteamAppId="$APPID" SteamGameId="$APPID"
exec "$BIN" "$@"
