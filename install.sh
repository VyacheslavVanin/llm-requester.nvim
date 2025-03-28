#!/bin/bash

# Define source and destination directories
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST_DIR="$HOME/.config/nvim/lua"

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Copy the entire lua directory to the Neovim configuration directory
cp -r "$SOURCE_DIR/lua/"* "$DEST_DIR/"

echo "llm-requester plugin installed successfully."
