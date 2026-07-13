#!/bin/bash

# Install Sidekick.app to Applications, and bring an existing agent-status
# integration along with it. ./build-app.sh && ./install.sh is the whole
# from-source upgrade: no follow-up script to remember.

set -e

APP_NAME="Sidekick.app"
BUILD_DIR="build"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    echo "✅ CLI tools installed"
fi

# Refresh the agent-status integration — the ~/.local/bin helpers, the
# sidekick-panes skill, and the hook entries in ~/.claude/settings.json and
# ~/.codex/config.toml. The installer script does the work (and the opt-in
# detection): if this machine never opted in it changes nothing and just prints
# how to. --binaries-from points it at the app we just installed, so it copies
# those exact binaries instead of kicking off a second release build.
echo ""
echo "🔄 Refreshing agent integration..."
if ! "${REPO_DIR}/scripts/install-agent-status-hooks" \
        --refresh-only \
        --binaries-from "/Applications/${APP_NAME}/Contents/MacOS"; then
    # A refresh failure is not an install failure: the app is in /Applications
    # either way, and it self-heals these same files on launch.
    echo "⚠️  Could not refresh the agent integration. Sidekick is installed; run"
    echo "    scripts/install-agent-status-hooks by hand to see what went wrong."
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "To run:"
echo "  - Launch from Applications folder"
echo "  - Or: open /Applications/${APP_NAME}"
echo "  - CLI: sidekick-ctl ping"
echo "  - Agent hooks: sidekick-agent-status busy"
