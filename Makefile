#
# Copyright (C) 2019 lisaac <lisaac.cn@gmail.com>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Docker library
LUCI_DEPENDS:=+luci-lib-json

PKG_LICENSE:=Apache-2.0

include ../../luci.mk

