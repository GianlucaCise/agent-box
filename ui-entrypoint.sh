#!/bin/bash
# Runs as the host user (keep-id). Prompts default to: deny, after 30s, "once".
set -euo pipefail

export HOME=/tmp/home XDG_RUNTIME_DIR=/tmp/xdg QT_QPA_PLATFORM=wayland
mkdir -p "$HOME/.config/opensnitch" && mkdir -p -m 700 "$XDG_RUNTIME_DIR"

if [[ ! -S /tmp/wayland-0 ]]; then
  echo "agent-box ui: no Wayland socket mounted (is WAYLAND_DISPLAY set on the host?)" >&2
  exit 1
fi
export WAYLAND_DISPLAY=/tmp/wayland-0

cat > "$HOME/.config/opensnitch/settings.conf" <<'EOF'
[global]
default_action=0
default_timeout=30
default_duration=0
EOF

exec opensnitch-ui --socket 127.0.0.1:50051
