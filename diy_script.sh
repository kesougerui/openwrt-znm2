#!/bin/bash
# =============================================================================
# diy_script.sh — OpenWrt 固件定制脚本（ZN-M2 · IPQ6000 · nowifi · NSS · daed+OxiDNS）
#
# 适用源码树：LiBwrt/openwrt-6.x @ 25.12-nss（LibWrt 6.12 内核 + NSS 分支）
# 运行位置：必须在 openwrt 源码根目录（.github/workflows 中由 Actions 调用，
#           本地编译时手动执行）。
#
# 用法（顺序敏感）：
#   cp ipq60xx-6.12-nowifi.config .config
#   bash diy_script.sh
#   make defconfig && make -j$(nproc) V=s
#
# v2 改进（相对原版）：
#   * 修复版本号注入 bug：原版把 $(date) 写进单引号，路由器上不会展开，
#     会显示字面量 "v$(date +%Y.%m.%d)"；现改为编译期展开后写死，简单可靠。
#   * 全程幂等：重复执行不会重复插入/重复 clone。
#   * 失败保护：set -e + 前置检查 + 关键步骤显式报错。
#   * golang 分支先验证再替换，分支不存在时回退上游，不硬失败。
# =============================================================================
set -e    # 任一命令失败立即退出，避免带着残缺状态继续编译

# ---------- 可调参数 ----------
DEFAULT_IP="${DEFAULT_IP:-192.168.2.1}"       # 默认 LAN IP
GOLANG_BRANCH="${GOLANG_BRANCH:-26.x}"        # sbwml golang 分支
BUILD_DATE="$(date +%Y.%m.%d)"                # 编译日期（版本号用，编译期固定）

# ---------- 0. 前置检查（防呆） ----------
[ -x ./scripts/feeds ] || { echo "!! 错误：未检测到 ./scripts/feeds，请在 OpenWrt 源码根目录运行本脚本"; exit 1; }
[ -f .config ]        || { echo "!! 错误：缺少 .config，请先执行：cp ipq60xx-6.12-nowifi.config .config"; exit 1; }
echo ">> [0/8] 前置检查通过（源码目录 OK，.config OK）"

# ---------- 0.5 补装 host 工具（daed eBPF 字节码编译用 clang；内核 BTF 用 pahole/dwarves） ----------
if ! command -v pahole >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo ">> [0.5] 安装 dwarves + clang（BTF/eBPF 构建依赖）"
        sudo apt-get update -qq >/dev/null 2>&1 || true
        sudo apt-get install -y -qq dwarves clang >/dev/null 2>&1 \
            || echo ">> 警告：dwarves/clang 安装失败（构建机已有则可忽略）"
    else
        echo ">> 警告：无 apt-get，请自行确认 pahole 与 clang 已安装"
    fi
fi

# ---------- 1. 自定义版本信息 + 网络诊断地址 ----------
# 原理：99-default-settings 是 uci-defaults 脚本，首次开机执行一次后自删。
# 注入内容：改写 /etc/openwrt_release 的版本字段 + 设置 LuCI 诊断地址。
# 日期在编译期展开写死，与 .config 的 CONFIG_VERSION_NUMBER 保持一致。
DS="package/emortal/default-settings/files/99-default-settings"
if [ -f "$DS" ] && ! grep -q 'AutoBuild customization' "$DS"; then
    echo ">> [1/8] 注入自定义版本/诊断配置 -> $DS"
    sed -i '/^exit 0$/d' "$DS"
    cat >> "$DS" <<EOF
# === AutoBuild customization (injected by diy_script.sh) ===
sed -i '/^DISTRIB_REVISION=/d;/^DISTRIB_RELEASE=/d;/^DISTRIB_DESCRIPTION=/d' /etc/openwrt_release
cat >> /etc/openwrt_release <<'RELEASE'
DISTRIB_REVISION='v${BUILD_DATE}'
DISTRIB_RELEASE='v${BUILD_DATE}'
DISTRIB_DESCRIPTION='AutoBuild Firmware Compiled By @waynesg Build ${BUILD_DATE} @ OpenWrt'
RELEASE
uci set luci.diag.ping=www.baidu.com
uci set luci.diag.route=www.baidu.com
uci set luci.diag.dns=www.baidu.com
uci commit luci
exit 0
EOF
else
    echo ">> [1/8] 跳过版本注入（$DS 不存在或已定制过，脚本可重复执行）"
fi

# ---------- 2. 最大连接数 65535（幂等） ----------
SYSCTL="package/base-files/files/etc/sysctl.conf"
if [ -f "$SYSCTL" ] && ! grep -q '^net.netfilter.nf_conntrack_max=' "$SYSCTL"; then
    echo ">> [2/8] 写入 nf_conntrack_max=65535 -> $SYSCTL"
    sed -i '/customized in this file/a net.netfilter.nf_conntrack_max=65535' "$SYSCTL"
else
    echo ">> [2/8] 跳过：nf_conntrack_max 已存在或文件缺失"
fi

# ---------- 3. golang 换 sbwml 版（先验证分支，失败回退上游） ----------
# 说明：daed 是 Go 源码编译，需要较新的 Go 工具链。先 ls-remote 确认远程分支存在再替换；
#       分支不存在时保留上游 golang（仍可编译，只是版本旧），不中断构建。
if git ls-remote --heads https://github.com/sbwml/packages_lang_golang "$GOLANG_BRANCH" >/dev/null 2>&1; then
    echo ">> [3/8] 更换 golang -> sbwml 分支 $GOLANG_BRANCH"
    rm -rf feeds/packages/lang/golang
    git clone --depth 1 -b "$GOLANG_BRANCH" \
        https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
else
    echo ">> [3/8] 警告：sbwml golang 分支 [$GOLANG_BRANCH] 不存在，保留上游 golang（可用 GOLANG_BRANCH 覆盖）"
fi

# ---------- 4. 默认 LAN IP ----------
CFG_GEN="package/base-files/files/bin/config_generate"
if [ -f "$CFG_GEN" ]; then
    echo ">> [4/8] 默认 IP -> $DEFAULT_IP"
    sed -i "s/192.168.1.1/$DEFAULT_IP/g" "$CFG_GEN"
else
    echo ">> [4/8] 警告：未找到 $CFG_GEN，跳过 IP 修改"
fi

# ---------- 5. .config 版本号 = 编译日期（幂等） ----------
set_version() { # $1=CONFIG 键名  $2=值
    if grep -q "^$1=" .config; then
        sed -i "s/^$1=.*/$1=\"$2\"/" .config
    else
        echo "$1=\"$2\"" >> .config
    fi
}
echo ">> [5/8] 写入 .config 版本号：$BUILD_DATE"
set_version CONFIG_VERSION_NUMBER "$BUILD_DATE"
set_version CONFIG_VERSION_CODE  "R$(date +%Y%m%d)"

# ---------- 6. daed + OxiDNS + eBPF 内核配置 ----------
# 6a. daed（luci-app-daed，含 daed 后端；已存在则更新，保证可重复执行）
if [ -d package/luci-app-daed ]; then
    echo ">> [6/8] luci-app-daed 已存在，git pull 更新"
    git -C package/luci-app-daed pull --ff-only \
        || echo ">> [6/8] luci-app-daed 更新失败（忽略，使用现有版本）"
else
    echo ">> [6/8] clone luci-app-daed (kix) -> package/luci-app-daed"
    git clone --depth 1 -b kix https://github.com/QiuSimons/luci-app-daed package/luci-app-daed
fi
# 编译修补（源自 DaeWRT-CI 实测补丁：pnpm / quic-go 换源 / init 顺序）
sed -i 's/pnpm install ; \\/pnpm install --no-frozen-lockfile ; \\/g' package/luci-app-daed/daed/Makefile
sed -i 's|github.com/daeuniverse/quic-go|github.com/olicesx/quic-go|g' package/luci-app-daed/daed/Makefile
sed -i 's|/run/i\\  procd_set_param|/procd_set_param command/i \\\tprocd_set_param|g' package/luci-app-daed/luci-app-daed/root/etc/init.d/luci_daed

# 6b. OxiDNS 打包（仓库自带 package/oxidns -> 源码树）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$SCRIPT_DIR/package/oxidns" ] || { echo "!! 错误：缺少 $SCRIPT_DIR/package/oxidns"; exit 1; }
rm -rf package/oxidns
cp -r "$SCRIPT_DIR/package/oxidns" package/oxidns
echo ">> [6/8] oxidns 包已拷入 package/oxidns"

# 6c. eBPF/BTF 内核配置注入（generic 默认关闭 BTF，daed CO-RE 需要 /sys/kernel/btf/vmlinux）
for KF in target/linux/qualcommax/ipq60xx/config-default target/linux/qualcommax/config-6.12; do
    [ -f "$KF" ] || continue
    if grep -q 'CONFIG_DEBUG_INFO_BTF=y' "$KF"; then
        echo ">> [6/8] $KF 已含 BTF 配置，跳过"
    else
        cat >> "$KF" <<'KEOF'
# ==== eBPF/BTF (daed) injected by diy_script.sh ====
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUPS=y
CONFIG_KPROBES=y
CONFIG_NET_INGRESS=y
CONFIG_NET_EGRESS=y
CONFIG_NET_SCH_INGRESS=m
CONFIG_NET_CLS_BPF=m
CONFIG_NET_CLS_ACT=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y
KEOF
        echo ">> [6/8] eBPF/BTF 内核配置 -> $KF"
    fi
done

# ---------- 7. 清理 feeds.conf.default 中不存在的 feed ----------
# 说明：nss_packages / sqm_scripts_nss / video 是 ImmortalWrt 23.05 时代的专属
#       feed，LiBwrt 25.12-nss 树中不存在，留着会让 apk update 报错（404）。
#       只删 src-git 行，避免误伤注释。
echo ">> [7/8] 清理 feeds.conf.default（nss_packages/sqm_scripts_nss/video）"
sed -i '/^src-git \(nss_packages\|sqm_scripts_nss\|video\)\b/d' feeds.conf.default

# ---------- 8. 重新拉取并安装 feeds（golang 替换、daed/oxidns 落地均在此前完成） ----------
echo ">> [8/8] feeds update -a（网络较慢时请耐心等待）"
./scripts/feeds update -a || { echo "!! feeds update 失败，请检查网络后重试"; exit 1; }
echo ">> [8/8] feeds install -a"
./scripts/feeds install -a || { echo "!! feeds install 失败"; exit 1; }
# feeds 自带 luci-app-daed/dae/daed 与本地克隆的 package/luci-app-daed 冲突（重复包），
# feeds install -a 之后再清（防 make defconfig 报 duplicate）
rm -rf feeds/luci/applications/luci-app-dae* package/feeds/luci/luci-app-dae* \
       feeds/packages/net/daed package/feeds/packages/daed
echo ">> [8/8] 已清除 feeds 内置 daed/dae，使用本地 package/luci-app-daed"

# ---------- 完成提示 ----------
cat <<EOF

============================================
定制完成。下一步：
  make defconfig          # 让 .config 与 feeds 对齐
  make -j\$(nproc) V=s     # 开始编译（首次约 1-2 小时）
编译产物位于 bin/targets/qualcommax/ipq60xx/
============================================
EOF
