#!/bin/bash
set -e

# Model variables (adjust repo name based on your preferred quantizer on HuggingFace)
# Model variables 
HF_REPO="JonathanColetti/Qwen3.8-27B-Uncensored-GGUF"
MODEL_FILE="Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MODEL_DIR="/models"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
CTX_SIZE=65536    #65536    # 49152
EFFECTIVE_CTX=32768    #38912    #36864    #40960  #49152  #20480   #16384   #28672   #32768      # when compaction should kick in
KEEP_RECENT=6144  #4096  #8192 #6144
MAX_OUT=8192   #12288 #20480
REASON_BUDGET=512
N_SLOT=1

# ============================================================
# Embedding model (small + better)
# ============================================================
EMB_HF_REPO="Qwen/Qwen3-Embedding-0.6B-GGUF"
EMB_MODEL_FILE="Qwen3-Embedding-0.6B-Q8_0.gguf"
EMB_MODEL_PATH="$MODEL_DIR/$EMB_MODEL_FILE"
EMB_PORT=8081
EMB_CTX=8192

mkdir -p $MODEL_DIR

# 1. Download the GGUF model if it's not present
if [ ! -f "$MODEL_PATH" ]; then
    echo "Downloading $MODEL_FILE (This is ~16.8GB and will take a while)..."
    hf download $HF_REPO $MODEL_FILE --local-dir $MODEL_DIR
else
    echo "Model found at $MODEL_PATH, skipping download."
fi

# ------------------------------------------------------------
# Download embedding model if missing
# ------------------------------------------------------------
if [ ! -f "$EMB_MODEL_PATH" ]; then
    echo "Downloading embedding model $EMB_MODEL_FILE (~0.4 GB)..."
    hf download "$EMB_HF_REPO" "$EMB_MODEL_FILE" --local-dir "$MODEL_DIR"
else
    echo "Embedding model found at $EMB_MODEL_PATH"
fi

# 2. Start llama.cpp in OpenAI API server mode with maximum GPU offloading
echo "Starting local LLM server..."
unset LD_LIBRARY_PATH 

/opt/llama.cpp/build/bin/llama-server \
    -m "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size $CTX_SIZE \
    --parallel $N_SLOT \
    --n-predict "$MAX_OUT" \
    --no-reasoning-preserve \
    --reasoning-budget $REASON_BUDGET \
    --n-gpu-layers 99 \
    --flash-attn on \
    --jinja \
    --chat-template-file /models/qwen3.8-openclaw.jinja \
    --api-key sk-local &

# ------------------------------------------------------------
# Start dedicated embedding server (port 8081)
# ------------------------------------------------------------
echo "Starting embedding server on :$EMB_PORT..."
/opt/llama.cpp/build/bin/llama-server \
    -m "$EMB_MODEL_PATH" \
    --host 0.0.0.0 \
    --port $EMB_PORT \
    --ctx-size $EMB_CTX \
    --embedding \
    --pooling last \
    --n-gpu-layers 99 \
    --flash-attn on \
    --api-key sk-local &

# 2. Wait for the model to load into VRAM dynamically
echo "Waiting for LLM server to initialize (this may take 30+ seconds)..."
while ! curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:8080/v1/models | grep -q "id"; do
    sleep 2
done
echo "LLM server is fully loaded and ready!"

echo "Waiting for embedding server..."
while ! curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:$EMB_PORT/v1/models | grep -q '"id"'; do
    sleep 1
done
echo "Embedding server ready."

# Resolve the model id the server actually advertises
MODEL_ID=$(curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:8080/v1/models \
  | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -z "$MODEL_ID" ]; then
    MODEL_ID="$MODEL_FILE"   # fallback
fi

# Strip leading path junk if present
MODEL_ID="${MODEL_ID#/models/}"
MODEL_ID="${MODEL_ID##*/}"   # just the filename if needed

EMB_MODEL_ID=$(curl -s -H "Authorization: Bearer sk-local" http://127.0.0.1:$EMB_PORT/v1/models \
  | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$EMB_MODEL_ID" ] && EMB_MODEL_ID="$EMB_MODEL_FILE"

EMB_MODEL_ID="${EMB_MODEL_ID#/models/}"
EMB_MODEL_ID="${EMB_MODEL_ID##*/}"

echo "Detected model id: $MODEL_ID"
echo "Embed model id: $EMB_MODEL_ID"

# 3. Point OpenClaw chat + memory at the local server
export OPENAI_BASE_URL="http://127.0.0.1:8080/v1"
export OPENAI_API_KEY="sk-local"

echo "Configuring OpenClaw for local OpenAI-compatible server..."

set +e
openclaw gateway stop --force >/dev/null 2>&1
config_ok=0
for i in $(seq 1 12); do
  if openclaw config validate >/dev/null 2>&1; then
    config_ok=1
    break
  fi
  echo "Config locked or unreadable (Gateway ownership); waiting 10s ($i/12)..."
  sleep 10
done
set -e

if [ "$config_ok" != "1" ]; then
  echo "ERROR: OpenClaw config still locked after ~2 minutes."
  exit 1
fi

openclaw config set models.providers.local \
  "{\"baseUrl\":\"http://127.0.0.1:8080/v1\",\"apiKey\":\"sk-local\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"${MODEL_ID}\",\"name\":\"Local Qwen\",\"contextWindow\":${CTX_SIZE},\"contextTokens\":${EFFECTIVE_CTX},\"maxTokens\":${MAX_OUT}}]}" \
  --strict-json --replace

openclaw config set gateway.controlUi.allowedOrigins '["http://localhost:18790","http://localhost:18789"]'
openclaw config set agents.defaults.model "local/${MODEL_ID}"
openclaw config set agents.defaults.timeoutSeconds 1800

openclaw config set memory.search.provider openai-compatible
openclaw config set memory.search.model "${EMB_MODEL_ID}"
openclaw config set memory.search.remote.baseUrl "http://127.0.0.1:${EMB_PORT}/v1"
openclaw config set memory.search.remote.apiKey "sk-local"
openclaw config set memory.search.fallback none

openclaw config set agents.defaults.bootstrapTotalMaxChars 8000
openclaw config set agents.defaults.experimental.localModelLean true
openclaw config set agents.defaults.compaction.mode safeguard
openclaw config set agents.defaults.compaction.keepRecentTokens "$KEEP_RECENT"
openclaw config set agents.defaults.compaction.notifyUser true
openclaw config set gateway.controlUi.sessionObserver false

openclaw --version
echo "Starting OpenClaw..."
exec openclaw gateway run --allow-unconfigured --token "my-secure-password"
