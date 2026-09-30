#!/bin/bash
set -e

# Model variables (adjust repo name based on your preferred quantizer on HuggingFace)
# Model variables 
HF_REPO="JonathanColetti/Qwen3.8-27B-Uncensored-GGUF"
MODEL_FILE="Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MODEL_DIR="/models"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

mkdir -p $MODEL_DIR

# 1. Download the GGUF model if it's not present
if [ ! -f "$MODEL_PATH" ]; then
    echo "Downloading $MODEL_FILE (This is ~16.8GB and will take a while)..."
    hf download $HF_REPO $MODEL_FILE --local-dir $MODEL_DIR
else
    echo "Model found at $MODEL_PATH, skipping download."
fi

# 2. Start llama.cpp in OpenAI API server mode with maximum GPU offloading
echo "Starting local LLM server..."
unset LD_LIBRARY_PATH 

/opt/llama.cpp/build/bin/llama-server \
    -m "$MODEL_PATH" \
    --alias "qwen3.8-uncensored" \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size 32768 \
    --n-gpu-layers 99 \
    --flash-attn on \
    --chat-template qwen2.5 \
    --api-key sk-local &

# Wait for the model to load into VRAM
echo "Waiting 15 seconds for LLM server to initialize..."
sleep 15

# 3. Configure OpenClaw environment variables to route to the local server
export OPENAI_BASE_URL="http://127.0.0.1:8080/v1"
export OPENAI_API_KEY="sk-local"  # llama.cpp accepts any string as a key
export OPENCLAW_MODEL="local"

# 4. Initialize and start OpenClaw
echo "Starting OpenClaw..."
openclaw gateway run --allow-unconfigured --token "my-secure-password" 

