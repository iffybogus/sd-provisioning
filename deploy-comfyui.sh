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
