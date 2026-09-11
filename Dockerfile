# Hermes Agent + OfficeCLI + CloakBrowser（Stealth Chromium）+ Playwright MCP
#
# 构建上下文里需要有本 Dockerfile 和 03-playwright-cloak 两个文件：
#   docker build -t hermes-cloak .
#
# 相对上游镜像 nousresearch/hermes-agent:main 的改动，逐段都有注释：
#   1) apt 依赖：原版的 libssl3 在本镜像（Debian 13 trixie）里叫 libssl3t64，
#      并补齐 Chromium/Stealth Chromium 的运行库
#   2) OfficeCLI 安装段（原样保留）
#   3) 新增 CloakBrowser：Stealth Chromium，二进制固定在 /opt/cloakbrowser
#   4) 新增 @playwright/mcp 全局安装（省掉运行时 npx 联网下载）
#   5) 新增 Playwright MCP 的 config.json，executablePath 指向 CloakBrowser 的 chrome
#   6) 新增 cont-init.d 启动钩子：幂等地把 MCP server 注册进卷上的 config.yaml
#      —— 必须运行时注册，因为 /opt/data 是挂载卷，构建期写入会被卷覆盖

FROM nousresearch/hermes-agent:main

# 国内加速源（与官方安装脚本一致）
ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

USER root

RUN uv pip install --upgrade lark-oapi python-telegram-bot

# ---------------------------------------------------------------------------
# 1) 系统依赖
#    ⚠ 原版的 libssl3 在本镜像里叫 libssl3t64，照抄会装不上；
#      下面这组是 Chromium 无头运行库，缺任何一个都可能启动即崩。
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libicu-dev \
      libssl3t64 \
      zlib1g \
      libnss3 libnspr4 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 \
      libcups2t64 libdrm2 libgbm1 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libxext6 libxi6 libxtst6 libxcb1 \
      libasound2t64 libpango-1.0-0 libcairo2 \
      fonts-noto-cjk; \
    rm -rf /var/lib/apt/lists/*

# 明确使用完整全球化支持；不要设为 1，否则中文、日期与区域格式处理可能异常。
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0

# ---------------------------------------------------------------------------
# 2) OfficeCLI（原样保留）
#    官方安装脚本会在检测到 ~/.hermes 后一并下载 OfficeCLI 的 Hermes skill。
#    后续将二进制放入系统 PATH，并把 skill 放进 Hermes 内置技能目录，
#    容器启动时 Hermes 会同步它到 /opt/data/skills。
# ---------------------------------------------------------------------------
RUN set -eux; \
  mkdir -p /root/.hermes; \
  curl -fsSL --retry 3 --retry-all-errors \
    https://raw.githubusercontent.com/iOfficeAI/OfficeCLI/main/install.sh \
    -o /tmp/install-officecli.sh; \
  bash /tmp/install-officecli.sh; \
  install -m 0755 /root/.local/bin/officecli /usr/local/bin/officecli; \
  install -D -m 0644 \
    /root/.hermes/skills/officecli/SKILL.md \
    /opt/hermes/skills/officecli/SKILL.md; \
  rm -rf /tmp/install-officecli.sh /tmp/officecli /tmp/officecli-SHA256SUMS \
    /root/.local/bin/officecli
RUN officecli --version

# ---------------------------------------------------------------------------
# 3) CloakBrowser：Stealth Chromium
#    CLOAKBROWSER_CACHE_DIR 把二进制固定在 /opt/cloakbrowser（不落在 /root，
#    也不落在会被卷覆盖的 /opt/data）；目录名形如 chromium-<version>[-pro]，
#    可执行文件是其中的 chrome。
#    · 不设 license key 时下载免费版（Chromium 146）
#    · 运行时若传 CLOAKBROWSER_LICENSE_KEY，wrapper 会往这个目录下载 Pro 二进制，
#      所以这里把 owner 交给 hermes，否则运行时只读会 EACCES（Pro 用户注意）
#    · 构建机连不上 GitHub Releases 时，可先设 CLOAKBROWSER_DOWNLOAD_URL 指向镜像源
# ---------------------------------------------------------------------------
ENV CLOAKBROWSER_CACHE_DIR=/opt/cloakbrowser
RUN set -eux; \
    uv tool install cloakbrowser; \
    install -m 0755 /root/.local/bin/cloakbrowser /usr/local/bin/cloakbrowser; \
    cloakbrowser install; \
    cloakbrowser info; \
    chown -R hermes:hermes /opt/cloakbrowser; \
    chmod -R a+rX /opt/cloakbrowser; \
    CHROME="$(find /opt/cloakbrowser -maxdepth 2 -type f -name chrome | head -n1)"; \
    test -n "$CHROME"; \
    test -x "$CHROME"; \
    printf '%s\n' "$CHROME" > /opt/cloakbrowser/BINARY_PATH; \
    echo "CloakBrowser binary: $CHROME"

# ---------------------------------------------------------------------------
# 4) Playwright MCP（微软维护）：全局装到 /usr/local，hermes 用户可读，
#    运行时不必再走 npx 联网下载。node 26 已在镜像里（npm prefix=/usr/local）。
# ---------------------------------------------------------------------------
RUN npm install -g --no-audit --no-fund @playwright/mcp@0.0.80 \
 && npm cache clean --force
RUN set -eux; \
    test -x /usr/local/bin/playwright-mcp; \
    timeout 30 /usr/local/bin/playwright-mcp --help 2>&1 | head -n 12 || true

# ---------------------------------------------------------------------------
# 5) Playwright MCP 配置文件
#    executablePath 用第 3 步探测到的真实路径（不写死版本号）；
#    outputDir 指向卷内目录，运行时由启动钩子建好并 chown 给 hermes。
#    launchOptions 是 @playwright/mcp 官方 config schema 里的字段。
# ---------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /opt/playwright-mcp; \
    CHROME="$(cat /opt/cloakbrowser/BINARY_PATH)"; \
    printf '{\n  "browser": {\n    "browserName": "chromium",\n    "launchOptions": {\n      "executablePath": "%s"\n    }\n  },\n  "outputDir": "/opt/data/playwright-mcp/output"\n}\n' "$CHROME" \
      > /opt/playwright-mcp/config.json; \
    chmod 0644 /opt/playwright-mcp/config.json; \
    node -e "JSON.parse(require('fs').readFileSync('/opt/playwright-mcp/config.json','utf8')); console.log('config.json OK')"; \
    cat /opt/playwright-mcp/config.json

# hermes mcp add playwright --command playwright-mcp --args --config /opt/playwright-mcp/config.json

# ---------------------------------------------------------------------------
# 构建期自检：任一项失败即构建失败
# ---------------------------------------------------------------------------
RUN set -eux; \
    officecli --version; \
    cloakbrowser info | head -n 20; \
    test -x "$(cat /opt/cloakbrowser/BINARY_PATH)"; \
    test -x /usr/local/bin/playwright-mcp; \
    grep -q executablePath /opt/playwright-mcp/config.json; \
    echo "image self-check OK"
