#!/bin/bash
set -e

echo "=========================================="
echo "  MeowOS PvZ-Portable 原生移植与部署工具"
echo "=========================================="

GAMES_DIR="/home/radxa/games"
PVZ_DIR="${GAMES_DIR}/pvz"

echo "[1/4] 安装编译与多媒体依赖 (SDL2 / GLES / CMake)..."
sudo apt-get update
sudo apt-get install -y cmake build-essential ninja-build \
    libsdl2-dev libopenmpt-dev libpng-dev libjpeg-dev zlib1g-dev \
    xserver-xorg-core xserver-xorg-video-modesetting xserver-xorg-input-libinput \
    x11-xserver-utils x11-utils xinput onboard

echo "[2/4] 克隆并编译 PvZ-Portable 官方原版逆向开源引擎..."
mkdir -p "${GAMES_DIR}"
cd "${GAMES_DIR}"
if [ ! -d "PvZ-Portable" ]; then
    git clone https://github.com/wszqkzqk/PvZ-Portable.git
    git -C PvZ-Portable checkout "${MEOW_PVZ_REF:-d77bf193b90502dce7594b3e6db556a11825f63e}"
else
    echo "Preserving existing source checkout and local changes"
fi

cd "${GAMES_DIR}/PvZ-Portable"
mkdir -p build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DLOW_MEMORY=ON ..
ninja -j"${MEOW_BUILD_JOBS:-2}"

echo "[3/4] 组织游戏资源与自动存档目录..."
mkdir -p "${PVZ_DIR}/userdata"
test -x "${GAMES_DIR}/PvZ-Portable/build/pvz-portable"
install -m 0755 "${GAMES_DIR}/PvZ-Portable/build/pvz-portable" "${PVZ_DIR}/pvz-portable"
if [ -d "${GAMES_DIR}/PvZ-Portable/properties" ]; then
    cp -r "${GAMES_DIR}/PvZ-Portable/properties" "${PVZ_DIR}/"
fi

echo "[4/4] 生成 MeowOS 启动与退出自动保存包装脚本..."
cat << 'EOF' > "${PVZ_DIR}/run.sh"
#!/bin/bash
cd /home/radxa/games/pvz
exec sudo -n /bin/systemctl --no-block start meow-pvz.service
EOF
chmod +x "${PVZ_DIR}/run.sh"

echo "=========================================="
echo "  PvZ-Portable 引擎编译完成！"
echo "  请将官方 main.pak 放入 ${PVZ_DIR}/main.pak 即可畅玩！"
echo "=========================================="
