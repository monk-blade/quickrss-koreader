#!/usr/bin/env bash
# Install KOReader emulator build prerequisites on Debian/Ubuntu (incl. WSL2).
# See: https://github.com/koreader/koreader/blob/master/doc/Building.md
set -euo pipefail

echo "Installing KOReader build dependencies (requires sudo)…"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    autoconf automake build-essential ca-certificates cmake gcc-multilib gettext \
    git libtool libtool-bin meson nasm ninja-build patch pkg-config unzip wget \
    ccache lua-check luajit shellcheck shfmt

# SDL3 runtime package (optional). Ubuntu 24.04 (noble) does not ship libsdl3-0.
# When absent, KOReader builds SDL3 from source — that requires X11 or Wayland dev libs.
SDL_X11_DEV_PKGS=(
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev
    libxi-dev libxss-dev libxtst-dev libxkbcommon-dev libegl1-mesa-dev
)

echo ""
echo "Checking for SDL3…"
if apt-cache show libsdl3-0 &>/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libsdl3-0
    echo "Installed libsdl3-0 from apt."
else
    echo "libsdl3-0 not in apt — KOReader will compile SDL3 during ./kodev build."
    echo "Installing X11/EGL headers required for that SDL build (WSL2 uses X11)…"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${SDL_X11_DEV_PKGS[@]}"
fi

echo ""
echo "Done. WSL2 users: ensure DISPLAY is set (WSLg or VcXsrv)."
echo "  echo \$DISPLAY   # should not be empty"
echo ""
echo "Next steps:"
echo "  ./scripts/build-koreader.sh"
echo "  ./scripts/dev-link.sh"
