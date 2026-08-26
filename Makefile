APP_NAME    := MailSpace
BUNDLE_ID   := com.vitalii.MailSpace
CONFIG      := release
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
ICON_SRC    := assets/icon-1024.png
ICNS        := $(BUILD_DIR)/AppIcon.icns

# Stable self-signed code-signing identity, created once by `make signing-cert`.
# Without it the bundle is ad-hoc signed, which works but gives the app a new
# identity on every rebuild — and therefore a fresh notification permission
# prompt each time.
SIGN_IDENTITY ?= MailSpace Self-Signed

.PHONY: all build compile icon bundle sign signing-cert run smoke test clean

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

## signing-cert - create the stable self-signed code-signing identity (once per Mac)
signing-cert:
	./scripts/make-signing-cert.sh

sign: bundle
	@if security find-certificate -c "$(SIGN_IDENTITY)" >/dev/null 2>&1; then \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) $(APP); \
		echo "build: signed with \"$(SIGN_IDENTITY)\""; \
	else \
		codesign --force --sign - --identifier $(BUNDLE_ID) $(APP); \
		echo "build: warning - no \"$(SIGN_IDENTITY)\" certificate, fell back to ad-hoc signing."; \
		echo "build:          notifications still work, but macOS will ask for notification"; \
		echo "build:          permission again after every rebuild. Run 'make signing-cert' once to stop that."; \
	fi
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
