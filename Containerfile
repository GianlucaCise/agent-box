# One file, two images: `agent` (opensnitchd + pi + OpenCode + dsh) and `ui` (opensnitch-ui). See compose.yaml.

# OpenSnitch: latest upstream release, checked against the SHA-256 digests GitHub publishes.
# An optional `gh_token` build secret avoids the GitHub API's anonymous rate limit in CI.
FROM registry.fedoraproject.org/fedora:44 AS opensnitch
RUN dnf -y install jq && dnf clean all
RUN --mount=type=secret,id=gh_token set -eu; mkdir /rpms; \
    auth=(); [[ -s /run/secrets/gh_token ]] && auth=(-H "Authorization: Bearer $(cat /run/secrets/gh_token)"); \
    curl -fsSL "${auth[@]}" https://api.github.com/repos/evilsocket/opensnitch/releases/latest -o /tmp/release.json; \
    for re in '^opensnitch-[0-9.]+-1\.x86_64\.rpm$' '^opensnitch-ui-[0-9.]+-1\.noarch\.rpm$'; do \
      read -r name url digest < <(jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | "\(.name) \(.browser_download_url) \(.digest)"' /tmp/release.json); \
      [[ "$digest" == sha256:* ]]; \
      curl -fsSLo "/rpms/$name" "$url"; \
      echo "${digest#sha256:}  /rpms/$name" | sha256sum -c -; \
    done


FROM registry.fedoraproject.org/fedora:44 AS agent
ARG PI_VERSION=1.1.0
ARG OPENCODE_VERSION=2.0.30
ARG DSH_VERSION=0.2.0-rc.2
RUN dnf -y install nodejs npm git curl jq ripgrep fd-find findutils procps-ng iproute nftables util-linux \
      libnetfilter_queue libnfnetlink info python3 \
 && dnf clean all
# without scriptlets: the daemon's %post runs `systemctl start`, and there is no systemd here
RUN --mount=type=bind,from=opensnitch,source=/rpms,target=/rpms rpm -i --noscripts /rpms/opensnitch-[0-9]*.rpm
# npm pulls every x64 build of the OpenCode binary (~200 MB each); its postinstall keeps one in bin/.
# dsh ships node-pty prebuilds for macOS and Windows too.
RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" "@opencode/cli@${OPENCODE_VERSION}" \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
 && rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-* \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty/prebuilds/darwin-* \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty/prebuilds/win32-* \
 && opencode --version && dsh --version && npm cache clean --force
# dsh's interactive front ends are third-party plugins, each in its own profile (installed with pnpm).
# dsh-tui asks npm for a newer version on every start, with no switch to turn it off: skip that check.
ARG PNPM_VERSION=12.15.0
ARG DSH_TUI_VERSION=0.17.0
ARG DSHLINE_VERSION=0.26.1
RUN npm install -g "pnpm@${PNPM_VERSION}" \
 && export DSH_HOME=/home/agent/.dsh DSH_TELEMETRY_DISABLED=1 \
 && dsh plugin --profile dsh-tui add "@deepseek-harness-tui/dsh-tui@${DSH_TUI_VERSION}" \
 && dsh plugin --profile dshline add "@dshline/dshline@${DSHLINE_VERSION}" \
 && f=$DSH_HOME/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui/lib/types/update.js \
 && sed -i 's|^export async function checkForTuiUpdate() {$|&\n    return undefined; // agent-box: no update check on start|' "$f" \
 && grep -q 'agent-box: no update check' "$f" \
 && chmod -R a+rX "$DSH_HOME" && rm -rf /root/.cache /root/.local/share/pnpm && npm cache clean --force
COPY opensnitch/default-config.json /etc/opensnitchd/default-config.json
# built-in rules are (re)installed by the entrypoint on every start, next to the persisted ones
COPY opensnitch/rules/ /usr/share/agent-box/rules/
RUN cp /etc/opensnitchd/rules/000-allow-localhost*.json /usr/share/agent-box/rules/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pi"]


FROM registry.fedoraproject.org/fedora:44 AS ui
# the UI rpm doesn't declare its python deps (upstream expects pip)
RUN --mount=type=bind,from=opensnitch,source=/rpms,target=/rpms \
    dnf -y install /rpms/opensnitch-ui-*.rpm python3-grpcio python3-protobuf python3-slugify python3-notify2 \
      qt6-qtwayland dejavu-sans-fonts \
 && dnf clean all
COPY ui-entrypoint.sh /usr/local/bin/ui-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/ui-entrypoint.sh"]
