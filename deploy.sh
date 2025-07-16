#!/bin/bash
set -e
set -x
exec > >(tee -a /workspace/provisioning.log) 2>&1

# Step -1: Set DNS resolvers
echo -e 'nameserver 8.8.8.8\nnameserver 1.1.1.1' > /etc/resolv.conf

# Step 0: Create user and setup permissions
if ! id "user" &>/dev/null; then
    useradd -m user
fi
chown -R user:user /workspace

# Add .local/bin to PATH for user
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/user/.bashrc

# Step 3.3: Set environment variables for Python module discovery
su - user -c "echo 'export PYTHONPATH=\$HOME/.local/lib/python3.*/site-packages:\$PYTHONPATH' >> ~/.bashrc"
su - user -c "echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc"


# Step 1: Install dependencies
apt update && apt install -y python3 python3-pip git-lfs wget curl git unzip sudo software-properties-common openssh-client nodejs npm jq

if ! command -v python &> /dev/null; then
  ln -s /usr/bin/python3 /usr/bin/python
fi

# Step 2: Gradio setup and binary
mkdir -p /workspace/.gradio/frpc
chmod -R 777 /workspace/.gradio

wget -nv -O /workspace/.gradio/frpc/frpc_linux_amd64_v0.3 \
  https://cdn-media.huggingface.co/frpc-gradio-0.3/frpc_linux_amd64
chmod +x /workspace/.gradio/frpc/frpc_linux_amd64_v0.3

# Step 3.2: Install gradio and safetensors as 'user'
su - user -c "export PATH=\"\$HOME/.local/bin:\$PATH\" && HOME=/home/user pip3 install --user gradio safetensors"

echo "[INFO] Installed gradio and safetensors for 'user'"

# Step 4: Install .NET SDK
wget -nv -O /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --version 8.0.100 --install-dir /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet

# Step 5.5: Stable upgrade of SwarmUI
echo "[INFO] Preparing SwarmUI Git repo..."
cd /workspace/SwarmUI
git config --global --add safe.directory /workspace/SwarmUI

# Define version control
STABLE_TAG="0.9.5-Beta"
STABLE_COMMIT="194b0c0f"  # Commit shown in your session
ALLOW_MASTER_OVERRIDE=false  # Set to true ONLY when testing latest SwarmUI

if [ -d .git ]; then
    git fetch --all --tags
    if [ "$ALLOW_MASTER_OVERRIDE" = true ]; then
        echo "[WARNING] Overriding stability — using master branch!"
        git checkout master && git pull origin master
        echo "[INFO] Active SwarmUI commit: $(git rev-parse HEAD)"
    else
        echo "[INFO] Locking SwarmUI to tag $STABLE_TAG with commit $STABLE_COMMIT"
        git checkout $STABLE_COMMIT
        echo "[INFO] SwarmUI version pinned to commit: $(git rev-parse HEAD)"
    fi
else
    echo "[WARN] No Git repo found — skipping upgrade."
fi

# Step 5.6: Install Python modules for 'user'
echo "[INFO] Installing Python dependencies for 'user'..."

su - user -c "export PATH=\"\$HOME/.local/bin:\$PATH\" && HOME=/home/user pip3 install --user gradio safetensors"

# Ensure environment variables are persistent
su - user -c "echo 'export PYTHONPATH=\$HOME/.local/lib/python3.*/site-packages:\$PYTHONPATH' >> ~/.bashrc"
su - user -c "echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc"

# Step 5.7: Install FreneticUtilities dependency
echo "[INFO] Installing FreneticUtilities..."
dotnet add src/SwarmUI.csproj package FreneticLLC.FreneticUtilities --version 1.1.1

# Step 5.8: Clone and install ComfyUI if missing
echo "[INFO] Checking for ComfyUI installation..."
if [ ! -d /workspace/ComfyUI ]; then
  echo "[INFO] Cloning ComfyUI..."
  git clone https://github.com/comfyanonymous/ComfyUI /workspace/ComfyUI
  echo "[INFO] Installing ComfyUI dependencies..."
  pip install -r /workspace/ComfyUI/requirements.txt

  echo "[INFO] Installing additional required modules..."
  pip install safetensors
fi

# Step 5.9: Clean and rebuild backend
echo "[INFO] Rebuilding SwarmUI backend..."
rm -rf src/bin/* src/obj/*
dotnet restore src/SwarmUI.csproj
dotnet publish src/SwarmUI.csproj -c Release -o src/bin/live_release/

# Step 5.9.5: Fix permissions and ownership
echo "[INFO] Fixing ownership and permissions..."
chown -R user:user /workspace/SwarmUI/src/bin/live_release/
chmod -R u+rwX /workspace/SwarmUI/src/bin/live_release/
chown -R user:user /workspace/SwarmUI/
chmod -R u+rwX /workspace/SwarmUI/

# Step 5.9.6: Launch SwarmUI interface
echo "[INFO] Launching SwarmUI on port 7801 with workflow preload..."
cd /workspace/SwarmUI
nohup ./launch-linux.sh --launch_mode none \
    --port 7801 \
    --workflow "text_to_video_wan.json" \
    --session_id "auto" \
    >> /workspace/server_output.log 2>&1 &

sleep 6  # Increased delay to ensure backend fully initializes

# Step 6.0: Retrieve valid session ID
echo "[INFO] Fetching session ID..."
SESSION_ID=$(curl -v -s -X POST http://localhost:7801/API/GetNewSession \
  -H "Content-Type: application/json" -d '{}' | grep -oP '"session_id":"\K[^"]+')

if [ -z "$SESSION_ID" ]; then
  echo "[ERROR] Session ID retrieval failed."
  exit 1
fi

if ! python3 -c "import safetensors" &>/dev/null; then
  echo "[INFO] Installing missing Python module: safetensors"
  pip install safetensors
fi

# Step 6.1: Register ComfyUI backend
echo "[INFO] Registering ComfyUI backend..."
curl -v -s -X POST http://localhost:7801/API/AddBackend \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "'"$SESSION_ID"'",
    "backend_type": "comfy_self_start",
    "backend_id": "comfy1",
    "enabled": true,
    "params": {
      "path": "/workspace/ComfyUI/main.py"
    }
  }'

# Step 6.2: Download WAN2.1 models using environment variable
env HF_TOKEN=$HF_TOKEN su - user <<'EOF'
mkdir -p /workspace/SwarmUI/Models/diffusion_models/WAN2.1
cd /workspace/SwarmUI/Models/diffusion_models/WAN2.1

wget -nv -O clip_vision_h.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
wget -nv -O wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
wget -nv -O wan2.1_i2v_720p_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
wget -nv -O wan2.1_t2v_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors"
wget -nv -O wan2.1_vace_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors"
EOF

# Step 6.3: Download example workflows
su - user <<'EOF'
cd /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/ExampleWorkflows/
wget -nv -O text_to_video_wan.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json"
wget -nv -O image_to_video_wan_720p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json"
wget -nv -O image_to_video_wan_480p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json"

cp text_to_video_wan.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
cp image_to_video_wan_720p_example.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
cp image_to_video_wan_480p_example.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
EOF

# Step 6.4: Launch backend API on port 5000
nohup su - user -c '
cd /workspace/SwarmUI
export ASPNETCORE_URLS=http://0.0.0.0:5000
./src/bin/live_release/SwarmUI --launch_mode none --port 5000 &
' >> /workspace/server_output.log 2>&1 &

# Step 8: Create launch_gradio.py as user
su - user -c 'cat <<EOF > /workspace/SwarmUI/launch_gradio.py
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

# ✅ Launch ComfyUI subprocess
def launch_comfyui():
    print(f"[INFO] Launching ComfyUI on port {COMFY_PORT}...")
    subprocess.Popen(["python3", COMFY_MAIN, "--port", str(COMFY_PORT)])

# ✅ Wait for ComfyUI to respond
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

# ✅ Persist session across reboots
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

    # If session not found, create one
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

# ✅ Query valid model names
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

# ✅ Use ComfyUI API to generate image
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

# ✅ Get latest output video
def fetch_latest_video():
    files = sorted(glob("/workspace/SwarmUI/output/*.mp4"), key=os.path.getmtime, reverse=True)
    return files[0] if files else None

# 🎬 Pipeline begins
launch_comfyui()
wait_for_comfy()
session = load_or_create_session()
session_started = session is not None
model_list = list_available_models(session) if session_started else []

# 🌿 Gradio UI
with gr.Blocks() as demo:
    gr.Markdown("## WAN 2.1 API Gateway")
    with gr.Row():
        model_dropdown = gr.Dropdown(choices=model_list, label="Model", value=model_list[0] if model_list else None)
        prompt_input = gr.Textbox(label="Prompt", value="monkey in a tree")

    output_display = gr.JSON(label="ComfyUI API Response")
    video_preview = gr.Video(label="Latest Output", interactive=True)

    def run_all(model, prompt):
        result = call_comfy_api(prompt, model)
        video = fetch_latest_video()
        return result, video

    run_button = gr.Button("Generate")
    run_button.click(fn=run_all, inputs=[model_dropdown, prompt_input], outputs=[output_display, video_preview])

demo.queue().launch(share=True, server_name="0.0.0.0", server_port=7860)
EOF'

# Step 9: Launch Gradio
nohup su - user -c '
export PATH="$HOME/.local/bin:$PATH"
export GRADIO_FRPC_BINARY=/workspace/.gradio/frpc/frpc_linux_amd64_v0.3
export GRADIO_CACHE_DIR=/workspace/.gradio
export GRADIO_TEMP_DIR=/workspace/.gradio
cd /workspace/SwarmUI
HOME=/home/user python3 launch_gradio.py
' >> /workspace/gradio_output.log 2>&1 &

sleep 20
PUBLIC_URL=$(grep -o 'https://.*\.gradio\.live' /workspace/gradio_output.log | head -n 1)
echo "$PUBLIC_URL" > /workspace/share_url.txt

if [[ -n "$PUBLIC_URL" ]]; then
  curl -G https://n8n.ifeatuo.com/videohooks \
       -H "Content-Type: application/json" \
       --data-urlencode "share_url=$PUBLIC_URL"
fi

# Step 10: Watchdog for outbid termination
cat <<'EOF' > /workspace/watch_bid.sh
#!/bin/bash
while true; do
  status=$(curl -s http://localhost:1337/status | jq -r '.outbid')
  if [[ "$status" == "true" ]]; then
    echo "Outbid detected. Shutting down."
    shutdown now
  fi
  sleep 60
done
EOF

chmod +x /workspace/watch_bid.sh
nohup bash /workspace/watch_bid.sh >> /workspace/watchdog.log 2>&1 &

# Step 11: Enable auto-launch via rc.local
cat <<'EORC' > /etc/rc.local
#!/bin/bash
su - user -c '
export PATH="$HOME/.local/bin:$PATH"
export GRADIO_FRPC_BINARY=/workspace/.gradio/frpc/frpc_linux_amd64_v0.3
export GRADIO_CACHE_DIR=/workspace/.gradio
export GRADIO_TEMP_DIR=/workspace/.gradio
cd /workspace/SwarmUI
HOME=/home/user nohup python3 launch_gradio.py >> /workspace/gradio_output.log 2>&1 &
'
sleep 20
PUBLIC_URL=$(grep -o "https://.*\.gradio\.live" /workspace/gradio_output.log | head -n 1)
export PUBLIC_URL
if [[ -n "$PUBLIC_URL" ]]; then
  echo "$PUBLIC_URL" > /workspace/share_url.txt
  curl -G https://n8n.ifeatuo.com/videohooks --data-urlencode "share_url=$PUBLIC_URL"
fi
nohup bash /workspace/watch_bid.sh >> /workspace/watchdog.log 2>&1 &
exit 0
EORC
chmod +x /etc/rc.local

echo "[INFO] Provisioning complete."
echo "[INFO] Final active SwarmUI commit: $(cd /workspace/SwarmUI && git rev-parse HEAD)"
python3 -c "import gradio; print('[INFO] Gradio version:', gradio.__version__)"
