include $(THEOS)/makefiles/common.mk

TOOL_NAME = framecli

ARCHS = arm64
SYSROOT = $(THEOS)/sdks/iPhoneOS15.5.sdk
BUNDLE_NAME = framepreferences

framecli_INSTALL_PATH = /usr/local/bin
framecli_FRAMEWORKS = Foundation

framecli_FILES = main.m
framecli_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tool.mk
