#!/usr/bin/env bash

echo $MACOS_CODESIGN_IDENTITY
cd flutter; flutter pub get; cd -
bash .github/scripts/generate-bridge.sh
./build.py --flutter
rm camellia-$VERSION.dmg
# security find-identity -v
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict ./flutter/build/macos/Build/Products/Release/Camellia.app -vvv
create-dmg --icon "Camellia.app" 200 190 --hide-extension "Camellia.app" --window-size 800 400 --app-drop-link 600 185 camellia-$VERSION.dmg ./flutter/build/macos/Build/Products/Release/Camellia.app
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict camellia-$VERSION.dmg -vvv
# notarize the camellia-${{ env.VERSION }}.dmg
rcodesign notary-submit --api-key-path ~/.p12/api-key.json  --staple camellia-$VERSION.dmg
