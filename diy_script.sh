#!/bin/bash
# =============================================================================
# diy_script.sh — OpenWrt 固件定制脚本
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
# =============================================================================
set -e    # 任一命令失败立即退出，避免带着残缺状态继续编译

# ---------- 可调参数 ----------
DEFAULT_IP="${DEFAULT_IP:-192.168.2.1}"       # 默认 LAN IP
BUILD_DATE="$(date +%Y.%m.%d)"                # 编译日期（版本号用，编译期固定）

# ---------- 0. 前置检查（防呆） ----------
[ -x ./scripts/feeds ] || { echo "!! 错误：未检测到 ./scripts/feeds，请在 OpenWrt 源码根目录运行本脚本"; exit 1; }
[ -f .config ]        || { echo "!! 错误：缺少 .config，请先执行：cp ipq60xx-6.12-nowifi.config .config"; exit 1; }
echo ">> [0/8] 前置检查通过（源码目录 OK，.config OK）"

# ---------- 0.5 补装 host 工具 + 腾磁盘（内核 BTF 用 pahole/dwarves） ----------
# GitHub runner 预装工具链占 20~30GB，BTF 内核(vmlinux debug)会把它撑爆
# （run #8 死于 No space left on device）。只在 runner 上存在这些目录，本地编译自动跳过。
if [ -d /opt/hostedtoolcache ] || [ -d /usr/local/lib/android ]; then
    echo ">> [0.5] 清理 runner 预装工具链释放磁盘"
    sudo rm -rf /opt/hostedtoolcache/* /usr/local/lib/android /usr/share/dotnet \
        /usr/local/.ghcup /opt/ghc /usr/local/share/powershell /usr/local/lib/node_modules 2>/dev/null || true
    df -h / | tail -1
fi
if ! command -v pahole >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo ">> [0.5] 安装 dwarves（BTF 构建依赖）"
        sudo apt-get update -qq >/dev/null 2>&1 || true
        sudo apt-get install -y -qq dwarves >/dev/null 2>&1 \
            || echo ">> 警告：dwarves 安装失败（构建机已有则可忽略）"
    else
        echo ">> 警告：无 apt-get，请自行确认 pahole 已安装"
    fi
fi

# ---------- 0.6 临时/缓存改道到构建盘 ----------
# maximize-build-space 后根分区只剩 ~100MB；GOCACHE/TMPDIR/npm 缓存默认落根分区，
# BTF(pahole) 临时文件会直接把根分区写爆（run#8/#9 死因）。
# GITHUB_ENV 写入对后续步骤（Download DL / Compile Firmware）生效；本地跑无此变量自动跳过。
if [ -n "$GITHUB_ENV" ] && [ -n "$GITHUB_WORKSPACE" ]; then
    CACHE_DIR="$GITHUB_WORKSPACE/.ci-cache"
    mkdir -p "$CACHE_DIR/tmp" "$CACHE_DIR/go-tmp"
    {
        echo "TMPDIR=$CACHE_DIR/tmp"
        echo "TMP=$CACHE_DIR/tmp"
        echo "TEMP=$CACHE_DIR/tmp"
        echo "GOCACHE=$CACHE_DIR/go-build"
        echo "GOMODCACHE=$CACHE_DIR/go-mod"
        echo "GOTMPDIR=$CACHE_DIR/go-tmp"
        echo "npm_config_cache=$CACHE_DIR/npm"
        echo "XDG_CACHE_HOME=$CACHE_DIR/xdg"
        echo "CCACHE_DIR=$CACHE_DIR/ccache"
    } >> "$GITHUB_ENV"
    echo ">> [0.6] 临时/缓存目录改道 $CACHE_DIR"
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

# ---------- 6. eBPF/BTF 内核配置注入 ----------
# 说明：generic 默认关闭 BTF；保留注入，以后装 daed 等 eBPF 插件可直接用
for KF in target/linux/qualcommax/ipq60xx/config-default target/linux/qualcommax/config-6.12; do
    [ -f "$KF" ] || continue
    if grep -q 'CONFIG_DEBUG_INFO_BTF=y' "$KF"; then
        echo ">> [6/8] $KF 已含 BTF 配置，跳过"
    else
        cat >> "$KF" <<'KEOF'
# ==== eBPF/BTF injected by diy_script.sh ====
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

# ---------- 8. 重新拉取并安装 feeds ----------
echo ">> [8/8] feeds update -a（网络较慢时请耐心等待）"
./scripts/feeds update -a || { echo "!! feeds update 失败，请检查网络后重试"; exit 1; }
echo ">> [8/8] feeds install -a"
./scripts/feeds install -a || { echo "!! feeds install 失败"; exit 1; }

# ---------- 完成提示 ----------
cat <<EOF

============================================
定制完成。下一步：
  make defconfig          # 让 .config 与 feeds 对齐
  make -j\$(nproc) V=s     # 开始编译（首次约 1-2 小时）
编译产物位于 bin/targets/qualcommax/ipq60xx/
============================================
EOF
