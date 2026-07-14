FROM nousresearch/hermes-agent:latest
ENV UV_INDEX_URL=https://tsinghua.edu.cn
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0
# 1. 切换回 root 仅用于需要高权限的工具安装
USER root
RUN set -eux; \
  # 下载并执行 OfficeCLI 安装脚本
  curl -fsSL --retry 3 --retry-all-errors \
    https://githubusercontent.com \
    -o /tmp/install-officecli.sh; \
  bash /tmp/install-officecli.sh; \
  # 将二进制放入全局系统路径
  install -m 0755 /root/.local/bin/officecli /usr/local/bin/officecli; \
  # 清理 root 的临时垃圾，但【不要】破坏标准的 hermes 技能路径权限
  rm -rf /tmp/install-officecli.sh /tmp/officecli /tmp/officecli-SHA256SUMS; \
  rm -rf /root/.local
# 2. ！！！非常关键：切回 Hermes 镜像默认的非 root 用户（假设为 hermes）
# 如果不知道默认用户名，可以不写 USER，但必须在下方通过 chown 修复权限
USER hermes

# 3. 推荐在容器启动后，或者通过非 root 用户来安全初始化技能
RUN officecli --version

# 如果必须要放进 /opt/hermes/skills，请确保它的拥有者不是 root：
USER root
RUN mkdir -p /opt/hermes/skills/officecli && cp /root/.hermes/skills/officecli/SKILL.md /opt/hermes/skills/officecli/
RUN chown -R hermes:hermes /opt/hermes/skills/
