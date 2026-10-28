#!/bin/bash
# Runs as root inside the container: start the OpenSnitch daemon, then drop to the
# unprivileged host-mapped user (no capabilities, no_new_privs) to run the agent.
set -euo pipefail

# the agent runs as whoever owns the mounted project folder, the working dir (your user, thanks to keep-id)
WORKDIR=$PWD
HOST_UID=$(stat -c %u "$WORKDIR") HOST_GID=$(stat -c %g "$WORKDIR")
if [[ "$HOST_UID" == 0 ]]; then
  echo "agent-box: $WORKDIR is owned by root, refusing to run the agent as root" >&2; exit 1
fi
MODEL_PORT=${MODEL_PORT:-8080}
MODEL_ID=${MODEL_ID:-}
MODEL_CONTEXT=${MODEL_CONTEXT:-32768}
RULES=/etc/opensnitchd/rules

sed "s/@MODEL_PORT@/$MODEL_PORT/" "$RULES/002-allow-model.json.in" > "$RULES/002-allow-model.json"
rm "$RULES/002-allow-model.json.in"

opensnitchd -config-file /etc/opensnitchd/default-config.json -rules-path "$RULES" -log-file /var/log/opensnitchd.log &

# fail closed: don't start the agent unless the daemon's queue rule is in place
queue_rule_in_place() { [[ "$(nft list chain inet opensnitch mangle_output 2>/dev/null)" == *"syn queue to"* ]]; }
for _ in $(seq 50); do
  queue_rule_in_place && break
  sleep 0.2
done
if ! queue_rule_in_place; then
  echo "agent-box: opensnitchd did not install its firewall rules" >&2
  tail -20 /var/log/opensnitchd.log >&2 || true
  exit 1
fi

# pi config for the OpenAI-compatible model server on the host's 127.0.0.1:$MODEL_PORT
AGENT_HOME=/home/agent
mkdir -p "$AGENT_HOME/.pi/agent"
if [[ -n "$MODEL_ID" ]]; then
  jq -n --arg url "http://169.254.1.3:$MODEL_PORT/v1" --arg key "${MODEL_API_KEY:-none}" --arg id "$MODEL_ID" \
    --argjson ctx "$MODEL_CONTEXT" \
    '{providers: {local: {baseUrl: $url, api: "openai-completions", apiKey: $key,
      models: [{id: $id, contextWindow: $ctx, maxTokens: ([$ctx / 4, 32768] | min | floor), reasoning: true}]}}}' \
    > "$AGENT_HOME/.pi/agent/models.json"
fi
chown -R "$HOST_UID:$HOST_GID" "$AGENT_HOME"
chmod 700 "$AGENT_HOME"

if [[ "$*" == pi ]]; then
  if [[ -z "$MODEL_ID" ]]; then
    echo "agent-box: set MODEL_ID to the model name your server on 127.0.0.1:$MODEL_PORT serves" >&2; exit 1
  fi
  set -- pi --model "local/$MODEL_ID"
fi

cd "$WORKDIR"
exec setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --clear-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs \
  env -u MODEL_API_KEY HOME="$AGENT_HOME" "$@"
