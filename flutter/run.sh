#!/usr/bin/env bash

flutter pub get
bash ../.github/scripts/generate-bridge.sh
# call `flutter clean` if cargo build fails
# export LLVM_HOME=/Library/Developer/CommandLineTools/usr/
cargo build --features flutter
flutter run $@
