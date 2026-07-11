# Works on Linux, macOS, and Windows (GNU make + Git Bash — `scoop install make`).
# `flutter` is taken from PATH; the /home/ravindu fallback covers the Linux box
# where it isn't exported. The platform-tools PATH append is a no-op elsewhere.
FLUTTER := $(shell which flutter 2>/dev/null || echo /home/ravindu/development/flutter/bin/flutter)
DEFINES := --dart-define-from-file=.dart_defines.json
export PATH := $(PATH):/home/ravindu/Android/Sdk/platform-tools

# First connected Android device id, parsed from `flutter devices` plain output
# (id sits between the first two "•" bullets; no python needed). Lazy `=` so
# the ~2s device scan only runs for the android target. Falls back to the
# literal "android" so flutter prints its own device error.
ANDROID_DEVICE = $(or $(shell $(FLUTTER) devices 2>/dev/null | grep ' android-' | head -1 | awk -F '•' '{print $$2}' | xargs),android)

.PHONY: linux windows macos android apk build-linux build-windows

linux:
	$(FLUTTER) run -d linux $(DEFINES)

windows:
	$(FLUTTER) run -d windows $(DEFINES)

macos:
	$(FLUTTER) run -d macos $(DEFINES)

android:
	$(FLUTTER) run -d $(ANDROID_DEVICE) $(DEFINES)

apk:
	$(FLUTTER) build apk $(DEFINES)

build-linux:
	$(FLUTTER) build linux $(DEFINES)

build-windows:
	$(FLUTTER) build windows $(DEFINES)
