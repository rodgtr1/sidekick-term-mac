#!/bin/bash

# Install Sidekick.app to Applications

set -e

APP_NAME="Sidekick.app"
BUILD_DIR="build"

if [ ! -d "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "❌ ${APP_NAME} not found. Run ./build-app.sh first."
    exit 1
fi

echo "🚀 Installing Sidekick to Applications..."

# Check if Sidekick is running
if pgrep -x "Sidekick" > /dev/null; then
    echo "⚠️  Sidekick is currently running. Please quit it first."
    read -p "   Kill Sidekick now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        killall Sidekick 2>/dev/null || true
        sleep 1
    else
        echo "❌ Installation cancelled. Please quit Sidekick and try again."
        exit 1
    fi
fi

# Remove existing installation if present
if [ -d "/Applications/${APP_NAME}" ]; then
    echo "📦 Removing existing Sidekick installation..."
    sudo rm -rf "/Applications/${APP_NAME}"
fi

# Copy to Applications
sudo cp -r "${BUILD_DIR}/${APP_NAME}" /Applications/

echo "✅ Sidekick installed to /Applications/"

# Optionally install CLI tools
read -p "📦 Install CLI tools to /usr/local/bin? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/sidekick-ctl" /usr/local/bin/sidekick-ctl
    echo "✅ CLI tools installed"
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "To run:"
echo "  - Launch from Applications folder"
echo "  - Or: open /Applications/${APP_NAME}"
echo "  - CLI: sidekick-ctl ping"