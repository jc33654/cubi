.PHONY: build release test clean bundle icon install run cert hook-test

APP_DEST := $(HOME)/Applications/Cubi.app
IDENTITY ?= cubi-dev

build:
	swift build

release:
	swift build -c release

# Command Line Tools ship swift-testing outside the default search paths; Xcode does not need these.
CLT_FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F$(CLT_FW) -Xlinker -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB)

test:
	swift test $(TEST_FLAGS)

clean:
	rm -rf .build build

# Checks for the self-signed Code Signing certificate used by scripts/bundle.sh.
cert:
	@if security find-identity -p codesigning | grep -q '"$(IDENTITY)"'; then \
	  echo "identity '$(IDENTITY)' found"; \
	else \
	  echo "identity '$(IDENTITY)' not found. Create it once:"; \
	  echo "  Keychain Access → menu Keychain Access → Certificate Assistant → Create a Certificate…"; \
	  echo "  Name: $(IDENTITY)   Identity Type: Self Signed Root   Certificate Type: Code Signing"; \
	  exit 1; \
	fi

# Render the app icon from the app itself (no image assets in the repo).
icon: release
	mkdir -p build
	.build/release/cubi --render-icon build/cubi-icon.png
	scripts/make-icns.sh build/cubi-icon.png build/cubi.icns

bundle:
	CUBI_SIGN_IDENTITY=$(IDENTITY) scripts/bundle.sh

install: bundle
	mkdir -p $(HOME)/Applications
	rsync -a --delete build/Cubi.app/ "$(APP_DEST)/"
	@echo "installed $(APP_DEST)"

run: install
	-pkill -x cubi
	open "$(APP_DEST)"

# Feed a fake payload through the relay with the app absent: must exit 0 and print nothing.
hook-test: release
	echo '{"hook_event_name":"SessionStart","session_id":"test"}' | .build/release/cubi-hook --agent claude-code --event SessionStart; echo "exit=$$?"
