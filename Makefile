CRYSTAL ?= crystal
CRYSTAL_FLAGS ?=
BUILD_DIR ?= build

space := $(subst ,, )
OUTPUT_DIR := $(or $(BUILD_DIR),build)/examples
MAKE_OUTPUT_DIR := $(subst $(space),\$(space),$(OUTPUT_DIR))

EXAMPLE_SOURCES := $(sort $(wildcard examples/*.cr))
EXAMPLE_NAMES := $(basename $(notdir $(EXAMPLE_SOURCES)))
EXAMPLE_BINARIES := $(addprefix $(MAKE_OUTPUT_DIR)/,$(EXAMPLE_NAMES))
LIBRARY_SOURCES := $(sort $(shell find src -type f -name '*.cr' -print))
TUI_SOURCE := examples/offline_tui/main.cr
TUI_SOURCES := $(sort $(wildcard examples/offline_tui/*.cr))
TUI_BINARY := $(MAKE_OUTPUT_DIR)/offline_tui

.PHONY: help examples clean tui $(addprefix example-,$(EXAMPLE_NAMES))
.DELETE_ON_ERROR:

help:
	@echo "Targets:"
	@echo "  make examples                 Build every top-level examples/*.cr file"
	@echo "  make example-<name>           Build one example, e.g. make example-read_typed_window"
	@echo "  make tui                      Build the optional TUI (requires external CRYSTAL_PATH)"
	@echo "  make clean                    Remove generated binaries and debug sidecars"
	@echo "  make help                     Show this help"
	@echo ""
	@echo "Binaries are written to $(OUTPUT_DIR)/. Configure CRYSTAL, CRYSTAL_FLAGS, or BUILD_DIR as needed."
	@echo "Use a separate BUILD_DIR for each CRYSTAL_FLAGS setting."
	@echo "Example names: $(EXAMPLE_NAMES)"

examples: $(EXAMPLE_BINARIES)

$(addprefix example-,$(EXAMPLE_NAMES)): example-%: $(MAKE_OUTPUT_DIR)/%
	@:

$(MAKE_OUTPUT_DIR)/%: examples/%.cr $(LIBRARY_SOURCES) Makefile
	@mkdir -p -- "$(OUTPUT_DIR)"
	"$(CRYSTAL)" build $(CRYSTAL_FLAGS) "$<" -o "$@"

tui: $(TUI_BINARY)

$(TUI_BINARY): $(TUI_SOURCES) $(LIBRARY_SOURCES) Makefile
	@test -n "$(CRYSTAL_PATH)" || { echo "Set CRYSTAL_PATH to include crystal_tui/src before building the optional TUI." >&2; exit 2; }
	@mkdir -p -- "$(OUTPUT_DIR)"
	CRYSTAL_PATH="$(CRYSTAL_PATH)" "$(CRYSTAL)" build $(CRYSTAL_FLAGS) "$(TUI_SOURCE)" -o "$@"

clean:
	@set -e; \
	for name in $(EXAMPLE_NAMES) offline_tui; do \
	  $(RM) -- "$(OUTPUT_DIR)/$$name" "$(OUTPUT_DIR)/$$name.dwarf"; \
	done
