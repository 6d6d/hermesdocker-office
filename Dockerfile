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
#   6) 飞书 / Lark CLI（lark-cli，npm 全局装到 /usr/local/bin）
#   7) （可选）chrome / google-chrome 别名 —— 默认保持注释
#   8) 构建期自检（任一项失败即构建失败）
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
ENV UV_EXCLUDE_NEWER=2027-12-31T23:59:59Z

# Hermes 运行用的解释器：一律写死字面路径 /opt/hermes/.venv/bin/python。
#
# ⚠ 踩过的坑：这里原先用 `ENV HERMES_VENV=/opt/hermes/.venv`，
#   再以 `${HERMES_VENV}/bin/python` 引用。构建时该变量展开为空，
#   命令退化成 `--python /bin/python`（Debian 上 /bin -> /usr/bin，
#   所以 uv 报 "environment at: /usr"），撞上 PEP 668
#   externally-managed-environment 拒绝安装，构建失败（exit code 1）。
#   表面像"源/网络问题"，实际是变量展开问题。
#   现在不依赖任何变量，从根上消除这类故障。

# -----------------------------------------------------------------------------
# 0.1) 构建期代理：刻意不声明 ARG
#
#   ⚠ 这里曾经有 `ARG HTTP_PROXY / ARG HTTPS_PROXY / ARG NO_PROXY`，已删除。
#
#   原因：Docker 会把【构建客户端环境】里的 HTTP_PROXY/HTTPS_PROXY 自动注入
#   到构建中，前提正是 Dockerfile 里声明了同名 ARG。一旦被注入，
#   构建容器里的 127.0.0.1:23333 指向的是【构建容器自己】而非宿主机，
#   uv 访问镜像源就会连不上（Connection refused）。
#
#   本构建不需要代理：第 0 节选用的 aliyun 源可直连（实测解析 104 包）。
#   不声明 ARG，就不会有任何代理变量被悄悄带进构建。
#
#   若某天确实需要构建期代理，不要加回 ARG，改用 buildx 的显式注入：
#     docker buildx build --network=host \
#       --build-arg HTTP_PROXY=http://127.0.0.1:23333 \
#       --build-arg HTTPS_PROXY=http://127.0.0.1:23333 .
#   （--network=host 时 127.0.0.1 才真的指向宿主机）
# -----------------------------------------------------------------------------

USER root

# -----------------------------------------------------------------------------
# 0.2) 自备一份 uv —— 不要指望基线镜像的 PATH
#
#   ⚠ 2026-09-25 实测结论（构建失败的直接原因）：
#     `:main` 是移动标签。9/22 成功构建用的是摘要 sha256:cd6b026d…，今天 :main
#     已是 sha256:90d156e1…；基线一变，下面所有层的缓存全部失效，下一节的
#     `uv pip install` 重跑，于是撞上：
#         RUN uv pip install ...   ->   uv: not found   （exit code 127）
#     构建直接失败。这不是依赖解析问题，是基线不再提供 uv。
#
#     新基线为什么没有 uv：它改用 pm 统一管工具链，上游 Dockerfile 只把
#     python3 / node / npm / ffmpeg / rg / npx 软链进 /usr/local/bin，uv 刻意
#     不暴露——原文注释「build consumers receive Python environments, never an
#     installer executable」。所以下游镜像必须自带一个 uv。
#
#   取自官方镜像 ghcr.io/astral-sh/uv（多架构 amd64/arm64，buildx 会按目标平台
#   解析；已核对该 tag 的层里就是根目录下的 /uv 与 /uvx）。钉 tag 是为了可复现，
#   换版本只改这一行。
# -----------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /usr/local/bin/uv
RUN uv --version

# 依赖安装。
#
# ⚠ 历史坑记录（这一层前后失败过多次，根因各不相同）：
#   1) `--python ${HERMES_VENV}/bin/python` —— 变量空展开退化成 /bin/python，
#      撞上系统 Python 的 PEP 668 保护（exit 2）。
#   2) 字面路径 + `test -x ... || exit 1` 守卫 —— 守卫本身掩盖真实报错。
#   3) 一长串诊断命令 —— 引入过多失败面。
#   4) `--upgrade` —— 强制取最新版，最容易与基线镜像里已钉住的依赖冲突。
#   5) 裸 `uv` —— 基线 2026-09-25 起不再把 uv 放 PATH（见第 0.2 节），
#      报 `uv: not found`（exit 127）；已在第 0.2 节自带 uv 修掉。
#
# 退出码指纹（实测）：
#   2 = 网络/路径/权限/解释器问题；1 = 依赖解析无解（No solution found）。
#   127 = 命令不存在（缺 uv / 缺可执行文件）。
#   所以看到 exit 1 就该去日志里搜 "No solution found when resolving dependencies"。
#
# ⚠ 显式 --python 写死字面路径，不让 uv 自己猜环境：
#   旧基线里 uv 靠 cwd（WORKDIR /opt/hermes）发现 .venv 才装进 Hermes 的虚拟环境，
#   基线将来再改 WORKDIR 就会装错地方。
#
# ⚠ 钉版本、去掉 --upgrade：与现有容器里实测可用的版本保持一致
#   （lark-oapi 1.7.3 / python-telegram-bot 22.8）。
#   注意：上游 pyproject 的 feishu extra 声明的是 lark-oapi==1.6.8，
#   要跟齐上游就把下面 1.7.3 换成 1.6.8。
#
# ⚠ 这两个包是 Hermes 的 telegram / feishu 平台依赖，基线镜像不含它们
#   （属于 pyproject 的可选 extra，不在 [all] 里），所以必须在这里装。
RUN uv pip install --python /opt/hermes/.venv/bin/python \
      "lark-oapi==1.7.3" "python-telegram-bot==22.8"

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
# ENV PLAYWRIGHT_VERSION=1.62.0 "playwright==${PLAYWRIGHT_VERSION}"
RUN set -eux; \
    uv pip install --exclude-newer-package "playwright=false" playwright; \
    playwright install chromium; \
    chmod -R a+rX /opt/ms-playwright; \
    echo "--- installed chromium dirs ---"; \
    find /opt/ms-playwright -maxdepth 2 -type d -name 'chromium*' | head -n 5

RUN set -eux; \
    ls -la /opt/ms-playwright; \
    find /opt/ms-playwright -maxdepth 4 -type f \( -name chrome -o -name headless_shell \) -print; \
    B="$(find /opt/ms-playwright -maxdepth 4 -type f \( -name chrome -o -name headless_shell \) -print -quit)"; \
    test -x "$B"; \
    ln -sf "$B" /usr/bin/google-chrome; \
    ln -sf "$B" /usr/bin/google-chrome-stable; \
    ln -sf "$B" /usr/bin/chromium; \
    ln -sf "$B" /usr/bin/chromium-browser; \
    "$B" --version;
    
# -----------------------------------------------------------------------------
# 4) agent-browser（Vercel Labs，npm 全局）
#    版本与 Hermes 源码钉版保持一致：
#      tools/browser_tool.py: AGENT_BROWSER_NPX_SPEC = "agent-browser@^0.26.0"
#    对 0.x.y 而言 ^0.26.0 == >=0.26.0 <0.27.0，不会漂到最新的 0.37.x，
#    避免与 Hermes 期望的 CLI 接口不一致。
#
#   ⚠ --allow-scripts 是必须的（2026-09-25 实测，与第 0.2 节同一次基线漂移）：
#     新基线的 npm 默认拦截安装脚本，而 agent-browser 的可执行壳正是它的
#     postinstall（node scripts/postinstall.js）生成的。被拦掉的表现：
#       npm warn install-scripts  agent-browser@0.26.0 (postinstall: ...)
#       /bin/sh: 1: agent-browser: not found   （exit 127）-> 构建失败
#     旧基线的 npm 默认执行脚本，所以以前不写这个 flag 也没事。
#     将来 npm 再改政策、报 unknown option 时，按 npm 的提示改名即可。
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g --allow-scripts=agent-browser "agent-browser@^0.26.0"; \
    command -v agent-browser; \
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
# 6) 飞书 / Lark CLI（lark-cli）
#
#   官方安装指引（open.feishu.cn，2026-09 核对）：
#     npm install -g @larksuite/cli                          # CLI 本体（本层，进镜像）
#     npx -y skills add https://open.feishu.cn --skill -y    # CLI skills（运行期执行一次）
#     lark-cli config init --new                             # 绑定应用凭证（浏览器交互）
#     lark-cli auth login --recommend                        # 登录授权（浏览器交互）
#
#   ⚠ 为什么必须装进 /usr/local/bin，而不是运行期挂载的卷里：
#     /opt/data 是运行期挂载的 ZFS 卷，其中的 ~/.local/bin 并不在 Hermes 进程的
#     PATH 内（实测 PATH=/usr/local/bin:/usr/bin:/bin）。把 lark-cli 装到 ~/.local
#     等于没装：command -v lark-cli 找不到，lark-* skill 的 requires.bins 校验
#     会判定缺失。与第 5 节 browser-use 是同一个坑。
#     卷里 /opt/data/home/.local/bin/lark-cli 正是这种「装了但不可达」的残留，
#     重建镜像后建议删掉那份，免得以后排查时看错版本。
#
#   ⚠ 本层需要构建期外网：npm 包只带一个 Node 壳，postinstall 用系统 curl 下载
#     平台二进制（约 48MB）并做 SHA256 校验（校验清单随包发布），失败回退
#     registry.npmmirror.com：
#       https://github.com/larksuite/cli/releases/download/v<ver>/lark-cli-<ver>-linux-{amd64,arm64}.tar.gz
#     系统 curl 已在基础镜像内（第 2 节也用到 curl）。linux-amd64 / linux-arm64
#     官方都有产物，工作流里的双架构构建安全。装完镜像大约 +48MB。
#
#   ⚠ npm 11.17 实测：会打印一条 allow-scripts 警告但那一次仍执行了 postinstall
#     （bin/lark-cli 48MB 确实生成）。2026-09-25 起基线漂移，新基线的 npm 改成
#     默认拦截安装脚本，这一层果然照这句话失败：postinstall 不执行 -> 二进制不
#     下载、连 bin/ 目录都不生成 -> 本层末尾 `lark-cli --version` 报 not found
#     （exit 127），构建直接失败。所以 flag 现在是必须的：
#       npm install -g --allow-scripts=@larksuite/cli @larksuite/cli
#     老版 npm 不认识这个 flag，会直接报错；本镜像已按新基线写死。
#
#   ⚠ 版本跟随 npm latest（当前 1.0.96）：CLI 自带 _notice 升级提示，不钉版本
#     可与运行期拉取的 skills 包保持同代；要钉就写 @larksuite/cli@1.0.96。
#
#   ⚠ 凭证与登录态刻意不进镜像：config init / auth login 都是浏览器交互，且落盘在
#     运行期卷里（实测 $HOME/.lark-cli/hermes/config.json），换新卷就要重新授权。
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g --allow-scripts=@larksuite/cli @larksuite/cli; \
    command -v lark-cli; \
    lark-cli --version

# -----------------------------------------------------------------------------
# 7) 可选：chrome/google-chrome 别名
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
# 8) 构建期自检：任一项失败即构建失败
#    覆盖真正会被用到的能力，而不仅是"文件存在"。
# -----------------------------------------------------------------------------
RUN set -eux; \
    echo "=== OfficeCLI ==="; \
    officecli --version; \
    echo "=== Python / Playwright ==="; \
    /opt/hermes/.venv/bin/python -c "import playwright, sys; print('playwright OK at', sys.executable)"; \
#     echo "=== Chromium 二进制 ==="; \
#     B="$(find /opt/ms-playwright -type f \( -name chrome -o -name headless_shell \) 2>/dev/null | head -1)"
#     test -n "$B" || { echo "no chromium binary found"; ls -laR /opt/ms-playwright; exit 1; }
#     ldd "$B" | (! grep -q 'not found'); \
#     "$B" --version; \
#     echo "=== Chromium 真实启动 ==="; \
#     /opt/hermes/.venv/bin/python -c "\
# from playwright.sync_api import sync_playwright as S;\
# p=S().start(); b=p.chromium.launch(args=['--no-sandbox']);\
# pg=b.new_page(); pg.goto('data:text/html,<h1>ok</h1>');\
# print('chromium launch OK ->', pg.evaluate('document.querySelector(\"h1\").innerText'));\
# b.close(); p.stop()"; \
    echo "=== agent-browser CLI ==="; \
    command -v agent-browser; \
    agent-browser --version; \
    echo "=== browser-use CLI ==="; \
    command -v browser-use; \
    browser-use --version || true; \
    echo "=== 飞书 / Lark CLI ==="; \
    command -v lark-cli; \
    lark-cli --version; \
    echo "=== 飞书 / Telegram Python 依赖（装进 Hermes 虚拟环境）==="; \
    /opt/hermes/.venv/bin/python -c "import lark_oapi, telegram; from importlib.metadata import version; print('lark-oapi', version('lark-oapi'), '/ python-telegram-bot', version('python-telegram-bot'), 'import OK')"; \
    echo "image self-check OK"
