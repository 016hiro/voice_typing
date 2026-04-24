APP     := VoiceTyping
BUNDLE  := $(APP).app
BIN     := .build/release/$(APP)
PAYLOAD := build/$(BUNDLE)
MLX_METALLIB_SCRIPT := .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh
MLX_METALLIB := .build/release/mlx.metallib
# v0.6.0: Sparkle.framework — SwiftPM produces it but doesn't auto-embed
# in the app bundle the way Xcode does. We copy it into Contents/Frameworks
# (where @rpath/Sparkle.framework looks at runtime) before codesign.
SPARKLE_FRAMEWORK := .build/release/Sparkle.framework

# Stable codesigning identity — created by `make setup-cert`. If present,
# `make build` signs with it (stable cdhash → TCC grants persist across
# rebuilds). If absent, falls back to ad-hoc sign (old behavior; TCC must
# be re-granted every build).
SIGNING_IDENTITY ?= VoiceTyping Dev
# Drop -v: the local self-signed cert reports CSSMERR_TP_NOT_TRUSTED and -v
# filters it out, but codesign can still use it. What matters for TCC is
# the stable cdhash, not the trust chain.
HAVE_SIGNING_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -q "\"$(SIGNING_IDENTITY)\"" && echo yes || echo no)

.PHONY: build run install clean debug metallib setup-metal setup-cert icons reset-perms test test-e2e benchmark-vad benchmark-speed dmg release setup-sparkle-tools setup-dmg-tools

# v0.6.0 release infrastructure
SPARKLE_VERSION  := 2.9.1
SPARKLE_TOOLS    := .build/sparkle-tools
SIGN_UPDATE      := $(SPARKLE_TOOLS)/bin/sign_update
GH_PAGES         := build/gh-pages
APPCAST          := $(GH_PAGES)/appcast.xml
GITHUB_REPO      := 016hiro/voice_typing
DMG_URL_BASE     := https://github.com/$(GITHUB_REPO)/releases/download

# Test bundle path produced by `swift build --build-tests`. E2E tests need
# `mlx.metallib` copied next to this binary so `Bundle.main.executableURL`'s
# directory contains the shaders (same mechanism as the release app bundle).
TEST_BUNDLE_MACOS := .build/arm64-apple-macosx/debug/VoiceTypingPackageTests.xctest/Contents/MacOS
FIXTURE_ROOT := $(shell pwd)/Tests/Fixtures

build: metallib icons
	swift build -c release --arch arm64
	rm -rf $(PAYLOAD)
	mkdir -p $(PAYLOAD)/Contents/MacOS $(PAYLOAD)/Contents/Resources $(PAYLOAD)/Contents/Frameworks
	cp $(BIN) $(PAYLOAD)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(PAYLOAD)/Contents/Info.plist
	cp Resources/AppIcon.icns $(PAYLOAD)/Contents/Resources/AppIcon.icns
	# v0.6.0: SwiftPM doesn't add @executable_path/../Frameworks to LC_RPATH
	# for executable targets, so dyld can't find embedded frameworks at launch
	# (e.g. Sparkle.framework crashes the app with "Library not loaded:
	# @rpath/Sparkle.framework/..."). Inject the rpath post-build, idempotent.
	@if ! otool -l $(PAYLOAD)/Contents/MacOS/$(APP) | grep -q "@executable_path/../Frameworks"; then \
	  install_name_tool -add_rpath "@executable_path/../Frameworks" $(PAYLOAD)/Contents/MacOS/$(APP); \
	  echo "  injected rpath @executable_path/../Frameworks"; \
	fi
	# v0.6.0: embed Sparkle.framework (auto-update) — the binary links
	# @rpath/Sparkle.framework/Versions/B/Sparkle, so the framework must
	# live in Contents/Frameworks before launch. ditto preserves the
	# Versions/B symlink chain and the embedded XPC services / Updater.app.
	@if [ -d $(SPARKLE_FRAMEWORK) ]; then \
	  ditto $(SPARKLE_FRAMEWORK) $(PAYLOAD)/Contents/Frameworks/Sparkle.framework; \
	  echo "  embedded Sparkle.framework → $(PAYLOAD)/Contents/Frameworks/"; \
	else \
	  echo "  [error] $(SPARKLE_FRAMEWORK) not found — Sparkle dependency missing or build failed."; \
	  exit 1; \
	fi
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
	# Bundle the Silero VAD model (1.2 MB) so streaming mode works offline on first run.
	# Without this, SileroVADModel.fromPretrained() hits HuggingFace and hangs when
	# the user triggers voice input offline. See QwenASRRecognizer.bundledVADCacheDir.
	@if [ -f Resources/SileroVAD/model.safetensors ]; then \
	  mkdir -p $(PAYLOAD)/Contents/Resources/SileroVAD; \
	  cp Resources/SileroVAD/model.safetensors Resources/SileroVAD/config.json \
	     $(PAYLOAD)/Contents/Resources/SileroVAD/; \
	  echo "  embedded Silero VAD → $(PAYLOAD)/Contents/Resources/SileroVAD/"; \
	else \
	  echo "  [warn] Resources/SileroVAD/model.safetensors missing — streaming will download VAD on first use."; \
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

# v0.6.0: one-time download of Sparkle's CLI tools (sign_update, generate_keys).
# They aren't in the SwiftPM checkout — Sparkle ships them as a separate release
# tarball. We cache them under .build/ (gitignored) so CI/dev can reproduce.
setup-sparkle-tools:
	@if [ -x $(SIGN_UPDATE) ]; then \
	  echo "  sparkle tools already at $(SPARKLE_TOOLS)/bin/"; \
	else \
	  echo "  downloading Sparkle $(SPARKLE_VERSION) tools..."; \
	  mkdir -p $(SPARKLE_TOOLS); \
	  curl -sSL -o $(SPARKLE_TOOLS)/Sparkle.tar.xz \
	    https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz; \
	  tar -xf $(SPARKLE_TOOLS)/Sparkle.tar.xz -C $(SPARKLE_TOOLS); \
	  echo "  installed to $(SPARKLE_TOOLS)/bin/"; \
	fi

# v0.6.0: one-time install of create-dmg via Homebrew. Required by `make dmg`
# for the custom volume icon, window layout, and icon positioning. Without
# it `make dmg` errors with a friendly hint.
setup-dmg-tools:
	@if command -v create-dmg >/dev/null 2>&1; then \
	  echo "  create-dmg already installed at $$(command -v create-dmg)"; \
	else \
	  echo "  installing create-dmg via Homebrew..."; \
	  brew install create-dmg; \
	fi

# v0.6.0: Package the freshly-built .app into a distribution DMG.
# Usage:  make dmg VERSION=0.6.0
dmg: build setup-dmg-tools
	@test -n "$(VERSION)" || { echo "error: VERSION not set. Usage: make dmg VERSION=0.6.0" >&2; exit 1; }
	bash Scripts/release/make_dmg.sh $(VERSION)

# v0.6.0: Full release flow — build + DMG + EdDSA sign + appcast update.
# Prerequisites (one-time):
#   1. `make setup-sparkle-tools`
#   2. EdDSA keypair in Keychain: `$(SPARKLE_TOOLS)/bin/generate_keys`
#      (then paste the printed public key into Resources/Info.plist SUPublicEDKey)
#   3. gh-pages worktree: `git worktree add $(GH_PAGES) gh-pages`
#
# Usage:  make release VERSION=0.6.0 BUILD=14
# Leaves you with local changes to push:
#   - build/VoiceTyping-<VERSION>.dmg (ready to upload to GitHub Release)
#   - $(APPCAST) updated (ready to commit + push in the gh-pages worktree)
release: dmg setup-sparkle-tools
	@test -n "$(VERSION)" || { echo "error: VERSION not set. Usage: make release VERSION=0.6.0 BUILD=14" >&2; exit 1; }
	@test -n "$(BUILD)"   || { echo "error: BUILD not set.   Usage: make release VERSION=0.6.0 BUILD=14" >&2; exit 1; }
	@test -d $(GH_PAGES)  || { echo "error: $(GH_PAGES) not found. Run: git worktree add $(GH_PAGES) gh-pages" >&2; exit 1; }
	@DMG="build/VoiceTyping-$(VERSION).dmg"; \
	 ED_SIG="$$($(SIGN_UPDATE) -p $$DMG)" || { echo "error: sign_update failed (is the EdDSA private key in your Keychain? run $(SPARKLE_TOOLS)/bin/generate_keys)" >&2; exit 1; }; \
	 echo "  signed DMG → ed_signature=$$ED_SIG"; \
	 python3 Scripts/release/update_appcast.py \
	   --appcast $(APPCAST) \
	   --version $(VERSION) \
	   --build $(BUILD) \
	   --min-system 15.0 \
	   --dmg $$DMG \
	   --dmg-url $(DMG_URL_BASE)/v$(VERSION)/VoiceTyping-$(VERSION).dmg \
	   --ed-signature "$$ED_SIG"; \
	 echo ""; \
	 echo "  ── Next steps ─────────────────────────────────────────────"; \
	 echo "  1. gh release create v$(VERSION) $$DMG --title 'v$(VERSION)' --notes-file docs/devlog/v$(VERSION).md"; \
	 echo "  2. (cd $(GH_PAGES) && git add appcast.xml && git commit -m 'appcast: v$(VERSION)' && git push)"
	 echo "  3. On a clean Mac: download the DMG, install, verify Sparkle detects the next release"

# v0.4.5 prep: sweep candidate VAD tuning presets across every fixture and
# print a side-by-side recap. Same staging as `test-e2e` but runs ONLY the
# `E2EVADTuningBenchmark` suite with `VT_BENCHMARK=1` flipped on. Other E2E
# tests are filtered out so the benchmark output isn't buried.
benchmark-vad: metallib
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
	VT_BENCHMARK=1 \
	swift test --arch arm64 --filter E2EVADTuningBenchmark

# v0.5.1 prep: per-backend × per-fixture batch transcription wall-clock + RTF.
# Loads each backend in turn (Qwen 0.6B → 1.7B → Whisper, see test source for
# why), discards the first fixture per backend as warmup, prints a recap table
# with hardware footer. Skips backends whose models aren't downloaded.
benchmark-speed: metallib
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
	VT_BENCHMARK=1 \
	swift test --arch arm64 --filter E2EBackendSpeedBenchmark
