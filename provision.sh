#!/bin/bash
set -e

# 1. Create user 'forgeuser' and set permissions
if ! id "forgeuser" &>/dev/null; then
    useradd -m forgeuser
fi
chown -R forgeuser:forgeuser /workspace

# 2. Install system dependencies
apt update
apt install -y python3 python3-pip git-lfs wget curl

# Create 'python' alias if missing
if ! command -v python &> /dev/null; then
    ln -s /usr/bin/python3 /usr/bin/python
fi

# 3. Switch to 'forgeuser' for environment setup
sudo -u forgeuser bash <<'EOF'

cd /workspace

# 4. Clone WebUI Forge repo
if [ ! -d "stable-diffusion-webui-forge" ]; then
    git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git
fi

cd stable-diffusion-webui-forge

# 5. Create and activate virtual environment
python -m venv venv
source venv/bin/activate

# 6. Upgrade pip and install dependencies inside venv
pip install --upgrade pip
pip install -r requirements.txt || true
pip install joblib matplotlib protobuf==4.25.3 numpy==1.26.4

# 7. Download models
mkdir -p models/Stable-diffusion
mkdir -p models/Lora

# 🎨 DreamShaper v7
wget -O models/Stable-diffusion/DreamShaper_v7.safetensors \
  "https://huggingface.co/digiplay/DreamShaper_7/resolve/main/dreamshaper_7.safetensors"

# 👁️ RealisticVision v5.1
wget -O models/Stable-diffusion/RealisticVision_v5.1.safetensors \
  "https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE/resolve/main/Realistic_Vision_V5.1.safetensors"

# 🧠 Josef Koudelka Style LoRA
wget -O models/Lora/Josef_Koudelka_Style_SDXL.safetensors \
  "https://huggingface.co/TheLastBen/Josef_Koudelka_Style_SDXL/resolve/main/koud.safetensors"

# 8. Export runtime configs
export MPLCONFIGDIR=/tmp
export GRADIO_SERVER_PORT=7860

# 9. Launch Forge
nohup python launch.py --xformers --api --share --port 7860 > /workspace/server.log 2>&1 &

# 10. Wait for Gradio public URL
while ! grep -q 'Running on public URL:' /workspace/server.log; do
    sleep 2
done

# 11. Extract and save the share URL
SHARE_URL=$(grep "Running on public URL:" /workspace/server.log | awk '{ print $NF }')
echo "$SHARE_URL" > /workspace/share_url.txt

# 12. Notify n8n
curl -G "http://n8n.ifeatuo.com/webhook-test/imagehooks" \
     --data-urlencode "share_url=$SHARE_URL"

# 13. Notify n8n
curl -G "http://n8n.ifeatuo.com/webhook/imagehooks" \
     --data-urlencode "share_url=$SHARE_URL"
     
EOF
