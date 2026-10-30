export THEOS_DEVICE_IP = 192.168.1.189
export THEOS_DEVICE_PORT = 22
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus
VCamPlus_FILES = Tweak.m
VCamPlus_FRAMEWORKS = Foundation UIKit AVFoundation CoreVideo CoreMedia PhotosUI VideoToolbox
VCamPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
VCamPlus_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard mediaserverd || true"
