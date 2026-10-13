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
#   sh kodbox-update.sh                    # 自动获取最新版，装到 LuCI 配置的目录
#   sh kodbox-update.sh 1.70.03# 指定版本
#   sh kodbox-update.sh 1.70.03 /mnt/mmcblk1p4   # 同时指定安装目录
#
# 安装目录优先级：
#   1) 命令行第二个参数
#   2) LuCI 「同步与备份」里 kodexplorer 的 project_directory（真正的 web 根目录）
#   3) 常见位置探测
#   4) 默认 /mnt/mmcblk1p4
#
# v3 修复（实测踩坑记录）：
#   1) 盒子未安装 git          -> 改用 GitHub tarball，不依赖 git
#   2) busybox tar 不支持 --strip-components -> 解压后进子目录取真实路径
#   3) config.php 在 config/ 子目录，不在顶层-> 修正完整性校验路径
#   4) 插件目录嵌套导致拍平错乱-> 改为逐项 chown，只改 kodbox 自身目录
#   5) 打包整个挂载点风险极大  -> 改为只备份 kodbox 自身文件
#
# ⚠️ 会自动备份原目录（只含 kodbox 文件）到 /tmp/kodbox_backup_<时间戳>.tar.gz
# ⚠️ 注意：/tmp 在 OpenWrt 是内存盘（tmpfs），重启即失效，备份请及时取回。
# =============================================================================

echo "=========================================="
echo " 可道云 KODBox 手动更新工具 v2"
echo "=========================================="

VERSION="${1:-}"
DEST="${2:-}"# 可选第二个参数：指定安装目录
API="https://api.github.com/repos/kalcaddle/kodbox/releases/latest"

# ---------- 1. 定位安装目录 ----------
echo "[1/6] 定位 kodbox 安装目录..."
rm -rf /tmp/kb_extract /tmp/kb_dl /tmp/kodbox_new 2>/dev/null

KOD_DIR=""
# 1) 命令行指定优先
if [ -n "$DEST" ]; then
    KOD_DIR="$DEST"
    echo "  使用命令行指定目录: $KOD_DIR"
else
    # 2) 读取 LuCI 已配置的 project_directory（这才是真正的 web 根目录）
    CFG="$(uci -q get kodexplorer.@global[0].project_directory 2>/dev/null)"
    if [ -n "$CFG" ] && [ -d "$CFG" ]; then
        KOD_DIR="$CFG"
        echo "  使用 LuCI 项目目录: $KOD_DIR"
    fi
    # 3) 回退：扫常见位置（注意是 <dir>/config/version.php）
    if [ -z "$KOD_DIR" ]; then
        for d in /mnt/*/ /www/kodbox /opt/kodbox /usr/share/kodbox /tmp/kodcloud; do
            if [ -f "${d%/}/config/version.php" ]; then KOD_DIR="${d%/}"; break; fi
        done
        [ -n "$KOD_DIR" ] && echo "  自动探测到: $KOD_DIR"
    fi
    # 4) 都没找到 -> 默认装到 /mnt/mmcblk1p4（持久化存储，重启不丢）
    if [ -z "$KOD_DIR" ]; then
        KOD_DIR="/mnt/mmcblk1p4"
        echo "  未找到现有安装，装到默认位置: $KOD_DIR"
    fi
fi
echo "  安装目录: $KOD_DIR"

CUR_VER=""
[ -f "$KOD_DIR/config/version.php" ] && CUR_VER=$(grep "define(.KOD_VERSION"  "$KOD_DIR/config/version.php" 2>/dev/null | head -1 | cut -d"'" -f4)
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
# 注意：busybox find 不支持 -path，这里直接取唯一子目录
SRC_DIR=$(ls -d /tmp/kb_extract/*/ 2>/dev/null | head -n1)
if [ -z "$SRC_DIR" ]; then
    echo "  ✗ 解压后未找到内容目录"
    exit 1
fi
if [ ! -f "${SRC_DIR}config/version.php" ] || [ ! -f "${SRC_DIR}index.php" ]; then
    echo "  ✗ 解压后内容不完整（缺 index.php 或 config/version.php）"
    exit 1
fi
echo "  ✓ 解压完成: $SRC_DIR"

# ---------- 6. 备份 + 覆盖 ----------
echo "[6/6] 备份并安装..."
# 仅在已安装过时才备份（避免把整个 /mnt 分区打包）
if [ -f "$KOD_DIR/config/version.php" ]; then
    BACKUP="${TMPDIR:-/tmp}/kodbox_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    # 只备份 kodbox 自身文件，不打包整个目录（目录里可能有 AdGuardHome 等其它内容）
    tar czf "$BACKUP" -C "$KOD_DIR" \
        index.php app config plugins static data ChangeLog.md 2>/dev/null || true
    if [ -f "$BACKUP" ]; then
        echo "  ✓ 已备份 kodbox 文件到: $BACKUP"
    else
        echo "  ! 备份失败（不影响安装）"
        BACKUP=""
    fi
else
    echo "  ! 首次安装，无需备份"
    BACKUP=""
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

# 只改 kodbox 自身目录的属主（KOD_DIR 里可能还有 AdGuardHome 等其它应用，
# 不能 chown -R 整个目录，否则会破坏别人的权限）
for sub in app config data plugins static index.php; do
    [ -e "$KOD_DIR/$sub" ] && chown -R www:www "$KOD_DIR/$sub" 2>/dev/null
done

rm -rf /tmp/kb_dl /tmp/kb_extract /tmp/kb.tar.gz /tmp/kodbox_new

# 重启可道云服务（若已安装该 init 脚本）
if [ -x /etc/init.d/kodexplorer ]; then
    /etc/init.d/kodexplorer stop2>/dev/null || /etc/init.d/kodexplorer stop 2>/dev/null
    sleep 2
    /etc/init.d/kodexplorer start 2>/dev/null
    echo "  ✓ 已重启 kodexplorer 服务"
fi
# 注意：不要重启全局 php-fpm / nginx —— 盒子上还有 AdGuardHome 等其它服务在用，
# kodexplorer 使用自己独立的 php-fpm 实例与 nginx 配置（端口 8080）。

sleep 2

NEW_VER=$(grep "define(.KOD_VERSION"  "$KOD_DIR/config/version.php" 2>/dev/null | head -1 | cut -d"'" -f4)
echo ""
echo "=========================================="
echo " ✓ 安装完成"
echo "   目录  : $KOD_DIR"
echo "   版本  : ${CUR_VER:-无} -> ${NEW_VER:-未知}"
[ -n "$BACKUP" ] && [ -f "$BACKUP" ] && echo "   备份  : $BACKUP"
echo ""
echo " 请刷新可道云页面确认版本。"
echo " 若页面版本未变，请在 LuCI 同步与备份中确认"
echo " 「项目目录」与上面目录一致：$KOD_DIR"
echo "==========================================="