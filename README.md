# hermesdocker-office

基于官方 Hermes Docker（`nousresearch/hermes-agent:main`）追加：OfficeCLI、Playwright + Chromium、
agent-browser、browser-use，以及**飞书 / Lark 命令行工具**。

- 镜像：`ghcr.io/6d6d/hermes-officecli`
- 构建：推 `main` 后由 `.github/workflows/build-image.yml` 自动构建（`linux/amd64` + `linux/arm64`，每 3 天一次定时重建）
- 本地构建：`docker build -t hermes-officecli .`

Office 文档处理仅使用 OfficeCLI，镜像不安装 LibreOffice 或旧版 Office 格式转换备用环境。构建自检会检查 LibreOffice 软件包、命令和标准安装目录，发现后即终止构建；OfficeCLI 所需的系统库、字体和浏览器保留。

## 镜像里已装好的命令行工具

| 命令 | 来源 | 说明 |
|---|---|---|
| `officecli` | iOfficeAI/OfficeCLI | Office 文档处理 |
| `agent-browser` | Vercel Labs | 版本与 Hermes 源码钉版一致（^0.26.0） |
| `browser-use` | browser-use | Hermes `browser_exec` 的后端 |
| `lark-cli` | `npm i -g @larksuite/cli` | 飞书 / Lark CLI |
| `uv` | `ghcr.io/astral-sh/uv:0.11.6` | 基线镜像自 2026-09-25 起不再提供 uv，镜像自备一份 |

所有命令都装在 `/usr/local/bin`（镜像层、在 PATH 上）。**不要**装到 `/opt/data/home/.local`：
`~/.local/bin` 不在 Hermes 进程的 PATH 内，装了也 `command -v` 不到。

## 镜像里预装的 Python 依赖（装进 Hermes 的虚拟环境）

Hermes 的平台与记忆依赖不在基线镜像里（属于 `pyproject.toml` 的可选 extra，`[all]` 不含），
所以在这里预装并钉版本：

- `lark-oapi==1.7.3`、`python-telegram-bot==22.8` —— 飞书 / Telegram 平台依赖
- `mem0ai==2.0.10` —— Mem0 记忆 provider（`hermes memory setup` 选 mem0）；随包带入
  `qdrant-client`，「进程内 / OSS」模式的本地向量库（`$HERMES_HOME/mem0_qdrant`）开箱可用，
  不需要另起 Qdrant 服务

装法是 `uv pip install --python /opt/hermes/.venv/bin/python ...`：显式指向 Hermes 的虚拟环境，
不让 uv 猜。版本跟随 Hermes 源码钉的值（`tools/lazy_deps.py`），不要自行升级。

要用 Ollama 当 LLM / embedder 的话，还得补装 pip 包 `ollama`（镜像里没有 Ollama 本体）。

## 换新数据卷时要补的一步

skills 包和授权凭证都是运行期内容（且授权需要浏览器交互），刻意不烤进镜像，也不受镜像更新影响。
容器起来后在容器内各执行一次即可：

```bash
# 飞书 / Lark —— 28 个 lark-* skills
npx -y skills add https://open.feishu.cn --skill -y
lark-cli config init --new            # 绑定应用凭证（浏览器交互）
lark-cli auth login --recommend       # 登录授权（浏览器交互）
lark-cli auth status
```

以上命令在 skill 目录里只是软链（`~/.agents/skills` → `$HERMES_HOME/skills`），
凭证落盘在数据卷内，容器重建不会丢：

- 飞书：`$HOME/.lark-cli/hermes/config.json`

> 旧的运行期安装残留（`/opt/data/home/.local/bin/lark-cli`）建议删掉，
> 它不在 PATH 上、只是排查时容易看错版本。

## 构建缓存与最终清理

- uv 的三处依赖安装都使用命令级 `UV_NO_CACHE=1`，下载使用临时缓存并自动回收；运行期的缓存策略不变。
- npm 安装使用专用目录 `/tmp/hermes-build-npm`，每次安装完成后在同一个 `RUN` 中删除。
- 最后一段 `RUN` 先完成自检，再清理 apt 下载文件和索引、root 下的 uv/pip/Go 编译缓存及 npm 缓存，以及列明的安装临时文件、Node 编译缓存和 Playwright 临时目录。自检与清理在同一层，避免自检缓存进入镜像。
- OfficeCLI、Office 文档处理依赖、Python 虚拟环境、已安装的工具和浏览器保留。

Docker 镜像逐层保存文件，只在末尾删除前面层的缓存无法缩小前面的层，因此安装步骤本身也要避免留下缓存。此清理不访问 `/opt/data`，不会清理已有数据卷里的 Go 缓存、npx 工具、项目 `node_modules` 或 Hermes 管理的依赖环境；这些属于运行期数据。
