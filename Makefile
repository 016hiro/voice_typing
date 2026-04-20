APP     := VoiceTyping
BUNDLE  := $(APP).app
BIN     := .build/release/$(APP)
PAYLOAD := build/$(BUNDLE)
MLX_METALLIB_SCRIPT := .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh
MLX_METALLIB := .build/release/mlx.metallib

# Stable codesigning identity — created by `make setup-cert`. If present,
# `make build` signs with it (stable cdhash → TCC grants persist across
# rebuilds). If absent, falls back to ad-hoc sign (old behavior; TCC must
# be re-granted every build).
SIGNING_IDENTITY ?= VoiceTyping Dev
# Drop -v: the local self-signed cert reports CSSMERR_TP_NOT_TRUSTED and -v
# filters it out, but codesign can still use it. What matters for TCC is
# the stable cdhash, not the trust chain.
HAVE_SIGNING_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -q "\"$(SIGNING_IDENTITY)\"" && echo yes || echo no)

.PHONY: build run install clean debug metallib setup-metal setup-cert icons reset-perms test test-e2e

# Test bundle path produced by `swift build --build-tests`. E2E tests need
# `mlx.metallib` copied next to this binary so `Bundle.main.executableURL`'s
# directory contains the shaders (same mechanism as the release app bundle).
TEST_BUNDLE_MACOS := .build/arm64-apple-macosx/debug/VoiceTypingPackageTests.xctest/Contents/MacOS
FIXTURE_ROOT := $(shell pwd)/Tests/Fixtures

build: metallib icons
	swift build -c release --arch arm64
	rm -rf $(PAYLOAD)
	mkdir -p $(PAYLOAD)/Contents/MacOS $(PAYLOAD)/Contents/Resources
	cp $(BIN) $(PAYLOAD)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(PAYLOAD)/Contents/Info.plist
	cp Resources/AppIcon.icns $(PAYLOAD)/Contents/Resources/AppIcon.icns
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
ifeq ($(HAVE_SIGNING_IDENTITY),yes)
	codesign --force --deep --sign "$(SIGNING_IDENTITY)" \
	  --entitlements Resources/VoiceTyping.entitlements \
	  --options runtime \
	  $(PAYLOAD)
	@echo "  signed with '$(SIGNING_IDENTITY)' (stable cdhash)"
else
	codesign --force --deep --sign - \
	  --entitlements Resources/VoiceTyping.entitlements \
	  --options runtime \
	  $(PAYLOAD)
	@echo "  ad-hoc signed — run 'make setup-cert' once for stable TCC grants across rebuilds"
endif
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

# Regenerates 10 master PNGs in Resources/icons/ and rebuilds
# Resources/AppIcon.icns from the active design (default: 02 waveform).
# Override with e.g. `make icons ICON=05`.
ICON ?= 02
icons:
	swift Scripts/generate_icons.swift $(ICON)

# One-time: install Apple's Metal Toolchain. Needed to compile MLX shaders.
# If this fails with DVTPlugInLoading errors, you may need to run
# `sudo xcodebuild -runFirstLaunch` first (requires your password).
setup-metal:
	xcodebuild -downloadComponent MetalToolchain

# One-time: create a local self-signed codesigning identity so subsequent
# `make build` runs produce a stable cdhash. Without this, macOS TCC
# resets Microphone/Accessibility grants every rebuild.
setup-cert:
	bash Scripts/setup_cert.sh

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

# Dev convenience: reset TCC grants for this bundle so the next launch
# re-prompts for Microphone + Accessibility. Useful when testing permission
# flows or after bundle-id changes. Safe to run even if no grants exist.
reset-perms:
	-tccutil reset Accessibility com.voicetyping.app
	-tccutil reset Microphone   com.voicetyping.app
	@echo "✓ Reset TCC for com.voicetyping.app"

# Fast regression loop: unit tests only (no fixtures, no model download).
# Matches what CI runs. E2E tests filtered out by `--skip E2E`.
test:
	VT_FIXTURE_ROOT=$(FIXTURE_ROOT) swift test --skip E2E --arch arm64

# Full regression: unit + E2E. Requires Qwen model already downloaded to
# `~/Library/Application Support/VoiceTyping/models/` (launch the app once
# to trigger). Silero VAD downloads on first run (~2 MB).
#
# Stages mlx.metallib into the test bundle so MLX kernels can find it —
# Bundle.main.executableURL in the test process points at the xctest binary,
# not the app bundle, so without this copy MLXSupport.isAvailable's path
# check misses it.
test-e2e: metallib
	swift build --build-tests --arch arm64
	@if [ -f $(MLX_METALLIB) ]; then \
	  cp $(MLX_METALLIB) $(TEST_BUNDLE_MACOS)/mlx.metallib; \
	  echo "  staged mlx.metallib → $(TEST_BUNDLE_MACOS)/"; \
	else \
	  echo "  [warn] $(MLX_METALLIB) missing — run 'make setup-metal'"; \
	  exit 1; \
	fi
	VT_FIXTURE_ROOT=$(FIXTURE_ROOT) \
	VT_MLX_TEST_READY=1 \
	swift test --arch arm64
