FLUTTER := $(shell which flutter 2>/dev/null || echo /home/ravindu/development/flutter/bin/flutter)
DEFINES := --dart-define-from-file=.dart_defines.json

.PHONY: linux windows macos android apk

linux:
	$(FLUTTER) run -d linux $(DEFINES)

windows:
	$(FLUTTER) run -d windows $(DEFINES)

macos:
	$(FLUTTER) run -d macos $(DEFINES)

android:
	$(FLUTTER) run -d $(shell $(FLUTTER) devices --machine 2>/dev/null | python3 -c "import sys,json; devs=[d for d in json.load(sys.stdin) if d.get('targetPlatform','').startswith('android')]; print(devs[0]['id'] if devs else 'android')") $(DEFINES)

apk:
	$(FLUTTER) build apk $(DEFINES)

build-linux:
	$(FLUTTER) build linux $(DEFINES)

build-windows:
	$(FLUTTER) build windows $(DEFINES)
