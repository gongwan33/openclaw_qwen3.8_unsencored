sudo docker run -d \
  --name openclaw3.8-agent \
  --gpus all \
  -v /home/gongwan33/Documents/openclaw_shared_workspace/models:/models \
  -v /home/gongwan33/Documents/openclaw_qwen3.8/entrypoint.sh:/app/entrypoint.sh \
  -v /media/veracrypt1/openclaw_shared_workspace:/root/.openclaw/workspace
  -p 8080:8080 \
  -p 18789:18789 \
  openclaw-qwen3.8-uncensored
