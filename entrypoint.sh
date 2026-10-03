#!/bin/bash
set -e

# Model variables (adjust repo name based on your preferred quantizer on HuggingFace)
# Model variables 
HF_REPO="JonathanColetti/Qwen3.8-27B-Uncensored-GGUF"
MODEL_FILE="Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MODEL_DIR="/models"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
CTX_SIZE=65536
MAX_OUT=4096
REASON_BUDGET=512

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
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size $CTX_SIZE \
    --parallel 1 \
    --n-predict "$MAX_OUT" \
    --no-reasoning-preserve \
    --reasoning-budget $REASON_BUDGET \
    --n-gpu-layers 99 \
    --flash-attn on \
    --jinja \
    --embedding \
    --pooling last \
    --api-key sk-local &

# 2. Wait for the model to load into VRAM dynamically
echo "Waiting for LLM server to initialize (this may take 30+ seconds)..."
while ! curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:8080/v1/models | grep -q "id"; do
    sleep 2
done
echo "LLM server is fully loaded and ready!"

# Resolve the model id the server actually advertises
MODEL_ID=$(curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:8080/v1/models \
  | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -z "$MODEL_ID" ]; then
    MODEL_ID="$MODEL_FILE"   # fallback
fi
echo "Detected model id: $MODEL_ID"

# 3. Point OpenClaw chat + memory at the local server
export OPENAI_BASE_URL="http://127.0.0.1:8080/v1"
export OPENAI_API_KEY="sk-local"

echo "Configuring OpenClaw for local OpenAI-compatible server..."

# Chat provider
openclaw config set models.providers.openai.baseUrl "http://127.0.0.1:8080/v1"
openclaw config set models.providers.openai.apiKey "sk-local"
openclaw config set agents.defaults.model "openai/${MODEL_ID}"

# Memory embeddings (Option A — same server)
openclaw config set memory.search.provider openai-compatible
openclaw config set memory.search.model "${MODEL_ID}"
openclaw config set memory.search.remote.baseUrl "http://127.0.0.1:8080/v1/"
openclaw config set memory.search.remote.apiKey "sk-local"
openclaw config set memory.search.fallback none

openclaw config set agents.defaults.bootstrapTotalMaxChars 4000
openclaw config set agents.defaults.experimental.localModelLean true
openclaw config set agents.defaults.contextTokens $CTX_SIZE 

openclaw config set models.providers.openai.models \
  "[{\"id\":\"${MODEL_ID}\",\"name\":\"Local Qwen\",\"contextWindow\":$CTX_SIZE,\"contextTokens\":$CTX_SIZE,\"maxTokens\":$MAX_OUT}]" \
  --strict-json

# 4. Initialize and start OpenClaw
echo "Starting OpenClaw..."
openclaw gateway run --allow-unconfigured --token "my-secure-password" 

