#!/bin/bash

# Uninstall current PyTorch
echo "Uninstalling current PyTorch..."
pip uninstall -y torch torchvision torchaudio

# Install PyTorch with CUDA 11.8 support
echo "Installing PyTorch with CUDA 11.8 support..."
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

# Add CUDA environment variables to .bashrc
echo "Adding CUDA environment variables to .bashrc..."
echo '
# CUDA environment variables
export PATH=/usr/local/cuda-11.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64:$LD_LIBRARY_PATH
' >> ~/.bashrc

# Source .bashrc to apply changes
source ~/.bashrc

# Create a Python script to verify the installation
echo "Creating verification script..."
cat << EOF > verify_pytorch.py
import torch

print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")
print(f"CUDA version: {torch.version.cuda}")
print(f"GPU device name: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A'}")
EOF

# Run the verification script
echo "Running verification script..."
python verify_pytorch.py

echo "Setup complete. Please restart your terminal or run 'source ~/.bashrc' for the environment variable changes to take effect."
