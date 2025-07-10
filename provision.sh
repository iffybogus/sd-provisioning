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
mkdir -p models/Lora

# 🎨 DreamShaper v7 (SD 1.5 - stylized rendering)
wget -O models/Stable-diffusion/DreamShaper_v7.safetensors \
  "https://huggingface.co/digiplay/DreamShaper_7/resolve/main/dreamshaper_7.safetensors"

# 👁️ RealisticVision v5.1 (SD 1.5 - photorealistic detail)
wget -O models/Stable-diffusion/RealisticVision_v5.1.safetensors \
  "https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE/resolve/main/Realistic_Vision_V5.1.safetensors"

# 🧠 Josef Koudelka Style LoRA (SDXL aesthetic modifier)
wget -O models/Lora/Josef_Koudelka_Style_SDXL.safetensors \
  "https://huggingface.co/TheLastBen/Josef_Koudelka_Style_SDXL/resolve/main/koud.safetensors"

# 8. Export variables to avoid permission warnings
export MPLCONFIGDIR=/tmp
export GRADIO_SERVER_PORT=7860

# 9. Launch WebUI and stream logs
nohup python launch.py --xformers --api --share --port 7860 > /workspace/server.log 2>&1 &

# 10. Wait for the share URL to appear in logs
while ! grep -q 'Running on public URL:' /workspace/server.log; do
    sleep 2
done

# 11. Extract only the Gradio public URL
SHARE_URL=$(grep "Running on public URL:" /workspace/server.log | awk '{ print $NF }')
echo "$SHARE_URL" > /workspace/share_url.txt

# 12. Send to n8n webhook
# curl -X POST http://n8n.ifeatuo.com/webhook/9b784c89-924a-40b0-a7b9-94b362020645 \
curl -X POST https://n8n.ifeatuo.com/webhook-test/9b784c89-924a-40b0-a7b9-94b362020645 \
     -H "Content-Type: application/json" \
     -d "{\"share_url\": \"$SHARE_URL\"}"

EOF
