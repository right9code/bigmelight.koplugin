PLUGIN_DIR := bigmelight.koplugin
MAIN_LUA   := $(PLUGIN_DIR)/main.lua
HELPER_SH  := helper/bigme_light.sh
VERSION    := 1.2.0
ZIP_NAME   := bigmelight-v$(VERSION).zip

.PHONY: all embed check clean release

all: embed

# Regenerate the base64 helper embedded in main.lua from helper/bigme_light.sh
embed:
	@B64=$$(base64 -w0 "$(HELPER_SH)"); \
	sed -i "s|^local HELPER_B64 = \".*\"|local HELPER_B64 = \"$$B64\"|" "$(MAIN_LUA)"
	@echo "embedded $(HELPER_SH) -> $(MAIN_LUA)"

# Fail if the embedded helper is out of sync with the source script
check: embed
	@git diff --quiet -- "$(MAIN_LUA)" || { \
		echo "ERROR: $(MAIN_LUA) embedded helper is out of sync with $(HELPER_SH)"; \
		echo "Run 'make embed' and commit the result."; \
		git checkout -- "$(MAIN_LUA)"; exit 1; }

# Build the release zip users drop into koreader/plugins/
# The archive must contain a top-level bigmelight.koplugin/ folder.
release: embed
	@rm -f "$(ZIP_NAME)"
	@rm -rf /tmp/kilo/bigmelight-release
	@mkdir -p /tmp/kilo/bigmelight-release
	@cp -r "$(PLUGIN_DIR)" /tmp/kilo/bigmelight-release/
	@OUT="$$(pwd)/$(ZIP_NAME)"; \
	cd /tmp/kilo/bigmelight-release && zip -qr "$$OUT" "$(PLUGIN_DIR)"
	@rm -rf /tmp/kilo/bigmelight-release
	@echo "built $(ZIP_NAME)"


clean:
	@rm -f "$(ZIP_NAME)"
