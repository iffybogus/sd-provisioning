#!/bin/bash

set -e
set -x
exec > >(tee -a /workspace/provisioning.log) 2>&1

# ────── Step 0: Environment Variables ──────
export SWARMUI_PORT=7801
export COMFYUI_PORT=7802
export GRADIO_PORT=7860
export WAN_PATH="/workspace/SwarmUI/Models/diffusion_models/WAN2.1"
export SESSION_LOG="/workspace/logs/session_response.log"
export GRADIO_ENV="/workspace/.gradio"
export GRADIO_SCRIPT="/workspace/SwarmUI/launch_gradio.py"
export FRPC_PATH="$GRADIO_ENV/frpc/frpc_linux_amd64_v0.3"
export MODEL_USER="user"

mkdir -p "$WAN_PATH" /workspace/logs "$GRADIO_ENV/frpc"

# ────── Step 0.5: System & user setup ──────

if ! id "$MODEL_USER" &>/dev/null; then
  useradd -m "$MODEL_USER"
fi
chown -R "$MODEL_USER:$MODEL_USER" /workspace
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/$MODEL_USER/.bashrc"
echo 'export PYTHONPATH=$HOME/.local/lib/python3.*/site-packages:$PYTHONPATH' >> "/home/$MODEL_USER/.bashrc"

# ────── Step 1: Install system packages ──────
apt update && apt install -y python3 python3-pip git-lfs wget curl git unzip sudo software-properties-common openssh-client nodejs npm jq netcat

if ! command -v python &>/dev/null; then ln -s /usr/bin/python3 /usr/bin/python; fi

# ────── Step 2: Install .NET SDK ──────
wget -nv -O /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --version 8.0.100 --install-dir /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet

# ────── Step 3: Install Python modules ──────
su - "$MODEL_USER" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
pip3 install --user torch einops tqdm gradio safetensors --extra-index-url https://download.pytorch.org/whl/cu118
EOF

# ────── Step 4: Download FRPC binary ──────
FRPC_BIN="/workspace/.gradio/frpc/frpc_linux_amd64_v0.3"
mkdir -p "$(dirname "$FRPC_BIN")"
wget -nv -O "$FRPC_BIN" https://cdn-media.huggingface.co/frpc-gradio-0.3/frpc_linux_amd64 || {
  sleep 2
  wget -nv -O "$FRPC_BIN" https://cdn-media.huggingface.co/frpc-gradio-0.3/frpc_linux_amd64 || {
    echo "[ERROR] FRPC download failed"; exit 1;
  }
}
chmod +x "$FRPC_BIN"

# ────── Step 5: Clone & build SwarmUI ──────
cd /workspace
git clone https://github.com/iffybogus/SwarmUI || echo "[INFO] SwarmUI already present."
cd /workspace/SwarmUI
git config --global --add safe.directory /workspace/SwarmUI
git fetch --all --tags
git checkout 194b0c0f
rm -rf src/bin/* src/obj/*
dotnet restore src/SwarmUI.csproj
dotnet publish src/SwarmUI.csproj -c Release -o src/bin/live_release/

# ────── Step 6: Download WAN2.1 models ──────
cd /workspace/ComfyUI/models/
wget -nv -O clip_vision/clip_vision_h.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
wget -nv -O vae/wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
wget -nv -O diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
wget -nv -O unet/wan2.1_t2v_1.3B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors"
wget -nv -O unet/wan2.1_t2v_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors"
wget -nv -O vae/wan2.1_vace_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors"
wget -nv -O clip/umt5_xxl_fp8_e4m3fn_scaled.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ────── Step 8: Download WAN2.1 workflows ──────
su - "$MODEL_USER" <<'EOF'
cd /workspace/ComfyUI/input/
wget -nv -O text_to_video_wan.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json"
wget -nv -O image_to_video_wan_720p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json"
wget -nv -O image_to_video_wan_480p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json"
EOF

# ────── Step 9: Install ComfyUI ──────
COMFYUI_DIR="/workspace/ComfyUI"
if [ ! -d "$COMFYUI_DIR" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
fi
pip3 install -r "$COMFYUI_DIR/requirements.txt"
pip3 install safetensors einops tqdm
chown -R "$MODEL_USER:$MODEL_USER" "$COMFYUI_DIR"
chmod -R u+rwX "$COMFYUI_DIR"

# ────── Step 10: Launch SwarmUI backend (port 5000) ──────
nohup su - "$MODEL_USER" -c '
cd /workspace/SwarmUI
export ASPNETCORE_URLS=http://0.0.0.0:5000
./src/bin/live_release/SwarmUI --launch_mode none --port 5000
' >> /workspace/server_output.log 2>&1 &
sleep 5
nc -z localhost 5000 && echo "[READY] SwarmUI API on port 5000"

# ────── Step 11: Launch ComfyUI on port 7802 ──────
nohup python3 /workspace/ComfyUI/main.py --port 7802 >> /workspace/comfy_output.log 2>&1 &
sleep 6
nc -z localhost 7802 && echo "[READY] ComfyUI is running"

# ────── Step 12: Launch FRPC tunnel to expose ComfyUI ──────
cat <<EOF > "$GRADIO_ENV/frpc/frpc_comfy.ini"
[common]

[comfyui]
type = http
local_port = $COMFYUI_PORT
subdomain = comfyui-$(hostname | tr -dc 'a-zA-Z0-9')
EOF

# ────── Step 13: Launch Ngrok tunnel to expose ComfyUI ──────
# === CONFIG ===
AUTH_TOKEN="301FQa9CBoZxUbFgmaFoYjQ31iO_62sr8sfM9oYMCaWLMyzdm"
PORT = $COMFYUI_PORT
LOG_FILE="/workspace/session_response.log"

# === INSTALL NGROK v3 ===
wget -qO ngrok.tgz https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar -xzf ngrok.tgz
mv ngrok /usr/local/bin/ngrok

# === AUTHENTICATE ===
ngrok authtoken "$AUTH_TOKEN"

# === LAUNCH TUNNEL ===
(ngrok http $PORT > "$LOG_FILE" 2>&1) &

# Wait a moment for tunnel to establish
sleep 3

# === EXTRACT PUBLIC LINK ===
export PUBLIC_URL=$(grep -o 'https://[^ ]*\.ngrok-free.app' "$LOG_FILE" | head -n 1)

echo "🌐 Public Link: $PUBLIC_URL"

if [[ -n "$PUBLIC_URL" ]]; then
  echo "[INFO] Sending webhook notification..." | tee -a /workspace/provision.log
  curl -G https://n8n.ifeatuo.com/videohooks \
       -H "Content-Type: application/json" \
       --data-urlencode "share_url=$PUBLIC_URL"
fi
