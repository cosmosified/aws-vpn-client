# Native macOS build for aws-vpn-client + patched OpenVPN.
#
# This builds everything on the host (no Docker), producing native binaries:
#   build/openvpn-darwin   - patched OpenVPN client (native arch)
#   build/aws-vpn-client   - the Go CLI
#
# Usage:
#   make                       # build everything (default OPENVPN_VERSION)
#   make OPENVPN_VERSION=2.6.3  # build against a different patched version
#   make openvpn               # build only the patched OpenVPN binary
#   make client                # build only the Go CLI
#   make check-deps            # verify required tooling is installed
#   make clean                 # remove the build directory
#
# Requires Homebrew packages: openssl@3, lzo, lz4, autoconf, automake, libtool, pkg-config
#   brew install openssl@3 lzo lz4 autoconf automake libtool pkg-config

OPENVPN_VERSION ?= 2.7.4

# --- Layout -----------------------------------------------------------------
BUILD_DIR    := build
SRC_DIR      := $(BUILD_DIR)/openvpn-$(OPENVPN_VERSION)
ZIP          := $(BUILD_DIR)/openvpn-$(OPENVPN_VERSION).zip
PATCH        := patches/openvpn-v$(OPENVPN_VERSION)-aws.patch
DOWNLOAD_URL := https://github.com/OpenVPN/openvpn/archive/v$(OPENVPN_VERSION).zip

OVPN_BIN   := $(BUILD_DIR)/openvpn-darwin
CLIENT_BIN := $(BUILD_DIR)/aws-vpn-client

# --- Toolchain / Homebrew (auto-detected: works on arm64 and Intel) ---------
BREW_PREFIX    := $(shell brew --prefix 2>/dev/null)
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null)
JOBS           := $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Headers/libs for the (non-keg-only) deps like lzo/lz4 live under the prefix.
# openssl@3 is keg-only, so it is found via pkg-config instead.
OVPN_CFLAGS  := -I$(BREW_PREFIX)/include
OVPN_LDFLAGS := -L$(BREW_PREFIX)/lib
OVPN_PKGCFG  := $(OPENSSL_PREFIX)/lib/pkgconfig

GO_SRCS := $(shell find . -name '*.go' -not -path './$(BUILD_DIR)/*' 2>/dev/null) go.mod go.sum

.DEFAULT_GOAL := all
.PHONY: all openvpn client check-deps clean distclean help

all: openvpn client ## Build the patched OpenVPN binary and the Go CLI

openvpn: $(OVPN_BIN) ## Build only the patched OpenVPN binary

client: $(CLIENT_BIN) ## Build only the Go CLI

# --- Dependency check -------------------------------------------------------
check-deps: ## Verify required tooling is installed
	@missing=0; \
	for t in brew go curl unzip patch autoreconf pkg-config; do \
		command -v $$t >/dev/null 2>&1 || { echo "  missing: $$t"; missing=1; }; \
	done; \
	if [ -z "$(OPENSSL_PREFIX)" ]; then echo "  missing: openssl@3 (brew install openssl@3)"; missing=1; fi; \
	pkg-config --exists lzo2  2>/dev/null || { echo "  missing: lzo (brew install lzo)"; missing=1; }; \
	pkg-config --exists liblz4 2>/dev/null || { echo "  missing: lz4 (brew install lz4)"; missing=1; }; \
	test -f "$(PATCH)" || { echo "  missing patch: $(PATCH)"; missing=1; }; \
	if [ $$missing -ne 0 ]; then echo "Dependency check failed."; exit 1; fi; \
	echo "All dependencies present."

$(BUILD_DIR):
	mkdir -p $@

# --- OpenVPN: download -> patch -> autoreconf -> configure -> make -----------
$(ZIP): | $(BUILD_DIR)
	curl -fsSL "$(DOWNLOAD_URL)" -o $@

$(SRC_DIR)/.patched: $(ZIP) $(PATCH)
	rm -rf $(SRC_DIR)
	cd $(BUILD_DIR) && unzip -q "$(notdir $(ZIP))"
	cd $(SRC_DIR) && patch -p1 < "$(CURDIR)/$(PATCH)"
	# Stable symlink (./openvpn -> build/openvpn-<version>) so clangd's
	# compile_flags.txt can reference a version-independent path.
	ln -sfn $(SRC_DIR) openvpn
	touch $@

$(SRC_DIR)/.configured: $(SRC_DIR)/.patched
	cd $(SRC_DIR) && autoreconf -ivf
	cd $(SRC_DIR) && \
		CFLAGS="$(OVPN_CFLAGS)" \
		LDFLAGS="$(OVPN_LDFLAGS)" \
		PKG_CONFIG_PATH="$(OVPN_PKGCFG)" \
		./configure
	touch $@

$(OVPN_BIN): $(SRC_DIR)/.configured | $(BUILD_DIR)
	cd $(SRC_DIR) && $(MAKE) -j$(JOBS)
	cp $(SRC_DIR)/src/openvpn/openvpn $@
	@echo "Built $@"
	@./$@ --version | head -1 || true

# --- Go CLI -----------------------------------------------------------------
$(CLIENT_BIN): $(GO_SRCS) | $(BUILD_DIR)
	CGO_ENABLED=0 go build -ldflags '-s -w' -o $@ .
	@echo "Built $@"

# --- Housekeeping -----------------------------------------------------------
clean: ## Remove the entire build directory
	rm -rf $(BUILD_DIR)

distclean: clean ## Alias for clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*## "}{printf "  %-14s %s\n", $$1, $$2}'
