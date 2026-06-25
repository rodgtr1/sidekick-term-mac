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

# Create sidekick-agent-status CLI tool in bundle
echo "📋 Adding sidekick-agent-status CLI..."
cp ".build/release/sidekick-agent-status" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-agent-status"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-agent-status"

# Create sidekick-hook CLI tool in bundle (PreToolUse edit review)
echo "📋 Adding sidekick-hook CLI..."
cp ".build/release/sidekick-hook" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-hook"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-hook"

# Create sidekick-mcp MCP server in bundle (Model Context Protocol)
echo "📋 Adding sidekick-mcp MCP server..."
cp ".build/release/sidekick-mcp" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-mcp"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-mcp"

# Create sidekick-telemetry helper in bundle (Stop-hook token/cost reporter)
echo "📋 Adding sidekick-telemetry helper..."
cp ".build/release/sidekick-telemetry" "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-telemetry"
chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/sidekick-telemetry"

# Zip for handing to another Mac. scp/USB transfers skip the quarantine
# flag entirely; browser/AirDrop transfers need right-click -> Open (or
# System Settings -> Privacy & Security -> Open Anyway) on first launch.
echo "📦 Creating distribution zip..."
ditto -c -k --keepParent "${BUILD_DIR}/${BUNDLE_NAME}" "${BUILD_DIR}/Sidekick.zip"

echo "✅ App bundle created at: ${BUILD_DIR}/${BUNDLE_NAME}"
echo "✅ Distribution zip at:   ${BUILD_DIR}/Sidekick.zip"
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
echo "   ln -sf /Applications/${BUNDLE_NAME}/Contents/MacOS/sidekick-agent-status /usr/local/bin/sidekick-agent-status"
echo ""
echo "🔌 To register the MCP server with Claude Code:"
echo "   claude mcp add --scope user sidekick /Applications/${BUNDLE_NAME}/Contents/MacOS/sidekick-mcp"
