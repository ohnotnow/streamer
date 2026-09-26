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

.PHONY: build generate run install test clean

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
