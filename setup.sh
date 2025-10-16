#!/bin/bash
# Setup script for RDB to ElastiCache migration tool

set -e

echo "======================================"
echo "RDB ElastiCache Migrator Setup"
echo "======================================"
echo

# Check Python version
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is not installed"
    exit 1
fi

PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
echo "Found Python version: $PYTHON_VERSION"

# Create virtual environment
echo "Creating virtual environment..."
python3 -m venv venv

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip

# Install dependencies
echo "Installing dependencies..."
pip install -r requirements.txt

echo
echo "======================================"
echo "Setup complete!"
echo "======================================"
echo
echo "Next steps:"
echo "1. Activate the virtual environment:"
echo "   source venv/bin/activate"
echo
echo "2. Copy and edit the configuration:"
echo "   cp config.example.json config.json"
echo "   # Edit config.json with your settings"
echo
echo "3. Run the migration:"
echo "   python migrate.py --config config.json"
echo
