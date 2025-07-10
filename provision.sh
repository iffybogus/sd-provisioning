#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Add forgeuser and grant sudo
useradd -m forgeuser
echo "forgeuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up working directory
mkdir -p /workspace
chown forgeuser:forgeuser /workspace

# Switch to forgeuser and run the rest
su - forgeuser <<'EOF'
cd /workspace
git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git
cd stable-diffusion-webui-forge

python3 -m venv venv
. venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt || true  # continue if partial error

# Download models
mkdir -p models/Stable-diffusion
wget -O models/Stable-diffusion/DreamShaper_v7.safetensors https://civitai.com/api/download/models/130072?type=Model&format=SafeTensor
wget -O models/Stable-diffusion/RealisticVision_v5.1.safetensors "https://civitai.com/api/download/models/501240?token=4962ef56501271d752e35f374e076419&type=Model&format=SafeTensors&size=pruned&fp=fp16"

# Launch web UI
# Start the server and extract the share link
python launch.py --xformers --api --share --port 7860 | tee /workspace/server.log | grep -oP 'https://[^\s]+' > /workspace/share_url.txt &
EOF
