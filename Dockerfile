# Hermes Agent + OfficeCLI + agent-browser + Playwright (Python)
#
# 构建上下文里需要有本 Dockerfile：
#   docker build -t hermes-cloak .
#
# 相对上游镜像 nousresearch/hermes-agent:main 的改动：
#   1) apt 依赖：原版 libssl3 在 Debian 13 trixie 里叫 libssl3t64，
#      并补齐 Chromium 无头运行库
#   2) OfficeCLI 安装段（原样保留）
#   3) Playwright（Python）安装 + 全局浏览器路径（关键：hermes 用户要能读）
#   4) agent-browser（Vercel Labs，npm 全局）
#   5) 构建期自检

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
# 3) Playwright（Python）+ 共享浏览器路径
#    ⚠ PLAYWRIGHT_BROWSERS_PATH 是关键：
#      默认装到 /root/.cache/ms-playwright，运行时 hermes 用户读不到，
#      会报 "Executable doesn't exist"。
#      固定到 /opt/ms-playwright 并放开读/执行权限。
#    ⚠ 用 uv pip install 与第 2 行保持同一 Python 环境，
#      别改成系统 pip，否则 Hermes 里 import playwright 会找不到。
# ---------------------------------------------------------------------------
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN set -eux; \
    uv pip install playwright; \
    playwright install --with-deps chromium; \
    chmod -R a+rX /opt/ms-playwright; \
    echo "--- installed chromium dirs ---"; \
    find /opt/ms-playwright -maxdepth 2 -type d -name 'chromium*' | head -n 5


# ---------------------------------------------------------------------------
# 构建期自检：任一项失败即构建失败
# ---------------------------------------------------------------------------
RUN set -eux; \
    officecli --version; \
    python -c "import playwright; print('playwright OK')"; \
    ls -d /opt/ms-playwright/chromium* >/dev/null; \
    echo "image self-check OK"
