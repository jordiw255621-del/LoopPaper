#!/bin/zsh
# Builds LoopPaper.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/LoopPaper.app
rm -rf build && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library \
  Sources/*.swift -o $APP/Contents/MacOS/LoopPaper
cp Info.plist $APP/Contents/
codesign --force --sign - $APP
mkdir -p ~/Applications
rm -rf ~/Applications/LoopPaper.app
cp -R $APP ~/Applications/
echo "Installed ~/Applications/LoopPaper.app"
