SCHEME = Quick Access for Pass
APP_NAME = Quick Access for Pass.app
BUILD_DIR = build

.PHONY: build install clean

build:
	xcodebuild -scheme "$(SCHEME)" -configuration Release -derivedDataPath $(BUILD_DIR) build

install: build
	-pkill -x "Quick Access for Pass" 2>/dev/null; sleep 0.5
	rm -rf "/Applications/$(APP_NAME)"
	mv "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" /Applications/
	open "/Applications/$(APP_NAME)"

clean:
	rm -rf $(BUILD_DIR)
