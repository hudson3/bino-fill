MODEL ?= decider-4b
APP_HOME := $(HOME)/Library/Application Support/Bino
PREFIX ?= $(HOME)/.local/bin
PRACTICE_HOME := $(CURDIR)/.practice-home
APP ?= /Applications/Bino.app
# "-" signs for this Mac only. A developer identity keeps macOS permissions across rebuilds.
SIGN_ID ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}'),-)

.PHONY: setup build bundle app install test practice practice-vault clean

# One-time: Python environment for the decision model, and tell bino where it lives.
setup:
	test -d .venv || python3 -m venv .venv
	.venv/bin/pip install -q --upgrade pip
	CMAKE_ARGS="-DGGML_METAL=on" .venv/bin/pip install -q -r sidecar/requirements.txt
	mkdir -p "$(APP_HOME)" && chmod 700 "$(APP_HOME)"
	printf '{"python": "%s", "server": "%s", "model": "%s"}\n' \
		"$(CURDIR)/.venv/bin/python" "$(CURDIR)/sidecar/server.py" "$(MODEL)" > "$(APP_HOME)/config.json"
	@echo "Decision model set to $(MODEL)."

build:
	swift build -c release
	@# The commit this build came from, read by `bino update` and the sidebar's update check.
	@printf '%s%s\n' "$$(git rev-parse HEAD)" "$$(git diff --quiet HEAD -- . ':!README.md' 2>/dev/null || echo -dirty)" > .build/release/bino-commit

# Builds the double-clickable Bino.app (the same program as the `bino` command) in .build/.
bundle: build
	rm -rf .build/Bino.app .build/Bino.iconset
	mkdir -p .build/Bino.app/Contents/MacOS .build/Bino.app/Contents/Resources .build/Bino.iconset
	cp .build/release/bino .build/Bino.app/Contents/MacOS/Bino
	cp packaging/Info.plist .build/Bino.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :BinoCommit string $$(cat .build/release/bino-commit)" -c "Add :BinoRepo string $(CURDIR)" .build/Bino.app/Contents/Info.plist
	.build/release/bino dev make-icon .build/icon.png > /dev/null
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/icon.png --out .build/Bino.iconset/icon_$${s}x$${s}.png > /dev/null; \
		d=$$((s * 2)); sips -z $$d $$d .build/icon.png --out .build/Bino.iconset/icon_$${s}x$${s}@2x.png > /dev/null; \
	done
	iconutil -c icns .build/Bino.iconset -o .build/Bino.app/Contents/Resources/Bino.icns
	codesign --force --sign "$(SIGN_ID)" .build/Bino.app

# Puts Bino.app in Applications. Quit Bino first so the new one starts.
app: bundle
	rm -rf "$(APP)"
	cp -R .build/Bino.app "$(APP)"
	@echo "Installed: $(APP)"

# Puts `bino` on your PATH and Bino.app in Applications.
install: build app
	mkdir -p "$(PREFIX)"
	ln -sf "$(CURDIR)/.build/release/bino" "$(PREFIX)/bino"
	@echo "Installed: $(PREFIX)/bino"
	@# Terminal does not look in ~/.local/bin on this Mac, but it does look in Homebrew's folder.
	@if [ -w /opt/homebrew/bin ]; then ln -sf "$(CURDIR)/.build/release/bino" /opt/homebrew/bin/bino && echo "Installed: /opt/homebrew/bin/bino"; fi
	@case ":$$PATH:" in *":$(PREFIX):"*) ;; *) echo "Add $(PREFIX) to your PATH to run it as just 'bino'." ;; esac

test:
	swift test

# A made-up person in a separate vault, for trying Bino on the practice site.
practice-vault: build
	BINO_HOME="$(PRACTICE_HOME)" .build/release/bino vault seed-test

# Serves the practice airline site at http://localhost:8765/step1.html
practice:
	python3 -m http.server 8765 --bind 127.0.0.1 --directory testsite

clean:
	rm -rf .build

