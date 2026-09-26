APP = build/Build/Products/Release/Streamer.app

# Optional, untracked: sign every build with one certificate from your keychain, for example
#   SIGN = 0123456789ABCDEF0123456789ABCDEF01234567   # the hash `security find-identity -v -p codesigning` prints
#   TEAM = ABCDE12345                                  # the team id in brackets in the same line
# Left unset, builds are ad-hoc. See blether's Makefile for why it is the hash and not the name.
-include local.mk
ifdef SIGN
SIGNING = CODE_SIGN_IDENTITY="$(SIGN)" CODE_SIGN_STYLE=Manual
endif
ifdef TEAM
SIGNING += DEVELOPMENT_TEAM=$(TEAM)
endif

.PHONY: build generate run install test clean icon

build: Streamer.xcodeproj
	xcodebuild -project Streamer.xcodeproj -scheme Streamer -configuration Release -derivedDataPath build build $(SIGNING)

SOURCES = $(shell find Sources Tests -type f)

generate Streamer.xcodeproj: project.yml $(SOURCES)
	xcodegen generate

run: build
	open $(APP)

# A copy in /Applications that keeps its Music permission: macOS ties the permission to this exact
# build, so it only asks again after the next install.
install: build
	-pkill -x Streamer
	rm -rf /Applications/Streamer.app
	ditto $(APP) /Applications/Streamer.app
	open /Applications/Streamer.app

test: Streamer.xcodeproj
	xcodebuild -project Streamer.xcodeproj -scheme Streamer -derivedDataPath build test CODE_SIGNING_ALLOWED=NO

clean:
	rm -rf build

# Regenerates the app icon and the README image from icon-source.png. Needs ImageMagick; not part of
# the build. The artwork sits on a dark rounded square matching Apple's grid (824 inside 1024, corner
# about 185), so macOS shows it as it is instead of framing it in grey.
ICONSET = Sources/Streamer/Assets.xcassets/AppIcon.appiconset
icon:
	mkdir -p build/icon docs
	magick -size 824x824 xc:none -fill white -draw "roundrectangle 0,0,823,823,185,185" build/icon/mask.png
	magick -size 824x824 gradient:'#232a66'-'#0b0d2a' build/icon/mask.png -alpha off -compose CopyOpacity -composite build/icon/plate.png
	magick -size 1024x1024 xc:none build/icon/plate.png -geometry +100+100 -composite \( icon-source.png -resize 690x690 \) -gravity center -geometry +0+8 -composite build/icon/icon.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size build/icon/icon.png --out $(ICONSET)/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) build/icon/icon.png --out $(ICONSET)/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	sips -z 256 256 build/icon/icon.png --out docs/icon.png >/dev/null
