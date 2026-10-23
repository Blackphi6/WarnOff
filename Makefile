SWIFTC  := xcrun swiftc
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)
APPNAME := WarnOff
BIN     := WarnOff
BUNDLE  := local.warnoff
DIST    := dist/$(APPNAME).app
MACOS   := $(DIST)/Contents/MacOS
RES     := $(DIST)/Contents/Resources
SRC     := Sources/main.swift
ICNS    := Assets/AppIcon.icns
LOCALES := Resources/en.lproj/Localizable.strings \
           Resources/ja.lproj/Localizable.strings \
           Resources/zh-Hans.lproj/Localizable.strings \
           Resources/zh-Hant.lproj/Localizable.strings
FRAMEWORKS := -framework SwiftUI -framework AppKit -framework CoreServices -framework ServiceManagement

.PHONY: all app test install clean run icons release-zip

all: app test

icons: $(ICNS)

$(ICNS): scripts/render-icons.swift scripts/make-icons.sh
	bash scripts/make-icons.sh

app: $(DIST)

$(DIST): $(SRC) Info.plist $(ICNS) $(LOCALES)
	rm -rf "$(DIST)"
	mkdir -p "$(MACOS)" "$(RES)"
	$(SWIFTC) -parse-as-library -sdk "$(SDK)" -target arm64-apple-macosx14.0 -O \
		$(FRAMEWORKS) -o "$(MACOS)/$(BIN)-arm64" $(SRC)
	$(SWIFTC) -parse-as-library -sdk "$(SDK)" -target x86_64-apple-macosx14.0 -O \
		$(FRAMEWORKS) -o "$(MACOS)/$(BIN)-x86_64" $(SRC)
	lipo -create -output "$(MACOS)/$(BIN)" "$(MACOS)/$(BIN)-arm64" "$(MACOS)/$(BIN)-x86_64"
	rm -f "$(MACOS)/$(BIN)-arm64" "$(MACOS)/$(BIN)-x86_64"
	cp Info.plist "$(DIST)/Contents/Info.plist"
	cp "$(ICNS)" "$(RES)/AppIcon.icns"
	cp -R Resources/en.lproj Resources/ja.lproj Resources/zh-Hans.lproj Resources/zh-Hant.lproj "$(RES)/"
	printf 'APPL????' > "$(DIST)/Contents/PkgInfo"
	codesign --force --sign - --identifier "$(BUNDLE)" "$(DIST)"

test: app
	bash scripts/selfcheck.sh

install: app
	killall WarnOff 2>/dev/null || true
	rsync -a --delete "$(DIST)" /Applications/
	xattr -dr com.apple.quarantine "/Applications/$(APPNAME).app" 2>/dev/null || true
	open "/Applications/$(APPNAME).app"

run: app
	open "$(DIST)"

release-zip: app
	mkdir -p dist
	rm -f "dist/$(APPNAME)-macOS.zip"
	ditto -c -k --sequesterRsrc --keepParent "$(DIST)" "dist/$(APPNAME)-macOS.zip"
	@ls -lh "dist/$(APPNAME)-macOS.zip"

clean:
	rm -rf dist
