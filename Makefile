.PHONY: build run dev dmg clean

APP_NAME    = Parrot
BUILD_DIR   = .build/release
DEBUG_DIR   = .build/debug
APP_BUNDLE  = $(APP_NAME).app
DIST_DIR    = dist
DMG_FILE    = $(DIST_DIR)/$(APP_NAME).dmg

MLX_METAL_DIR = .build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal
METALLIB      = .build/mlx.metallib

SIGN_IDENTITY ?= Developer ID Application: Yudu Ban (RYLS8UDY5D)
ENTITLEMENTS   = Resources/Parrot.entitlements

define assemble_app
	@rm -rf "$(1)"
	@mkdir -p "$(1)/Contents/MacOS"
	@mkdir -p "$(1)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(1)/Contents/MacOS/"
	@cp "$(METALLIB)" "$(1)/Contents/MacOS/mlx.metallib"
	@cp Resources/Info.plist "$(1)/Contents/"
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		codesign --force --deep --sign - "$(1)"; \
	else \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" \
			--entitlements "$(ENTITLEMENTS)" \
			--options runtime \
			--timestamp \
			"$(1)"; \
	fi
endef

metallib:
	@if [ ! -f "$(METALLIB)" ] || [ -n "$$(find $(MLX_METAL_DIR) -name '*.metal' -newer $(METALLIB) 2>/dev/null)" ]; then \
		echo "Compiling Metal shaders..."; \
		rm -rf .build/mlx_air && mkdir -p .build/mlx_air; \
		for f in $(MLX_METAL_DIR)/*.metal; do \
			xcrun metal -target air64-apple-macos14.0 \
				-I $(MLX_METAL_DIR) \
				-I $(MLX_METAL_DIR)/steel \
				-I $(MLX_METAL_DIR)/steel/attn \
				-I $(MLX_METAL_DIR)/steel/conv \
				-I $(MLX_METAL_DIR)/steel/gemm \
				-I $(MLX_METAL_DIR)/fft \
				-c "$$f" -o ".build/mlx_air/$$(basename $$f .metal).air"; \
		done; \
		xcrun metallib .build/mlx_air/*.air -o "$(METALLIB)"; \
		rm -rf .build/mlx_air; \
	fi

build:
	swift build -c release
	@$(MAKE) metallib
	$(call assemble_app,$(APP_BUNDLE))
	@echo "Built $(APP_BUNDLE)"

run: build
	@open "$(APP_BUNDLE)"

dev:
	swift build
	@$(MAKE) metallib
	@cp "$(METALLIB)" "$(DEBUG_DIR)/mlx.metallib" 2>/dev/null || true
	@"$(DEBUG_DIR)/$(APP_NAME)"

dmg:
	swift build -c release
	@$(MAKE) metallib
	$(call assemble_app,$(DIST_DIR)/$(APP_NAME).app)
	@rm -rf "$(DIST_DIR)/dmg" "$(DMG_FILE)"
	@mkdir -p "$(DIST_DIR)/dmg"
	@ditto "$(DIST_DIR)/$(APP_NAME).app" "$(DIST_DIR)/dmg/$(APP_NAME).app"
	@ln -s /Applications "$(DIST_DIR)/dmg/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST_DIR)/dmg" -ov -format UDZO "$(DMG_FILE)"
	@rm -rf "$(DIST_DIR)/dmg" "$(DIST_DIR)/$(APP_NAME).app"
	@echo "Built $(DMG_FILE)"

clean:
	swift package clean
	@rm -rf "$(APP_BUNDLE)" "$(DIST_DIR)" "$(METALLIB)"
