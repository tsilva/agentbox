#!/usr/bin/env bash
set -euo pipefail

# claudebox one-liner installer
# Usage: curl -fsSL https://raw.githubusercontent.com/tsilva/claudebox/main/install.sh | bash

REPO_URL="https://github.com/tsilva/claudebox.git"
INSTALL_DIR="${HOME}/.claudebox/repo"

echo "Installing claudebox..."

# Clone or update repo
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "Cloning repository..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# Run the installer
cd "$INSTALL_DIR"
./claudebox-dev.sh install

echo ""
echo "Installation complete!"
echo "Run 'source ~/.zshrc' (or ~/.bashrc), then:"
echo "  claudebox login    # authenticate once"
echo "  claudebox          # start coding"
