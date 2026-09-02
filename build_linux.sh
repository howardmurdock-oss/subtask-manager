#!/usr/bin/env bash
# ==============================================================================
# Linux / Steam Deck Native Build & Packaging Script for SubTask Manager
# ==============================================================================
set -e

echo "==> Preparing SubTask Manager Linux Build..."

# Check required build dependencies
command -v flutter >/dev/null 2>&1 || { echo "Error: flutter CLI is required but not installed." >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "Warning: clang not found. Please ensure clang, cmake, ninja, and libgtk-3-dev are installed." >&2; }

echo "==> Running Flutter pub get..."
flutter pub get

echo "==> Running test suite..."
flutter test

echo "==> Compiling Flutter Linux Release Bundle..."
flutter build linux --release

BUILD_OUTPUT="build/linux/x64/release/bundle"
RELEASE_DIR="Releases/Linux"
ARCHIVE_NAME="SubTaskManager-Linux-x64.tar.gz"

if [ -d "$BUILD_OUTPUT" ]; then
    echo "==> Packaging Linux Release bundle into $RELEASE_DIR/$ARCHIVE_NAME..."
    mkdir -p "$RELEASE_DIR"
    tar -czf "$RELEASE_DIR/$ARCHIVE_NAME" -C "$BUILD_OUTPUT" .
    echo "==> Successfully created $RELEASE_DIR/$ARCHIVE_NAME!"
    echo "    To run on Linux/Steam Deck: extract the archive and execute ./orders_app"
else
    echo "Error: Build output directory not found at $BUILD_OUTPUT" >&2
    exit 1
fi
