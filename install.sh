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

# Remove existing installation if present (sudo only when a previous
# install is root-owned).
if [ -d "/Applications/${APP_NAME}" ]; then
    echo "📦 Removing existing Sidekick installation..."
    rm -rf "/Applications/${APP_NAME}" 2>/dev/null || sudo rm -rf "/Applications/${APP_NAME}"
fi

# Copy to Applications
cp -r "${BUILD_DIR}/${APP_NAME}" /Applications/ 2>/dev/null || sudo cp -r "${BUILD_DIR}/${APP_NAME}" /Applications/

echo "✅ Sidekick installed to /Applications/"

# Optionally install CLI tools
read -p "📦 Install CLI tools to /usr/local/bin? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ ! -d /usr/local/bin ]; then
        echo "📁 Creating /usr/local/bin..."
        sudo mkdir -p /usr/local/bin
    fi
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/sidekick-ctl" /usr/local/bin/sidekick-ctl
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/sidekick-agent-status" /usr/local/bin/sidekick-agent-status
    sudo ln -sf "/Applications/${APP_NAME}/Contents/MacOS/sidekick-hook" /usr/local/bin/sidekick-hook
    echo "✅ CLI tools installed"
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "To run:"
echo "  - Launch from Applications folder"
echo "  - Or: open /Applications/${APP_NAME}"
echo "  - CLI: sidekick-ctl ping"
echo "  - Agent hooks: sidekick-agent-status busy"
