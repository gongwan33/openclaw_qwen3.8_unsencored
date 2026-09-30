# Use NVIDIA CUDA base image for hardware acceleration
FROM nvidia/cuda:12.2.2-devel-ubuntu22.04

# Prevent interactive prompts during apt installations
ENV DEBIAN_FRONTEND=noninteractive

# Install core dependencies, Python, and Node.js (required for OpenClaw)
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    cmake \
    python3 \
    python3-pip \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Hugging Face CLI to handle GGUF downloads
RUN pip3 install -U "huggingface_hub[cli]"

# Point the linker to the CUDA compatibility stubs during build
ENV LD_LIBRARY_PATH=/usr/local/cuda/compat:$LD_LIBRARY_PATH

# Build llama.cpp server with CUDA support
WORKDIR /opt/llama.cpp
RUN git clone https://github.com/ggerganov/llama.cpp . \
    && cmake -B build -DGGML_CUDA=ON \
    && cmake --build build --config Release -j$(nproc)

# Install OpenClaw globally via npm
RUN npm install -g openclaw clawhub

# Set up the application directory
WORKDIR /app
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose llama.cpp API port and any potential OpenClaw web UI port
EXPOSE 8080 18789

ENTRYPOINT ["/app/entrypoint.sh"]
