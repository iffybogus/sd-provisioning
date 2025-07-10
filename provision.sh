#!/bin/bash

# Exit on any error
set -e

# Create user 'forgeuser' with no password and no prompt
useradd -m forgeuser || true

# Give 'forgeuser' sudo privileges
if ! grep -q '^forgeuser' /etc/sudoers; then
  echo 'forgeuser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
fi

# Set permissions for workspace
mkdir -p /workspace
chown -R forgeuser:forgeuser /workspace

# Switch to forgeuser for the rest of the setup
sudo -u forgeuser bash << 'EOF'

cd /workspace

# Clone the Stable Diffusion WebUI Forge repo
if [ ! -d "/workspace/stable-diffusion-webui-forge" ]; then
  git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git /workspace/stable-diffusion-webui-forge
fi

cd /workspace/stable-diffusion-webui-forge

# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install required packages
pip install -r requirements.txt || true
pip install -r requirements_extensions.txt || true

# Install missing system dependencies
pip install joblib protobuf==3.20.0 numpy==1.24.4

# Download models
mkdir -p /workspace/stable-diffusion-webui-forge/models/Stable-diffusion

wget -O /workspace/stable-diffusion-webui-forge/models/Stable-diffusion/DreamShaper_v7.safetensors \
  https://civitai.com/api/download/models/128713

wget -O /workspace/stable-diffusion-webui-forge/models/Stable-diffusion/RealisticVision_v5.1.safetensors \
  "https://civitai.com/api/download/models/501240?token=4962ef56501271d752e35f374e076419&type=Model&format=SafeTensors&size=pruned&fp=fp16"

# Make sure the script is executable
chmod +x launch.py

# Start the server and extract the share link to a file
nohup python launch.py --xformers --api --share --port 7860 \
  | tee /workspace/server.log \
  | grep -oP 'https://[^"]+' > /workspace/share_url.txt &

# After share URL is detected
SHARE_URL=$(grep -oP 'https://[^\s]+' /workspace/share_url.txt | head -n 1)

# Send to n8n webhook
curl -X POST http://n8n.ifeatuo.com/webhook/9b784c89-924a-40b0-a7b9-94b362020645 \
     -H "Content-Type: application/json" \
     -d "{\"share_url\": \"$SHARE_URL\"}"

EOF
