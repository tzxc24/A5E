#!/bin/sh
set -eu

GAME_DIR=${MEOW_PVZ_DIR:-/home/radxa/games/pvz}
GAME="$GAME_DIR/pvz-portable"
HELPER_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -x "$GAME" ] || { echo "Missing executable: $GAME" >&2; exit 1; }
[ -s "$GAME_DIR/main.pak" ] || { echo "Missing main.pak in $GAME_DIR" >&2; exit 2; }
[ -d "$GAME_DIR/properties" ] || { echo "Missing properties in $GAME_DIR" >&2; exit 2; }
for tool in Xorg xrandr xinput xwininfo setpriv xset python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool" >&2; exit 3; }
done
[ -r "$HELPER_DIR/meow-pvz-touch.py" ] || { echo 'Missing touch adapter' >&2; exit 3; }
python3 "$HELPER_DIR/meow-power.py" --allow-game
if [ "${1:-}" = --check ]; then echo PVZ_PREFLIGHT_OK; exit 0; fi
[ "$(id -u)" = 0 ] || { echo 'Run through meow-pvz.service' >&2; exit 4; }

SESSION=/run/meow-pvz
DISPLAY=:1
export DISPLAY
XORG_PID=
GAME_PID=
KEYBOARD_PID=
PALETTE_PID=
TOUCH_PID=
cleanup() {
    trap - EXIT INT TERM
    for pid in "$GAME_PID" "$TOUCH_PID" "$PALETTE_PID" "$KEYBOARD_PID" "$XORG_PID"; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "$GAME_PID" "$TOUCH_PID" "$PALETTE_PID" "$KEYBOARD_PID" "$XORG_PID"; do
        [ -n "$pid" ] || continue
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT
trap 'exit 0' INT TERM
mkdir -p "$SESSION"
cat >"$SESSION/xorg.conf" <<'EOF'
Section "Device"
    Identifier "Meow PvZ GPU"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "AccelMethod" "glamor"
EndSection
Section "Screen"
    Identifier "Meow PvZ Screen"
    Device "Meow PvZ GPU"
EndSection
EOF
# Isolated UNIX-only X server; never kill another application's Xorg process.
Xorg "$DISPLAY" -config "$SESSION/xorg.conf" vt1 -keeptty -nolisten tcp -noreset -ac \
    >"$SESSION/xorg.log" 2>&1 &
XORG_PID=$!
i=0
until xrandr --query >"$SESSION/xrandr.log" 2>/dev/null; do
    kill -0 "$XORG_PID" 2>/dev/null || { cat "$SESSION/xorg.log" >&2; exit 5; }
    i=$((i+1)); [ "$i" -lt 60 ] || { echo 'Xorg startup timeout' >&2; exit 5; }
    sleep 0.1
done
OUTPUT=$(awk '$2 == "connected" {print $1; exit}' "$SESSION/xrandr.log")
[ -n "$OUTPUT" ] || { echo 'No connected display' >&2; exit 5; }
xrandr --output "$OUTPUT" --rotate left
xset s off
xset -dpms
TOUCH_ID=
i=0
while [ -z "$TOUCH_ID" ] && [ "$i" -lt 40 ]; do
    TOUCH_ID=$(xinput list --id-only jadard-touchscreen 2>/dev/null || true)
    i=$((i+1)); [ -n "$TOUCH_ID" ] || sleep 0.1
done
[ -n "$TOUCH_ID" ] || { echo 'jadard-touchscreen not found' >&2; exit 6; }
xinput set-prop "$TOUCH_ID" 'Coordinate Transformation Matrix' 0 -1 1 1 0 0 0 0 1
xinput list-props "$TOUCH_ID" >"$SESSION/touch.log"
xrandr --query >"$SESSION/xrandr.log"
cd "$GAME_DIR"
setpriv --reuid=radxa --regid=radxa --init-groups env \
    DISPLAY="$DISPLAY" HOME=/home/radxa USER=radxa LOGNAME=radxa \
    SDL_VIDEODRIVER=x11 SDL_TOUCH_MOUSE_EVENTS=1 SDL_MOUSE_TOUCH_EVENTS=0 \
    XDG_RUNTIME_DIR=/run/user/1000 \
    "$GAME" -resdir "$GAME_DIR" "$@" &
GAME_PID=$!
# Read the device independently and update the XTEST mouse before each click.
# Disabling only this X11 device prevents duplicate stale SDL/core clicks.
TOUCH_NODE=$(xinput list-props "$TOUCH_ID" | sed -n 's/.*Device Node.*"\([^"]*\)".*/\1/p')
[ -c "$TOUCH_NODE" ] || { echo 'Touch event node unavailable' >&2; exit 6; }
xinput disable "$TOUCH_ID"
setpriv --reuid=radxa --regid=radxa --init-groups env DISPLAY="$DISPLAY" \
    python3 "$HELPER_DIR/meow-pvz-touch.py" "$TOUCH_NODE" "$GAME_PID" \
    >"$SESSION/touch-adapter.log" 2>&1 &
TOUCH_PID=$!
i=0
until grep -q PVZ_TOUCH_READY "$SESSION/touch-adapter.log"; do
    kill -0 "$TOUCH_PID" 2>/dev/null || { cat "$SESSION/touch-adapter.log" >&2; exit 6; }
    i=$((i+1)); [ "$i" -lt 30 ] || { echo 'Touch adapter timeout' >&2; exit 6; }
    sleep 0.1
done
if command -v onboard >/dev/null 2>&1; then
    # The native game opens a player-name dialog on first launch. Keep the
    # existing touch keyboard's palette available without covering gameplay.
    for setting in 'org.onboard.icon-palette in-use true' 'org.onboard.window force-to-top true'; do
        # These are fixed schema/key/value triples, never user input.
        setpriv --reuid=radxa --regid=radxa --init-groups env \
            DISPLAY="$DISPLAY" HOME=/home/radxa \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            gsettings set $setting >/dev/null 2>&1 || true
    done
    setpriv --reuid=radxa --regid=radxa --init-groups env \
        DISPLAY="$DISPLAY" HOME=/home/radxa \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        onboard -D 0 >"$SESSION/keyboard.log" 2>&1 &
    KEYBOARD_PID=$!
    i=0
    while [ "$i" -lt 60 ] && ! xwininfo -root -tree 2>/dev/null | grep -q 'PvZ Portable'; do
        kill -0 "$GAME_PID" 2>/dev/null || break
        i=$((i+1)); sleep 0.1
    done
    # Let SDL finish raising its fullscreen window, then raise the keyboard
    # palette above it; there is no window manager in this session.
    sleep 1
    timeout 2s setpriv --reuid=radxa --regid=radxa --init-groups env \
        DISPLAY="$DISPLAY" HOME=/home/radxa \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        gdbus call --session --dest org.onboard.Onboard \
        --object-path /org/onboard/Onboard/Keyboard \
        --method org.onboard.Onboard.Keyboard.Show >/dev/null 2>&1 || true
    sleep 0.2
    i=0
    while [ "$i" -lt 25 ]; do
        if timeout 1s setpriv --reuid=radxa --regid=radxa --init-groups env \
            DISPLAY="$DISPLAY" HOME=/home/radxa \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            gdbus call --session --dest org.onboard.Onboard \
            --object-path /org/onboard/Onboard/Keyboard \
            --method org.onboard.Onboard.Keyboard.Hide >/dev/null 2>&1; then break; fi
        i=$((i+1)); sleep 0.1
    done
    setpriv --reuid=radxa --regid=radxa --init-groups env DISPLAY="$DISPLAY" \
        python3 "$HELPER_DIR/meow-pvz-keyboard.py" "$GAME_PID" \
        >"$SESSION/palette.log" 2>&1 &
    PALETTE_PID=$!
fi
set +e
wait "$GAME_PID"
STATUS=$?
set -e
GAME_PID=
exit "$STATUS"
