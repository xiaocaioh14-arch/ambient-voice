LLAMA_DIR = libs/llama.cpp
LLAMA_BUILD = $(LLAMA_DIR)/build
NPROC := $(shell sysctl -n hw.logicalcpu)

.PHONY: setup build run test clean release

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
