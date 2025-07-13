#!/bin/bash
set -e
set -x
exec > >(tee -a /workspace/provisioning.log) 2>&1

# Step -1: Set DNS resolvers
echo -e 'nameserver 8.8.8.8\nnameserver 1.1.1.1' > /etc/resolv.conf

# Step 0: Create user and setup permissions
if ! id "forgeuser" &>/dev/null; then
    useradd -m forgeuser
fi
chown -R forgeuser:forgeuser /workspace

# Add .local/bin to PATH for forgeuser
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/forgeuser/.bashrc

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

# Step 3: Install Gradio as forgeuser with PATH
su - forgeuser -c "export PATH=\"\$HOME/.local/bin:\$PATH\" && HOME=/home/forgeuser pip3 install --user gradio"

# Step 4: Install .NET SDK
wget -O /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --version 8.0.100 --install-dir /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet

# Step 5: Clone and build SwarmUI
su - forgeuser -c "rm -rf /workspace/SwarmUI && git clone https://github.com/mcmonkeyprojects/SwarmUI.git /workspace/SwarmUI"
su - forgeuser -c "cd /workspace/SwarmUI && HOME=/home/forgeuser dotnet publish -c Release -o publish || dotnet build"

# Step 6: Download WAN2.1 models using environment variable
env HF_TOKEN=$HF_TOKEN su - forgeuser <<'EOF'
mkdir -p /workspace/SwarmUI/Models/diffusion_models/WAN2.1
cd /workspace/SwarmUI/Models/diffusion_models/WAN2.1

wget -O clip_vision_h.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
wget -O wan_2.1_vae.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
wget -O wan2.1_i2v_720p_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_fp16.safetensors"
wget -O wan2.1_t2v_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_fp16.safetensors"
wget -O wan2.1_vace_14B_fp16.safetensors "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors"
EOF

# Step 7: Create launch_gradio.py as forgeuser
su - forgeuser -c 'cat <<EOF > /workspace/SwarmUI/launch_gradio.py
import os
os.environ["GRADIO_FRPC_BINARY"] = "/workspace/.gradio/frpc/frpc_linux_amd64_v0.3"
os.environ["GRADIO_CACHE_DIR"] = "/workspace/.gradio"
os.environ["GRADIO_TEMP_DIR"] = "/workspace/.gradio"
import gradio as gr
import requests

def call_api(endpoint="i2v", prompt="A dog running in the rain"):
    url = f"http://localhost:5000/api/{endpoint}?prompt=" + prompt
    try:
        response = requests.get(url)
        return response.json()
    except Exception as e:
        return {"error": str(e)}

gr.Interface(
    fn=call_api,
    inputs=[
        gr.Dropdown(["i2v", "t2v", "vace"], label="Model"),
        gr.Textbox(label="Prompt")
    ],
    outputs="json",
    title="WAN 2.1 API Gateway"
).launch(share=True, server_name="0.0.0.0", server_port=7860)
EOF'

# Step 8: Launch Gradio as forgeuser
nohup su - forgeuser -c '
export PATH="$HOME/.local/bin:$PATH"
export GRADIO_FRPC_BINARY=/workspace/.gradio/frpc/frpc_linux_amd64_v0.3
export GRADIO_CACHE_DIR=/workspace/.gradio
export GRADIO_TEMP_DIR=/workspace/.gradio
cd /workspace/SwarmUI
HOME=/home/forgeuser python3 launch_gradio.py
' >> /workspace/gradio_output.log 2>&1 &

sleep 20
PUBLIC_URL=$(grep -o 'https://.*\.gradio\.live' /workspace/gradio_output.log | head -n 1)
echo "$PUBLIC_URL" > /workspace/share_url.txt

if [[ -n "$PUBLIC_URL" ]]; then
  curl -G https://n8n.ifeatuo.com/videohooks \
       -H "Content-Type: application/json" \
       --data-urlencode "share_url=$PUBLIC_URL"
fi

# Step 9: Watchdog for outbid termination
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

# Step 10: Enable auto-launch via rc.local
cat <<'EORC' > /etc/rc.local
#!/bin/bash
su - forgeuser -c '
export PATH="$HOME/.local/bin:$PATH"
export GRADIO_FRPC_BINARY=/workspace/.gradio/frpc/frpc_linux_amd64_v0.3
export GRADIO_CACHE_DIR=/workspace/.gradio
export GRADIO_TEMP_DIR=/workspace/.gradio
cd /workspace/SwarmUI
HOME=/home/forgeuser nohup python3 launch_gradio.py >> /workspace/gradio_output.log 2>&1 &
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
