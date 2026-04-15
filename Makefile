APP     := VoiceTyping
BUNDLE  := $(APP).app
BIN     := .build/release/$(APP)
PAYLOAD := build/$(BUNDLE)

.PHONY: build run install clean debug

build:
	swift build -c release --arch arm64
	rm -rf $(PAYLOAD)
	mkdir -p $(PAYLOAD)/Contents/MacOS $(PAYLOAD)/Contents/Resources
	cp $(BIN) $(PAYLOAD)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(PAYLOAD)/Contents/Info.plist
	# Copy any SwiftPM-produced resource bundles (WhisperKit metal shaders, etc.)
	@for b in .build/release/*.bundle; do \
	  if [ -e "$$b" ]; then cp -R "$$b" $(PAYLOAD)/Contents/Resources/; fi; \
	done
	codesign --force --deep --sign - \
	  --entitlements Resources/VoiceTyping.entitlements \
	  --options runtime \
	  $(PAYLOAD)
	@echo "Built $(PAYLOAD)"

debug:
	swift build --arch arm64

run: build
	open $(PAYLOAD)

install: build
	rm -rf /Applications/$(BUNDLE)
	cp -R $(PAYLOAD) /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

clean:
	swift package clean
	rm -rf build .build
