#!/usr/bin/env bash
cargo ndk --platform 26 --target arm64-v8a build --release --features flutter,hwcodec
