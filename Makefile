LLAMA_DIR = libs/llama.cpp
LLAMA_BUILD = $(LLAMA_DIR)/build
NPROC := $(shell sysctl -n hw.logicalcpu)
APP_BUNDLE = /Applications/WE.app
SIGN_ID = WE Dev Signing

.PHONY: setup build run test clean release install

setup: $(LLAMA_BUILD)/src/libllama.a

$(LLAMA_BUILD)/src/libllama.a:
	@if [ ! -d "$(LLAMA_DIR)" ]; then \
		echo "Cloning llama.cpp..."; \
		git clone --depth 1 https://github.com/ggerganov/llama.cpp.git $(LLAMA_DIR); \
	fi
	@mkdir -p $(LLAMA_BUILD)
	cd $(LLAMA_BUILD) && cmake .. \
		-DLLAMA_METAL=ON \
		-DLLAMA_ACCELERATE=ON \
		-DGGML_METAL=ON \
		-DGGML_ACCELERATE=ON \
		-DGGML_BLAS=ON \
		-DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_BUILD_TYPE=Release
	cd $(LLAMA_BUILD) && make -j$(NPROC)
	@echo "llama.cpp built successfully."

build: setup
	swift build

run: build
	swift run WE

test:
	swift test

clean:
	swift package clean
	rm -rf $(LLAMA_BUILD)

release: setup
	swift build -c release

## Build, install to /Applications/WE.app, sign with stable cert, and relaunch.
install: build
	@pkill -f "MacOS/WE" 2>/dev/null; sleep 1 || true
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp .build/arm64-apple-macosx/debug/WE "$(APP_BUNDLE)/Contents/MacOS/WE"
	@cp -R .build/arm64-apple-macosx/debug/Sparkle.framework "$(APP_BUNDLE)/Contents/MacOS/"
	@codesign --force --sign "$(SIGN_ID)" "$(APP_BUNDLE)/Contents/MacOS/WE" 2>/dev/null || \
		codesign --force --sign - "$(APP_BUNDLE)/Contents/MacOS/WE"
	@open "$(APP_BUNDLE)"
	@sleep 2
	@echo "WE installed and launched."
