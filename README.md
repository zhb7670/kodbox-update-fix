# kodbox-update-fix

可道云（KODBox）**手动更新工具** —— 绕过失效的官方更新通道，改从 GitHub 官方仓库拉取源码部署。

---

## 为什么需要这个

在 OpenWrt（luci-app-kodexplorer）上点「可道云 → 在线更新」会失败，原因：

| 问题 | 现象 |
|---|---|
| 旧更新地址失效 | `static.kodcloud.io` 域名已废弃（NXDOMAIN / 502） |
| 新地址被封 | 官方接口改回 `static.kodcloud.com`，但该 CDN **整站返回 403** |

实测过 7 种绕过方式（加 Referer / 换 UA / 旧文件名 / 直连 IP / http 等）**全部 403**，连根路径也一样 —— 官方下载通道已完全封死。

**本脚本的思路**：不走官方 CDN，直接从可道云官方 GitHub 仓库
[kalcaddle/kodbox](https://github.com/kalcaddle/kodbox) 拉取源码部署。

---

## 快速使用

### 方式一：命令行执行（推荐）

SSH 登录盒子后执行：

```bash
wget https://raw.githubusercontent.com/zhb7670/kodbox-update-fix/main/kodbox-update.sh
sh kodbox-update.sh
```

### 方式二：指定版本 / 目录

```bash
sh kodbox-update.sh 1.70.03                      # 指定版本
sh kodbox-update.sh 1.70.03 /mnt/mmcblk1p4       # 同时指定安装目录
```

---

## 安装目录怎么确定

脚本按以下优先级自动判断（**通常不用你指定**）：

1. 命令行第二个参数
2. **LuCI → 同步与备份 → 可道云 → 项目目录**（`kodexplorer.project_directory`）
   —— 这才是 kodbox 真正的 web 根目录
3. 常见位置探测（`/mnt/*/`、`/www/kodbox` 等）
4. 兜底默认 `/mnt/mmcblk1p4`

> ⚠️ **重要**：LuCI 里配的「项目目录」是 kodbox 的**根目录本身**，
> 不是它下面再套一层 `kodbox/`。所以如果你把目录设为 `/mnt/mmcblk1p4`，
> 脚本就会把 `app/ config/ plugins/ static/ index.php` 直接放进该目录。

---

## 脚本做了什么

1. 定位 kodbox 安装目录
2. 查 GitHub 最新版本（或用你指定的版本）
3. 检查 GitHub 可达性
4. 下载 `tarball`（**不需要盒子装 git**）
5. 解压并校验完整性
6. 备份原文件 → 覆盖安装 → 重启服务

---

## 注意事项

| 项 | 说明 |
|---|---|
| **备份位置** | `/tmp/kodbox_backup_<时间戳>.tar.gz`，**只含 kodbox 自身文件** |
| ⚠️ **`/tmp` 是内存盘** | OpenWrt 的 `/tmp` 是 tmpfs，**重启即失效**，请及时取回备份 |
| 权限安全 | 只对 kodbox 自身目录 `chown`，**不会改动同分区其它应用**（如 AdGuardHome、docker） |
| 存储建议 | `/tmp` 在 OpenWrt 是内存盘，**重启丢**。建议装到 `/mnt/xxx` 等持久化分区 |
| 服务端口 | 可道云默认监听 **8080** |

---

## 已修复的坑（实测记录）

在多个 OpenWrt 设备上实测，遇到并解决了这些问题：

| # | 问题 | 解决 |
|---|---|---|
| 1 | 盒子未安装 `git` | 改用 GitHub tarball 下载，不依赖 git |
| 2 | busybox `tar` 不支持 `--strip-components` | 解压后进子目录取真实路径 |
| 3 | `config.php` 在 `config/` 子目录，不在顶层 | 修正完整性校验路径 |
| 4 | 递归 `chown` 会误改同分区其它应用 | 改为只改 kodbox 自身目录 |
| 5 | 打包整个挂载点风险极大 | 改为只备份 kodbox 自身文件 |
| 6 | 重启全局 php-fpm/nginx 会打断其它服务 | 只重启 kodexplorer（它用独立实例 + 8080） |

---

## 常见问题

**Q：更新后页面还是旧版本？**
A：检查 LuCI → 同步与备份 → 可道云 里的「项目目录」是否与脚本输出一致，然后清理浏览器缓存。

**Q：脚本提示「未找到 rootfs / 无法访问 GitHub」？**
A：盒子需要能访问 github.com。可先在盒子上执行：
```bash
wget --spider https://github.com && echo OK
```

**Q：能装最新版吗？**
A：可以。脚本默认从 GitHub 查最新 release 标签。实测可取到 **1.70.03**。

---

## 相关链接

- 可道云源码：https://github.com/kalcaddle/kodbox
- luci-app-kodexplorer：https://github.com/ophub/luci-app-amlogic

## 说明

本工具仅在用户确认官方更新通道不可用时提供手动替代方案。
可道云的版权与代码归属原作者 kalcaddle。