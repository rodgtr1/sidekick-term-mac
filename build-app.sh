#!/bin/bash

# Build and package Sidekick.app for macOS

set -e

echo "🔨 Building Sidekick..."

# Build the Swift package
swift build --configuration release

# Create app bundle structure
APP_NAME="Sidekick"
BUNDLE_NAME="${APP_NAME}.app"
BUILD_DIR="build"

echo "📦 Creating app bundle structure..."

# Clean and create bundle directory
rm -rf "${BUILD_DIR}/${BUNDLE_NAME}"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources"

# Copy executable
echo "📋 Copying executable..."
cp ".build/release/${APP_NAME}" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
echo "📋 Copying Info.plist..."
cp "Info.plist" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Info.plist"

# Create a simple icon (text-based for now)
echo "🎨 Creating app icon..."
# Create a simple 512x512 icon using iconutil (if available)
if command -v sips >/dev/null 2>&1; then
    # Create a simple colored square as placeholder
    sips -c 512 512 --setProperty format png -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/AppIcon.png" 2>/dev/null || {
        echo "ℹ️  Using default icon (sips failed)"
    }
fi

# Set executable permissions
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"

# Create sidekick-ctl CLI tool in bundle
echo "📋 Adding sidekick-ctl CLI..."
cp ".build/release/sidekick-ctl" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-ctl"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-ctl"

echo "✅ App bundle created at: ${BUILD_DIR}/${BUNDLE_NAME}"
echo ""
echo "📱 To install:"
echo "   cp -r ${BUILD_DIR}/${BUNDLE_NAME} /Applications/"
echo ""
echo "🚀 To run:"
echo "   open ${BUILD_DIR}/${BUNDLE_NAME}"
echo "   # or"
echo "   /Applications/${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"
echo ""
echo "🛠️  To add CLI tools to PATH:"
echo "   ln -sf /Applications/${BUNDLE_NAME}/Contents/MacOS/sidekick-ctl /usr/local/bin/sidekick-ctl"