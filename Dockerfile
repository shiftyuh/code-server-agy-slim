FROM debian:13-slim

ARG TARGETARCH=amd64
ARG CODE_SERVER_VERSION=4.145.2
ARG TTYD_VERSION=1.7.7
ARG AGY_RELEASE_BASE_URL=https://antigravity-cli-auto-updater-974169037036.us-central1.run.app

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    SHELL=/usr/bin/zsh \
    JAVA_TOOL_OPTIONS="-Xmx512m"

# 1. 基础运行依赖 + Python 3 + OpenJDK 21 (无图形界面精简版)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      git \
      sudo \
      gosu \
      dbus \
      gnome-keyring \
      zsh \
      tmux \
      bubblewrap \
      procps \
      unzip \
      xz-utils \
      nodejs \
      python3 \
      python3-pip \
      python3-venv \
      openjdk-21-jdk-headless && \
    rm -rf /var/lib/apt/lists/*

# 2. 创建兼容 1Panel / LinuxServer 契约的 abc 用户
RUN groupadd -g 1000 abc && \
    useradd -u 1000 -g abc -d /config -s /usr/bin/zsh -M abc && \
    echo "abc ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/abc && \
    chmod 0440 /etc/sudoers.d/abc && \
    mkdir -p /config /etc/skel

# 3. 安装官方 coder/code-server
RUN curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz" -o /tmp/code-server.tar.gz && \
    mkdir -p /opt/code-server && \
    tar -xzf /tmp/code-server.tar.gz --strip-components=1 -C /opt/code-server && \
    ln -sf /opt/code-server/bin/code-server /usr/local/bin/code-server && \
    rm -f /tmp/code-server.tar.gz

# 4. 安装 ttyd（按架构自动匹配并校验 SHA256）
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) ttyd_arch="x86_64" ;; \
      arm64) ttyd_arch="aarch64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" -o /tmp/ttyd; \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/SHA256SUMS" -o /tmp/ttyd.sha256; \
    expected_sha="$(grep "ttyd.${ttyd_arch}$" /tmp/ttyd.sha256 | awk '{print $1}')"; \
    echo "${expected_sha}  /tmp/ttyd" | sha256sum -c -; \
    install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
    rm -f /tmp/ttyd /tmp/ttyd.sha256

# 5. 安装官方 Antigravity CLI (agy) 并生成兼容更新的包装脚本
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64|arm64) agy_arch="${TARGETARCH}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    manifest="$(curl -fsSL "${AGY_RELEASE_BASE_URL}/manifests/linux_${agy_arch}.json")"; \
    agy_url="$(printf '%s' "${manifest}" | jq -r '.url')"; \
    agy_sha512="$(printf '%s' "${manifest}" | jq -r '.sha512')"; \
    curl -fsSL "${agy_url}" -o /tmp/agy.tar.gz; \
    echo "${agy_sha512}  /tmp/agy.tar.gz" | sha512sum -c -; \
    mkdir -p /tmp/agy-extract /opt/antigravity; \
    tar -xzf /tmp/agy.tar.gz -C /tmp/agy-extract; \
    agy_bin="$(find /tmp/agy-extract -type f -name antigravity | head -n 1)"; \
    install -m 0755 "${agy_bin}" /opt/antigravity/agy; \
    rm -rf /tmp/agy.tar.gz /tmp/agy-extract; \
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'if [ -x /config/.gemini/bin/agy ]; then' \
      '  exec /config/.gemini/bin/agy "$@"' \
      'fi' \
      'exec /opt/antigravity/agy "$@"' \
      > /usr/local/bin/agy; \
    chmod 0755 /usr/local/bin/agy; \
    HOME=/tmp /usr/local/bin/agy --version

# 6. 复制上游 Scluzlep/code-server-tools 的 Antigravity 补丁与启动脚本
COPY upstream/scripts/code-server-entrypoint.sh /usr/local/bin/code-server-entrypoint
COPY upstream/scripts/launch-code-server.sh /usr/local/bin/launch-code-server
COPY upstream/scripts/agyshell.sh /usr/local/bin/agyshell
COPY upstream/scripts/agyshell.tmux.conf /etc/agyshell.tmux.conf
COPY upstream/scripts/agy-webui /usr/local/share/agy-webui
COPY upstream/scripts/agy-console.cjs /usr/local/lib/agy-console.cjs
COPY upstream/scripts/patch-antigravity-proxy.cjs /usr/local/lib/patch-antigravity-proxy.cjs
COPY upstream/scripts/patch-agy-routes.cjs /usr/local/lib/patch-agy-routes.cjs
COPY upstream/scripts/p10k.zsh /etc/skel/.p10k.zsh

# 提供极简无依赖的默认 .zshrc（不装 Oh My Zsh 以节省空间）
RUN printf '%s\n' \
      'export PATH="/config/.gemini/bin:/usr/local/bin:$PATH"' \
      'HISTFILE=/config/.zsh_history' \
      'HISTSIZE=5000' \
      'SAVEHIST=5000' \
      'setopt SHARE_HISTORY HIST_IGNORE_DUPS' \
      'PROMPT="%F{cyan}%n@code-server%f:%F{yellow}%~%f$ "' \
      > /etc/skel/.zshrc && \
    chmod 0755 /usr/local/bin/code-server-entrypoint \
               /usr/local/bin/launch-code-server \
               /usr/local/bin/agyshell

# 7. 给 code-server 打上 Antigravity 代理与 /agy/ 路由补丁
RUN node /usr/local/lib/patch-antigravity-proxy.cjs && \
    node /usr/local/lib/patch-agy-routes.cjs && \
    HOME=/tmp /usr/local/bin/agyshell --check && \
    bwrap --version

EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/code-server-entrypoint"]
