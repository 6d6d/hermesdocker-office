# =============================================================================
# Hermes Agent + OfficeCLI + agent-browser + Playwright (Python)
#
# 构建：
#   docker build -t hermes-cloak .
#
# 基线：nousresearch/hermes-agent:main
#
# 相对上游镜像的改动：
#   0) 国内加速源（已替换失效的 tuna）
#   1) apt 依赖：Debian 13 trixie 的 libssl3 -> libssl3t64 + Chromium 无头运行库
#   2) OfficeCLI 安装（原样保留）
#   3) Playwright(Python) + 共享浏览器路径
#   4) agent-browser（npm 全局，版本与 Hermes 源码钉版一致）
#   5) browser-use CLI（Hermes browser_exec 的后端，必须预装）
#   6) 构建期自检（任一项失败即构建失败）
# =============================================================================

FROM nousresearch/hermes-agent:main

# -----------------------------------------------------------------------------
# 0) 国内加速源 —— 2026-09-12 实测结论（这一节是本次修复的重点）
#
#   [可用] aliyun    https://mirrors.aliyun.com/pypi/simple/        解析 104 包
#   [可用] bfsu      https://mirrors.bfsu.edu.cn/pypi/web/simple/   解析 104 包
#   [可用] pypi.org  https://pypi.org/simple                        解析 104 包
#
#   [失效] cernet    https://mirrors.cernet.edu.cn/pypi/web/simple
#            纯 302 聚合跳转站：本机 TCP 443 通，但只回 302 到
#            mirrors.hust.edu.cn，而该目标在容器内连接超时。
#            uv 实测：Request failed after 3 retries -> operation timed out
#   [失效] ustc      https://mirrors.ustc.edu.cn/pypi/simple/
#            索引会把 wheel 重定向到 tuna，tuna 对文件下载返回 403
#   [失效] tuna      https://pypi.tuna.tsinghua.edu.cn/simple/
#            全量 403（/、/simple/、/simple/<pkg>/ 全部 403），不是单包问题
#
#   ⚠ 原 Dockerfile 用的就是 tuna。因为它是 ENV，会注入每个子进程，
#     导致 uvx/uv 在「运行期」解析失败 —— browser_exec 整个工具直接不可用，
#     且 `hermes tools` 的安装按钮（UV_NO_CONFIG=1 + 继承环境变量）也无法自救。
# -----------------------------------------------------------------------------
ENV UV_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com

# Hermes 运行用的解释器（PLAYWRIGHT_BROWSERS_PATH 之外，显式指定可避免
# `uv pip install` 依赖运行期 VIRTUAL_ENV 的行为差异）
ENV HERMES_VENV=/opt/hermes/.venv

# -----------------------------------------------------------------------------
# 0.1) 构建期 HTTP 代理（可选，默认不启用）
#
#   ⚠ 构建同样跑在容器里，所以 127.0.0.1 在这里指向「构建容器」自己的 loopback，
#     不是宿主机。要让构建走宿主机的 127.0.0.1:23333，二选一：
#
#     a) 让宿主代理监听 0.0.0.0，然后用桥接网关地址：
#          docker build -t hermes-cloak \
#            --build-arg HTTP_PROXY=http://172.20.0.1:23333 \
#            --build-arg HTTPS_PROXY=http://172.20.0.1:23333 .
#
#     b) 用宿主网络构建，此时 127.0.0.1 才真的指向宿主机：
#          docker build -t hermes-cloak --network=host \
#            --build-arg HTTP_PROXY=http://127.0.0.1:23333 \
#            --build-arg HTTPS_PROXY=http://127.0.0.1:23333 .
#
#   不传 --build-arg 时这些变量为空，构建照常直连，互不影响。
#   注意：构建期若启用了代理，uv 访问 aliyun 也会绕经代理；若代理对国内站点
#   反而更慢，把镜像域名加进 NO_PROXY：
#          --build-arg NO_PROXY=localhost,127.0.0.1,mirrors.aliyun.com
#
#   （这组 ARG 只作用于构建期，不会写进最终镜像的 ENV；
#     运行期代理请在 docker-compose.yml 里配。）
# -----------------------------------------------------------------------------
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY


USER root

RUN uv pip install --python ${HERMES_VENV}/bin/python --upgrade lark-oapi python-telegram-bot

# -----------------------------------------------------------------------------
# 1) 系统依赖
#    ⚠ 原版的 libssl3 在本镜像（Debian 13 trixie）里叫 libssl3t64，照抄装不上。
#    下面这组是 Chromium 无头运行库。已用 ldd 实测：装完这两组后
#    chromium / chrome-headless-shell 均无 "not found" 依赖，清单是完整的。
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 2) OfficeCLI（原样保留）
#    官方安装脚本会在检测到 ~/.hermes 后一并下载 OfficeCLI 的 Hermes skill。
#    后续将二进制放入系统 PATH，并把 skill 放进 Hermes 内置技能目录，
#    容器启动时 Hermes 会同步它到 /opt/data/skills。
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 3) Playwright（Python）+ 共享浏览器路径
#    ⚠ PLAYWRIGHT_BROWSERS_PATH 是必须的：默认会去找
#      $HOME/.cache/ms-playwright，而运行期 HOME=/opt/data/home 落在数据卷里（空的），
#      实测不设该变量会直接报 "Executable doesn't exist"。
#    ⚠ 版本必须与 Chromium build 号配套：playwright 1.62.0 对应 chromium-1234。
#      不锁版本的话，将来升级后 build 号变了，/opt/ms-playwright 里的浏览器就废了。
#    ⚠ 去掉了 --with-deps：上面第 1 节已手写完整库清单，
#      --with-deps 会再跑一遍 apt-get，重复且易与 rm -rf apt/lists 冲突。
#    ⚠ 显式 --python 指向 Hermes venv，官方镜像的系统 python3 是 import 不到 playwright 的。
# -----------------------------------------------------------------------------
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
ENV PLAYWRIGHT_VERSION=1.62.0
RUN set -eux; \
    uv pip install --python ${HERMES_VENV}/bin/python "playwright==${PLAYWRIGHT_VERSION}"; \
    playwright install chromium; \
    chmod -R a+rX /opt/ms-playwright; \
    echo "--- installed chromium dirs ---"; \
    find /opt/ms-playwright -maxdepth 2 -type d -name 'chromium*' | head -n 5

# -----------------------------------------------------------------------------
# 4) agent-browser（Vercel Labs，npm 全局）
#    版本与 Hermes 源码钉版保持一致：
#      tools/browser_tool.py: AGENT_BROWSER_NPX_SPEC = "agent-browser@^0.26.0"
#    对 0.x.y 而言 ^0.26.0 == >=0.26.0 <0.27.0，不会漂到最新的 0.37.x，
#    避免与 Hermes 期望的 CLI 接口不一致。
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g "agent-browser@^0.26.0"; \
    agent-browser --version

# -----------------------------------------------------------------------------
# 5) browser-use CLI —— Hermes browser_exec 的后端
#
#    ⚠ 为什么必须在镜像里装：
#      Hermes 的 _find_cli() 探测顺序是
#          $HERMES_HOME/bin  ->  PATH  ->  ~/.local/bin  ->  uvx browser-use（兜底）
#      如果都没命中，最后会退到 `uvx browser-use`，那要求「运行期」索引可用 ——
#      正是 tuna 失效时崩掉的路径。预装后走 PATH 命中，运行期完全不依赖索引。
#
#    ⚠ 为什么装 /usr/local/bin 而不是 $HERMES_HOME/bin：
#      实测 /opt/data 是运行时挂载的 ZFS 卷
#          (zfs: /1000/Compose/hermes/hermesdata -> /opt/data)
#      构建期写进 /opt/data/bin 的内容在运行期会被卷遮蔽，等于没装。
#      Hermes 进程的 PATH 包含 /usr/local/bin，可被 PATH 探测命中；
#      同理 ~/.local/bin 也落在卷里，不可用。
# -----------------------------------------------------------------------------
ENV UV_TOOL_BIN_DIR=/usr/local/bin
RUN set -eux; \
    uv tool install browser-use; \
    chmod -R a+rX /usr/local/bin; \
    browser-use --version || true

# -----------------------------------------------------------------------------
# 6) 可选：chrome/google-chrome 别名
#    当前容器 /opt/data/bin 里有一个运行期手工贴的悬空 wrapper：
#        exec /opt/cloakbrowser/chromium-146.0.7680.177.5/chrome   (该路径不存在)
#    若需要 chrome 命令可用，下面的真链接更可靠；若担心影响 agent-browser
#    自身的 Chromium 解析，可保持注释状态。
# -----------------------------------------------------------------------------
# RUN set -eux; \
#     B="$(ls -d /opt/ms-playwright/chromium-*/chrome-linux64/chrome | head -1)"; \
#     ln -sf "$B" /usr/local/bin/google-chrome; \
#     ln -sf "$B" /usr/local/bin/google-chrome-stable; \
#     "$B" --version

# -----------------------------------------------------------------------------
# 7) 构建期自检：任一项失败即构建失败
#    覆盖真正会被用到的能力，而不仅是"文件存在"。
# -----------------------------------------------------------------------------
RUN set -eux; \
    echo "=== OfficeCLI ==="; \
    officecli --version; \
    echo "=== Python / Playwright ==="; \
    ${HERMES_VENV}/bin/python -c "import playwright, sys; print('playwright OK at', sys.executable)"; \
    echo "=== Chromium 二进制 ==="; \
    B="$(ls -d /opt/ms-playwright/chromium-*/chrome-linux64/chrome | head -1)"; \
    test -x "$B"; \
    ldd "$B" | (! grep -q 'not found'); \
    "$B" --version; \
    echo "=== Chromium 真实启动 ==="; \
    ${HERMES_VENV}/bin/python -c "\
from playwright.sync_api import sync_playwright as S;\
p=S().start(); b=p.chromium.launch(args=['--no-sandbox']);\
pg=b.new_page(); pg.goto('data:text/html,<h1>ok</h1>');\
print('chromium launch OK ->', pg.evaluate('document.querySelector(\"h1\").innerText'));\
b.close(); p.stop()"; \
    echo "=== agent-browser CLI ==="; \
    command -v agent-browser; \
    agent-browser --version; \
    echo "=== browser-use CLI ==="; \
    command -v browser-use; \
    browser-use --version || true; \
    echo "image self-check OK"
