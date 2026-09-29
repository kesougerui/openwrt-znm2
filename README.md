# ZN-M2 OpenWrt 固件编译材料说明（openwrt-znm2）

> 目标设备：ZN-M2（IPQ6000 · aarch64 · 512MB RAM）
> 固件定位：无 WiFi、有线 + NSS 硬件加速、**daed（eBPF 透明代理）+ UPnP** 专用

---

## 1. 材料组成

| 文件 | 作用 |
|---|---|
| `ipq60xx-6.12-nowifi.config` | 固件构建配置：daed(eBPF) + UPnP，无 OpenClash / 无 OxiDNS |
| `diy_script.sh` | 编译前定制脚本：版本号、默认 IP、golang、daed clone+补丁、eBPF/BTF 内核注入、feeds 清理 |
| `.github/workflows/IPQ60XX-6.12-NOWIFI.yml` | GitHub Actions 工作流（编译 + Release + 钩子脚本） |
| `BUILD.md` | 本文 |

---

## 2. 源码树要求（已内置）

工作流已内置使用 `LiBwrt/openwrt-6.x` @ `25.12-nss`：
- `target/linux/qualcommax/config-6.12` ✓
- `target/linux/qualcommax/ipq60xx/config-default` ✓（eBPF/BTF 注入目标之一）

---

## 3. 构建方式

**方式一（推荐）：GitHub Actions**
1. 打开仓库 `Actions` → 选择 `IPQ60XX-6.12-NOWIFI`
2. 点 `Run workflow`（或 Star 仓库自动触发）
3. 完成后产物在 `Releases`

**方式二：本地**
```bash
bash diy_script.sh
```

**diy_script.sh 执行流程（8 步）：**
```text
[0/8]   前置检查（防呆）
[0.5]   补装 host 工具（clang + pahole/dwarves：daed eBPF 字节码 + BTF 内核）
[1/8]   自定义版本信息 + 网络诊断地址
[2/8]   最大连接数 65535（幂等）
[3/8]   golang 换 sbwml 版（先验证分支，失败回退上游）
[4/8]   默认 LAN IP
[5/8]   .config 版本号 = 编译日期（幂等）
[6/8]   daed 落地：clone QiuSimons/luci-app-daed@kix + 3 条编译补丁 + eBPF/BTF 内核注入
[7/8]   清理 feeds.conf.default 中不存在的 feed
[8/8]   重新拉取并安装 feeds + 清除 feed 自带 luci-app-daed/daed 冲突
```

---

## 4. 自检清单

| # | 检查点 | 命令 / 位置 | 期望 |
|---|---|---|---|
| 1 | NSS 驱动落地 | `make package/collect/kmods/compile V=s` | `kmod-qca-nss-drv.ko` 生成 |
| 2 | ipq60xx 目录存在 | `ls target/linux/qualcommax/ipq60xx/` | 目录存在 |
| 3 | nowifi 包关闭 | `grep -E "CONFIG_PACKAGE_iwlwifi\|CONFIG_PACKAGE_iwlwifi-latest-loaded" .config` | 两行均为 not set |
| 4 | luci 基础组件 | `grep CONFIG_PACKAGE_luci-i18n-base-zh-cn .config` | `=y` |
| 5 | daed 落地 | `ls package/luci-app-daed/daed/Makefile` | 文件存在 |
| 6 | BTF 内核注入 | `grep CONFIG_DEBUG_INFO_BTF=y target/linux/qualcommax/ipq60xx/config-default target/linux/qualcommax/config-6.12` | 两个文件均命中 |

---

## 5. 配置要点

### 1. daed（eBPF 透明代理）
- `CONFIG_PACKAGE_luci-app-daed=y`
- daed：Go 源码编译，`diy_script.sh` 自动 clone QiuSimons/luci-app-daed@kix 分支
- 依赖 golang 26.2.4 升级（Go 1.26 编译）
- 3 条编译补丁（源自 DaeWRT-CI 实测）：pnpm 非冻结锁文件、quic-go 换源、init 脚本修复

### 2. UPnP
- `CONFIG_PACKAGE_luci-app-upnp=y` + 中文语言包 + `miniupnpd-nftables`
- nftables 版本，与固件 firewall4 体系一致

### 3. eBPF / BTF 内核（daed 硬依赖）
- `.config`（OpenWrt 命名空间）：`CONFIG_KERNEL_DEBUG_INFO_BTF=y`、`KERNEL_CGROUP_BPF`、`KERNEL_BPF_EVENTS`、`KERNEL_XDP_SOCKETS`、`BPF_TOOLCHAIN_HOST` 等
- **原始内核 CONFIG 行**（`CONFIG_DEBUG_INFO_BTF=y` 等）由 `diy_script.sh [6/8]` 追加到：
  - `target/linux/qualcommax/ipq60xx/config-default`
  - `target/linux/qualcommax/config-6.12`
- 背景：generic config 默认 `# CONFIG_DEBUG_INFO_BTF is not set`，不注入则 daed 的 CO-RE 加载直接失败

### 4. NSS / nowifi（保持）
- `CONFIG_PACKAGE_sqm-scripts-nss=y`（硬件加速 SQM）
- `CONFIG_PACKAGE_kmod-qca-nss-crypto=y`
- `CONFIG_PACKAGE_iwlwifi=n`、`iwlwifi-latest-loaded=n`

---

## 6. 改进日志

### v2（2026-08-03：编译环境优化）
| 项目 | 说明 |
|---|---|
| golang 升级 | 1.24.0 → 1.25.7（升级到 26.2.4） |
| 新增 luci-app-openclash | 中文界面完整支持，max 版内核 |
| 拉取 luci-app-openclash | 新增支持含精简更新脚本 |
| 调整 OpenClash 配置 | 拉取 luci-app-openclash + 打开 upgrade + inline-nf 静态编译 |

### v3（本次：去 OpenClash → daed + eBPF）
| 项目 | 说明 |
|---|---|
| 移除 OpenClash | luci 包、coreutils-nohup/timeout、libcap-bin、iptables/kmod-tproxy、dnsmasq-full 全删 |
| 接入 daed | clone QiuSimons/luci-app-daed@kix + 3 条 DaeWRT 实测编译补丁（pnpm/quic/init） |
| eBPF/BTF 内核 | `.config` 11 行 + 脚本注入原始内核 BTF 配置（CO-RE 链路必需） |
| UPnP | luci-app-upnp + miniupnpd-nftables（原 =n 打开） |
| CI 健壮性 | 0.5 步补装 dwarves/clang（原依赖安装 URL 已 404）；feed 自带 luci-app-daed/daed 冲突清除 |
| OxiDNS | ~~打包进镜像~~ 不装（由用户自行按现役方式安装） |

---

## 7. 常见问题（FAQ）

**Q1：刷机后原地升级还是必须恢复出厂？**
用 `sysupgrade -n`（原地升级，保留配置），非 `-n` 会清掉 `/etc/config` 之外的配置文件。 initramfs → factory 首刷仍需双清。

**Q2：刷机后第一次开机，dnsmasq 和 daed 都想管 DNS 怎么办？**
- dnsmasq 开机占 53（默认开机自启）。daed 的 DNS 模块若配置为监听 53 会起不来。
- 不用 daed 接管 DNS：什么都不用做，dnsmasq 照常工作。
- 让 daed 接管 DNS：关掉 dnsmasq，`/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable`，再在 daed 界面配置 DNS 监听。
- OxiDNS 不在固件内；若你自行安装了 OxiDNS 要用它管 53：`/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable` 后启动 oxidns。

**Q3：NSS 报错，内核驱动没落地？**
强制重编 kmods：`make package/collect/kmods/compile V=s`，检查 `kmod-qca-nss-drv.ko`。

**Q4：编译时提示版本号/默认 IP 重复执行？**
`diy_script.sh` 已做幂等保护（grep 检查），可多次执行。

**Q5：如何确认 eBPF/BTF 已生效？**
刷机后执行 `ls /sys/kernel/btf/vmlinux`（有文件 = BTF 就绪），`cat /proc/sys/net/core/bpf_jit_enable` 应为 1。
