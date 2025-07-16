#!/bin/bash

# ─── Config ─────────────────────────────────────────────
SWARMUI_PORT=7801
COMFYUI_PORT=7802
GRADIO_PORT=7860
WAN_PATH="/workspace/SwarmUI/Models/diffusion_models/WAN2.1"
MODEL_USER="user"
SESSION_LOG="/workspace/logs/session_response.log"
FRPC_PATH="/workspace/.gradio/frpc/frpc_linux_amd64_v0.3"
GRADIO_ENV="/workspace/.gradio"
mkdir -p "$WAN_PATH" /workspace/logs
# ───────────────────────────────────────────────────────

# ─── Step 0: DNS Sanity Check ──────────────────────────
echo "[INFO] Checking /etc/resolv.conf..."
if ! grep -q "nameserver" /etc/resolv.conf; then
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  echo "[INFO] Default DNS nameservers added."
fi

# ─── Step 1: Launch SwarmUI ────────────────────────────
echo "[INFO] Launching SwarmUI..."
cd /workspace/SwarmUI
nohup ./launch-linux.sh --launch_mode none \
  --port "$SWARMUI_PORT" \
  --workflow "text_to_video_wan.json" \
  --session_id "auto" >> /workspace/server_output.log 2>&1 &
sleep 6

# ─── Step 2: Get Session ID ────────────────────────────
echo "[INFO] Fetching SwarmUI session ID..."
RESPONSE=$(curl -s -X POST http://localhost:$SWARMUI_PORT/API/GetNewSession -H "Content-Type: application/json" -d '{}')
echo "$RESPONSE" >> "$SESSION_LOG"
SESSION_ID=$(echo "$RESPONSE" | grep -oP '"session_id":"\K[^"]+')
if [ -z "$SESSION_ID" ]; then
  echo "[ERROR] Failed to retrieve session ID."
  exit 1
fi

# ─── Step 3: Download WAN2.1 Models ────────────────────
echo "[INFO] Downloading WAN2.1 models..."
env HF_TOKEN=$HF_TOKEN su - "$MODEL_USER" <<'EOF'
mkdir -p /workspace/SwarmUI/Models/diffusion_models/WAN2.1
cd /workspace/SwarmUI/Models/diffusion_models/WAN2.1

wget -nv -O clip_vision_h.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
wget -nv -O wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
wget -nv -O wan2.1_i2v_720p_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
wget -nv -O wan2.1_t2v_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors"
wget -nv -O wan2.1_vace_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors"
EOF
chown -R "$MODEL_USER:$MODEL_USER" "$WAN_PATH"

# ─── Step 4: Generate Metadata Files ───────────────────
for f in "$WAN_PATH"/*.safetensors; do
  base=$(basename "$f" .safetensors)
  json="$WAN_PATH/$base.swarm.json"
  [ -f "$json" ] || cat <<EOF > "$json"
{
  "title": "$base",
  "description": "WAN2.1 cinematic model",
  "tags": ["wan", "video", "diffusion"],
  "standard_width": 512,
  "standard_height": 512
}
EOF
done
chown -R "$MODEL_USER:$MODEL_USER" "$WAN_PATH"

# ─── Step 5: Load Workflows ────────────────────────────
su - "$MODEL_USER" <<'EOF'
cd /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/ExampleWorkflows/
wget -nv -O text_to_video_wan.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json"
wget -nv -O image_to_video_wan_720p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json"
wget -nv -O image_to_video_wan_480p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json"
cp *.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
EOF
chown -R "$MODEL_USER:$MODEL_USER" /workspace/SwarmUI/src/BuiltinExtensions/

# ─── Step 6: Python Dependencies ───────────────────────
su - "$MODEL_USER" -c "pip3 install --user gradio safetensors"

# ─── Step 7: Register ComfyUI Backend ─────────────────
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://localhost:$SWARMUI_PORT/API/AddBackend \
  -H "Content-Type: application/json" -d '{}')
if [ "$CODE" == "200" ]; then
  curl -s -X POST http://localhost:$SWARMUI_PORT/API/AddBackend \
    -H "Content-Type: application/json" \
    -d '{
      "session_id": "'"$SESSION_ID"'",
      "backend_type": "comfy_self_start",
      "backend_id": "comfy1",
      "enabled": true,
      "params": { "path": "/workspace/ComfyUI/main.py" }
    }'
fi

# ─── Step 8: Launch ComfyUI ────────────────────────────
if ! lsof -i :"$COMFYUI_PORT" >/dev/null; then
  echo "[INFO] Starting ComfyUI on port $COMFYUI_PORT..."
  nohup python3 /workspace/ComfyUI/main.py --port "$COMFYUI_PORT" >> /workspace/comfy_output.log 2>&1 &
fi

# ─── Step 9: Launch Gradio Interface ───────────────────
echo "[INFO] Starting Gradio UI..."
nohup su - "$MODEL_USER" -c "
export PATH=\"\$HOME/.local/bin:\$PATH\"
export GRADIO_FRPC_BINARY=$FRPC_PATH
export GRADIO_CACHE_DIR=$GRADIO_ENV
export GRADIO_TEMP_DIR=$GRADIO_ENV
cd /workspace/SwarmUI
HOME=/home/$MODEL_USER python3 launch_gradio.py
" >> /workspace/gradio_output.log 2>&1 &

sleep 20
PUBLIC_URL=$(grep -o 'https://.*\.gradio\.live' /workspace/gradio_output.log | head -n 1)
echo "$PUBLIC_URL" > /workspace/share_url.txt
if [[ -n "$PUBLIC_URL" ]]; then
  curl -G https://n8n.ifeatuo.com/videohooks \
       -H "Content-Type: application/json" \
       --data-urlencode "share_url=$PUBLIC_URL"
fi

# ─── Step 10: Watchdog for Outbid Detection ───────────
cat <<'EOF' > /workspace/watch_bid.sh
#!/bin/bash
while true; do
  status=$(curl -s http://localhost:1337/status
