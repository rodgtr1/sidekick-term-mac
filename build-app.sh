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

# Copy app icon
echo "🎨 Copying app icon..."
if [ -f "Resources/icon.png" ]; then
    # Create iconset from PNG
    ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"

    # Generate different sizes for iconset
    sips -z 16 16 Resources/icon.png --out "${ICONSET_DIR}/icon_16x16.png" 2>/dev/null
    sips -z 32 32 Resources/icon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" 2>/dev/null
    sips -z 32 32 Resources/icon.png --out "${ICONSET_DIR}/icon_32x32.png" 2>/dev/null
    sips -z 64 64 Resources/icon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" 2>/dev/null
    sips -z 128 128 Resources/icon.png --out "${ICONSET_DIR}/icon_128x128.png" 2>/dev/null
    sips -z 256 256 Resources/icon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" 2>/dev/null
    sips -z 256 256 Resources/icon.png --out "${ICONSET_DIR}/icon_256x256.png" 2>/dev/null
    sips -z 512 512 Resources/icon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" 2>/dev/null
    sips -z 512 512 Resources/icon.png --out "${ICONSET_DIR}/icon_512x512.png" 2>/dev/null
    cp Resources/icon.png "${ICONSET_DIR}/icon_512x512@2x.png" 2>/dev/null

    # Convert to icns
    iconutil -c icns "${ICONSET_DIR}" -o "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "✅ Icon created from Resources/icon.png"
else
    echo "⚠️  Warning: Resources/icon.png not found"
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