# Thin wrapper around xcodebuild with automatic signing.
#
#   make TEAM=ABCDE12345    # first time: records your team in Local.xcconfig, then builds
#   make                    # later builds
#   make install            # copies the app to /Applications (required to activate the extension)

# Use full Xcode even if xcode-select points at the standalone Command Line Tools.
XCODE_SELECT := $(shell xcode-select -p)
DEVELOPER_DIR ?= $(if $(findstring CommandLineTools,$(XCODE_SELECT)),/Applications/Xcode.app/Contents/Developer,$(XCODE_SELECT))
export DEVELOPER_DIR

APP := build/Release/CFILRepro.app

.PHONY: build adhoc install clean
build:
ifneq ($(TEAM),)
	echo "DEVELOPMENT_TEAM = $(TEAM)" > Local.xcconfig
endif
	@test -f Local.xcconfig || { echo "run: make TEAM=<your team ID>  (Xcode > Settings > Accounts > your team)"; exit 1; }
	# A fresh build number each time makes `CFILRepro activate` replace an older installed extension.
	xcodebuild -project CFILRepro.xcodeproj -target CFILRepro -configuration Release \
	  -allowProvisioningUpdates SYMROOT="$(CURDIR)/build" CURRENT_PROJECT_VERSION=$$(date +%s) build
	@echo "built $(APP)"

# Unsigned (ad-hoc) build, only loadable on a Mac/VM with SIP off and amfi_get_out_of_my_way=1.
# Output: build-adhoc/Release/CFILRepro.app
# Xcode refuses to ad-hoc sign profile-gated entitlements, so build unsigned and sign here.
ADHOC_APP  := build-adhoc/Release/CFILRepro.app
adhoc:
	# Bundle IDs must come from an xcconfig (command-line overrides don't reach the embed step).
	test -f Local.xcconfig || echo "BUNDLE_PREFIX = dev.adhoc" > Local.xcconfig
	rm -rf build-adhoc
	xcodebuild -project CFILRepro.xcodeproj -target CFILRepro -configuration Release \
	  CODE_SIGNING_ALLOWED=NO SYMROOT="$(CURDIR)/build-adhoc" CURRENT_PROJECT_VERSION=$$(date +%s) build
	sed 's/$$(TeamIdentifierPrefix)//' ext/CFILReproFilter.entitlements > build-adhoc/ext.entitlements
	sed 's/$$(TeamIdentifierPrefix)//' app/CFILRepro.entitlements > build-adhoc/app.entitlements
	codesign --force --options runtime --sign - --entitlements build-adhoc/ext.entitlements $(ADHOC_APP)/Contents/Library/SystemExtensions/*.systemextension
	codesign --force --options runtime --sign - --entitlements build-adhoc/app.entitlements $(ADHOC_APP)
	@echo "built $(ADHOC_APP)"

install: build
	rm -rf /Applications/CFILRepro.app
	cp -R $(APP) /Applications/
	@echo "installed /Applications/CFILRepro.app"

clean:
	rm -rf build build-adhoc
