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
MODEL_OUTPUT=$(( MODEL_CONTEXT / 4 < 32768 ? MODEL_CONTEXT / 4 : 32768 ))
MODEL_URL="http://169.254.1.3:$MODEL_PORT/v1"
BUILTIN=/usr/share/agent-box/rules
RULES=/etc/opensnitchd/rules   # a volume: rules you answer "always" to are kept here

# built-in rules, refreshed on every start
cp "$BUILTIN"/*.json "$RULES/"
sed "s/@MODEL_PORT@/$MODEL_PORT/" "$BUILTIN/002-allow-model.json.in" > "$RULES/002-allow-model.json"
if [[ "${ALLOW_DNS:-0}" == 1 ]]; then
  resolvers=$(awk '$1 == "nameserver" {printf "%s%s", sep, $2; sep="|"}' /etc/resolv.conf)
  jq --arg re "^(${resolvers//./\\.})\$" '.operator.list[0].data = $re' \
    "$BUILTIN/003-allow-dns.json.in" > "$RULES/003-allow-dns.json"
else
  rm -f "$RULES/003-allow-dns.json"
fi

# every box shares the ui container's network: a second daemon couldn't bind queue 0, yet the first
# one's firewall rules would pass the check below, and would vanish when that box exits
if awk '$1 == 0 {found = 1} END {exit !found}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
  echo "agent-box: another agent-box is already running (only one at a time)" >&2; exit 1
fi

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

# agent configs for the OpenAI-compatible model server on the host's 127.0.0.1:$MODEL_PORT
AGENT_HOME=/home/agent
mkdir -p "$AGENT_HOME/.pi/agent" "$AGENT_HOME/.config/opencode" "$AGENT_HOME/.dsh" "$AGENT_HOME/.dsh-tui"
# dsh-tui's first-run guide asks for an API key and a model, both already set up here
echo '{"completed": true, "version": 1}' > "$AGENT_HOME/.dsh-tui/onboarding.json"
if [[ -n "$MODEL_ID" ]]; then
  jq -n --arg url "$MODEL_URL" --arg key "${MODEL_API_KEY:-none}" --arg id "$MODEL_ID" \
    --argjson ctx "$MODEL_CONTEXT" --argjson out "$MODEL_OUTPUT" \
    '{providers: {local: {baseUrl: $url, api: "openai-completions", apiKey: $key,
      models: [{id: $id, contextWindow: $ctx, maxTokens: $out, reasoning: true}]}}}' \
    > "$AGENT_HOME/.pi/agent/models.json"
  jq -n --arg url "$MODEL_URL" --arg key "${MODEL_API_KEY:-none}" --arg id "$MODEL_ID" \
    --argjson ctx "$MODEL_CONTEXT" --argjson out "$MODEL_OUTPUT" \
    '{"$schema": "https://opencode.ai/config.json",
      providers: {local: {name: "local", package: "@opencode/ai/providers/openai-compatible",
        settings: {baseURL: $url, apiKey: $key},
        models: {model: {modelID: $id, name: $id,
          capabilities: {tools: true, input: ["text"], output: ["text"]},
          limit: {context: $ctx, output: $out}}}}},
      model: "local/model"}' \
    > "$AGENT_HOME/.config/opencode/opencode.json"
  # dsh reads its key only from an environment variable (JSON is valid YAML).
  # Effort levels map to the OpenAI `reasoning_effort` parameter ("off" sends "none").
  jq -n --arg url "$MODEL_URL" --arg id "$MODEL_ID" \
    --argjson ctx "$MODEL_CONTEXT" --argjson out "$MODEL_OUTPUT" \
    '[{id: "llm-pi-ai", config: {providers: {local: {displayName: "local", apiKeyEnv: "LOCAL_MODEL_API_KEY",
        api: "openai-completions", baseURL: $url, compat: {supportsReasoningEffort: true},
        models: [{id: $id, name: $id, contextWindow: $ctx, maxTokens: $out,
          reasoningEfforts: {off: "none", low: "low", medium: "medium", high: "high"}}]}}}},
      {id: "agent-default-model", config: {provider: "local", model: $id, reasoningEffort: "medium"}}]' \
    > "$AGENT_HOME/.dsh/cordis.patch.yml"
fi
# dsh's plugin profiles come with the image: their node_modules stay root-owned and read-only
find "$AGENT_HOME" -path "$AGENT_HOME/.dsh/profiles/*/node_modules" -prune -o -exec chown -h "$HOST_UID:$HOST_GID" {} +
chmod 700 "$AGENT_HOME"

agent_env=()
case "${1:-}" in
  pi|opencode|dsh)
    if [[ -z "$MODEL_ID" ]]; then
      echo "agent-box: set MODEL_ID to the model name your server on 127.0.0.1:$MODEL_PORT serves" >&2; exit 1
    fi
    [[ "$*" == pi ]] && set -- pi --model "local/$MODEL_ID"
    [[ "$*" == dsh ]] && set -- dsh dsh-tui
    [[ "$1" == dsh ]] && agent_env=(LOCAL_MODEL_API_KEY="${MODEL_API_KEY:-none}")
    ;;
esac

cd "$WORKDIR"
exec setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --clear-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs \
  env -u MODEL_API_KEY HOME="$AGENT_HOME" "${agent_env[@]}" \
    OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 DSH_TELEMETRY_DISABLED=1 "$@"
