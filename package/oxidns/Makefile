# SPDX-License-Identifier: GPL-2.0-only
#
# oxidns — 预编译静态 musl 二进制打包（aarch64）
# 上游：https://github.com/svenshi/oxidns/releases
# files/ 来自现役路由器（config/learned/init/uci 开箱即用）

include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns
PKG_VERSION:=1.6.0
PKG_RELEASE:=1

PKG_SOURCE:=oxidns-$(PKG_VERSION)-aarch64-unknown-linux-musl.tar.gz
PKG_SOURCE_URL:=https://github.com/svenshi/oxidns/releases/download/v$(PKG_VERSION)/
PKG_HASH:=8d7b8625f79a0c3c926c97d345da3fa169e82e7720047f070de3129ddcac30db

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/oxidns
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OxiDNS DNS server (dynamic learning + WebUI)
  URL:=https://github.com/svenshi/oxidns
  ARCH:=aarch64
endef

define Package/oxidns/description
 OxiDNS: modern DNS server with learn_domain dynamic rules, lazy cache,
 query recorder and WebUI. Prebuilt static musl binary, aarch64 only.
endef

define Package/oxidns/conffiles
/etc/oxidns/config.yaml
/etc/oxidns/rules/learned_proxy.txt
/etc/oxidns/rules/learned_direct.txt
/etc/config/oxidns
endef

# tarball 内为平铺结构：oxidns / config.yaml / webui/*
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/oxidns/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/oxidns $(1)/usr/bin/oxidns
	$(INSTALL_DIR) $(1)/usr/share/oxidns
	$(CP) $(PKG_BUILD_DIR)/webui $(1)/usr/share/oxidns/webui
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/oxidns.init $(1)/etc/init.d/oxidns
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/oxidns.config $(1)/etc/config/oxidns
	$(INSTALL_DIR) $(1)/etc/oxidns/rules
	$(INSTALL_CONF) ./files/config.yaml $(1)/etc/oxidns/config.yaml
	$(INSTALL_DATA) ./files/learned_proxy.txt $(1)/etc/oxidns/rules/learned_proxy.txt
	$(INSTALL_DATA) ./files/learned_direct.txt $(1)/etc/oxidns/rules/learned_direct.txt
endef

$(eval $(call BuildPackage,oxidns))
