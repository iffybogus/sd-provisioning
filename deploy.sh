#!/bin/bash

# ────── Environment Configuration ──────
export SWARMUI_PORT=7801
export COMFYUI_PORT=7802
export GRADIO_PORT=7860
export WAN_PATH="/workspace/SwarmUI/Models/diffusion_models/WAN2.1"
export MODEL_USER="user"
export SESSION_LOG="/workspace/logs/session_response.log"
export FRPC_PATH="/workspace/.gradio/frpc/frpc_linux_amd64_v0.3"
export GRADIO_ENV="/workspace/.gradio"
export GRADIO_SCRIPT="/workspace/SwarmUI/launch_gradio.py"

mkdir -p "$WAN_PATH" /workspace/logs

# ────── Step 0: DNS Resolver Check ──────
echo "[INFO] Checking /etc/resolv.conf..." | tee -a /workspace/provision.log
if ! grep -q "nameserver" /etc/resolv.conf; then
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  echo "[INFO] Added fallback DNS resolvers." | tee -a /workspace/provision.log
fi

# ────── Step 1: Launch SwarmUI ──────
echo "[INFO] Launching SwarmUI..." | tee -a /workspace/provision.log
cd /workspace/SwarmUI
nohup ./launch-linux.sh --launch_mode none \
  --port "$SWARMUI_PORT" \
  --workflow "text_to_video_wan.json" \
  --session_id "auto" >> /workspace/server_output.log 2>&1 &
sleep 6

# ────── Step 2: Get SwarmUI Session ID ──────
echo "[INFO] Retrieving SwarmUI session ID..." | tee -a /workspace/provision.log
export RESPONSE=$(curl -s -X POST http://localhost:$SWARMUI_PORT/API/GetNewSession \
  -H "Content-Type: application/json" -d '{}')
echo "$RESPONSE" | tee -a "$SESSION_LOG"
export SESSION_ID=$(echo "$RESPONSE" | grep -oP '"session_id":"\K[^"]+')
if [ -z "$SESSION_ID" ]; then
  echo "[ERROR] Failed to get session ID!" | tee -a /workspace/provision.log
  exit 1
fi

# ────── Step 3: Download WAN2.1 Models ──────
echo "[INFO] Downloading WAN2.1 models..." | tee -a /workspace/provision.log
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

# ────── Step 4: Generate .swarm.json Metadata ──────
for f in "$WAN_PATH"/*.safetensors; do
  base=$(basename "$f" .safetensors)
  meta="$WAN_PATH/$base.swarm.json"
  [ -f "$meta" ] || cat <<EOF > "$meta"
{
  "title": "$base",
  "description": "WAN2.1 cinematic model",
  "tags": ["wan", "diffusion", "video"],
  "standard_width": 512,
  "standard_height": 512
}
EOF
done
chown -R "$MODEL_USER:$MODEL_USER" "$WAN_PATH"

# ────── Step 5: Download Example Workflows ──────
echo "[INFO] Downloading example workflows..." | tee -a /workspace/provision.log
su - "$MODEL_USER" <<'EOF'
cd /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/ExampleWorkflows/
wget -nv -O text_to_video_wan.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json"
wget -nv -O image_to_video_wan_720p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json"
wget -nv -O image_to_video_wan_480p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json"
cp *.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
EOF

# ────── Step 6: Install Python Modules ──────
echo "[INFO] Installing Python dependencies..." | tee -a /workspace/provision.log
su - "$MODEL_USER" -c "pip3 install --user gradio safetensors"

# ────── Step 7: Register ComfyUI Backend ──────
echo "[INFO] Registering ComfyUI backend..." | tee -a /workspace/provision.log
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
else
  echo "[WARN] Endpoint unavailable — backend not registered." | tee -a /workspace/provision.log
fi

# ────── Step 8: Launch ComfyUI ──────
echo "[INFO] Launching ComfyUI..." | tee -a /workspace/provision.log
if ! lsof -i :"$COMFYUI_PORT" >/dev/null; then
  nohup python3 /workspace/ComfyUI/main.py --port "$COMFYUI_PORT" >> /workspace/comfy_output.log 2>&1 &
else
  echo "[WARN] ComfyUI port $COMFYUI_PORT already in use." | tee -a /workspace/provision.log
fi

# ────── Step 9: Write Gradio UI Script ──────
echo "[INFO] Generating Gradio UI script..." | tee -a /workspace/provision.log
su - "$MODEL_USER" <<'EOF'
cat <<PYCODE > /workspace/SwarmUI/launch_gradio.py
import os
import time
import json
import socket
import requests
import subprocess
import gradio as gr
from glob import glob

# --------- Config ---------
COMFY_PORT = 7802
SESSION_FILE = "/workspace/comfy_session.json"
MODEL_PATH = "Models/diffusion_models/WAN2.1"
COMFY_MAIN = "/workspace/ComfyUI/main.py"
# --------------------------

def launch_comfyui():
    print(f"[INFO] Launching ComfyUI on port {COMFY_PORT}...")
    subprocess.Popen(["python3", COMFY_MAIN, "--port", str(COMFY_PORT)])

def wait_for_comfy(timeout=30):
    for i in range(timeout):
        try:
            with socket.create_connection(("localhost", COMFY_PORT), timeout=2):
                print(f"[READY] ComfyUI is listening on port {COMFY_PORT}")
                return True
        except:
            print(f"[WAIT] ComfyUI not ready ({i+1}/{timeout})...")
            time.sleep(1)
    return False

def load_or_create_session():
    if os.path.exists(SESSION_FILE):
        try:
            with open(SESSION_FILE, "r") as f:
                session = json.load(f).get("session_id")
                if session:
                    print(f"[INFO] Reusing existing session ID: {session}")
                    return session
        except:
            print("[WARN] Failed to load session file.")

    print("[INFO] Creating new ComfyUI session...")
    try:
        resp = requests.post(f"http://localhost:{COMFY_PORT}/API/GetNewSession", json={}, timeout=10)
        session = resp.json().get("SESSION_ID")
        with open(SESSION_FILE, "w") as f:
            json.dump({"session_id": session}, f)
        print(f"[INFO] New session ID saved: {session}")
        return session
    except Exception as e:
        print("[ERROR] Could not create ComfyUI session:", e)
        return None

def list_available_models(session_id):
    try:
        resp = requests.post(f"http://localhost:{COMFY_PORT}/API/ListModels", json={
            "session_id": session_id,
            "path": MODEL_PATH
        }, timeout=10)
        return resp.json().get("models", [])
    except Exception as e:
        print("[ERROR] Failed to list models:", e)
        return []

def call_comfy_api(prompt, model):
    payload = {
        "session_id": session,
        "prompt": prompt,
        "images": 1,
        "model": model,
        "width": 512,
        "height": 512,
        "donotsave": True
    }
    try:
        response = requests.post(f"http://localhost:{COMFY_PORT}/API/GenerateText2Image",
                                 json=payload, timeout=20)
        print("ComfyUI response:", response.text)
        return response.json()
    except Exception as e:
        return {"error": str(e)}

def fetch_latest_video():
    files = sorted(glob("/workspace/SwarmUI/output/*.mp4"), key=os.path.getmtime, reverse=True)
    return files[0] if files else None

launch_comfyui()
wait_for_comfy()
session = load_or_create_session()
session_started = session is not None
model_list = list_available_models(session) if session_started else []

with gr.Blocks() as demo:
    gr.Markdown("## WAN 2.1 API Gateway")
    with gr.Row():
        model_dropdown = gr.Dropdown(choices=model_list, label="Model",
                                     value=model_list[0] if model_list else None)
        prompt_input = gr.Textbox(label="Prompt", value="monkey in a tree")

    output_display = gr.JSON(label="ComfyUI API Response")
    video_preview = gr.Video(label="Latest Output", interactive=True)

    def run_all(model, prompt):
        result = call_comfy_api(prompt, model)
        video = fetch_latest_video()
        return result, video

    run_button = gr.Button("Generate")
    run_button.click(fn=run_all, inputs=[model_dropdown, prompt_input],
                     outputs=[output_display, video_preview])

demo.queue().launch(share=True, server_name="0.0.0.0", server_port=7860)
PYCODE
EOF

# ─── Step 10: Launch Gradio Interface ───────────────────
echo "[INFO] Starting Gradio UI..." | tee -a /workspace/provision.log
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
echo "[INFO] Gradio URL: $PUBLIC_URL" | tee -a /workspace/provision.log
echo "$PUBLIC_URL" > /workspace/share_url.txt

if [[ -n "$PUBLIC_URL" ]]; then
  echo "[INFO] Sending webhook notification..." | tee -a /workspace/provision.log
  curl -G https://n8n.ifeatuo.com/videohooks \
       -H "Content-Type: application/json" \
       --data-urlencode "share_url=$PUBLIC_URL"
fi

# ─── Step 11: Watchdog for Outbid Detection ───────────
echo "[INFO] Installing watchdog script..." | tee -a /workspace/provision.log
cat <<'EOF' > /workspace/watch_bid.sh
#!/bin/bash
while true; do
  status=$(curl -s http://localhost:1337/status | jq -r '.outbid')
  if [[ "$status" == "true" ]]; then
    echo "[WATCHDOG] Outbid detected. Shutting down gracefully..." | tee -a /workspace/watchdog.log
    shutdown now
  fi
  sleep 60
done
EOF

chmod +x /workspace/watch_bid.sh
nohup bash /workspace/watch_bid.sh >> /workspace/watchdog.log 2>&1 &

