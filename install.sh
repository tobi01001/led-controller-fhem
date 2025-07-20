#!/bin/bash
# Installation script for LEDController FHEM module

set -e

FHEM_DIR="/opt/fhem"
MODULE_NAME="98_LEDController.pm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "FHEM LED Controller Module Installation"
echo "======================================"

# Check if FHEM directory exists
if [ ! -d "$FHEM_DIR" ]; then
    echo "Warning: FHEM directory $FHEM_DIR not found."
    echo "Please specify the correct FHEM installation path:"
    read -p "FHEM directory: " FHEM_DIR
    
    if [ ! -d "$FHEM_DIR" ]; then
        echo "Error: Directory $FHEM_DIR does not exist."
        exit 1
    fi
fi

# Check if FHEM/FHEM directory exists
if [ ! -d "$FHEM_DIR/FHEM" ]; then
    echo "Error: $FHEM_DIR/FHEM directory not found."
    echo "This doesn't appear to be a valid FHEM installation."
    exit 1
fi

# Check if we have write permissions
if [ ! -w "$FHEM_DIR/FHEM" ]; then
    echo "Error: No write permission to $FHEM_DIR/FHEM"
    echo "Please run with sudo or as the FHEM user."
    exit 1
fi

echo "Installing to: $FHEM_DIR/FHEM/$MODULE_NAME"

# Backup existing module if it exists
if [ -f "$FHEM_DIR/FHEM/$MODULE_NAME" ]; then
    echo "Backing up existing module..."
    cp "$FHEM_DIR/FHEM/$MODULE_NAME" "$FHEM_DIR/FHEM/${MODULE_NAME}.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Copy the module
echo "Copying module file..."
cp "$SCRIPT_DIR/FHEM/$MODULE_NAME" "$FHEM_DIR/FHEM/"

# Set proper permissions
chmod 644 "$FHEM_DIR/FHEM/$MODULE_NAME"

echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Restart FHEM or reload the module: reload $MODULE_NAME"
echo "2. Define your LED devices: define myLED LEDController 192.168.1.100:80"
echo "3. See examples/fhem.cfg for configuration examples"
echo ""
echo "Documentation is available in README.md"