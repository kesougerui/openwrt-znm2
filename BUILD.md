# ZN-M2 OpenWrt 固件编译材料说明（openwrt-znm2）

> 目标设备：ZN-M2（IPQ6000 · aarch64 · 512MB RAM）
> 固件定位：无 WiFi、有线 + NSS 硬件加速、**daed（eBPF 透明代理）+ OxiDNS** 专用

---

## 1. 材料组成

| 文件 | 作用 |
|---|---|
| `ipq60xx-6.12-nowifi.config` | 固件裁剪配置：目标机型、内核选项、包选择 |
| `diy_script.sh` | 编译前定制脚本：版本号、默认 IP、golang、daed clone+补丁、OxiDNS 打包、eBPF/BTF 内核注入、feeds 清理 |
| `package/oxidns/` | OxiDNS 本地打包（预编译 musl 二进制 + 现役配置 + init/uci） |
| `.github/workflows/IPQ60XX-6.12-NOWIFI.yml` | GitHub Actions 云编译流水线（未改动） |

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

Actions 流水线顺序：

```
clone 源码(LiBwrt 25.12-nss) → cp config → make defconfig
→ 缓存工具链 → feeds update/install(第一次)
→ 跑 diy_script.sh
    [0.5] 补装 dwarves/clang（BTF/eBPF host 工具）
    [3]   golang 换 sbwml（daed 是 Go 编译）
    [6a]  clone QiuSimons/luci-app-daed @ kix + 3 条编译补丁
    [6b]  拷贝仓库 package/oxidns 进源码树
    [6c]  eBPF/BTF 原始内核配置注入 config-default + config-6.12
    [7/8] feeds 清理 + 二次 update/install + 清除 feeds 内置 daed/dae（防重复包）
→ make defconfig → make download → make 编译 → 发布
```

> 注意：`diy_script.sh` 内的 feeds install 是**第二次**，必须存在——
> golang 替换和 daed 依赖解析靠它生效。

### 3.2 本地编译

```bash
git clone --depth 1 -b 25.12-nss https://github.com/LiBwrt/openwrt-6.x.git openwrt
cd openwrt
cp 本目录/ipq60xx-6.12-nowifi.config .config
bash 本目录/diy_script.sh
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
| 5 | daed 已落地 | `ls package/luci-app-daed/daed/Makefile` | 文件存在 |
| 6 | OxiDNS 包已拷入 | `ls package/oxidns/Makefile` | 文件存在 |
| 7 | BTF 内核行已注入 | `grep CONFIG_DEBUG_INFO_BTF=y target/linux/qualcommax/ipq60xx/config-default` | 有输出 |
| 8 | feeds 无 404 | 脚本第 8 步 `feeds update -a` | 无 `nss_packages/video` 相关报错 |

## 5. 配置要点解读

- **目标**：`qualcommax/ipq60xx` 单机型 `zn_m2`（`MULTI_PROFILE=n`，只出 ZN-M2 镜像）
- **nowifi**：ath11k 驱动/固件、hostapd、wifi-scripts、wireless-regdb 全禁
- **daed**：`luci-app-daed=y`，core 由 diy 脚本克隆（`QiuSimons/luci-app-daed @ kix`），
  自带 `daed/` 后端（编译 BPF 字节码）；feeds 内置同名包会被脚本清除
- **OxiDNS**：`package/oxidns` 预编译 musl 二进制（v1.6.0），
  **现役路由器的 config.yaml / learned 列表 / init / uci 直接打进镜像**，
  均为 conffile（sysupgrade 升级保留）
- **eBPF 内核**：`.config` 加 `CONFIG_KERNEL_*`（CGROUP_BPF/BTF/EVENTS/XDP_SOCKETS 等），
  原始内核行（`CONFIG_DEBUG_INFO_BTF=y` 等，generic 默认关闭）由 diy 脚本注入
  `target/linux/qualcommax/ipq60xx/config-default` + `config-6.12`
- **host 工具**：daed 编译需 clang（eBPF 字节码）、内核 BTF 需 pahole/dwarves，
  脚本 0.5 步缺则自动补装（GitHub runner 无 pahole）
- **NSS 加速**：IGS/MAPT/PPTP/Shaper/Qdisc/MACsec，固件 12.2；WiFi 卸载关闭
- **精简项**：Docker 全家、USB 全家、btrfs/挂载工具、Argon 主题、OpenClash 全移除

## 6. 改进日志

### v3（本次：去 OpenClash → daed + OxiDNS + eBPF）

| 改进 | 说明 |
|---|---|
| 移除 OpenClash | luci-app-openclash、i18n、coreutils-nohup/timeout、libcap-bin、iptables/kmod-ipt-tproxy、dnsmasq-full 全删 |
| 接入 daed | clone `QiuSimons/luci-app-daed @ kix` + 3 条编译补丁（pnpm 加 `--no-frozen-lockfile`、quic-go 换源、luci_daed init 顺序）——补丁按字节拷自 DaeWRT-CI 实测版 |
| 新增 package/oxidns | 预编译 v1.6.0 musl 二进制（sha256 `8d7b8625…30db`）+ 现役配置，conffile 保留 |
| eBPF/BTF 内核 | `.config` 的 `CONFIG_KERNEL_*` + 脚本注入原始内核行（BTF CO-RE 链） |
| feed 冲突防护 | immortalwrt feed 自带 `luci-app-daed/dae`，feeds install 后强制清除，防 duplicate 包 |
| host 工具兜底 | is.gd 依赖地址已 404（上游挪文件），0.5 步按需补装 dwarves+clang |

### v2（原改进，保留有效）

版本号编译期展开、全程幂等、`set -e` 失败保护、golang 分支先验证、feeds 精准清理。

## 7. 常见问题 FAQ

**Q1：刷机需要 initramfs 吗？**
当前 `CONFIG_TARGET_ROOTFS_INITRAMFS=n`，只产 squashfs 镜像。若你的刷机路径是
U-Boot 直刷 initramfs（tftp 方式），把该行改为 `y` 重新编译。

**Q2：刷机后第一次开机，dnsmasq / OxiDNS / daed 都想管 53 端口怎么办？**
三者默认都会起来，必然抢 53。按你的 DNS 架构二选一（当前现役架构 = OxiDNS 管 53）：

```sh
# 方案 A（现役架构）：OxiDNS 管 53，关 dnsmasq，daed 的 DNS 监听改掉/不劫持 53
/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable

# 方案 B：让 daed 管 DNS，OxiDNS 退出 53
/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable
/etc/init.d/oxidns stop && /etc/init.d/oxidns disable
```

daed 侧在 LuCI「daed」里把 DNS 监听/劫持端口调好后再启用透明代理；
OxiDNS 侧配置在 `/etc/oxidns/config.yaml`（已带现役规则，开机即用）。

**Q3：编译报 "No rule to make target kmod-qca-nss-drv-..."？**
确认 `REPO_BRANCH=25.12-nss`（NSS 包由该分支提供）。若换了分支，删掉 config
中 `NSS 驱动` 段与 `CONFIG_NSS_DRV_*`/`CONFIG_NSS_FIRMWARE_*` 行。

**Q4：内核 BTF 编译报 pahole 相关错误？**
脚本 0.5 步会 `apt-get install dwarves`；若你的构建机无 apt，手动装
`dwarves`（提供 pahole）。GitHub Actions 上 runner 已有 clang。

**Q5：版本号显示问题？**
版本号为编译日期，与 LuCI 中 CONFIG_VERSION_NUMBER 一致（v2 修复版逻辑）。
