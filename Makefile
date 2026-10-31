PROJECT_DIR := $(abspath .)
ABLAC_DIR ?= $(abspath ../ablac)
COMPILER ?= $(ABLAC_DIR)/build/ablac
BUILD_DIR ?= $(PROJECT_DIR)/build
# A literal `#` inside $(shell ...) starts a comment in GNU make 3.81, and the
# old `\#` escape is kept verbatim since make 4.3; a variable works in both.
HASH := \#
NIXPKGS_SOURCE ?= $(shell nix eval --raw nixpkgs$(HASH)path)
NIXPKGS_IMPORT := -I nixpkgs=$(NIXPKGS_SOURCE)
# CI's released compiler builds programs that run outside the Nix shell, not in it.
INTEGRATION_SHELL ?= nix-shell $(NIXPKGS_IMPORT) $(ABLAC_DIR)/shell.nix --run

.PHONY: check test test-in-shell integration integration-in-shell clean

check:
	mkdir -p $(BUILD_DIR)
	$(COMPILER) package vendor --project $(PROJECT_DIR)
	$(COMPILER) build tests/signing_test.ab -o $(BUILD_DIR)/signing-test --no-cache
	$(COMPILER) build tests/client_test.ab -o $(BUILD_DIR)/client-test --no-cache
	$(COMPILER) build tests/config_test.ab -o $(BUILD_DIR)/config-test --no-cache
	$(COMPILER) build tests/integration_test.ab -o $(BUILD_DIR)/integration-test --no-cache

test:
	@if [ -n "$$IN_NIX_SHELL" ]; then \
		$(MAKE) test-in-shell; \
	else \
		nix-shell $(NIXPKGS_IMPORT) $(ABLAC_DIR)/shell.nix --run '$(MAKE) test-in-shell'; \
	fi

test-in-shell: check
	$(BUILD_DIR)/signing-test
	$(BUILD_DIR)/client-test
	S3_ENDPOINT_HOST=127.0.0.1 S3_ENDPOINT_PORT=19001 \
		S3_BUCKET=micro-config S3_REGION=eu-west-1 \
		S3_ACCESS_KEY_ID_FILE=$(PROJECT_DIR)/tests/access_key_fixture.txt \
		S3_SECRET_ACCESS_KEY_FILE=$(PROJECT_DIR)/tests/secret_key_fixture.txt \
		S3_SESSION_TOKEN=session-token S3_PATH_STYLE=true S3_USE_TLS=false \
		S3_MAX_NETWORK_RETRIES=3 $(BUILD_DIR)/config-test

integration: check
	@seaweedfs_path=$$(nix-build $(NIXPKGS_IMPORT) '<nixpkgs>' -A seaweedfs --no-out-link); \
		$(INTEGRATION_SHELL) "PATH=$$seaweedfs_path/bin:\$$PATH $(MAKE) integration-in-shell"

integration-in-shell:
	bash tools/test-s3.sh $(BUILD_DIR)/integration-test

clean:
	@if [ -d "$(BUILD_DIR)" ]; then gio trash "$(BUILD_DIR)"; fi
