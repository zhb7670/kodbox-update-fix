#!/bin/sh
# =============================================================================
# 可道云 KODBox 手动更新脚本（绕过失效的 static.kodcloud.io / 被封的 static.kodcloud.com）
#
# 背景：
#   1) 在线更新地址 static.kodcloud.io 已失效（域名 NXDOMAIN + 502）
#   2) 官方接口虽已改回 static.kodcloud.com，但该CDN 整站返回 403，无法下载
#   3) 故改从 GitHub 官方仓库拉取源码部署（tarball 方式，不依赖 git）
#
# 用法：
#   sh kodbox-update.sh              # 自动获取最新版
#   sh kodbox-update.sh 1.70.03# 指定版本
#
# v2 修复（实测发现的 3 个问题）：
#   1) 盒子未安装 git -> 改用 GitHub tarball 下载，不再依赖 git
#   2) busybox tar 不支持 --strip-components -> 解压后进子目录取真实路径
#   3) config.php 实际在 config/ 子目录，不在顶层 -> 修正完整性校验路径
#
# ⚠️ 会自动备份原目录到 /tmp/kodbox_backup_<时间戳>.tar.gz
# =============================================================================

echo "=========================================="
echo " 可道云 KODBox 手动更新工具 v2"
echo "=========================================="

VERSION="${1:-}"
API="https://api.github.com/repos/kalcaddle/kodbox/releases/latest"

# ---------- 1. 定位安装目录 ----------
echo "[1/6] 定位 kodbox 安装目录..."
# 先清掉可能残留的临时/解压目录，避免把解压目录误判为安装目录
rm -rf /tmp/kb_extract /tmp/kb_dl /tmp/kodbox_new 2>/dev/null

KOD_DIR=""
for d in /tmp/kodcloud /www/kodbox /opt/kodbox /root/kodbox /usr/share/kodbox; do
    if [ -f "$d/config/version.php" ]; then KOD_DIR="$d"; break; fi
done
if [ -z "$KOD_DIR" ]; then
    for base in /mnt/*/ /www/ /opt/ /root/ /home/*/; do
        if [ -f "${base}kodcloud/config/version.php" ]; then KOD_DIR="${base}kodcloud"; break; fi
        if [ -f "${base}kodbox/config/version.php" ]; then KOD_DIR="${base}kodbox"; break; fi
    done
fi
if [ -z "$KOD_DIR" ]; then
    # find 时排除 /tmp 下的临时与解压目录
    KOD_DIR=$(find / -maxdepth 7 -type f -path '*/config/version.php' 2>/dev/null \
              | grep -v '^/tmp/kb' | grep -v '^/tmp/kodbox_new' | head -n1 | sed 's|/config/version.php||')
fi
if [ -z "$KOD_DIR" ] || [ ! -d "$KOD_DIR" ]; then
    echo "  ! 未找到已安装的 kodbox，将安装到默认位置 /tmp/kodcloud"
    echo "    （LuCI「同步与备份」里的项目目录需设为 /tmp/kodcloud）"
    KOD_DIR="/tmp/kodcloud"
fi
echo "  安装目录: $KOD_DIR"

CUR_VER=""
[ -f "$KOD_DIR/config/version.php" ] && CUR_VER=$(grep KOD_VERSION "'" "$KOD_DIR/config/version.php" 2>/dev/null | head -1 | cut -d"'" -f4)
echo "  当前版本: ${CUR_VER:-（未安装/无法读取）}"

# ---------- 2. 确定目标版本 ----------
echo "[2/6] 确定目标版本..."
if [ -z "$VERSION" ]; then
    VERSION=$(wget --no-check-certificate --timeout=20 -qO- "$API" 2>/dev/null \
             | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi
[ -z "$VERSION" ] && VERSION="1.70.03"
echo "  目标版本: $VERSION"

# ---------- 3. 网络检查 ----------
echo "[3/6] 检查 GitHub 可达性..."
if ! wget --no-check-certificate --timeout=15 -q --spider https://github.com 2>/dev/null; then
    echo "  ✗ 无法访问 GitHub，请确认盒子能出网"
    exit 1
fi
echo "  ✓ GitHub 可达"

# ---------- 4. 下载（tarball 方式，无需 git）----------
echo "[4/6] 下载 kodbox $VERSION ..."
cd /tmp || exit 1
rm -rf kb_dl kb_extract kodbox_new kb.tar.gz

if ! wget --no-check-certificate --timeout=120 -O kb.tar.gz \
     "https://github.com/kalcaddle/kodbox/archive/refs/tags/${VERSION}.tar.gz" 2>/dev/null; then
    echo "  ✗ 下载失败"
    exit 1
fi
if [ ! -s kb.tar.gz ]; then
    echo "  ✗ 下载内容为空"
    exit 1
fi
echo "  ✓ 下载完成 ($(du -h kb.tar.gz | cut -f1))"

# ---------- 5. 解压 ----------
echo "[5/6] 解压..."
mkdir -p kb_extract
# busybox tar 可能不支持 --strip-components，故先正常解压再取子目录
if ! tar xzf kb.tar.gz -C kb_extract 2>/dev/null; then
    echo "  ✗ 解压失败"
    exit 1
fi
# 真实内容目录（tarball 内有一层 kodbox-<version>/）
SRC_DIR=$(find /tmp/kb_extract -maxdepth 2 -type f -name 'version.php' -path '*/config/*' 2>/dev/null | head -n1 | sed 's|/config/version.php||')
if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
    SRC_DIR=$(ls -d /tmp/kb_extract/*/ 2>/dev/null | head -n1)
fi
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/index.php" ]; then
    echo "  ✗ 解压后内容不完整（缺 index.php）"
    exit 1
fi
echo "  ✓ 解压完成: $SRC_DIR"

# ---------- 6. 备份 + 覆盖 ----------
echo "[6/6] 备份并安装..."
BACKUP="/tmp/kodbox_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
if [ -d "$KOD_DIR" ] && [ -f "$KOD_DIR/config/version.php" ]; then
    tar czf "$BACKUP" -C "$(dirname "$KOD_DIR")" "$(basename "$KOD_DIR")" 2>/dev/null || true
    echo "  ✓ 已备份到: $BACKUP"
else
    echo "  ! 原目录不存在，跳过备份"
fi

mkdir -p "$KOD_DIR"
# 保留本地配置（首次安装无此文件，忽略报错）
if [ -f "$KOD_DIR/config/config.php" ]; then
    cp -f "$KOD_DIR/config/config.php" /tmp/kod_local_config.php.bak 2>/dev/null || true
fi

cp -rf "$SRC_DIR"/. "$KOD_DIR"/

# 恢复本地配置
if [ -f /tmp/kod_local_config.php.bak ]; then
    cp -f /tmp/kod_local_config.php.bak "$KOD_DIR/config/config.php" 2>/dev/null || true
    rm -f /tmp/kod_local_config.php.bak
fi

chown -R www:www "$KOD_DIR" 2>/dev/null || true
rm -rf /tmp/kb_dl /tmp/kb_extract /tmp/kb.tar.gz /tmp/kodbox_new

# 重启 web 服务
/etc/init.d/php-fpm restart 2>/dev/null || \
  /etc/init.d/php8-fpm restart 2>/dev/null || \
  /etc/init.d/php7-fpm restart 2>/dev/null || true
/etc/init.d/nginx restart 2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true
sleep 2

NEW_VER=$(grep KOD_VERSION "'" "$KOD_DIR/config/version.php" 2>/dev/null | head -1 | cut -d"'" -f4)
echo ""
echo "=========================================="
echo " ✓ 安装完成"
echo "   目录  : $KOD_DIR"
echo "   版本  : ${CUR_VER:-无} -> ${NEW_VER:-未知}"
[ -f "$BACKUP" ] && echo "   备份  : $BACKUP"
echo ""
echo " 请刷新可道云页面确认版本。"
echo " 若页面版本未变，请在 LuCI 同步与备份中确认"
echo " 「项目目录」与上面目录一致：$KOD_DIR"
echo "==========================================="