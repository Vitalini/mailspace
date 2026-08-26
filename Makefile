APP_NAME    := MailSpace
# The identity the user's notification permission, accounts and Keychain items
# belong to. Never change it: a new identifier is a new app to macOS and throws
# the granted notification permission away.
BUNDLE_ID   := com.vitalii.MailSpace
CONFIG      := release
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
ICON_SRC    := assets/icon-1024.png
ICNS        := $(BUILD_DIR)/AppIcon.icns

# Disposable identity for the headless self-tests: the same compiled binary in a
# second bundle, so any notification prompt, authorization record, account list
# or Keychain item a probe creates belongs to it and not to the real app.
SELFTEST_BUNDLE_ID := $(BUNDLE_ID).SelfTest
SELFTEST_APP       := $(BUILD_DIR)/$(APP_NAME)-SelfTest.app

# Stable self-signed code-signing identity, created once by `make signing-cert`.
# Without it the bundle is ad-hoc signed, which works but gives the app a new
# identity on every rebuild — and therefore a fresh notification permission
# prompt each time.
SIGN_IDENTITY ?= MailSpace Self-Signed

.PHONY: all build compile icon bundle sign signing-cert selftest-app run smoke test clean

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
	@./scripts/codesign-bundle.sh $(APP) $(BUNDLE_ID) "$(SIGN_IDENTITY)"
	@echo "build: $(APP) ready"

## selftest-app - assemble the throwaway self-test bundle (same binary, own identity)
##                Nothing to recompile: it copies the built binary and rewrites
##                three Info.plist keys.
selftest-app: sign
	rm -rf $(SELFTEST_APP)
	mkdir -p $(SELFTEST_APP)/Contents/MacOS $(SELFTEST_APP)/Contents/Resources
	cp $(APP)/Contents/MacOS/$(APP_NAME) $(SELFTEST_APP)/Contents/MacOS/$(APP_NAME)
	cp $(APP)/Contents/Resources/AppIcon.icns $(SELFTEST_APP)/Contents/Resources/AppIcon.icns
	# Which app binary this was assembled from. Re-signing under the other
	# identifier rewrites the Mach-O, so the two files no longer compare equal;
	# this is how the smoke run still proves the probes exercise the shipped code.
	shasum -a 256 $(APP)/Contents/MacOS/$(APP_NAME) | cut -d' ' -f1 \
		> $(SELFTEST_APP)/Contents/Resources/source-binary.sha256
	cp Resources/Info.plist $(SELFTEST_APP)/Contents/Info.plist
	printf 'APPL????' > $(SELFTEST_APP)/Contents/PkgInfo
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleIdentifier $(SELFTEST_BUNDLE_ID)" \
		-c "Set :CFBundleName $(APP_NAME) SelfTest" \
		-c "Set :CFBundleDisplayName $(APP_NAME) SelfTest" \
		-c "Delete :CFBundleURLTypes" \
		$(SELFTEST_APP)/Contents/Info.plist >/dev/null
	@./scripts/codesign-bundle.sh $(SELFTEST_APP) $(SELFTEST_BUNDLE_ID) "$(SIGN_IDENTITY)"
	@echo "build: $(SELFTEST_APP) ready ($(SELFTEST_BUNDLE_ID))"

## run - build and launch the app
run: build
	open $(APP)

## smoke - build then run the packaging/launch smoke checks
##         Every check that launches anything launches the self-test bundle; the
##         real app is only inspected on disk.
smoke: selftest-app
	./scripts/smoke.sh $(APP) $(SELFTEST_APP)

## test - run the unit test suite
test:
	swift test

clean:
	rm -rf .build $(BUILD_DIR)
