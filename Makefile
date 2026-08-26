APP_NAME    := MailSpace
CONFIG      := release
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
ICON_SRC    := assets/icon-1024.png
ICNS        := $(BUILD_DIR)/AppIcon.icns

.PHONY: all build compile icon bundle sign run smoke test clean

all: build

## build - compile, assemble the .app bundle and ad-hoc sign it
build: sign

compile:
	swift build -c $(CONFIG)

## icon - render AppIcon.icns from assets/icon-1024.png (sips + iconutil)
icon:
	./scripts/make-icns.sh $(ICON_SRC) $(ICNS)

bundle: compile icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo

sign: bundle
	codesign --force --sign - --identifier com.vitalii.MailSpace $(APP)
	@echo "build: $(APP) ready"

## run - build and launch the app
run: build
	open $(APP)

## smoke - build then run the packaging/launch smoke checks
smoke: build
	./scripts/smoke.sh $(APP)

## test - run the unit test suite
test:
	swift test

clean:
	rm -rf .build $(BUILD_DIR)
