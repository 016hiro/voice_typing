APP     := VoiceTyping
BUNDLE  := $(APP).app
BIN     := .build/release/$(APP)
PAYLOAD := build/$(BUNDLE)
MLX_METALLIB_SCRIPT := .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh
MLX_METALLIB := .build/release/mlx.metallib

.PHONY: build run install clean debug metallib setup-metal

build: metallib
	swift build -c release --arch arm64
	rm -rf $(PAYLOAD)
	mkdir -p $(PAYLOAD)/Contents/MacOS $(PAYLOAD)/Contents/Resources
	cp $(BIN) $(PAYLOAD)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(PAYLOAD)/Contents/Info.plist
	# Copy SwiftPM-produced resource bundles (WhisperKit shaders, HuggingFace tokenizer bundles, etc.)
	@for b in .build/release/*.bundle; do \
	  if [ -e "$$b" ]; then cp -R "$$b" $(PAYLOAD)/Contents/Resources/; fi; \
	done
	# Copy MLX Metal shader library next to the executable (used by Qwen ASR backends).
	@if [ -f $(MLX_METALLIB) ]; then \
	  cp $(MLX_METALLIB) $(PAYLOAD)/Contents/MacOS/mlx.metallib; \
	  echo "  embedded $(MLX_METALLIB) → $(PAYLOAD)/Contents/MacOS/mlx.metallib"; \
	else \
	  echo "  [warn] $(MLX_METALLIB) not found — Qwen ASR backends will fail at runtime."; \
	  echo "         Run 'make setup-metal' once, then 'make build' again."; \
	fi
	codesign --force --deep --sign - \
	  --entitlements Resources/VoiceTyping.entitlements \
	  --options runtime \
	  $(PAYLOAD)
	@echo "Built $(PAYLOAD)"

# Build MLX's Metal shader library. Requires Apple's Metal Toolchain to be installed
# (see `make setup-metal`). No-op if already built and sources unchanged.
metallib:
	@if [ ! -d .build/checkouts/speech-swift ]; then \
	  echo "Resolving SwiftPM packages before compiling metallib..."; \
	  swift package resolve; \
	fi
	@if [ -x $(MLX_METALLIB_SCRIPT) ]; then \
	  BUILD_DIR=$$(pwd)/.build bash $(MLX_METALLIB_SCRIPT) release || \
	    echo "  [warn] metallib compile failed — run 'make setup-metal' if Metal Toolchain is missing."; \
	fi

# One-time: install Apple's Metal Toolchain. Needed to compile MLX shaders.
# If this fails with DVTPlugInLoading errors, you may need to run
# `sudo xcodebuild -runFirstLaunch` first (requires your password).
setup-metal:
	xcodebuild -downloadComponent MetalToolchain

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
