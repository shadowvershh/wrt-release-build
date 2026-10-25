#!/usr/bin/env bash
# 2026-09-18 本地定制 (幂等, 每次构建在 update.sh 之后自动重放)
# 用法: bash local_changes.sh <BUILD_DIR绝对路径>
# 定制内容:
#   1) 太乙 jdcloud_re-cs-07: 四个网口全部 LAN, 无 WAN (旁路由)
#   2) 从 small8 feed 安装 mihomo (OpenClash 内核)
#   3) 旁路由出厂预配置 (uci-defaults): 静态IP/网关, DHCP关闭, DNS链路
#   4) AdGuardHome 使用用户提供的 yaml 作为出厂配置
set -e

BUILD_DIR="$1"
[[ -d "$BUILD_DIR" ]] || { echo "local_changes: BUILD_DIR 不存在: $BUILD_DIR"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NET_FILE="$BUILD_DIR/target/linux/qualcommax/ipq60xx/base-files/etc/board.d/02_network"
DTS_FILE="$BUILD_DIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6010-re-cs-07.dts"

# ---- 1a) 太乙硬件口改名: dp1 原本 label="wan", 改为 lan0 ----
# LuCI "端口状态" 表是从 board.json 的 ports 里取网卡设备名的, 口就叫 wan 就会显示 wan 口。
# 四个口都要当 LAN, 所以把第一个口的设备名改掉: dp1..dp4 依次对应 lan0..lan3。
# 注意: 这里用 [[:space:]]* 而不是 ^\t — 本机 GNU grep 的 ERE 不认 \t 转义
if [ -f "$DTS_FILE" ] && grep -qE '^[[:space:]]*label = "(wan|lan4)";$' "$DTS_FILE"; then
    sed -i -E 's#^([[:space:]]*)label = "(wan|lan4)";$#\1label = "lan0";#' "$DTS_FILE"
    echo "local_changes: DTS dp1 label 已改为 lan0"
fi

# ---- 1b) 太乙四口全 LAN, 不建 wan 接口 ----
if [ -f "$NET_FILE" ] && grep -qF 'jdcloud,re-cs-07|\' "$NET_FILE"; then
    sed -i '\#^\tjdcloud,re-cs-07|\\$#d' "$NET_FILE"
    sed -i 's#^\tjdcloud,re-ss-01|\\$#\tjdcloud,re-cs-07)\n\t\tucidef_set_interface_lan "lan0 lan1 lan2 lan3"\n\t\t;;\n\tjdcloud,re-ss-01|\\#' "$NET_FILE"
    echo "local_changes: 太乙 02_network 已改为 4 口全 LAN (lan0 lan1 lan2 lan3)"
fi

# ---- 1c) 修正历史上已写入的旧版 (含 wan / lan4 口名) ----
if [ -f "$NET_FILE" ] && grep -qE 'ucidef_set_interface_lan "lan1 lan2 lan3 (wan|lan4)"' "$NET_FILE"; then
    sed -i -E 's#ucidef_set_interface_lan "lan1 lan2 lan3 (wan|lan4)"#ucidef_set_interface_lan "lan0 lan1 lan2 lan3"#' "$NET_FILE"
    echo "local_changes: 02_network 旧口名已修正为 lan0 lan1 lan2 lan3"
fi

# ---- 2) mihomo (OpenClash 内核) + 网易云解锁 ----
cd "$BUILD_DIR"
# CI: 上游 update_feeds 会主动移除 small8 源, 这里重新追加并强制安装(与本地构建等效)
if ! grep -q '^src-git small8' feeds.conf.default; then
    echo 'src-git small8 https://github.com/kenzok8/small-package' >> feeds.conf.default
    ./scripts/feeds update small8
    # 仅定向安装实际需要的包(与本地构建清单一致), 禁止 -a 全量安装:
    # small8 里新增了 opkg, -a 会覆盖核心 opkg (其 Makefile 无 host 构建),
    # 导致 make 报 "No rule to make target 'package/system/opkg/host/compile'"。
    ./scripts/feeds install -p small8 -f adguardhome chinadns-ng cups ddns-go dns2socks easytier geo2txt geoview haproxy hysteria ipt2socks luci-app-adguardhome luci-app-amlogic luci-app-cloudflarespeedtest luci-app-cupsd luci-app-ddns-go luci-app-easytier luci-app-homeproxy luci-app-istorex luci-app-lucky luci-app-mosdns luci-app-msd_lite luci-app-nikki luci-app-oaf luci-app-openclash luci-app-passwall luci-app-quickstart luci-app-ssr-plus luci-app-store luci-app-tailscale luci-lib-taskd luci-lib-xterm lucky mihomo mosdns msd_lite naiveproxy nikki oaf open-app-filter quickstart shadowsocksr-libev shadowsocks-rust simple-obfs sing-box tailscale taskd tcping trojan-plus tuic-client v2dat v2ray-core v2ray-geodata v2ray-plugin xray-core xray-plugin
fi

# CI: kenzok8 于 2026-10-23 把 xray-core 升到 26.10.21 (go.mod 要求 go >= 1.27),
# 其 Makefile 用默认 golang/host 变体。update.sh 已停用 sbwml 替换、恢复官方
# 多变体 golang (含 1.27), 这里把 xray 显式钉到 golang1.27/host。
for d in "$BUILD_DIR/feeds/custom_feed/xray-core" "$BUILD_DIR/feeds/small8/xray-core"; do
    if [ -f "$d/Makefile" ]; then
        sed -i 's#^PKG_BUILD_DEPENDS:=golang/host#PKG_BUILD_DEPENDS:=golang1.27/host#' "$d/Makefile"
        echo "local_changes: xray-core Go 工具链已钉到 1.27 ($d)"
    fi
done

# CI: 太乙固件无 WiFi (ath11k 已剔除), 但 qualcommax target 默认包带 wpad-mesh-openssl;
# 无 WiFi 驱动时 DRIVER_11AX_SUPPORT 关闭, hostapd 无 AX 而 NSS muedca 补丁代码
# 无宏保护, 导致 wpad-mesh-openssl 必然编译失败。从 target 默认包移除之,
# 并配合 deconfig 设备包里的 -wpad-mesh-openssl 双保险。
sed -i 's/uboot-envtools wpad-mesh-openssl/uboot-envtools/' "$BUILD_DIR/target/linux/qualcommax/Makefile"

# CI: nss_packages 换用 laipeng668 fork (NSS-12.5-K6.x), 换源需删旧工作树强制重克隆。
# 相比 qosmio 上游多 2 个提交:
#   "Personal Tailor" —— nss-ifb RCU 并发修复 / netlink l2tpv2、LSO 变量名修复 /
#     qca-nss-clients 依赖声明补全 / wifi-meshmgr 与固件版本联动;
#   "Add Linux kernel 6.18 support" —— 新增 6.18 适配补丁, 6.12 构建不受影响。
# 固件版本由 nss.config 碎片显式选择 12.5 (见该文件内注释), 不受此处默认值影响。
sed -i 's#^src-git nss_packages .*#src-git nss_packages https://github.com/laipeng668/nss-packages.git#' feeds.conf.default
rm -rf feeds/nss_packages package/feeds/nss_packages
./scripts/feeds update nss_packages
./scripts/feeds install -p nss_packages -a -f
if [ -d feeds/small8/mihomo ] && [ ! -e package/feeds/small8/mihomo ]; then
    ./scripts/feeds install -p small8 -f mihomo
    echo "local_changes: 已从 small8 安装 mihomo"
fi
if [ -d feeds/small8/luci-app-unblockneteasemusic ] && [ ! -e package/feeds/small8/luci-app-unblockneteasemusic ]; then
    ./scripts/feeds install -p small8 -f luci-app-unblockneteasemusic
    echo "local_changes: 已从 small8 安装 luci-app-unblockneteasemusic (网易云解锁)"
fi

# ---- 3) 旁路由出厂预配置 (uci-defaults, 首次开机执行一次) ----
# 文件名用 zz_ 前缀是必须的, 不能用 99_:
# uci-defaults 按文件名字母序执行, 而 luci-* 系列以字母 l 开头, 排在 "9" 之后。
# 之前叫 99_bypass_preset 时, 会出现:
#    99_bypass_preset  -> /etc/init.d/easytier disable   (我们的意图)
#    luci-easytier     -> /etc/init.d/easytier enable    (又给打开了)
# 结果 easytier 在禁用名单里却仍然开机自启。改成 zz_ 后它排在所有脚本之后执行。
PRESET_DIR="$BUILD_DIR/package/base-files/files/etc/uci-defaults"
mkdir -p "$PRESET_DIR"
rm -f "$PRESET_DIR/99_bypass_preset"
cat > "$PRESET_DIR/zz_bypass_preset" <<'EOF'
#!/bin/sh
# 2026-09-19 旁路由出厂预配置 (太乙 jdcloud_re-cs-07)
# 主路由(上游网关/DNS): 192.168.31.1, 本机: 192.168.31.100
# 注意: 网关要填真实主路由。填错会导致本机没有可用默认路由 —— 表现是全网不通、
#       AdGuardHome 上游全部超时、quickstart 首页显示「未联网」。

# LAN 静态 IP/网关
uci set network.lan.ipaddr='192.168.31.100'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.31.1'
uci -q delete network.lan.dns
uci add_list network.lan.dns='192.168.31.1'
uci commit network

# DHCP 关闭 (地址由主路由分配); IPv6 RA/DHCPv6 一并关闭
# 同时写 ignore 与 dhcpv4=disabled, 之前只写 ignore 出现过没生效的情况 (与主路由 DHCP 冲突)
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci commit dhcp
/etc/init.d/odhcpd disable 2>/dev/null

# dnsmasq 必须留在 53:
#   LAN 客户端 → 路由器:53 的查询会被 nft 的 prerouting 规则劫持到 AdGuardHome:5300
#   但路由器自己发出的查询走 output 链, 不经过 prerouting, 只能由本机 53 上的 dnsmasq 应答。
#   之前把 dnsmasq 挪到 5350, 导致 53 无人监听 + /etc/resolv.conf 指向 127.0.0.1
#   → 设备自身 DNS 完全失效 (nslookup 报 Connection refused)。
uci -q delete dhcp.@dnsmasq[0].port
uci commit dhcp

# AdGuardHome: 开机自启 + 53 端口重定向劫持 (yaml 里 dns.port=5300)
uci set AdGuardHome.AdGuardHome.enabled='1'
uci set AdGuardHome.AdGuardHome.redirect='redirect'
uci commit AdGuardHome
/etc/init.d/AdGuardHome enable 2>/dev/null

# 关掉官方 adguardhome 包那个 init 脚本:
# 它和 luci-app-adguardhome 的 /etc/init.d/AdGuardHome 管的是同一个二进制
# (/usr/bin/AdGuardHome), 两个都自启(S19 和 S95)会重复启动。
# 我们用的是 luci-app 那个(预设配的也是 AdGuardHome.* 的 uci)。
# 已在设备上实测: 只留 luci-app 的 init, AdGuardHome 能正常启动、5300 照常监听、
# nft 劫持规则照常生效。
/etc/init.d/adguardhome disable 2>/dev/null
uci set adguardhome.config.enabled='0'
uci commit adguardhome

# OpenClash: 修掉「所有节点不可用」的默认 DNS 死锁
# 镜像自带的 openclash 默认配置有三个坑, 叠在一起会让节点域名解析全部超时:
#   1) enable_custom_dns=0        → yml_change.sh 里 proxy-server-nameserver 的注入被这个门禁挡住
#   2) node_resolve 一条都没设     → 国内 DNS 不会被用于解析节点服务器地址
#   3) fallback 里 dns.google / dns.cloudflare.com 是 enabled=1 → 国区不可达
# 后果: 节点域名(海外IP)被 fallback-filter.geoip 判定为可疑转去问 fallback,
#       而 fallback 全部超时 → 解析失败 → 所有节点拨号失败、全部显示不可用。
# 本质是死锁: fallback 里那些墙外 DNS 本身要先有代理才通, 而代理要先解析节点域名。
# 这里按 group/ip 匹配而不是写死下标, 换订阅或包升级后依然有效。
if [ -f /etc/config/openclash ]; then
    uci set openclash.config.enable_custom_dns='1'
    i=0
    while uci -q get "openclash.@dns_servers[$i]" >/dev/null 2>&1; do
        g=$(uci -q get "openclash.@dns_servers[$i].group")
        ip=$(uci -q get "openclash.@dns_servers[$i].ip")
        [ "$g" = "default" ] && uci set "openclash.@dns_servers[$i].node_resolve=1"
        case "$ip" in
            dns.google/*|dns.cloudflare.com/*)
                uci set "openclash.@dns_servers[$i].enabled=0" ;;
        esac
        i=$((i + 1))
    done
    uci commit openclash
fi

# 关闭 uhttpd (LuCI 由 nginx 提供, 避免双 Web 服务抢 80/443)
/etc/init.d/uhttpd disable 2>/dev/null
/etc/init.d/uhttpd stop 2>/dev/null

# 停用上游埋的 custom_task 服务 (每天 3:15 drop_caches, 无意义且卡顿)
[ -f /etc/init.d/custom_task ] && /etc/init.d/custom_task disable
sed -i '/drop_caches/d' /etc/crontabs/root 2>/dev/null

# 预设 root 密码为 password (刷机后建议在 LuCI 修改)
sed -i 's#^root:[^:]*:#root:$1$tbypass$zpEjhZ84aeu9SYlPOwTXB1:#' /etc/shadow

# 保留的插件默认不开机自启 (需要时在 LuCI 启动项里打开)
# 注意: vlmcsd 不在这个名单里 —— 用户要求 KMS 服务器出厂即启用 (见下方单独处理)
# 后半段是「镜像默认自启、但会在局域网上开监听端口」的服务, 旁路由不需要:
#   radius     RADIUS 认证服务
#   xl2tpd     L2TP VPN 服务端 (实测在监听 0.0.0.0:1701)
#   microsocks SOCKS5 代理
#   3proxy     代理服务
#   relayd     中继服务
#   wsdd2      SMB 发现 (而 samba4 已经关了, 留着没意义)
# 同时 stop 一次, 保证首次开机这一轮也不会在跑。
#
# 自启动按官方规范来: 只由 /etc/rc.d/S* 符号链接决定, 也就是 /etc/init.d/X disable。
# LuCI 的「系统→启动项」操作的就是这个链接(页面代码里就是执行
# /etc/init.d/X enable 或 disable), 所以两边是同一个开关, 不冲突, 后写的生效。
#
# 特意不去动插件私有的 uci 标志(cupsd.config.enabled / unblockneteasemusic.config.enable
# 之类): 那不属于官方规范, 而且有些插件的 init 会读它 —— 例如 vlmcsd 的
#   config_get_bool enabled "config" "enabled" "0"
#   [ "$enabled" -eq "1" ] || return 1
# 一旦把标志归零, 即使你在 LuCI 启动项里启用了它也不会运行, 反而破坏官方开关的语义。
for svc in miniupnpd samba4 sqm easytier lucky appfilter autoreboot shadowsocksr \
           radius xl2tpd microsocks 3proxy relayd wsdd2; do
    /etc/init.d/$svc disable 2>/dev/null
    /etc/init.d/$svc stop 2>/dev/null
done

# oafd 修复: /etc/config/app_filter 出厂为空文件(无 uci section), 导致
# OAF "高级设置"页保存返回 2000 但实际不落盘。补一个全局 section。
if [ -f /etc/config/app_filter ] && ! grep -q "^config global" /etc/config/app_filter 2>/dev/null; then
    printf "config global 'global'
" >> /etc/config/app_filter
fi

# cupsd init 补丁: 原版不读 cupsd.config.enabled 标志, LuCI 勾选框形同虚设
# (取消勾选后服务照跑)。补上标准 OpenWrt 逻辑: enabled=0 时 start 直接返回。
CUPSD_INIT_PATCHED=0
for d in "$BUILD_DIR/feeds/custom_feed/cups" "$BUILD_DIR/feeds/small8/cups"; do
    if [ -f "$d/files/cupsd.init" ] && ! grep -q "config_get_bool enabled" "$d/files/cupsd.init"; then
        sed -i '/^start() {$/a\  config_load cupsd
  local enabled
  config_get_bool enabled config enabled 1
  [ "$enabled" = 0 ] \&\& return 0' "$d/files/cupsd.init"
        CUPSD_INIT_PATCHED=1
    fi
done
[ "$CUPSD_INIT_PATCHED" = 1 ] && echo "local_changes: cupsd init 已补 enabled 标志检查"

# 修 luci-app-unblockneteasemusic 3.4-r1 的 ACL 路径 bug (只影响状态页显示日志):
# 它的 ACL 把日志登记为 /var/run/unblockneteasemusic/run.log, 但 /var 是指向 /tmp 的
# 软链, rpcd 匹配 ACL 时会解析真实路径成 /tmp/run/..., 于是登记项匹配不上 →
# 状态页读日志被拒, 显示「未知错误：PermissionError: 没有权限」。
# 补一条真实路径的 ACL 即可 (已在设备上用会话级 ubus 调用验证过)。
# 纯显示问题, 不影响插件本身能否工作。
UNM_ACL=/usr/share/rpcd/acl.d/luci-app-unblockneteasemusic.json
if [ -f "$UNM_ACL" ] && ! grep -q '"/tmp/run/unblockneteasemusic/run.log"' "$UNM_ACL"; then
    sed -i 's#"/var/run/unblockneteasemusic/run.log": \[ "read" \]#"/tmp/run/unblockneteasemusic/run.log": [ "read" ], "/var/run/unblockneteasemusic/run.log": [ "read" ]#' "$UNM_ACL"
    /etc/init.d/rpcd restart 2>/dev/null
fi

# vlmcsd (KMS 服务器): 显式启用 + 开机自启
# 官方机制只需要 /etc/init.d/vlmcsd enable (建 rc.d 自启链接)。
# 但 vlmcsd 的 init 还会读自己的 uci 标志并提前返回:
#   config_get_bool enabled "config" "enabled" "0"
#   [ "$enabled" -eq "1" ] || return 1
# 所以这个标志必须一起设成 1, 否则有自启链接也不会跑。两个开关都得开。
uci set vlmcsd.config.enabled='1'
uci commit vlmcsd
/etc/init.d/vlmcsd enable 2>/dev/null

# unblockneteasemusic (网易云解锁): 用户要求出厂即启用
# 判据同上: 它的 uci 默认是 enable='0', 而 init 会读这个标志并提前返回
#   is_enabled "config" "enable" || return 1
# 所以不能只建自启链接 —— 标志也必须设成 1, 否则有链接也不会启动。
# 另注: 它没有预置 Node 内核(/usr/share/unblockneteasemusic/core/), 首次启动会自己
# 下载(走 api.github.com + fastly.jsdelivr.net), 所以首次开机后会等一会儿才起来;
# 下载失败则保持未运行, 下次启动重试。
uci set unblockneteasemusic.config.enable='1'
uci commit unblockneteasemusic
/etc/init.d/unblockneteasemusic enable 2>/dev/null

# CUPS 打印服务器: 关掉自启
# 官方机制: /etc/init.d/cupsd disable 即可(镜像里自带了 /etc/rc.d/S50cupsd, 所以它
# 出厂就是自启的, 而它的 uci-defaults 只做了 stop、从没 disable)。
# 另外把它的 uci 标志也设成 0 —— 这里**可以**这么做, 因为 /etc/init.d/cupsd 只有
# START=50、完全不读 cupsd.config.enabled, 所以设 0 没有任何功能副作用, 纯粹是让
# 那个失效的复选框不再骗人(它不勾也照样自启)。
# 需要打印时用: /etc/init.d/cupsd enable && /etc/init.d/cupsd start
# (要在「系统 → 启动项」里开; 页面那个复选框对自启无效)
/etc/init.d/cupsd disable 2>/dev/null
uci set cupsd.config.enabled='0'
uci commit cupsd

# OpenClash 内核衔接: 系统内 mihomo 软链为 clash_meta, 全新刷机免联网下载内核
if [ -x /usr/bin/mihomo ] && [ ! -e /etc/openclash/core/clash_meta ]; then
    mkdir -p /etc/openclash/core
    ln -sf /usr/bin/mihomo /etc/openclash/core/clash_meta
fi

# 修复 quickstart 首页向导菜单不显示 (首开时 LuCI 菜单缓存建在 quickstart 进程启动前)
mkdir -p /etc/init.d
cat > /etc/init.d/fix_luci_menu <<'FIXEOF'
#!/bin/sh /etc/rc.common
START=99
boot() {
    rm -f /tmp/luci-indexcache /tmp/luci-modulecache
}
FIXEOF
chmod 755 /etc/init.d/fix_luci_menu
/etc/init.d/fix_luci_menu enable

exit 0
EOF
chmod 755 "$PRESET_DIR/zz_bypass_preset"
echo "local_changes: 已写入 zz_bypass_preset (静态IP/DHCP关/DNS预配置)"

# ---- 3a2) AdGuardHome 规则库纳入 sysupgrade 备份 ----
# 上游的备份清单只含 /etc/AdGuardHome.yaml, 不含 data/ 目录下的规则库,
# 结果每次 sysupgrade 后规则库为空 -> 广告过滤静默失效(实测刷机后需手动触发下载)。
# 这里把 data/ 目录也加进去, 刷机后规则随配置一起保留。
SUCONF="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"
mkdir -p "$(dirname "$SUCONF")"
touch "$SUCONF"
grep -q 'AdGuardHome/data' "$SUCONF" || echo '/etc/AdGuardHome/data/' >> "$SUCONF"
echo "local_changes: 已把 AdGuardHome 规则库加入 sysupgrade 备份清单"

# ---- 3b) 自写迷你 NSS 状态页 luci-app-nssstatus (零依赖, 纯 Lua) ----
NSSAPP="$BUILD_DIR/package/emortal/luci-app-nssstatus"
mkdir -p "$NSSAPP/luasrc/controller" "$NSSAPP/luasrc/view/nssstatus"
cat > "$NSSAPP/Makefile" <<'MK'
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nssstatus
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-nssstatus
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=NSS hardware acceleration status page
  DEPENDS:=+luci-base +luci-compat
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-nssstatus/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/nssstatus.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/nssstatus
	$(INSTALL_DATA) ./luasrc/view/nssstatus/status.htm $(1)/usr/lib/lua/luci/view/nssstatus/
endef

$(eval $(call BuildPackage,luci-app-nssstatus))
MK
cat > "$NSSAPP/luasrc/controller/nssstatus.lua" <<'LUA'
module("luci.controller.nssstatus", package.seeall)

function index()
    entry({"admin", "status", "nssstatus"}, template("nssstatus/status"), _("NSS Status"), 90)
    entry({"admin", "status", "nssstatus", "data"}, call("nss_data")).leaf = true
end

-- 采集一次 NSS/ECM 状态, 输出 JSON 供页面轮询 (每 2 秒)
function nss_data()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local util = require "luci.util"

    local function rf(p)
        local s = fs.readfile(p)
        return s and util.trim(s) or nil
    end

    local out = { conn = 0, conn_tcp = 0, conn_udp = 0, conn_other = 0, ecm_mods = 0, nss_cpu = -1, nss_cpu_min = -1, nss_cpu_max = -1, n2h_rx_byts = 0, n2h_tx_byts = 0, n2h_rx_pkts = 0, n2h_tx_pkts = 0, fw = "?", ports = {} }

    -- ECM 已卸载到硬件的会话数
    out.conn = tonumber(rf("/sys/kernel/debug/ecm/ecm_db/connection_count") or "") or 0

    -- 按协议分解: connection_count_simple 输出 "tcp N udp N other N total N"
    -- (qca-nss-ecm/ecm_db/ecm_db_connection.c:4543 snprintf 格式)
    local cs = fs.readfile("/sys/kernel/debug/ecm/ecm_db/connection_count_simple")
    if cs then
        out.conn_tcp = tonumber(cs:match("tcp%s+(%d+)")) or 0
        out.conn_udp = tonumber(cs:match("udp%s+(%d+)")) or 0
        out.conn_other = tonumber(cs:match("other%s+(%d+)")) or 0
    end

    -- 已加载的 ECM 引擎模块数
    local fm = io.open("/proc/modules", "r")
    if fm then
        for line in fm:lines() do
            if line:sub(1, 3) == "ecm" then out.ecm_mods = out.ecm_mods + 1 end
        end
        fm:close()
    end

    -- NSS 硬件加速吞吐: 取 n2h (NSS core <-> host) 数据面累计计数, 速率由页面按差值算。
    -- 实测: 该计数随转发流量实时增长, 是"NSS 确实在硬件转发"的可靠证据。
    local n2h = fs.readfile("/sys/kernel/debug/qca-nss-drv/stats/n2h")
    if n2h then
        out.n2h_rx_byts = tonumber(n2h:match("n2h_rx_byts%s*=%s*(%d+)")) or 0
        out.n2h_tx_byts = tonumber(n2h:match("n2h_tx_byts%s*=%s*(%d+)")) or 0
        out.n2h_rx_pkts = tonumber(n2h:match("n2h_rx_pkts%s*=%s*(%d+)")) or 0
        out.n2h_tx_pkts = tonumber(n2h:match("n2h_tx_pkts%s*=%s*(%d+)")) or 0
    end

    -- 调频驱动上报的 CPU 负载 (仅作诊断用):
    -- cpu_load_ubi 由 nss_freq_stats.c 注册, 依赖 NSS 固件周期性上报指令数。
    -- 实测本版本固件不上报, nss_freq_compute_cpu_usage() 在 inst_cnt==0 时直接 return,
    -- 导致 used 永远停在开机初值(8%), min/avg/max 恒等 —— 不能反映真实负载,
    -- 因此卡片区改用 n2h 吞吐, 这里只保留原始值备查。
    local raw = fs.readfile("/sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi")
    if raw then
        local mn, av, mx = raw:match("(%d+)%%%s+(%d+)%%%s+(%d+)%%")
        if mn then
            out.nss_cpu_min = tonumber(mn)
            out.nss_cpu = tonumber(av) or -1
            out.nss_cpu_max = tonumber(mx)
        end
    end

    -- NSS 固件版本:
    --   包版本(opkg control)只是 OpenWrt 打包版本, 与芯片内实际运行的固件不是一回事。
    --   真实版本要从固件二进制里读, 同上游 nss_diag.sh 的做法:
    --   grep -h -m1 -a -o 'Version:.[^[:cntrl:]]*' /lib/firmware/qca*.bin
    local ctl = fs.readfile("/usr/lib/opkg/info/nss-firmware-ipq60xx.control")
    if ctl then out.fw = ctl:match("Version:%s*([^\r\n]+)") or "?" end
    local fwraw = sys.exec("grep -h -m1 -a -o 'Version:.[^[:cntrl:]]*' /lib/firmware/qca*.bin 2>/dev/null | head -1") or ""
    local fwreal = fwraw:match("Version:%s*([^\r\n]+)")
    if fwreal then out.fwreal = util.trim(fwreal) end

    -- /proc/net/dev 的累计字节数 (速率交给页面按差值算, 服务端不存状态)
    local bytes = {}
    for line in (fs.readfile("/proc/net/dev") or ""):gmatch("[^\r\n]+") do
        local name, rest = line:match("^%s*([%w%.%-]+):%s*(.+)$")
        if name then
            local nums = {}
            for n in rest:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
            if #nums >= 9 then bytes[name] = { nums[1], nums[9] } end
        end
    end

    -- 真实物理网口: 只有交换机端口在 /sys/class/net/<n>/ 下有 device 软链。
    -- br-lan / dheth0 / dummy0 / gre0 这些虚拟接口没有 device, 但它们也有 speed 文件,
    -- 所以不能用 speed 判断, 否则端口列表会混进一堆虚拟接口。
    local names = {}
    for n in (sys.exec("ls -1 /sys/class/net 2>/dev/null") or ""):gmatch("[%w%.%-]+") do
        if fs.access("/sys/class/net/" .. n .. "/device") then names[#names + 1] = n end
    end
    table.sort(names)
    for _, n in ipairs(names) do
        local b = bytes[n] or { 0, 0 }
        out.ports[#out.ports + 1] = {
            name  = n,
            up    = (rf("/sys/class/net/" .. n .. "/operstate") == "up"),
            speed = tonumber(rf("/sys/class/net/" .. n .. "/speed") or "") or 0,
            rx    = b[1],
            tx    = b[2]
        }
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(out)
end
LUA
cat > "$NSSAPP/luasrc/view/nssstatus/status.htm" <<'HTM'
<%+header%>
<h2 name="content"><%:NSS 硬件加速%>
  <small style="float:right;font-size:12.5px;color:#8d9aa5;font-weight:400;line-height:34px">
    每 2 秒刷新<span id="nss-upd"></span>
  </small>
</h2>

<style>
.nss-grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin-bottom:14px}
.nss-card{background:#fff;border:1px solid #e2e2e2;border-radius:10px;padding:14px 16px;display:flex;flex-direction:column;min-width:0}
.nss-card .lbl{font-size:13px;color:#7b8a97;margin-bottom:7px}
.nss-card .val{font-size:26px;font-weight:600;line-height:1.15;font-variant-numeric:tabular-nums;min-height:34px;display:flex;align-items:center;white-space:nowrap}
.nss-card .sub{font-size:12.5px;color:#8d9aa5;margin-top:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#k-conn-sub,#k-mod-sub{font-family:monospace;font-size:12.5px;color:#607d8b;letter-spacing:.2px}
/* 协议分解/引擎说明这类列表: 窄卡片里宁可折行也不要截断 */
#k-conn-sub,#k-mod-sub{white-space:normal;overflow:visible;text-overflow:clip}
.badge{display:inline-block;font-size:17px;font-weight:600;padding:2px 11px;border-radius:12px;background:#e8f5e9;color:#2e7d32}
.badge.bad{background:#ffebee;color:#c62828}
#k-fw{font-family:monospace;font-size:15px;font-weight:600;word-break:break-all;line-height:1.25}
.nss-bar{height:7px;border-radius:4px;background:#eee;overflow:hidden;margin-top:9px}
.nss-bar>i{display:block;height:100%;width:0;border-radius:4px;transition:width .45s ease,background .3s}
.nss-panel{background:#fff;border:1px solid #e2e2e2;border-radius:10px;padding:13px 15px;margin-bottom:14px}
.nss-panel h3{margin:0 0 9px;font-size:13px;font-weight:600;color:#333}
.nss-panel h3 small{font-weight:400;color:#8d9aa5;font-size:12px;margin-left:6px}
.pt{display:flex;align-items:center;gap:9px;padding:7px 0;border-bottom:1px solid #f4f4f4}
.pt:last-child{border-bottom:0}
.pt .nm{width:50px;font-family:monospace;font-size:13px;color:#333}
.pt .sp{width:74px;font-size:12px;color:#7b8a97;text-align:right}
.pt .bars{flex:1;min-width:56px}
.pt .bar{height:6px;background:#f2f2f2;border-radius:4px;overflow:hidden;margin:2px 0}
.pt .bar>i{display:block;height:100%;width:0;border-radius:4px}
.pt .rt{width:112px;font-size:12px;font-family:monospace;color:#455a64;text-align:right;line-height:1.5;font-variant-numeric:tabular-nums}
.nss-note{font-size:13px;color:#607d8b;line-height:1.85}
.nss-card .val .tag{font-size:12px;font-weight:400;color:#9aa7b2;margin-left:8px;align-self:flex-end;padding-bottom:3px}
.rng{position:relative;height:20px;margin-top:10px}
.rng .track{position:absolute;top:8px;left:0;right:0;height:4px;background:#e3e8eb;border-radius:2px}
.rng .span{position:absolute;top:8px;height:4px;background:#90caf9;border-radius:2px;transition:left .45s ease,width .45s ease}
.rng .dot{position:absolute;top:3px;width:14px;height:14px;margin-left:-7px;border-radius:50%;background:#1976d2;border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.28);transition:left .45s ease}
.rng-ends{display:flex;gap:14px;font-size:12.5px;color:#8d9aa5;margin-top:4px;white-space:nowrap}
.rng-ends b{color:#37474f;font-variant-numeric:tabular-nums;font-weight:600}
</style>

<div class="nss-grid">
  <div class="nss-card">
    <div class="lbl">加速连接数</div>
    <div class="val" id="k-conn">–</div>
    <div class="sub" id="k-conn-sub">ECM 卸载到硬件的会话</div>
  </div>
  <div class="nss-card">
    <div class="lbl">NSS CPU 负载</div>
    <div class="val"><span id="k-cpu">–</span><span class="tag">驱动上报</span></div>
    <div class="rng">
      <div class="track"></div>
      <div class="span" id="k-cpu-span"></div>
      <div class="dot" id="k-cpu-dot"></div>
    </div>
    <div class="rng-ends">
      <span>最低 <b id="k-cpu-min">–</b></span>
      <span>最高 <b id="k-cpu-max">–</b></span>
    </div>
  </div>
  <div class="nss-card">
    <div class="lbl">NSS↔主机吞吐</div>
    <div class="val"><span id="k-nss">–</span></div>
    <div class="sub" id="k-nss-rx">↓ –</div>
    <div class="sub" id="k-nss-tx">↑ –</div>
    <div class="sub" id="k-nss-pps">–</div>
  </div>
  <div class="nss-card">
    <div class="lbl">ECM 引擎模块</div>
    <div class="val"><span class="badge" id="k-mod">–</span></div>
    <div class="sub" id="k-mod-sub">读取中…</div>
  </div>
  <div class="nss-card">
    <div class="lbl">NSS 固件</div>
    <div class="val"><span id="k-fw">–</span></div>
    <div class="sub" id="k-fw-full">–</div>
    <div class="sub" id="k-fw-pkg">打包版本 –</div>
  </div>
</div>

<div class="nss-panel">
  <h3>加速连接数趋势<small>最近 60 秒</small></h3>
  <canvas id="nss-chart" style="width:100%;height:120px;display:block"></canvas>
</div>

<div class="nss-panel">
  <h3>网口实时速率<small>每 2 秒刷新</small></h3>
  <div id="nss-ports"><div style="color:#aaa;font-size:12px">读取中…</div></div>
</div>

<div class="nss-panel nss-note">
  NSS 由 ECM 引擎自动接管加速，无需在防火墙页开启「流量分载」。<br>
  <b>加速连接数</b>是唯一可直接读到的加速指标：实测随转发流量增长（22→37），持续增长即表示转发在走硬件。<br>
  <b>NSS↔主机吞吐</b>取自 n2h 计数，统计的是需要交给主机处理的包（未走快路径）；
  已完全卸载到硬件的快路径包不经过主机，也不产生字节计数，因此固件层读不到「加速吞吐」本身。<br>
  <span style="color:#9e9e9e">注：<b>CPU 负载</b>为驱动上报值。实测加压 10MB/s 转发时该值仍恒为 8%（min/avg/max 完全相同）——
  NSS 固件未上报指令数，<code>nss_freq_compute_cpu_usage()</code> 在 <code>inst_cnt==0</code> 时直接返回，
  数值停在开机初值，本版本仅供参考。</span>
</div>

<script type="text/javascript">
(function () {
	var INTERVAL = 2000, MAXPTS = 30;
	var hist = [], prev = {}, timer = null;
	/* 必须用绝对路径: LuCI 菜单给的页面地址结尾没有斜杠, 相对路径 "data" 会被
	   解析成 /admin/status/data (少一段 nssstatus) 而 404 */
	var URL_DATA = '<%=luci.dispatcher.build_url("admin", "status", "nssstatus", "data")%>';

	function el(id) { return document.getElementById(id); }

	function fmtRate(bps) {
		if (bps >= 1048576) return (bps / 1048576).toFixed(2) + ' MB/s';
		if (bps >= 1024) return (bps / 1024).toFixed(1) + ' KB/s';
		return Math.round(bps) + ' B/s';
	}

	function cpuColor(p) { return p < 50 ? '#43a047' : (p < 80 ? '#fb8c00' : '#e53935'); }

	function drawChart() {
		var c = el('nss-chart');
		if (!c) return;
		var w = c.clientWidth, h = c.clientHeight || 120;
		if (w <= 0) return;
		var dpr = window.devicePixelRatio || 1;
		if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
			c.width = Math.round(w * dpr);
			c.height = Math.round(h * dpr);
		}
		var g = c.getContext('2d');
		g.setTransform(dpr, 0, 0, dpr, 0, 0);
		g.clearRect(0, 0, w, h);

		var top = 16, bot = h - 16;

		g.strokeStyle = '#f0f0f0';
		g.lineWidth = 1;
		for (var i = 1; i < 4; i++) {
			var gy = top + (bot - top) * i / 4;
			g.beginPath(); g.moveTo(0, gy); g.lineTo(w, gy); g.stroke();
		}
		g.strokeStyle = '#e4e4e4';
		g.beginPath(); g.moveTo(0, bot); g.lineTo(w, bot); g.stroke();

		/* 数据点不足时不要画成一条孤立色带, 给个明确提示 */
		if (hist.length < 2) {
			g.fillStyle = '#b0bec5';
			g.font = '12px sans-serif';
			g.textAlign = 'center';
			g.fillText('数据积累中…（每 2 秒采样，共 30 点）', w / 2, (top + bot) / 2 + 4);
			g.textAlign = 'left';
			return;
		}

		var mx = 1;
		for (var j = 0; j < hist.length; j++) if (hist[j] > mx) mx = hist[j];

		function px(i) { return w * i / (MAXPTS - 1); }
		function py(v) { return bot - (bot - top) * (v / mx); }

		g.beginPath();
		g.moveTo(px(0), bot);
		for (var k = 0; k < hist.length; k++) g.lineTo(px(k), py(hist[k]));
		g.lineTo(px(hist.length - 1), bot);
		g.closePath();
		g.fillStyle = 'rgba(25,118,210,0.10)';
		g.fill();

		g.beginPath();
		for (var m = 0; m < hist.length; m++) {
			if (m) g.lineTo(px(m), py(hist[m])); else g.moveTo(px(m), py(hist[m]));
		}
		g.strokeStyle = '#1976d2';
		g.lineWidth = 2;
		g.lineJoin = 'round';
		g.stroke();

		/* 点少时把采样点画出来, 否则看着像一条悬空的横线 */
		if (hist.length <= 12) {
			g.fillStyle = '#1976d2';
			for (var d = 0; d < hist.length; d++) {
				g.beginPath();
				g.arc(px(d), py(hist[d]), 2.6, 0, Math.PI * 2);
				g.fill();
			}
		}

		g.fillStyle = '#90a4ae';
		g.font = '11px monospace';
		g.textAlign = 'right';
		g.fillText('峰值 ' + mx, w - 2, 12);
		g.textAlign = 'left';
		g.fillText('0', 2, bot - 4);
	}

	function renderPorts(ports) {
		var box = el('nss-ports');
		if (!box) return;
		var maxr = 1, rates = [];

		for (var i = 0; i < ports.length; i++) {
			var p = ports[i], o = prev[p.name], r = { rx: 0, tx: 0 };
			if (o) {
				if (p.rx >= o.rx) r.rx = (p.rx - o.rx) * 1000 / INTERVAL;
				if (p.tx >= o.tx) r.tx = (p.tx - o.tx) * 1000 / INTERVAL;
			}
			prev[p.name] = { rx: p.rx, tx: p.tx };
			if (r.rx > maxr) maxr = r.rx;
			if (r.tx > maxr) maxr = r.tx;
			rates.push(r);
		}

		var html = '';
		for (var k = 0; k < ports.length; k++) {
			var q = ports[k], rr = rates[k];
			var sp = q.speed > 0 ? (q.speed >= 1000 ? (q.speed / 1000) + ' Gbps' : q.speed + ' Mbps') : '—';
			html += '<div class="pt">' +
				'<div class="nm">' + q.name + '</div>' +
				'<div class="sp"><span style="color:' + (q.up ? '#43a047' : '#ccc') + '">●</span> ' + sp + '</div>' +
				'<div class="bars">' +
					'<div class="bar"><i style="background:#1976d2;width:' + (rr.rx / maxr * 100).toFixed(1) + '%"></i></div>' +
					'<div class="bar"><i style="background:#00897b;width:' + (rr.tx / maxr * 100).toFixed(1) + '%"></i></div>' +
				'</div>' +
				'<div class="rt">↓ ' + fmtRate(rr.rx) + '<br>↑ ' + fmtRate(rr.tx) + '</div>' +
				'</div>';
		}
		box.innerHTML = html || '<div style="color:#aaa;font-size:12px">没有检测到物理网口</div>';
	}

	function poll() {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', URL_DATA, true);
		xhr.onreadystatechange = function () {
			if (xhr.readyState !== 4) return;
			if (xhr.status !== 200) {
				var s = el('k-mod-sub');
				if (s) {
					s.textContent = '读取失败 (HTTP ' + xhr.status + ')';
					s.style.color = '#e53935';
				}
				var box = el('nss-ports');
				if (box) {
					box.innerHTML = '<div style="color:#c62828;font-size:12px">' +
						'取数失败 (HTTP ' + xhr.status + ') 于 ' + URL_DATA + '</div>';
				}
				if (timer) clearInterval(timer);
				return;
			}
			var d;
			try { d = JSON.parse(xhr.responseText); } catch (e) { return; }

			el('k-conn').textContent = d.conn;
			var cs = el('k-conn-sub');
			if (cs) {
				cs.textContent = 'TCP ' + (d.conn_tcp || 0) + ' · UDP ' + (d.conn_udp || 0)
					+ ' · 其他 ' + (d.conn_other || 0);
			}

			/* 驱动上报的调频负载: Min/Avg/Max 顺序, Avg 取第二个 (nss_core.h:816) */
			var cpu = d.nss_cpu;
			el('k-cpu').textContent = cpu >= 0 ? cpu + '%' : '—';
			el('k-cpu').style.color = cpu >= 0 ? cpuColor(Math.min(cpu, 100)) : '';
			if (d.nss_cpu_min >= 0 && d.nss_cpu_max >= 0) {
				el('k-cpu-min').textContent = d.nss_cpu_min + '%';
				el('k-cpu-max').textContent = d.nss_cpu_max + '%';
				var cl = function (v) { return Math.max(0, Math.min(100, v)); };
				var mn = cl(d.nss_cpu_min), mx = cl(d.nss_cpu_max);
				el('k-cpu-span').style.left = mn + '%';
				el('k-cpu-span').style.width = Math.max(0, mx - mn) + '%';
				el('k-cpu-dot').style.left = cl(cpu >= 0 ? cpu : 0) + '%';
			}

			/* NSS 加速吞吐: n2h 是累计计数, 服务端不存状态, 速率由页面按两次采样差值算 */
			var nssRx = d.n2h_rx_byts || 0, nssTx = d.n2h_tx_byts || 0;
			var nssRxP = d.n2h_rx_pkts || 0, nssTxP = d.n2h_tx_pkts || 0;
			var nssNow = nssRx + nssTx, nssPkts = nssRxP + nssTxP;
			if (prev.nssAt) {
				var dt = (Date.now() - prev.nssAt) / 1000;
				if (dt > 0.5 && nssNow >= prev.nssNow) {
					el('k-nss').textContent = fmtRate((nssNow - prev.nssNow) / dt);
					el('k-nss-pps').textContent = Math.round((nssPkts - prev.nssPkts) / dt) + ' 包/秒';
					el('k-nss-rx').textContent = '↓ ' + fmtRate((nssRx - prev.nssRx) / dt);
					el('k-nss-tx').textContent = '↑ ' + fmtRate((nssTx - prev.nssTx) / dt);
				}
			}
			prev.nssAt = Date.now();
			prev.nssNow = nssNow; prev.nssPkts = nssPkts;
			prev.nssRx = nssRx; prev.nssTx = nssTx;

			var sub = el('k-mod-sub');
			var ok = d.ecm_mods > 0;
			/* ecm 模块名唯一(nss 生态里只有 ecm.ko 以 ecm 命名), 显示计数会让人困惑,
			   直接给状态徽标更清楚; 用 class 切换配色, 避免内联样式覆盖 */
			el('k-mod').textContent = ok ? '已加载' : '未加载';
			el('k-mod').className = ok ? 'badge' : 'badge bad';
			sub.textContent = ok ? 'ecm 引擎 · 加速生效' : '硬件加速不可用';
			sub.style.color = ok ? '#2e7d32' : '#c62828';

			/* 完整标识太长(20字符)会撑破卡片: 大字只放版本号本体, 完整串放小字行 */
			var fwFull = d.fwreal || '';
			var fwCore = fwFull ? fwFull.replace(/^NSS\.CP\./, '').replace(/-R$/, '') : '';
			el('k-fw').textContent = fwCore || fwFull || d.fw || '–';
			var fwf = el('k-fw-full');
			if (fwf) fwf.textContent = fwFull || '–';
			var fwp = el('k-fw-pkg');
			if (fwp) fwp.textContent = '打包版本 ' + (d.fw || '?');

			hist.push(d.conn);
			while (hist.length > MAXPTS) hist.shift();
			drawChart();
			renderPorts(d.ports || []);

			var upd = el('nss-upd');
			if (upd) upd.textContent = ' · 更新于 ' + new Date().toTimeString().slice(0, 8);
		};
		xhr.send(null);
	}

	poll();
	timer = setInterval(poll, INTERVAL);
	window.addEventListener('resize', drawChart);
	window.addEventListener('beforeunload', function () { if (timer) clearInterval(timer); });
})();
</script>
<%+footer%>
HTM
echo "local_changes: 已生成 luci-app-nssstatus (NSS 状态页)"

# ---- 3c) 确保 luci-app-nssstatus 在 defconfig 里被启用 ----
# 包本身没有 DEFAULT, defconfig 不会自动选中, 必须由设备 defconfig 显式指定
DECONF="$REPO_ROOT/wrt_core/deconfig/jdcloud_ipq60xx_libwrt.config"
if [ -f "$DECONF" ]; then
    sed -i '/CONFIG_PACKAGE_luci-app-nssstatus/d' "$DECONF"
    echo 'CONFIG_PACKAGE_luci-app-nssstatus=y' >> "$DECONF"
    echo "local_changes: deconfig 已确保 CONFIG_PACKAGE_luci-app-nssstatus=y"
fi

# ---- 3d) 移除 netdata (用户要求不编译进固件) ----
# 这三个符号是自成一体的依赖链: netdata <- luci-app-netdata <- luci-i18n-netdata-zh-cn。
# 已确认没有任何其他包依赖或 select netdata, 所以全部关掉即可干净移除。
if [ -f "$DECONF" ]; then
    for sym in netdata luci-app-netdata luci-i18n-netdata-zh-cn; do
        sed -i "/^CONFIG_PACKAGE_${sym}=/d" "$DECONF"
        sed -i "/^# CONFIG_PACKAGE_${sym} is not set\$/d" "$DECONF"
        echo "# CONFIG_PACKAGE_${sym} is not set" >> "$DECONF"
    done
    echo "local_changes: deconfig 已移除 netdata (主程序 / LuCI 应用 / 中文语言包)"
fi

# ---- 4) AdGuardHome 出厂 yaml (用户提供, 2026-09-19) ----
AGH_DIR="$BUILD_DIR/package/feeds/small8/luci-app-adguardhome"
if [ -d "$AGH_DIR" ]; then
    cat > "$AGH_DIR/root/etc/AdGuardHome.yaml" <<'AGHYAML'
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
      - GET /dns-query
      - POST /dns-query
      - GET /dns-query/{ClientID}
      - POST /dns-query/{ClientID}
    insecure_enabled: false
  address: 0.0.0.0:3000
  session_ttl: 30d
users:
  - name: admin
    password: $2a$10$Ym2GBEXjVhyfPLMC7ug1F.dVwWnflVJzY9HGQjFBVmQrfp1kj6jEO
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: "zh-cn"
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5300
  anonymize_client_ip: false
  ratelimit: 200
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    # 2026-09-21 改: 指向 clash 的 DNS(7874), 让 AGH 过滤后的查询继续走 clash 的 fake-ip 分流。
    # 原为 223.5.5.5 / 1.12.12.12 —— 若保持原样, 会丢失 clash 的域名级分流能力。
    - 127.0.0.1:7874
  upstream_dns_file: ""
  bootstrap_dns:
    - 223.5.5.5
    - 119.29.29.29
  fallback_dns:
    - 223.5.5.5
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: true
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: "/tmp"
  ignored: []
  interval: 24h
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: "/tmp"
  ignored: []
  interval: 1d
  enabled: true
  ignored_enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /tmp/AdGuardHome/userfilters/*
  max_http_size: 256MB
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  rewrites_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
AGHYAML
    echo "local_changes: AdGuardHome 出厂 yaml 已替换 (用户配置, dns.port=5300)"
fi


# ---- 5) 出厂配置快照烘焙 (2026-09-21) ----
# 目的: 把设备上"已实测验证"的运行时修复烤进固件, 使重刷后出厂即修好, 不再需要手工打补丁。
#       详见 旁路由问题排查与修复报告.md 第十一节。
#
# 快照来源: factory_cfg/   (从设备 /etc 抓取)
# 落点:      $BUILD_DIR/files/  —— OpenWrt 的顶层"文件叠加树":
#            include/image.mk 里 $(call prepare_rootfs, ..., $(TOPDIR)/files)
#            会在**所有包安装完成之后**再把这些文件覆盖进 rootfs,
#            因此不涉及包的文件归属, 不会触发 opkg 的 check_data_file_clashes。
#            *** 这一点很关键 ***: 曾先尝试写进 luci-app-adguardhome 包的 root/,
#            结果因 /etc/config/firewall 属于 firewall4、/etc/config/dhcp 属于
#            dnsmasq-full 而报 "Cannot install package luci-app-adguardhome" 失败。
#            files/ 叠加方式无此问题。
#
# 覆盖的修复项:
#   1  MASQUERADE(根因)        -> etc/firewall.d/zz-masq-lan + etc/firewall.user
#                                 + etc/config/firewall 里已注册的 include
#   2  TPROXY UDP53 放行        -> etc/openclash/custom/openclash_custom_firewall_rules.sh
#   4  Sniffer 开关             -> etc/uci-defaults/99-factory-tuning
#   6  dhcp.lan.start=101       -> etc/config/dhcp
#   7  nginx 证书 cron 修正      -> etc/uci-defaults/99-factory-tuning
#   8  清理 wan 残留             -> etc/config/firewall
#   9  清理死 include            -> etc/config/firewall
#   10 删除无效 network.lan.dns  -> etc/config/network
#   11 LuCI「自定义规则」页修复   -> usr/share/fw3/helpers.conf
#   (第 3、5 项 AGH 上游与查询日志目录 已在第 4 节的 yaml heredoc 里直接改)
#
# 注意: /etc/config/openclash 与 luci/istore/dropbear 等杂项按用户要求**不冻结**,
#       所以第 4 项的 sniffer 开关走 uci-defaults 设 uci, 而不是整文件覆盖。

# 注意: 本脚本内没有 BASE_PATH (它只在 build.sh 中定义), 故从 BUILD_DIR 反推上一层。
# build.sh 以 "$BASE_PATH/$BUILD_DIR" 传入, 因此 dirname 即 wrt_release 根目录。
SNAP="$REPO_ROOT/factory_cfg"
FILES_ROOT="$BUILD_DIR/files"

if [ ! -d "$SNAP" ]; then
    echo "local_changes: !! 第 5 节跳过: 未找到快照目录 $SNAP"
else
    # files/ 是叠加树, 目录不存在时由本脚本创建 —— update.sh 里的 git clean 可能清掉它,
    # 而本脚本在 update.sh 之后运行, 所以这里正是正确的创建时机。
    mkdir -p "$FILES_ROOT/etc/config" "$FILES_ROOT/etc/firewall.d" \
             "$FILES_ROOT/etc/openclash" "$FILES_ROOT/etc/uci-defaults" "$FILES_ROOT/usr/share/fw3"

    # uci 配置: network(无 lan.dns) / dhcp(start=101) / firewall(仅 lan 区, 已注册 masq) / AdGuardHome
    for f in network dhcp firewall AdGuardHome; do
        [ -f "$SNAP/etc/config/$f" ] && cp -f "$SNAP/etc/config/$f" "$FILES_ROOT/etc/config/$f"
    done

    # 防火墙脚本: MASQUERADE 规则本体 + 可被 LuCI「自定义规则」页读写的入口文件
    [ -f "$SNAP/etc/firewall.user" ]          && cp -f "$SNAP/etc/firewall.user"          "$FILES_ROOT/etc/"
    [ -f "$SNAP/etc/firewall.d/zz-masq-lan" ] && cp -f "$SNAP/etc/firewall.d/zz-masq-lan" "$FILES_ROOT/etc/firewall.d/"
    chmod 755 "$FILES_ROOT/etc/firewall.d/zz-masq-lan" 2>/dev/null || true

    # OpenClash 自定义目录(15 个文件): 含 UDP53 放行脚本、sniffer 配置、hosts/rule 列表等
    [ -d "$SNAP/etc/openclash/custom" ] && cp -rf "$SNAP/etc/openclash/custom/." "$FILES_ROOT/etc/openclash/custom/"
    for s in openclash_custom_firewall_rules.sh openclash_custom_overwrite.sh; do
        chmod 755 "$FILES_ROOT/etc/openclash/custom/$s" 2>/dev/null || true
    done

    # 第 11 项: LuCI「自定义规则」页在纯 fw4 构建下被隐藏 ——
    # 因为 luci-app-firewall 的菜单定义把该页硬编码依赖在 fw3 路径 /usr/share/fw3/helpers.conf 上,
    # 而该文件只随旧 fw3 包提供, 纯 fw4 镜像里不存在(后端 ucode 本身已兼容 fw4)。
    # fw4 不读这个文件, 补上它仅为满足那条依赖检查。
    : > "$FILES_ROOT/usr/share/fw3/helpers.conf"

    # 第 4 / 7 项 + rc.local 冗余保险, 交给首次开机的 uci-defaults 执行
    cat > "$FILES_ROOT/etc/uci-defaults/99-factory-tuning" <<'FACTORYTUNING'
#!/bin/sh
# 出厂微调 —— 2026-09-21
# OpenWrt uci-defaults 约定: 首次开机执行一次, 成功即被删除。

# --- 修复 4: 打开 OpenClash Sniffer ---
# 不打开时: fake-ip-filter 含 rule-set:oc-cn-domain(国内域名返回真实 IP), 而 clash 只
# 拿到 IP 拿不到域名, 导致苹果/bilibili/games-cn/steam-cn 等域名类规则全部失效。
uci -q set openclash.config.enable_meta_sniffer='1'
uci -q set openclash.config.enable_meta_sniffer_custom='1'
uci -q set openclash.config.enable_meta_sniffer_pure_ip='1'
uci -q commit openclash

# --- 修复 7: nginx 证书检查 cron 表达式 ---
# 坏条目 "3 3 12 12 *"(每年 12/12 才执行) 由 nginx-util 二进制在【开机运行时】写入
# /etc/crontabs/root(见 feeds/packages/net/nginx-util/src/nginx-ssl-util.hpp),
# 晚于全部 uci-defaults —— 所以这里只装修正脚本, 由 rc.local(最后执行)调用才有效。
cat > /etc/fix-cert-cron.sh <<'FIXCRON'
#!/bin/sh
# 修正 nginx-util 写入的证书检查 cron: "每年 12 月 12 日" -> "每天 03:03"
C=/etc/crontabs/root
[ -f "$C" ] || exit 0
grep -q '^3 3 12 12 \*' "$C" || exit 0
sed -i 's#^3 3 12 12 \*#3 3 * * *#' "$C"
/etc/init.d/cron restart 2>/dev/null
FIXCRON
chmod 755 /etc/fix-cert-cron.sh

# --- MASQUERADE 开机冗余保险 ---
# 主机制是防火墙 include(见 /etc/config/firewall 里注册的 /etc/firewall.d/zz-masq-lan)。
# 这里在 /etc/rc.local 再挂一道; 脚本自身幂等, 重复执行不会叠加规则。
if [ -f /etc/rc.local ] && ! grep -q 'zz-masq-lan' /etc/rc.local; then
    sed -i '/^exit 0/i [ -x /etc/firewall.d/zz-masq-lan ] \&\& sh /etc/firewall.d/zz-masq-lan' /etc/rc.local
fi
# rc.local 在所有 init 服务(含 nginx-util)之后执行, 是修正 cron 的可靠时机
if [ -f /etc/rc.local ] && ! grep -q 'fix-cert-cron' /etc/rc.local; then
    sed -i '/^exit 0/i [ -x /etc/fix-cert-cron.sh ] \&\& sh /etc/fix-cert-cron.sh' /etc/rc.local
fi

exit 0
FACTORYTUNING
    chmod 755 "$FILES_ROOT/etc/uci-defaults/99-factory-tuning"

    echo "local_changes: 第 5 节完成 — 出厂快照已烘焙(uci 配置/防火墙/OpenClash 自定义/LuCI 修复/开机微调)"
fi

echo "local_changes: 完成"
