#!/bin/bash

set -e

# 1. Create user 'forgeuser' and set permissions
if ! id "forgeuser" &>/dev/null; then
    useradd -m forgeuser
fi
chown -R forgeuser:forgeuser /workspace

# 2. Switch to 'forgeuser'
sudo -u forgeuser bash <<'EOF'

cd /workspace

# 3. Clone Stable Diffusion WebUI Forge repo (if not already)
if [ ! -d "stable-diffusion-webui-forge" ]; then
    git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git
fi

cd stable-diffusion-webui-forge

# 4. Create and activate Python virtual environment
python3 -m venv venv
source venv/bin/activate

# 5. Upgrade pip and install required packages
pip install --upgrade pip
pip install -r requirements.txt || true  # Some will be pre-installed

# 6. Install missing packages (due to version conflicts or errors)
pip install joblib matplotlib protobuf==4.25.3 numpy==1.26.4

# 7. Download DreamShaper and RealisticVision models
mkdir -p models/Stable-diffusion

# DreamShaper v7
wget -O models/Stable-diffusion/DreamShaper_v7.safetensors \
  "https://civitai.com/api/download/models/128713?token=4962ef56501271d752e35f374e076419&type=Model&format=SafeTensors&size=pruned&fp=fp16"

# RealisticVision v5.1
wget -O models/Stable-diffusion/RealisticVision_v5.1.safetensors \
  "https://civitai.com/api/download/models/501240?token=4962ef56501271d752e35f374e076419&type=Model&format=SafeTensors&size=pruned&fp=fp16"

# 8. Export variables to avoid permission warnings
export MPLCONFIGDIR=/tmp
export GRADIO_SERVER_PORT=7860

# 9. Launch WebUI and capture public share URL with awk
nohup python launch.py --xformers --api --share --port 7860 \
  | tee /workspace/server.log \
  | awk '/Running on public URL:/ { print $NF; fflush(); exit }' > /workspace/share_url.txt &

# 10. Wait for share_url.txt to be populated
while [ ! -s /workspace/share_url.txt ]; do
    sleep 2
done

# 11. Read and send to n8n webhook
SHARE_URL=$(cat /workspace/share_url.txt)

curl -X POST http://n8n.ifeatuo.com/webhook/9b784c89-924a-40b0-a7b9-94b362020645 \
     -H "Content-Type: application/json" \
     -d "{\"share_url\": \"$SHARE_URL\"}"

EOF
