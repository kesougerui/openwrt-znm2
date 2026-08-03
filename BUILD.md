# ZN-M2 OpenWrt 固件编译材料说明（openwrt-znm2）

> 目标设备：ZN-M2（IPQ6000 · aarch64 · 512MB RAM）
> 固件定位：无 WiFi、有线 + NSS 硬件加速、OpenClash 科学上网专用

---

## 1. 材料组成

| 文件 | 作用 |
|---|---|
| `ipq60xx-6.12-nowifi.config` | 固件裁剪配置：目标机型、内核选项、包选择 |
| `diy_script.sh` | 编译前定制脚本：版本号、默认 IP、OpenClash、golang、feeds 清理 |
| `.github/workflows/IPQ60XX-6.12-NOWIFI.yml` | GitHub Actions 云编译流水线 |
| `*.bak` | 本次改进前的原始文件备份 |

## 2. 源码树要求

- **仓库**：`https://github.com/LiBwrt/openwrt-6.x.git`
- **分支**：`25.12-nss`（LibWrt 6.12 内核 + NSS 硬件加速分支）
- 包管理：apk（`CONFIG_USE_APK=y`）
- 该分支内置 NSS 驱动包（`kmod-qca-nss-drv-*`），config 中的 NSS 配置依赖它

## 3. 构建方式

### 3.1 GitHub Actions 云编译（仓库默认方式）

1. 推送本目录内容到 `kesougerui/openwrt-znm2`
2. 触发：GitHub 页面 **Star 仓库**（workflow 配置了 `watch` 触发），或
   Actions 页手动 `Run workflow`（可选 `force-build` 强制重新编译、`ssh` 远程调试）
3. 产物：Release 页自动发布（tag `ZN_M2-6.12-NOWIFI`），默认地址 `192.168.2.1`、密码空

Actions 流水线顺序（与本地手编差异点）：
```
clone 源码(LiBwrt 25.12-nss) → cp config → make defconfig
→ 缓存工具链 → feeds update/install(第一次)
→ 跑 diy_script.sh（golang 替换 + OpenClash clone + feeds 第二次 install）
→ make defconfig → make download → make 编译 → 发布
```
> 注意：`diy_script.sh` 内的 feeds install 是**第二次**，必须存在——
> 它让 golang 替换和 OpenClash 的依赖解析生效。

### 3.2 本地编译

```bash
git clone --depth 1 -b 25.12-nss https://github.com/LiBwrt/openwrt-6.x.git openwrt
cd openwrt
cp 报名材料目录/ipq60xx-6.12-nowifi.config .config
bash 报名材料目录/diy_script.sh
make defconfig
make -j$(nproc) V=s
# 产物：bin/targets/qualcommax/ipq60xx/*.bin
```

## 4. 编译前自检清单（check-first）

| # | 检查项 | 命令 | 通过标准 |
|---|---|---|---|
| 1 | 脚本语法 | `bash -n diy_script.sh` | 无输出 |
| 2 | config 键无冲突/重复 | 见 §6 脚本 | 无 WARN |
| 3 | sbwml golang 分支存在 | `git ls-remote --heads https://github.com/sbwml/packages_lang_golang 26.x` | 返回 `refs/heads/26.x`；若失败改 `GOLANG_BRANCH=25.x` 重跑脚本 |
| 4 | 源码树含 NSS 包 | `make defconfig 2>&1 \| grep -i "qca-nss"` | 无 "No rule to make target" |
| 5 | OpenClash 已落地 | `ls package/luci-app-openclash/Makefile` | 文件存在 |
| 6 | feeds 无 404 | 脚本第 8 步 `feeds update -a` | 无 `nss_packages/video` 相关报错 |

## 5. 配置要点解读

- **目标**：`qualcommax/ipq60xx` 单机型 `zn_m2`（`MULTI_PROFILE=n`，只出 ZN-M2 镜像）
- **nowifi**：ath11k 驱动/固件、hostapd、wifi-scripts、wireless-regdb 全禁
- **OpenClash 依赖**：bash、coreutils-nohup/timeout、libcap-bin、`kmod-tun`、
  `kmod-nf-tproxy`/`kmod-nft-tproxy`、`kmod-ipt-tproxy`/`iptables-mod-tproxy`、
  `ip-full`、`iptables-nft`+`xtables-nft`（兼容层）、`kmod-br-netfilter`、`kmod-ifb`
- **NSS 加速**：IGS/MAPT/PPTP/Shaper/Qdisc/MACsec，固件 12.2；WiFi 卸载关闭
- **精简项**：Docker 全家、USB 全家、btrfs/挂载工具、ttyd、Argon 主题均禁用

## 6. 改进日志（v2 相对原版）

### diy_script.sh
| 改进 | 原版问题 | v2 处理 |
|---|---|---|
| 版本号注入 | 单引号内 `$(date)` 在路由器上不展开，版本显示字面量 `v$(date +%Y.%m.%d)` | 编译期展开写死，与 `CONFIG_VERSION_NUMBER` 一致 |
| 幂等性 | 重复执行会重复插入配置/重复 clone | 全程幂等：标记行检查、grep 防重、目录存在则 pull |
| 失败保护 | 无 `set -e`，clone 失败也继续 | `set -e` + 前置检查（源码目录/.config）+ 步骤化进度输出 |
| golang 分支 | `-b 26.x` 硬依赖，分支不存在直接失败 | 先 `ls-remote` 验证，失败保留上游并提示 |
| feeds 清理 | 无差别删含 "video" 的行 | 只删 `^src-git` 行，避免误伤 |
| 默认 IP / 版本号 | 目标文件不存在时静默 | 存在性检查 + 可调参数（`DEFAULT_IP`/`GOLANG_BRANCH`） |

### ipq60xx-6.12-nowifi.config
| 改进 | 说明 |
|---|---|
| 补 OpenClash 依赖 8 项 | bash / coreutils-nohup / coreutils-timeout / libcap-bin / iptables-mod-tproxy / kmod-ipt-tproxy / dnsmasq-full / zoneinfo-asia（显式声明，依赖解析也会自动补齐） |
| 清理 13 处重复键 | firewall、libmbedtls、ip-full、iptables-mod-extra、btrfs-progs、mount-utils、ath11k-firmware×2、kmod-ath×4 各保留一份 |
| 关键注释 | NSS 报错排查、initramfs 刷机提示、USB 扩展提示 |

### 新增 BUILD.md
编译流程、自检清单、FAQ、改进对照表（本文件）。

## 7. 常见问题 FAQ

**Q1：刷机需要 initramfs 吗？**
当前 `CONFIG_TARGET_ROOTFS_INITRAMFS=n`，只产 squashfs 镜像。若你的刷机路径是
U-Boot 直刷 initramfs（tftp 方式），把该行改为 `y` 重新编译。

**Q2：dnsmasq-full 会和我路由上的 OxiDNS 冲突吗？**
不会。`dnsmasq-full` 是 dnsmasq 的功能增强版（nftset/ipset 支持），配置为
上游转发到 `127.0.0.1:5335` 的用法完全兼容；同时满足 OpenClash DNS 劫持需求。

**Q3：OpenClash TPROXY 模式起不来？**
检查固件是否含 `kmod-ipt-tproxy` + `iptables-mod-tproxy`（v2 已显式加入）；
内核侧 TPROXY 由 `kmod-nf-tproxy`/`kmod-nft-tproxy` 提供，均已包含。

**Q4：编译报 "No rule to make target kmod-qca-nss-drv-..."？**
确认 `REPO_BRANCH=25.12-nss`（NSS 包由该分支提供）。若换了分支，删掉 config
中 `NSS 驱动` 段与 `CONFIG_NSS_DRV_*`/`CONFIG_NSS_FIRMWARE_*` 行。

**Q5：版本号显示问题？**
原版脚本注入的版本号在部分固件上会显示字面量 `v$(date +%Y.%m.%d)`（shell 单引号
不展开），v2 已修复为编译日期，与 LuCI 中 CONFIG_VERSION_NUMBER 一致。
