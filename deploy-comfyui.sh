#!/bin/bash

set -e
exec > >(tee -a /tmp/provisioning.log) 2>&1

# ────── Step 0: Ensure we're running as user ──────
if [ "$(whoami)" != "user" ]; then
  echo "[ERROR] Must be run as 'user'" >&2
  exit 1
fi
if [ "$(whoami)" = "root" ]; then
  echo "[ERROR] Do not run pip installs as root. Use su - user." >&2
  exit 1
fi

sudo bash -c 'source /etc/environment'

# Configurable parameters
SECRET_ID="s3fs/vastai/ComfyUI"
S3FS_CREDS="/root/.passwd-s3fs"
AWS_REGION="us-east-1"

sudo mv /workspace/ComfyUI /tmp/ComfyUI2
sudo apt install -y s3fs
sudo curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo unzip awscliv2.zip
sudo ./aws/install
sudo aws --version

# Fetch and apply secret securely
sudo aws secretsmanager get-secret-value \
  --region "$AWS_DEFAULT_REGION" \
  --secret-id "$SECRET_ID" \
  --query 'SecretString' \
  --output text | jq -r '"\("$AWS_ACCESS_KEY_ID"):\("$AWS_SECRET_ACCESS_KEY")"' | sudo tee "$S3FS_CREDS" > /dev/null

#sudo echo "$(aws secretsmanager get-secret-value --region us-east-1 --secret-id s3fs/vastai/ComfyUI --query 'SecretString' --output text)" > ~/.passwd-s3fs
#sudo chmod 600 ~/.passwd-s3fs
sudo chmod 600 "$S3FS_CREDS"
echo "✅ AWS secret loaded into $S3FS_CREDS"
# Ensure AWS CLI is available
if ! command -v aws &> /dev/null; then
  echo "AWS CLI not found. Please install it before running this script."
  exit 1
fi
sudo mkdir -p /mnt/comfy-cache
sudo s3fs vastai.bucket /mnt/comfy-cache -o passwd_file=/root/.passwd-s3fs -o use_path_request_style -o url=https://s3.us-east-1.amazonaws.com
sudo ln -s /mnt/comfy-cache/workspace /workspace
sudo chown -R user:user /workspace
sudo cp /tmp/provisioning.log /workspace
exec > >(tee -a /workspace/provisioning.log) 2>&1

# ────── Step 1: Environment Setup ──────
export COMFYUI_PORT=7801
export NGROK_TOKEN="301FQa9CBoZxUbFgmaFoYjQ31iO_62sr8sfM9oYMCaWLMyzdm"
export WAN_DIR="/workspace/ComfyUI/models"
export WORKFLOW_DIR="/workspace/ComfyUI/input"
export COMFYUI_DIR="/workspace/ComfyUI"
export GRADIO_LOG="/workspace/logs/gradio_output.log"
export NGROK_LOG="/workspace/logs/ngrok_output.log"
export HOME="/home/user"
export PATH="$HOME/.local/bin:/usr/bin:$PATH"
echo "$PATH" | tee -a /workspace/provision.log

mkdir -p /home/user/.local
chown -R user:user /home/user/.local
HOME=/home/user pip3 install --user torch torchvision torchaudio

mkdir -p /workspace/{logs,.local/bin}

# ────── Step 2: Git & Python Setup ──────
cd /workspace
#mv -f ComfyUI ComfyUI2
if [ ! -d "$COMFYUI_DIR" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
  cd /workspace/ComfyUI/custom_nodes
  git clone https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager
fi
cd /workspace
pip3 install --user -r "$COMFYUI_DIR/requirements.txt"
pip3 install --user safetensors einops tqdm gradio Pillow

sudo chown -R user:user "$COMFYUI_DIR"
sudo cp -R /tmp/ComfyUI2 ComfyUI
sudo rm -rf /tmp/ComfyUI2

# ────── Step 3: Launch ComfyUI ──────

nohup python3 "$COMFYUI_DIR/main.py" --port "$COMFYUI_PORT" > /workspace/logs/comfyui.log 2>&1 &
sleep 6

# ────── Step 4: Download WAN2.1 Models ──────
download_with_retry() {
  local url="$1"
  local output="$2"
  local max_retries=5
  local wait_seconds=30
  local attempt=1

  while [ "$attempt" -le "$max_retries" ]; do
    echo "[INFO] Attempt $attempt: Downloading $output" | tee -a /workspace/provision.log
    wget -nv -O "$output" "$url"
    if [ $? -eq 0 ]; then
      echo "[SUCCESS] Downloaded $output" | tee -a /workspace/provision.log
      return 0
    else
      echo "[WARN] Failed to download $output — retrying in $wait_seconds seconds..." | tee -a /workspace/provision.log
      sleep "$wait_seconds"
      attempt=$((attempt+1))
    fi
  done

  echo "[ERROR] Giving up on $output after $max_retries attempts." | tee -a /workspace/provision.log
  return 1
}

mkdir -p "$WAN_DIR"/{clip_vision,vae,diffusion_models,unet,clip}
cd "$WAN_DIR"

#download() { wget -nv -O "$2" "$1"; }

download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "clip_vision/clip_vision_h.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "vae/wan_2.1_vae.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors" "diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors" "unet/wan2.1_t2v_1.3B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors" "unet/wan2.1_t2v_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "vae/wan2.1_vace_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "clip/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ────── Step 5: Download Workflows ──────
mkdir -p "$WORKFLOW_DIR"
cd "$WORKFLOW_DIR"

download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json" "text_to_video_wan.json"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json" "image_to_video_wan_720p_example.json"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json" "image_to_video_wan_480p_example.json"

# ────── Step 6: Gradio Tunnel ──────
cat << 'EOF' > "$COMFYUI_DIR/launch_gradio.py"
import gradio as gr

def inference_fn(x): return f"Echo: {x}"
gr.Interface(fn=inference_fn, inputs="text", outputs="text").launch(
    server_name="0.0.0.0", server_port=7860, share=True
)
EOF

nohup python3 "$COMFYUI_DIR/launch_gradio.py" > "$GRADIO_LOG" 2>&1 &
sleep 10
GRADIO_URL=$(grep -o 'https://.*\.gradio\.live' "$GRADIO_LOG" | head -n 1)

# ────── Step 7: Ngrok Tunnel ──────
cd /tmp
wget -qO /tmp/ngrok.tgz https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
chown user:user ngrok.tgz
tar -xzf /tmp/ngrok.tgz -C /workspace/.local/bin/
chmod +x /workspace/.local/bin/ngrok
export PATH="/workspace/.local/bin:$PATH"

cd /workspace/.local/bin/
chmod user:user ngrok
./ngrok authtoken "$NGROK_TOKEN"
nohup ./ngrok http "$COMFYUI_PORT" > "$NGROK_LOG" 2>&1 &
sleep 6
NGROK_URL=$(grep -o 'https://[^ ]*\.ngrok-free.app' "$NGROK_LOG" | head -n 1)

# ────── Step 8: Webhook Notification ──────
TUNNEL_URL="${GRADIO_URL:-$NGROK_URL}"
echo "[INFO] Tunnel URL: $TUNNEL_URL $NGROK_URL" | tee -a /workspace/provisioning.log

if [[ -n "$TUNNEL_URL" ]]; then
  curl -X POST -H "Content-Type: application/json" \
       -d "{\"url\": \"$TUNNEL_URL\"}" https://n8n.ifeatuo.com/videohooks \
       >> /workspace/provisioning.log 2>&1
fi

# ────── Step 9: Final Ownership ──────
chown -R user:user /workspace
tar -czf python_packages.tar.gz ~/.local/lib/python3.*/site-packages
aws s3 cp python_packages.tar.gz s3://vastai.bucket/comfy-cache/


