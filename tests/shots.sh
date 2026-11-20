#!/bin/sh
# Screenshot every view of a running chipscope with headless Chrome (throwaway profile).
# usage: tests/shots.sh [base-url] [out-dir] [views...]
BASE=${1:-http://127.0.0.1:7878}
OUT=${2:-/tmp/chipscope-shots}
shift 2 2>/dev/null
VIEWS=${*:-"mac soc cluster/pclu0 core/pclu0.1 gpu memory atlas sensors"}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$OUT"
for v in $VIEWS; do
  name=$(echo "$v" | tr '/' '_')
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir=/tmp/chipscope-chrome \
    --window-size=1680,1050 --virtual-time-budget=4000 --timeout=15000 --screenshot="$OUT/$name.png" "$BASE/?snapshot#/$v" >/dev/null 2>&1
  echo "$OUT/$name.png"
done
