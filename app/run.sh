#!/bin/bash
# Build chipscope (Swift app + native probe helper), wrap it in a signed .app, install it to
# ~/Applications and launch it.   ./run.sh            build + install + launch
#                                  ./run.sh --no-open  build + install only
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product ChipScope
mkdir -p .build/helper
clang -O2 -Wall -fobjc-arc -framework Foundation -framework Metal -framework Vision -framework CoreGraphics \
  ../native/probe.m -o .build/helper/chipscope-probe
APP=.build/chipscope.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ChipScope "$APP/Contents/MacOS/ChipScope"
cp .build/helper/chipscope-probe "$APP/Contents/MacOS/chipscope-probe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/chipscope-probe" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -x ChipScope 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/chipscope.app"
ditto "$APP" "$HOME/Applications/chipscope.app"
[ "${1:-}" = "--no-open" ] || open "$HOME/Applications/chipscope.app"
echo "chipscope installed to ~/Applications/chipscope.app"
