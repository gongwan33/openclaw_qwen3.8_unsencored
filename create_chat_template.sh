set -e

TEMPLATE_URL="http://127.0.0.1:8080/props"
TEMPLATE_FILE="/home/gongwan33/Documents/openclaw_shared_workspace/models/qwen3.8-openclaw.jinja"
API_KEY="sk-local"

# Extract the complete embedded template.
curl -fsS \
  -H "Authorization: Bearer ${API_KEY}" \
  "$TEMPLATE_URL" |
python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["chat_template"], end="")
' > "${TEMPLATE_FILE}.original"

# Patch the exact assertion that is causing HTTP 500.
python3 - "${TEMPLATE_FILE}.original" "$TEMPLATE_FILE" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
old = """{%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- raise_exception('System message must be at the beginning.') }}
        {%- endif %}"""

new = """{%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}
        {%- endif %}"""

count = source.count(old)
if count != 1:
    sys.exit(
        f"Expected exactly one matching assertion, found {count}. "
        "No patched template written."
    )

pathlib.Path(sys.argv[2]).write_text(source.replace(old, new, 1))
print(f"Patched template written to {sys.argv[2]}")
PY

# Verify that the failing assertion is gone.
if grep -Fq "System message must be at the beginning." "$TEMPLATE_FILE"; then
  echo "ERROR: original assertion remains"
  exit 1
fi

echo "Template ready: $TEMPLATE_FILE"
