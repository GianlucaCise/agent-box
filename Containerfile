# One file, two images: `agent` (opensnitchd + pi + OpenCode) and `ui` (opensnitch-ui). See compose.yaml.

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
RUN dnf -y install nodejs npm git curl jq ripgrep fd-find findutils procps-ng iproute nftables util-linux \
      libnetfilter_queue libnfnetlink info python3 \
 && dnf clean all
# without scriptlets: the daemon's %post runs `systemctl start`, and there is no systemd here
RUN --mount=type=bind,from=opensnitch,source=/rpms,target=/rpms rpm -i --noscripts /rpms/opensnitch-[0-9]*.rpm
# npm pulls every x64 build of the OpenCode binary (~200 MB each); its postinstall keeps one in bin/
RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" "@opencode/cli@${OPENCODE_VERSION}" \
 && rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-* \
 && opencode --version && npm cache clean --force
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
