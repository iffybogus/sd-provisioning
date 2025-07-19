#!/bin/bash

# ────── Step 0: Redirect /workspace to mounted disk ──────
echo "[INFO] Redirecting /workspace to /etc/hosts/workspace"
mkdir -p /etc/hosts/workspace
if [ -d /workspace ] && [ ! -L /workspace ]; then
  rsync -a /workspace/ /etc/hosts/workspace/
  mv /workspace /workspace_backup
fi
ln -sfn /etc/hosts/workspace /workspace

# ────── Step 1: Setup Logging ──────
mkdir -p /workspace/logs
touch /workspace/provisioning.log

# ────── Step 2: Define Retry Download Function ──────
download_with_retry() {
  local url="$1"
  local output="$2"
  local max_retries=5
  local wait_seconds=30
  local attempt=1

  while [ "$attempt" -le "$max_retries" ]; do
    echo "[INFO] Attempt $attempt: Downloading $output" | tee -a /workspace/provisioning.log
    wget -nv -O "$output" "$url"
    if [ $? -eq 0 ]; then
      echo "[SUCCESS] Downloaded $output" | tee -a /workspace/provisioning.log
      return 0
    else
      echo "[WARN] Failed to download $output — retrying in $wait_seconds seconds..." | tee -a /workspace/provisioning.log
      sleep "$wait_seconds"
      attempt=$((attempt+1))
    fi
  done

  echo "[ERROR] Giving up on $output after $max_retries attempts." | tee -a /workspace/provisioning.log
  return 1
}

# ────── Step 3: Download WAN2.1 Models ──────
echo "[INFO] Downloading WAN2.1 models..." | tee -a /workspace/provisioning.log
mkdir -p /workspace/ComfyUI/models/{clip_vision,vae,diffusion_models,unet,clip}
cd /workspace/ComfyUI/models/

download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "clip_vision/clip_vision_h.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "vae/wan_2.1_vae.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors" "diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors" "unet/wan2.1_t2v_1.3B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors" "unet/wan2.1_t2v_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "vae/wan2.1_vace_14B_fp16.safetensors"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "clip/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ────── Step 4: Download WAN2.1 Workflows ──────
echo "[INFO] Downloading WAN2.1 workflows..." | tee -a /workspace/provisioning.log
mkdir -p /workspace/ComfyUI/input/
cd /workspace/ComfyUI/input/

download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json" "text_to_video_wan.json"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json" "image_to_video_wan_720p_example.json"
download_with_retry "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json" "image_to_video_wan_480p_example.json"

# ────── Step 5: Launch Tunnels and Export Public URL ──────
TUNNEL_PORT=18188
TUNNEL_DEST="/workspace/logs/PUBLIC_URL.txt"

launch_gradio_tunnel() {
  echo "[INFO] Launching Gradio with share=True" | tee -a /workspace/provisioning.log
  python3 <<EOF
import gradio as gr
import os

def inference_fn(x): return f"Echo: {x}"
demo = gr.Interface(fn=inference_fn, inputs="text", outputs="text")
link = demo.launch(server_name="0.0.0.0", server_port=$TUNNEL_PORT, share=True)
with open("$TUNNEL_DEST", "w") as f: f.write(link + "\n")
os.environ["PUBLIC_URL"] = link
EOF
}

launch_ngrok_tunnel() {
  echo "[INFO] Installing and launching ngrok..." | tee -a /workspace/provisioning.log
  wget -nv -O /tmp/ngrok.zip https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-stable-linux-amd64.zip
  unzip -q /tmp/ngrok.zip -d /usr/local/bin/
  ngrok authtoken "${NGROK_TOKEN:-}" 2>/dev/null
  nohup ngrok http $TUNNEL_PORT > /workspace/logs/ngrok.log 2>&1 &
  sleep 5
  URL=$(grep -o 'https://[a-zA-Z0-9.-]*\.ngrok\.io' /workspace/logs/ngrok.log | head -n1)
  echo "$URL" > "$TUNNEL_DEST"
  export PUBLIC_URL="$URL"
}

# ────── Choose Your Tunnel Mode ──────
case "$TUNNEL_MODE" in
  gradio) launch_gradio_tunnel ;;
  ngrok)  launch_ngrok_tunnel ;;
  *)      echo "[WARN] Unknown tunnel mode. Defaulting to ngrok." ; launch_ngrok_tunnel ;;
esac

# ────── Optional: Call n8n webhook with public URL ──────
if [ -n "$PUBLIC_URL" ]; then
  curl -X POST -H "Content-Type: application/json" -d "{\"url\": \"$PUBLIC_URL\"}" https://n8n.ifeatuo.com/videohooks
fi
