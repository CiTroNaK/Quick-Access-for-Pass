# shellcheck disable=SC2034
SCHEME=Quick Access for Pass
APP_NAME=Quick Access for Pass.app
BUILD_DIR=build
BUILT_APP=$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)
BUNDLED_PASS_CLI_DIR=$(BUILD_DIR)/bundled-pass-cli

.PHONY: build install clean

build:
	rm -rf "$(BUILT_APP)/Contents/Helpers/ProtonPassCLI"
	xcodebuild -scheme "$(SCHEME)" -configuration Release -derivedDataPath "$(BUILD_DIR)" build
	scripts/verify-app-bundle-metadata.sh \
		"$(BUILT_APP)" \
		"$(BUILT_APP)/Contents/PlugIns/Quick Access AutoFill.appex"

install: build
	scripts/prepare-bundled-pass-cli.sh "$(BUNDLED_PASS_CLI_DIR)"
	scripts/inject-bundled-pass-cli.sh "$(BUILT_APP)" "$(BUNDLED_PASS_CLI_DIR)"
	pkill -x "Quick Access for Pass" 2>/dev/null || true; sleep 0.5
	rm -rf "/Applications/$(APP_NAME)"
	mv "$(BUILT_APP)" /Applications/
	open "/Applications/$(APP_NAME)"

clean:
	rm -rf "$(BUILD_DIR)"
