#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$ROOT_DIR/VERSION")

case "$VERSION" in
    *[!0-9.]*|*.*.*.*|.*|*.)
        printf '%s\n' "Invalid Meow OS version: $VERSION (expected MAJOR.MINOR.PATCH)" >&2
        exit 1
        ;;
esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "Invalid Meow OS version: $VERSION (expected MAJOR.MINOR.PATCH)" >&2
    exit 1
fi

HEADER_VERSION=$(sed -n 's/^#define MEOW_OS_VERSION "\([^"]*\)"/\1/p' "$ROOT_DIR/src/version.h")
if [ "$HEADER_VERSION" != "$VERSION" ]; then
    printf '%s\n' "VERSION ($VERSION) does not match src/version.h ($HEADER_VERSION)" >&2
    printf '%s\n' 'Run scripts/bump-version before deploying.' >&2
    exit 1
fi

# Fingerprint all maintained product inputs, excluding generated build output.
# If those inputs change, reusing the installed version is rejected.
SOURCE_HASH=$(
    find VERSION meow-os.pro qml.qrc src qml assets config polkit systemd udev scripts plymouth hardware tools \
        -type f ! -name '*.o' ! -name 'moc_*' ! -name 'qrc_*' -print \
        | LC_ALL=C sort \
        | xargs sha256sum \
        | sha256sum \
        | awk '{print $1}'
)
INSTALLED_VERSION=$(sed -n 's/^VERSION="\{0,1\}\([^" ]*\)"\{0,1\}$/\1/p' /etc/meow-os-release 2>/dev/null || true)
INSTALLED_HASH=$(cat /etc/meow-os/build.sha256 2>/dev/null || true)
if [ -n "$INSTALLED_HASH" ] && [ "$SOURCE_HASH" != "$INSTALLED_HASH" ]; then
    if [ "$VERSION" = "$INSTALLED_VERSION" ]; then
        printf '%s\n' "Source changed but version is still $VERSION." >&2
        printf '%s\n' 'Run scripts/bump-version before deploying.' >&2
        exit 1
    fi
    if [ "$(printf '%s\n%s\n' "$INSTALLED_VERSION" "$VERSION" | sort -V | head -n 1)" != "$INSTALLED_VERSION" ]; then
        printf '%s\n' "Refusing version rollback: installed=$INSTALLED_VERSION incoming=$VERSION" >&2
        exit 1
    fi
fi

cd "$ROOT_DIR"
./scripts/quality-gate.sh
if [ "${MEOW_QUALITY_STRICT:-0}" = "1" ]; then
    ./scripts/quality-gate.sh --strict
fi

# Mindustry uses a temporary Xorg session.  XRandR performs the panel rotation
# and the libinput Xorg driver exposes the physical touchscreen to XInput.
if ! command -v xrandr >/dev/null 2>&1 \
    || ! command -v xinput >/dev/null 2>&1 \
    || ! find /usr/lib/xorg/modules/input -name libinput_drv.so -print -quit 2>/dev/null | grep -q .; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        x11-xserver-utils xinput xserver-xorg-input-libinput
fi

# Mindustry runs in its own X11 session, so the Qt shell's input controls are
# not available while the game is focused.  Install a touch keyboard and a
# Chinese IME for text fields such as server names and chat.
if ! command -v onboard >/dev/null 2>&1 \
    || ! command -v fcitx5 >/dev/null 2>&1 \
    || ! dpkg-query -W -f '${Status}' fcitx5-pinyin 2>/dev/null \
        | grep -q '^install ok installed$'; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        onboard fcitx5 fcitx5-pinyin fcitx5-frontend-gtk3 fcitx5-frontend-qt5
fi

qmake meow-os.pro -o Makefile
# A5E images may expose 8 cores but have limited RAM; unrestricted parallel
# rcc/g++ jobs can OOM or crash rcc. Allow CI/large hosts to override while
# keeping deployment deterministic on the appliance.
BUILD_JOBS="${MEOW_BUILD_JOBS:-2}"
case "$BUILD_JOBS" in ''|*[!0-9]*) BUILD_JOBS=2 ;; esac
[ "$BUILD_JOBS" -gt 0 ] || BUILD_JOBS=1
make -j"$BUILD_JOBS"

install -d -m 0755 /opt/meow-os/bin /opt/meow-os/assets/sounds /opt/meow-os/share/early-splash/theme /opt/meow-os/share/early-splash/assets /etc/meow-os /etc/systemd/system /etc/systemd/journald.conf.d /etc/polkit-1/rules.d /etc/polkit-1/localauthority/50-local.d /etc/udev/rules.d /var/log/meow-os
install -d -m 2755 -o root -g systemd-journal /var/log/journal
install -m 0755 meow-os /opt/meow-os/meow-os
install -m 0755 scripts/mount-nvme-data /opt/meow-os/bin/mount-nvme-data
install -m 0644 assets/sounds/volume-meow.wav /opt/meow-os/assets/sounds/volume-meow.wav
sed 's/\r$//' scripts/meow-display-launcher > /tmp/meow-display-launcher && install -m 0755 /tmp/meow-display-launcher /opt/meow-os/bin/meow-display-launcher
install -d -m 0755 /opt/mindustry/gl4es/lib
sed 's/\r$//' scripts/meow-mindustry-launch.sh > /tmp/meow-mindustry-launch.sh && install -m 0755 /tmp/meow-mindustry-launch.sh /opt/mindustry/meow-mindustry-launch.sh
if [ -f /tmp/gl4es/lib/libGL.so.1 ]; then
    install -m 0755 /tmp/gl4es/lib/libGL.so.1 /opt/mindustry/gl4es/lib/libGL.so.1
    ln -sf libGL.so.1 /opt/mindustry/gl4es/lib/libGL.so
fi
install -m 0755 scripts/meow-backlight-permissions /opt/meow-os/bin/meow-backlight-permissions
install -m 0755 scripts/meow-cpufreq-recover /opt/meow-os/bin/meow-cpufreq-recover
install -d -o radxa -g radxa -m 0755 /var/lib/meow-os
install -m 0755 scripts/meow-wait-display /opt/meow-os/bin/meow-wait-display
sed 's/\r$//' scripts/meow-display-preflight > /tmp/meow-display-preflight && install -m 0755 /tmp/meow-display-preflight /opt/meow-os/bin/meow-display-preflight
sed 's/\r$//' scripts/meow-console-recovery > /tmp/meow-console-recovery && install -m 0755 /tmp/meow-console-recovery /opt/meow-os/bin/meow-console-recovery
sed 's/\r$//' scripts/meow-log-snapshot > /tmp/meow-log-snapshot && install -m 0755 /tmp/meow-log-snapshot /opt/meow-os/bin/meow-log-snapshot
install -m 0755 scripts/configure-boot-branding /opt/meow-os/bin/configure-boot-branding
install -m 0755 scripts/install-early-splash /opt/meow-os/bin/install-early-splash
install -m 0644 plymouth/meow-os/meow-os.plymouth /opt/meow-os/share/early-splash/theme/meow-os.plymouth
install -m 0644 plymouth/meow-os/meow-os.script /opt/meow-os/share/early-splash/theme/meow-os.script
install -m 0755 plymouth/meow-os/init-top-meow-plymouth /opt/meow-os/share/early-splash/theme/init-top-meow-plymouth
install -m 0755 plymouth/meow-os/init-premount-meow-plymouth /opt/meow-os/share/early-splash/theme/init-premount-meow-plymouth
install -m 0755 plymouth/meow-os/zz-meow-plymouth /opt/meow-os/share/early-splash/theme/zz-meow-plymouth
install -m 0644 assets/boot/meow-boot-landscape.png /opt/meow-os/share/early-splash/assets/meow-boot-landscape.png
install -m 0644 assets/boot/meow-boot-portrait.png /opt/meow-os/share/early-splash/assets/meow-boot-portrait.png
install -m 0755 systemd/vt_mode.py /opt/meow-os/vt_mode.py
sed 's/\r$//' systemd/meow-os.service > /tmp/meow-os.service && install -m 0644 /tmp/meow-os.service /etc/systemd/system/meow-os.service
sed 's/\r$//' systemd/meow-console-recovery.service > /tmp/meow-console-recovery.service && install -m 0644 /tmp/meow-console-recovery.service /etc/systemd/system/meow-console-recovery.service
sed 's/\r$//' systemd/meow-mindustry.service > /tmp/meow-mindustry.service && install -m 0644 /tmp/meow-mindustry.service /etc/systemd/system/meow-mindustry.service
sed 's/\r$//' config/meow-mindustry-sudoers > /tmp/meow-mindustry-sudoers && install -m 0440 /tmp/meow-mindustry-sudoers /etc/sudoers.d/meow-mindustry
sed 's/\r$//' scripts/meow-pvz-launch.sh > /tmp/meow-pvz-launch.sh && install -m 0755 /tmp/meow-pvz-launch.sh /opt/meow-os/bin/meow-pvz-launch.sh
install -m 0644 scripts/meow-pvz-keyboard.py /opt/meow-os/bin/meow-pvz-keyboard.py
install -m 0644 scripts/meow-pvz-touch.py /opt/meow-os/bin/meow-pvz-touch.py
sed 's/\r$//' systemd/meow-pvz.service > /tmp/meow-pvz.service && install -m 0644 /tmp/meow-pvz.service /etc/systemd/system/meow-pvz.service
sed 's/\r$//' config/meow-pvz-sudoers > /tmp/meow-pvz-sudoers && visudo -cf /tmp/meow-pvz-sudoers && install -m 0440 /tmp/meow-pvz-sudoers /etc/sudoers.d/meow-pvz
sed 's/\r$//' systemd/meow-boot-log.service > /tmp/meow-boot-log.service && install -m 0644 /tmp/meow-boot-log.service /etc/systemd/system/meow-boot-log.service
sed 's/\r$//' systemd/meow-diagnostic-capture@.service > /tmp/meow-diagnostic-capture@.service && install -m 0644 /tmp/meow-diagnostic-capture@.service /etc/systemd/system/meow-diagnostic-capture@.service
install -m 0644 systemd/meow-charge-enable.service /etc/systemd/system/meow-charge-enable.service
install -m 0644 systemd/meow-nvme-mount@.service /etc/systemd/system/meow-nvme-mount@.service
install -m 0644 config/display.conf /etc/meow-os/display.conf
install -m 0644 config/eglfs-kms.json /opt/meow-os/eglfs-kms.json
install -m 0644 config/asound.conf /etc/asound.conf
install -m 0644 config/journald-meow-os.conf /etc/systemd/journald.conf.d/99-meow-os.conf
install -m 0644 polkit/49-meow-os-network.rules /etc/polkit-1/rules.d/49-meow-os-network.rules
install -m 0644 polkit/49-meow-os-network.pkla /etc/polkit-1/localauthority/50-local.d/49-meow-os-network.pkla
rm -f /etc/polkit-1/rules.d/49-meow-os-mindustry.rules
install -m 0644 udev/99-meow-os-input.rules /etc/udev/rules.d/99-meow-os-input.rules
install -m 0644 udev/90-meow-nvme-data.rules /etc/udev/rules.d/90-meow-nvme-data.rules

# Keep the user's Fcitx profile intact while ensuring the bundled pinyin
# engine is available as a selectable input method in the game session.
install -d -o radxa -g radxa -m 0700 /home/radxa/.config/fcitx5
if [ ! -f /home/radxa/.config/fcitx5/profile ]; then
    printf '%s\n' '[Groups/0]' 'Name=Default' 'Default Layout=us' 'DefaultIM=keyboard-us' \
        '' '[Groups/0/Items/0]' 'Name=keyboard-us' 'Layout=' \
        '' '[Groups/0/Items/1]' 'Name=pinyin' 'Layout=' '' '[GroupOrder]' '0=Default' \
        > /home/radxa/.config/fcitx5/profile
elif ! grep -q '^Name=pinyin$' /home/radxa/.config/fcitx5/profile; then
    printf '%s\n' '' '[Groups/0/Items/1]' 'Name=pinyin' 'Layout=' \
        >> /home/radxa/.config/fcitx5/profile
fi
chown radxa:radxa /home/radxa/.config/fcitx5/profile
printf 'NAME="Meow OS"\nVERSION="%s"\nID=meow-os\nPRETTY_NAME="Meow OS %s"\n' "$VERSION" "$VERSION" > /etc/meow-os-release
printf '%s\n' "$SOURCE_HASH" > /etc/meow-os/build.sha256

usermod -aG input,video,render,audio,i2c,netdev radxa
systemctl daemon-reload
systemctl restart systemd-journald.service
journalctl --flush || true
udevadm control --reload-rules
systemctl enable meow-os.service
systemctl enable meow-boot-log.service
if systemctl list-unit-files systemd-pstore.service >/dev/null 2>&1; then
    systemctl enable systemd-pstore.service || true
fi
systemctl enable meow-charge-enable.service
/opt/meow-os/bin/configure-boot-branding
for partition in /dev/nvme*n*p[0-9]; do
    [ -b "$partition" ] || continue
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /data; then
        break
    fi
    systemctl start "meow-nvme-mount@$(basename "$partition").service" || true
    break
done
