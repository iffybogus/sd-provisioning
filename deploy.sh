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

# Step 1: Install dependencies
apt update && apt install -y python3 python3-pip git-lfs wget curl git unzip sudo software-properties-common openssh-client nodejs npm jq

if ! command -v python &> /dev/null; then
  ln -s /usr/bin/python3 /usr/bin/python
fi

# Step 2: Gradio setup and binary
mkdir -p /workspace/.gradio/frpc
chmod -R 777 /workspace/.gradio

wget -q --show-progress -O /workspace/.gradio/frpc/frpc_linux_amd64_v0.3 \
  https://cdn-media.huggingface.co/frpc-gradio-0.3/frpc_linux_amd64
chmod +x /workspace/.gradio/frpc/frpc_linux_amd64_v0.3

# Step 3: Install Gradio as user with PATH
su - user -c "export PATH=\"\$HOME/.local/bin:\$PATH\" && HOME=/home/user pip3 install --user gradio"

# Step 4: Install .NET SDK
wget -O /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --version 8.0.100 --install-dir /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet

# Step 5: Use existing SwarmUI repo (no git clone or build)

# Step 6: Download WAN2.1 models using environment variable
env HF_TOKEN=$HF_TOKEN su - user <<'EOF'
ls -la /workspace/SwarmUI
# mkdir -p /workspace/SwarmUI/Models/diffusion_models/WAN2.1
cd /workspace/SwarmUI/Models/diffusion_models/WAN2.1

wget -O clip_vision_h.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
wget -O wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
wget -O wan2.1_i2v_720p_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
wget -O wan2.1_t2v_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors"
wget -O wan2.1_vace_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors"
EOF

# Step 7: Download example workflows
su - user <<'EOF'
cd /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/ExampleWorkflows/
wget -O text_to_video_wan.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/text_to_video_wan.json"
wget -O image_to_video_wan_720p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_720p_example.json"
wget -O image_to_video_wan_480p_example.json "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/example%20workflows_Wan2.1/image_to_video_wan_480p_example.json"

cp text_to_video_wan.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
cp image_to_video_wan_720p_example.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
cp image_to_video_wan_480p_example.json /workspace/SwarmUI/src/BuiltinExtensions/ComfyUIBackend/CustomWorkflows/Examples/
EOF

# Step 7.5: Launch backend API on port 5000
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
import requests
import gradio as gr
from glob import glob

# Setup environment variables for Gradio + FRPC
os.environ["GRADIO_FRPC_BINARY"] = "/workspace/.gradio/frpc/frpc_linux_amd64_v0.3"
os.environ["GRADIO_CACHE_DIR"] = "/workspace/.gradio"
os.environ["GRADIO_TEMP_DIR"] = "/workspace/.gradio"

# Generate unique session ID
session = f"gradio-session-{int(time.time())}"
workflow_name = "text_to_video_wan.json"

# Attempt to start session on launch
def start_session():
    url = "http://localhost:5000/api/session/start"
    payload = {"session": session, "workflow": workflow_name}
    try:
        response = requests.post(url, json=payload)
        print("Session start response:", response.text)
        return response.status_code == 200
    except Exception as e:
        print("[ERROR] Session boot failed:", e)
        return False

session_started = start_session()

# Function to fetch latest video from output folder
def fetch_latest_video():
    files = sorted(glob("/workspace/SwarmUI/output/*.mp4"), key=os.path.getmtime, reverse=True)
    return files[0] if files else None

# Main prompt processing logic
def call_api(endpoint="i2v", prompt="A dog running in the rain"):
    if not session_started:
        return {"error": "Session initialization failed. The backend workflow could not be started."}

    url = f"http://localhost:5000/api/{endpoint}"
    payload = {"session": session, "data": [prompt]}

    try:
        with open("/workspace/request_log.json", "a") as log_file:
            log_file.write(json.dumps({
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                "endpoint": endpoint,
                "session": session,
                "prompt": prompt
            }) + "\n")
    except Exception as log_error:
        print(f"[LOGGING ERROR] {log_error}")

    try:
        response = requests.post(url, json=payload)
        print("Raw response:", response.text)
        data = response.json()
        return data
    except Exception as e:
        return {"error": str(e)}

# Wrap Gradio UI with video preview section
with gr.Blocks() as demo:
    gr.Markdown("## WAN 2.1 API Gateway")
    with gr.Row():
        model_dropdown = gr.Dropdown(choices=["i2v", "t2v", "vace"], label="Model", value="t2v")
        prompt_input = gr.Textbox(label="Prompt", value="monkey in a tree")
    output_display = gr.JSON(label="API Response")
    video_preview = gr.Video(label="Latest Output", interactive=True)

    def run_all(endpoint, prompt):
        result = call_api(endpoint, prompt)
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
