#!/bin/bash

set -e
exec > >(tee -a /workspace/provisioning.log) 2>&1

# ────── Step 0: Ensure we're running as user ──────
if [ "$(whoami)" != "user" ]; then
  echo "[ERROR] Must be run as 'user'" >&2
  exit 1
fi
if [ "$(whoami)" = "root" ]; then
  echo "[ERROR] Do not run pip installs as root. Use su - user." >&2
  exit 1
fi
# ────── Step 1: Environment Setup ──────
export COMFYUI_PORT=7801
export NGROK_TOKEN="301FQa9CBoZxUbFgmaFoYjQ31iO_62sr8sfM9oYMCaWLMyzdm"
export WAN_DIR="/workspace/ComfyUI/models"
export WORKFLOW_DIR="/workspace/ComfyUI/input"
export COMFYUI_DIR="/workspace/ComfyUI"
export GRADIO_LOG="/workspace/logs/gradio_output.log"
export NGROK_LOG="/workspace/logs/ngrok_output.log"

su - user << 'EOF'
export PATH="\$HOME/.local/bin:\$PATH"
pip3 install --user torch torchvision torchaudio
EOF

su - user << 'EOF'
mkdir -p /workspace/{logs,.local/bin}

# ────── Step 2: Git & Python Setup ──────
cd /workspace
mv -f ComfyUI ComfyUI2
if [ ! -d "$COMFYUI_DIR" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
fi

pip3 install --user -r "$COMFYUI_DIR/requirements.txt"
pip3 install --user safetensors einops tqdm gradio

chown -R user:user "$COMFYUI_DIR"
cp -R ComfyUI2 ComfyUI
rm -rf ComfyUI2

# ────── Step 3: Launch ComfyUI ──────

nohup python3 "$COMFYUI_DIR/main.py" --port "$COMFYUI_PORT" > /workspace/logs/comfyui.log 2>&1 &
sleep 6

# ────── Step 4: Download WAN2.1 Models ──────
mkdir -p "$WAN_DIR"/{clip_vision,vae,diffusion_models,unet,clip}
cd "$WAN_DIR"

download() { wget -nv -O "$2" "$1"; }

download "https://huggingface.co/Comfy-Org/...clip_vision_h.safetensors" "clip_vision/clip_vision_h.safetensors"
download "https://huggingface.co/Comfy-Org/...wan_2.1_vae.safetensors" "vae/wan_2.1_vae.safetensors"
download "https://huggingface.co/Comfy-Org/...wan2.1_i2v_720p_14B_fp16.safetensors" "diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
download "https://huggingface.co/Comfy-Org/...wan2.1_t2v_1.3B_fp16.safetensors" "unet/wan2.1_t2v_1.3B_fp16.safetensors"
download "https://huggingface.co/Comfy-Org/...wan2.1_t2v_14B_fp16.safetensors" "unet/wan2.1_t2v_14B_fp16.safetensors"
download "https://huggingface.co/Comfy-Org/...wan2.1_vace_14B_fp16.safetensors" "vae/wan2.1_vace_14B_fp16.safetensors"
download "https://huggingface.co/Comfy-Org/...umt5_xxl_fp8_e4m3fn_scaled.safetensors" "clip/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ────── Step 5: Download Workflows ──────
mkdir -p "$WORKFLOW_DIR"
cd "$WORKFLOW_DIR"

download "https://huggingface.co/Comfy-Org/...text_to_video_wan.json" "text_to_video_wan.json"
download "https://huggingface.co/Comfy-Org/...image_to_video_wan_720p_example.json" "image_to_video_wan_720p_example.json"
download "https://huggingface.co/Comfy-Org/...image_to_video_wan_480p_example.json" "image_to_video_wan_480p_example.json"
EOF
# ────── Step 6: Gradio Tunnel ──────
cat << 'EOF' > "$COMFYUI_DIR/launch_gradio.py"
import gradio as gr

def inference_fn(x): return f"Echo: {x}"
gr.Interface(fn=inference_fn, inputs="text", outputs="text").launch(
    server_name="0.0.0.0", server_port=$COMFYUI_PORT, share=True
)
EOF
=====
nohup python3 "$COMFYUI_DIR/launch_gradio.py" > "$GRADIO_LOG" 2>&1 &
sleep 10
GRADIO_URL=$(grep -o 'https://.*\.gradio\.live' "$GRADIO_LOG" | head -n 1)

# ────── Step 7: Ngrok Tunnel ──────
wget -qO /tmp/ngrok.tgz https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar -xzf /tmp/ngrok.tgz -C /workspace/.local/bin/
chmod +x /workspace/.local/bin/ngrok
export PATH="/workspace/.local/bin:$PATH"

ngrok authtoken "$NGROK_TOKEN"
nohup ngrok http "$COMFYUI_PORT" > "$NGROK_LOG" 2>&1 &
sleep 6
NGROK_URL=$(grep -o 'https://[^ ]*\.ngrok-free.app' "$NGROK_LOG" | head -n 1)

# ────── Step 8: Webhook Notification ──────
TUNNEL_URL="${GRADIO_URL:-$NGROK_URL}"
echo "[INFO] Tunnel URL: $TUNNEL_URL" | tee -a /workspace/provisioning.log

if [[ -n "$TUNNEL_URL" ]]; then
  curl -X POST -H "Content-Type: application/json" \
       -d "{\"url\": \"$TUNNEL_URL\"}" https://n8n.ifeatuo.com/videohooks \
       >> /workspace/provisioning.log 2>&1
fi

# ────── Step 9: Final Ownership ──────
chown -R user:user /workspace
