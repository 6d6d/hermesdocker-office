FROM nousresearch/hermes-agent:latest                                                                                                                               
USER root                                                                                                                                                           
# 官方安装脚本会在检测到 ~/.hermes 后一并下载 OfficeCLI 的 Hermes skill。                                                                                           
# 后续将二进制放入系统 PATH，并把 skill 放进 Hermes 内置技能目录，                                                                                                  
# 容器启动时 Hermes 会同步它到 /opt/data/skills。                                                                                                                   
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
      /root/.local /root/.hermes                                                                                                                                    
RUN officecli --version
