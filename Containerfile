# One file, two images: `agent` (opensnitchd + pi) and `ui` (opensnitch-ui). See compose.yaml.

# OpenSnitch: latest upstream release, checked against the SHA-256 digests GitHub publishes
FROM registry.fedoraproject.org/fedora:44 AS opensnitch
RUN dnf -y install jq && dnf clean all
RUN set -eu; mkdir /rpms; \
    curl -fsSL https://api.github.com/repos/evilsocket/opensnitch/releases/latest -o /tmp/release.json; \
    for re in '^opensnitch-[0-9.]+-1\.x86_64\.rpm$' '^opensnitch-ui-[0-9.]+-1\.noarch\.rpm$'; do \
      read -r name url digest < <(jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | "\(.name) \(.browser_download_url) \(.digest)"' /tmp/release.json); \
      [[ "$digest" == sha256:* ]]; \
      curl -fsSLo "/rpms/$name" "$url"; \
      echo "${digest#sha256:}  /rpms/$name" | sha256sum -c -; \
    done


FROM registry.fedoraproject.org/fedora:44 AS agent
ARG PI_VERSION=1.1.0
RUN dnf -y install nodejs npm git curl jq ripgrep fd-find findutils procps-ng iproute nftables util-linux \
      libnetfilter_queue libnfnetlink info python3 \
 && dnf clean all
# without scriptlets: the daemon's %post runs `systemctl start`, and there is no systemd here
RUN --mount=type=bind,from=opensnitch,source=/rpms,target=/rpms rpm -i --noscripts /rpms/opensnitch-[0-9]*.rpm
RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" && npm cache clean --force
COPY opensnitch/default-config.json /etc/opensnitchd/default-config.json
COPY opensnitch/rules/ /etc/opensnitchd/rules/
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
