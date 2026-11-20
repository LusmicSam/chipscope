#!/bin/sh
# Start chipscope: builds the native helper if needed, serves the UI on 127.0.0.1:7878, opens the browser.
cd "$(dirname "$0")" && exec /usr/bin/python3 -m chipscope "$@"
