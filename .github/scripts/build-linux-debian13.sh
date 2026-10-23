#!/usr/bin/env bash
# 在 Debian 13 (trixie) 容器内构建 Kelivo Linux 桌面版并打包 .deb。
# 由 .github/workflows/kelivo-agent-linux-debian13.yml 调用，工作目录为 /work。
set -euo pipefail

: "${VERSION:?VERSION 未设置}"
: "${VERSION_NUMBER:?VERSION_NUMBER 未设置}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.1}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git unzip xz-utils file dpkg-dev \
  clang cmake ninja-build pkg-config build-essential \
  libgtk-3-dev liblzma-dev libglu1-mesa-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libkeybinder-3.0-dev libayatana-appindicator3-dev libunwind-dev

curl -fsSL -o /tmp/flutter.tar.xz \
  "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
tar -xJf /tmp/flutter.tar.xz -C /opt
export PATH="/opt/flutter/bin:${PATH}"
git config --global --add safe.directory /opt/flutter
git config --global --add safe.directory "$PWD"

flutter --version
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release

BUNDLE="build/linux/x64/release/bundle"

# 便携 tar.gz
tar -C "$BUNDLE" -czf "Kelivo_linux_${VERSION}_debian13_amd64.tar.gz" .

# 组装 .deb
PKG=/tmp/kelivo-deb
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/kelivo" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE"/. "$PKG/opt/kelivo/"
ln -s /opt/kelivo/kelivo "$PKG/usr/bin/kelivo"

ICON_SOURCE="linux/kelivo.png"
[ -f "$ICON_SOURCE" ] || ICON_SOURCE="assets/app_icon.png"
install -m 644 "$ICON_SOURCE" "$PKG/usr/share/icons/hicolor/256x256/apps/kelivo.png"

cat > "$PKG/usr/share/applications/kelivo.desktop" <<'EOF'
[Desktop Entry]
Name=Kelivo
Comment=LLM chat client with agent tools
Exec=/opt/kelivo/kelivo
Path=/opt/kelivo
Icon=kelivo
Terminal=false
Type=Application
Categories=Utility;Network;
StartupWMClass=kelivo
Keywords=LLM;Chat;AI;
EOF

# 运行时依赖：按 ldd 反查 Debian 13 包名，避免手写 libgtk3 t64 等命名差异
mapfile -t DEP_PKGS < <(
  for bin in "$PKG/opt/kelivo/kelivo" "$PKG"/opt/kelivo/lib/*.so*; do
    [ -f "$bin" ] || continue
    ldd "$bin" 2>/dev/null || true
  done \
    | awk '/=> \// {print $3}' \
    | sort -u \
    | xargs -r dpkg -S 2>/dev/null \
    | cut -d: -f1 \
    | tr ',' '\n' \
    | sed 's/^ *//' \
    | grep -v '^$' \
    | grep -v '^kelivo$' \
    | sort -u
)
DEPENDS=$(IFS=,; echo "${DEP_PKGS[*]}")
DEPENDS="${DEPENDS:-libgtk-3-0t64 | libgtk-3-0, libc6}"

cat > "$PKG/DEBIAN/control" <<EOF
Package: kelivo
Version: ${VERSION_NUMBER}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Psyche <your@email.com>
Installed-Size: $(du -sk "$PKG/opt" | cut -f1)
Depends: ${DEPENDS}
Recommends: xdg-utils
Description: Kelivo - LLM chat client with agent tools
 A Flutter-based LLM chat client with device tools, skills and memory.
EOF

dpkg-deb --build --root-owner-group "$PKG" \
  "Kelivo_linux_${VERSION}_debian13_amd64.deb"

ls -lh Kelivo_linux_*_debian13_amd64.*
