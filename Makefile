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

# The one place a version number is written by hand. The tag name, the two
# Info.plist keys and the release asset name are all derived from it, so they
# cannot disagree with each other.
#
# CFBundleVersion is computed, never stored: 1.2.0 -> 10200. Monotonic exactly
# when the semver is, which `scripts/release.sh` enforces. A git commit count
# would not be — this repo merges agent worktrees.
VERSION      := $(shell cat VERSION)
BUILD_NUMBER := $(shell awk -F. '{printf "%d", $$1*10000 + $$2*100 + $$3}' VERSION)
GIT_DESCRIBE := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

.PHONY: all build compile icon bundle sign signing-cert selftest-app run smoke test clean \
        version update-key changelog-draft release release-dry-run bench assume

all: build

## build - compile, assemble the .app bundle and ad-hoc sign it
build: sign

compile:
	swift build -c $(CONFIG)

## icon - render AppIcon.icns from assets/icon-1024.png (sips + iconutil)
icon:
	./scripts/make-icns.sh $(ICON_SRC) $(ICNS)

# Writes the version into an assembled bundle and then proves it landed. The
# guard is the point: a renamed placeholder or a PlistBuddy that silently did
# nothing would otherwise ship an app whose "you have" line is a lie, and the
# updater compares against exactly that value.
define stamp_version
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD_NUMBER)" \
		-c "Add :MSGitDescribe string $(GIT_DESCRIBE)" \
		$(1)/Contents/Info.plist >/dev/null
	@grep -q '__MARKETING_VERSION__\|__BUILD_NUMBER__' $(1)/Contents/Info.plist \
		&& { echo "bundle: version placeholder survived substitution in $(1)"; exit 1; } || true
endef

bundle: compile icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	$(call stamp_version,$(APP))

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
	# The self-test bundle copies Resources/Info.plist directly, so it needs the
	# same substitution — an unstamped copy would carry the raw placeholders.
	$(call stamp_version,$(SELFTEST_APP))
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

## bench - measure what a recycle actually reclaims, both arms, offline
##         Runs the throwaway self-test bundle: no Google account, no mail, a
##         synthetic page in a temp directory, a deferred window that is ordered
##         out before the run loop turns. Never the app in /Applications.
##
##         Arm A is `reload()`, arm B is the shipping replacement. Phase
##         durations follow the plan (10 min grow, 5 min settle) and can be
##         shortened with MAILSPACE_BENCH_GROW / MAILSPACE_BENCH_SETTLE.
bench: selftest-app
	@echo "bench: arm A — webView.reload()"
	@MAILSPACE_SELFTEST=bench MAILSPACE_BENCH_ARM=a \
		$(SELFTEST_APP)/Contents/MacOS/$(APP_NAME) 2>/dev/null | grep '^SELFTEST '
	@echo "bench: arm B — replace the webview (the shipping path)"
	@MAILSPACE_SELFTEST=bench MAILSPACE_BENCH_ARM=b \
		$(SELFTEST_APP)/Contents/MacOS/$(APP_NAME) 2>/dev/null | grep '^SELFTEST '

## assume - check the two platform behaviours the recycling guards rest on
assume: selftest-app
	@MAILSPACE_SELFTEST=assume $(SELFTEST_APP)/Contents/MacOS/$(APP_NAME) 2>/dev/null | grep '^SELFTEST '

## test - run the unit test suite
test:
	swift test

## version - print what this checkout would ship as
version:
	@echo "marketing  $(VERSION)"
	@echo "build      $(BUILD_NUMBER)"
	@echo "describe   $(GIT_DESCRIBE)"

## update-key - create the Ed25519 key that signs release zips (once per Mac)
##              Writes the private key OUTSIDE the repo and pastes the public
##              half into Resources/Info.plist.
update-key:
	./scripts/make-update-key.sh

## changelog-draft - seed CHANGELOG.md's [Unreleased] section from git log
changelog-draft:
	./scripts/changelog-draft.sh

## release - build, package, sign, tag and publish v$(VERSION) to GitHub
release:
	./scripts/release.sh

## release-dry-run - everything `release` does except tag, push and publish
release-dry-run:
	./scripts/release.sh --dry-run

clean:
	rm -rf .build $(BUILD_DIR) dist
