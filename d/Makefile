ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD_DIR ?= $(ROOT)/build
BINARY ?= $(BUILD_DIR)/google-drive-api-d
DC ?= ldc2
PREFIX ?= $(HOME)/.local

SOURCE := $(ROOT)/commands/google_drive_api.d
METHODS := $(ROOT)/commands/google-drive-v3-methods.tsv
TEST := $(ROOT)/tests/google-drive-api-d.sh

.PHONY: all test install clean

all: $(BINARY)

$(BINARY): $(SOURCE) $(METHODS)
	mkdir -p "$(BUILD_DIR)"
	$(DC) -O -release -J"$(ROOT)/commands" "$(SOURCE)" -of="$@" -L-lcurl

test: $(BINARY)
	sh "$(TEST)" "$(BINARY)"

install: $(BINARY)
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 "$(BINARY)" "$(DESTDIR)$(PREFIX)/bin/google-drive-api-d"

clean:
	rm -f "$(BINARY)"
