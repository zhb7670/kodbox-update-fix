#!/bin/sh
# =============================================================================
#可道云 KODBox 手动更新脚本（绕过失效的 static.kodcloud.io）
#
# 背景：
#   可道云在线更新地址 https://static.kodcloud.io/update/download/kodbox_X.zip
#   的域名已失效（NXDOMAIN），服务器返回 502，导致在线更新必然失败。
#   此脚本改为直接从 GitHub 官方仓库拉取最新版并覆盖安装。
#
# 用法：
#   sh kodbox-update.sh              # 自动检测最新版本并更新
#   sh kodbox-update.sh 1.70.03      # 指定版本
#
# ⚠️ 脚本会自动备份原目录到 /tmp/kodbox_backup_<时间戳>.tar.gz
# =============================================================================

set -e

VERSION="${1:-}"
GITHUB_API="https://api.github.com/repos/kalcaddle/kodbox/releases/latest"

echo "=========================================="
echo " 可道云 KODBox 手动更新工具"
echo "=========================================="

# ---------- 1. 定位 kodbox 安装目录 ----------
echo "[1/6] 定位 kodbox 安装目录..."
KOD_DIR=""
for d in /mnt/*/kodbox /opt/kodbox /root/kodbox /home/*/kodbox /www/kodbox /usr/share/kodbox; do
    if [ -f "$d/config.php" ]; then KOD_DIR="$d"; break; fi
done
if [ -z "$KOD_DIR" ]; then
    KOD_DIR=$(find / -maxdepth 6 -type f -name 'config.php' -path '*kodbox*' 2>/dev/null | head -n1 | xargs dirname 2>/dev/null || true)
fi
if [ -z "$KOD_DIR" ] || [ ! -d "$KOD_DIR" ]; then
    echo "  ✗ 找不到 kodbox 目录。"
    echo "    可手动指定：sh kodbox-update.sh <版本> /path/to/kodbox"
    exit 1
fi
echo "  ✓ 安装目录: $KOD_DIR"

# ---------- 2. 确定目标版本 ----------
echo "[2/6] 确定目标版本..."
if [ -z "$VERSION" ]; then
    VERSION=$(curl -sL --max-time 20 "$GITHUB_API" 2>/dev/null \
             | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi
if [ -z "$VERSION" ]; then
    VERSION="1.70.03"
    echo "  ! 无法获取最新版本，回退到 $VERSION"
fi
echo "  ✓ 目标版本: $VERSION"

# ---------- 3. 网络前置检查 ----------
echo "[3/6] 检查网络与 GitHub 可达性..."
if ! curl -sI --max-time 15 https://github.com >/dev/null 2>&1; then
    echo "  ✗ 无法访问 GitHub。请确认盒子能出网。"
    exit 1
fi
echo "  ✓ GitHub 可达"

# ---------- 4. 下载 ----------
echo "[4/6] 下载 kodbox $VERSION ..."
cd /tmp
rm -rf kodbox_new
if ! git clone --depth 1 --branch "$VERSION" \
     https://github.com/kalcaddle/kodbox.git kodbox_new 2>/dev/null; then
    echo "  ! git clone 失败，尝试直接下载 tarball..."
    rm -rf kodbox_new kodbox.tar.gz
    curl -sL --max-time 120 -o kodbox.tar.gz \
      "https://github.com/kalcaddle/kodbox/archive/refs/tags/${VERSION}.tar.gz" || {
        echo "  ✗ 下载失败"; exit 1; }
    mkdir -p kodbox_new
    tar xzf kodbox.tar.gz -C kodbox_new --strip-components=1 || { echo "  ✗ 解压失败"; exit 1; }
fi
if [ ! -f /tmp/kodbox_new/config.php ]; then
    echo "  ✗ 下载内容不完整（缺 config.php）"; exit 1
fi
echo "  ✓ 下载完成"

# ---------- 5. 备份 + 覆盖 ----------
echo "[5/6] 备份原目录并覆盖..."
BACKUP="/tmp/kodbox_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
tar czf "$BACKUP" -C "$(dirname "$KOD_DIR")" "$(basename "$KOD_DIR")" 2>/dev/null || true
echo "  ✓ 已备份到: $BACKUP"

# 保留本地 config.php（避免丢配置）
LOCAL_CFG=""
[ -f "$KOD_DIR/config.php" ] && cp -f "$KOD_DIR/config.php" /tmp/kodbox_local_config.php.bak && LOCAL_CFG="yes"

cp -rf /tmp/kodbox_new/. "$KOD_DIR/"
[ -n "$LOCAL_CFG" ] && cp -f /tmp/kodbox_local_config.php.bak "$KOD_DIR/config.php"

chown -R www:www "$KOD_DIR" 2>/dev/null || true
echo "  ✓ 覆盖完成"

# ---------- 6. 重启服务 ----------
echo "[6/6] 重启 web 服务..."
/etc/init.d/php-fpm restart 2>/dev/null || /etc/init.d/php56-fpm restart 2>/dev/null || true
/etc/init.d/nginx restart 2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true
sleep 2

echo ""
echo "=========================================="
echo " ✓ 更新完成！"
echo "   目录: $KOD_DIR"
echo "   备份: $BACKUP"
echo "   请刷新可道云页面确认版本"
echo "=========================================="