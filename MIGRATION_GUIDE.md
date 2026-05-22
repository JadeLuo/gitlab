# AI 驱动的 GitLab CI/CD 流水线 - 离线部署与培训手册

## 一、架构概览

```
┌─────────────┐    MR 事件     ┌──────────────┐    调用     ┌───────────┐
│  开发者推送   │ ────────────> │  GitLab CE    │ <─────────> │  AI 模型   │
│  代码/MR     │               │  CI/CD 引擎   │   API       │ (Ollama等) │
└─────────────┘               └──────┬───────┘              └───────────┘
                                      │
                              ┌───────┴────────┐
                              │  GitLab Runner  │
                              │  (Shell 执行器)  │
                              └───────┬────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                   │
              ┌─────┴─────┐   ┌──────┴──────┐   ┌───────┴──────┐
              │   Build    │   │ AI 代码审查  │   │  AI 自愈构建  │
              │  构建阶段   │   │  MR 触发     │   │  失败时触发   │
              └───────────┘   └─────────────┘   └──────────────┘
```

**三大核心模块：**

| 模块 | 触发条件 | 功能 |
|------|---------|------|
| Build | 每次推送/MR | 安装依赖，验证构建 |
| AI 代码审查 | MR 创建/更新 | AI 审查 Diff，评论发布到 MR |
| AI 自愈构建 | Build 失败 | AI 分析日志，生成修复补丁并提交 |

---

## 二、前置条件

| 项目 | 要求 |
|------|------|
| GitLab CE | 16.x+，已配置好 Runner 注册能力 |
| Docker | 已安装，能运行容器 |
| AI 模型服务 | OpenAI 兼容 API（Ollama / DeepSeek / OpenAI 均可） |
| 网络 | Runner 容器需能访问 GitLab API 和 AI 模型 API |
| 磁盘 | 至少 2GB（Runner 镜像 ~340MB + Python 镜像 ~150MB） |

---

## 三、离线部署步骤（6 步）

### 步骤 1：加载 Docker 镜像

```bash
docker load -i images/gitlab-runner-latest.tar
docker load -i images/python-3.11-slim.tar    # 仅 Docker executor 需要此镜像
```

### 步骤 2：创建 GitLab 项目

```bash
# 方式 A：通过 API
curl -X POST "http://YOUR-GITLAB/api/v4/projects" \
  -H "PRIVATE-TOKEN: YOUR-TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"ai-cicd-pipeline","description":"AI驱动的CI/CD流水线"}'

# 方式 B：在 GitLab Web UI 手动创建
```

### 步骤 3：配置 CI/CD 变量

在 GitLab 项目 **Settings → CI/CD → Variables** 中添加：

| 变量名 | 值 | Masked | 说明 |
|--------|-----|--------|------|
| `AI_API_KEY` | `sk-xxx` | Yes | AI 模型 API Key |
| `AI_API_URL` | `http://ai-host:3000/` | No | AI 模型 API 地址 |
| `AI_MODEL_NAME` | `llm` | No | AI 模型名称 |
| `GITLAB_ACCESS_TOKEN` | `glpat-xxx` | Yes | GitLab 访问令牌（需 api + write_repository 权限） |
| `GITLAB_URL` | `http://your-gitlab:80` | No | GitLab API 地址（Runner 容器可达） |
| `MAX_RETRY_COUNT` | `3` | No | AI 修复最大重试次数 |

**或通过 API 批量添加：**
```bash
PROJECT_ID=1
GITLAB="http://your-gitlab"
TOKEN="glpat-xxx"

for var in "AI_API_KEY:sk-xxx:true" "AI_API_URL:http://ai-host:3000/:false" \
           "AI_MODEL_NAME:llm:false" "GITLAB_ACCESS_TOKEN:glpat-xxx:true" \
           "GITLAB_URL:http://your-gitlab:80:false" "MAX_RETRY_COUNT:3:false"; do
  KEY=$(echo $var | cut -d: -f1)
  VAL=$(echo $var | cut -d: -f2)
  MASK=$(echo $var | cut -d: -f3)
  curl -s -X POST "${GITLAB}/api/v4/projects/${PROJECT_ID}/variables" \
    -H "PRIVATE-TOKEN: ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"${KEY}\",\"value\":\"${VAL}\",\"masked\":${MASK},\"variable_type\":\"env_var\"}"
  echo "  Added: ${KEY}"
done
```

### 步骤 4：推送代码

```bash
cd project/
git init
git config user.email "you@company.com"
git config user.name "Your Name"
git add -A
git commit -m "Initial commit: AI-driven CI/CD pipeline"
git remote add origin http://oauth2:YOUR-TOKEN@your-gitlab/root/ai-cicd-pipeline.git
git push -u origin master
```

### 步骤 5：部署 GitLab Runner

#### 5.1 启动 Runner 容器

```bash
# Host 网络模式（推荐，Runner 可直接访问宿主机服务）
docker run -d --name gitlab-runner --restart always \
    --network host \
    -v /srv/gitlab-runner/config:/etc/gitlab-runner \
    gitlab/gitlab-runner:latest
```

#### 5.2 注册 Runner

```bash
# 获取项目 Runner 注册 Token
# 位置：GitLab 项目 → Settings → CI/CD → Runners → Project runners → New project runner
# 或通过 API：
RUNNERS_TOKEN=$(curl -s "http://your-gitlab/api/v4/projects/1" \
    -H "PRIVATE-TOKEN: glpat-xxx" | python3 -c "import sys,json; print(json.load(sys.stdin)['runners_token'])")

# 通过 API 注册
RUNNER_TOKEN=$(curl -s -X POST "http://your-gitlab/api/v4/runners" \
    -d "token=${RUNNERS_TOKEN}" \
    -d "description=shell-runner" \
    -d "tag_list=shell,python" \
    -d "run_untagged=true" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
```

#### 5.3 安装 Runner 依赖

```bash
docker exec gitlab-runner bash -c \
    "apt-get update -qq && apt-get install -y -qq python3 python3-pip git curl && \
     pip3 install --break-system-packages requests"
```

#### 5.4 配置 Runner

```bash
# 写入配置文件
docker exec gitlab-runner bash -c 'cat > /etc/gitlab-runner/config.toml << TOML
concurrent = 2
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "shell-runner"
  url = "http://your-gitlab:80"
  clone_url = "http://your-gitlab:80"
  id = 0
  token = "RUNNER_TOKEN_HERE"
  token_obtained_at = 0001-01-01T00:00:00Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "shell"
  shell = "bash"
  [runners.cache]
    MaxUploadedArchiveSize = 0
TOML'
```

#### 5.5 处理 Git Clone URL 问题（关键！）

GitLab 的 `external_url` 可能与 Runner 实际能访问的地址不一致，导致 `git clone` 失败。

```bash
# 如果 GitLab 的 external_url 是 http://gitlab.company.com
# 但 Runner 通过 http://192.168.1.100:80 访问，需要配置 URL 重定向
docker exec gitlab-runner bash -c \
    'git config --global url."http://192.168.1.100:80/".insteadOf "http://gitlab.company.com/"'

# 确保 gitlab-runner 用户也有此配置
docker exec gitlab-runner bash -c \
    'cp /root/.gitconfig /home/gitlab-runner/.gitconfig && \
     chown gitlab-runner:gitlab-runner /home/gitlab-runner/.gitconfig'
```

#### 5.6 验证 Runner

```bash
docker exec gitlab-runner gitlab-runner verify
# 输出 "is alive" 表示连接成功
```

### 步骤 6：验证流水线

推送代码后 Pipeline 应自动触发：

```bash
# 查看 Pipeline 状态
curl -s "http://your-gitlab/api/v4/projects/1/pipelines" \
    -H "PRIVATE-TOKEN: glpat-xxx" | python3 -c "
import sys,json
for p in json.load(sys.stdin)[:3]:
    print(f'Pipeline {p[\"id\"]}: {p[\"status\"]} ({p[\"ref\"]})')
"
```

---

## 四、AI 代码审查测试

```bash
# 1. 创建特性分支
git checkout -b feature/test-review

# 2. 添加一个有代码问题的文件
cat > test_module.py << 'EOF'
import os

def process_data(data):
    result = data.split(",")  # 潜在 Bug: data 可能为 None
    for i in range(len(result)):
        result[i] = result[i].strip().lower() * 100  # 性能: 不必要的重复
    if len(result) > 10:  # 魔法数字
        return result[:10]
    return result

class DataProcessor:
    def load(self):
        os.system(self.source)  # 安全问题: 命令注入
EOF

git add -A && git commit -m "Add test module for AI review"
git push -u origin feature/test-review

# 3. 通过 API 创建 MR
curl -X POST "http://your-gitlab/api/v4/projects/1/merge_requests" \
    -H "PRIVATE-TOKEN: glpat-xxx" \
    -H "Content-Type: application/json" \
    -d '{
        "source_branch": "feature/test-review",
        "target_branch": "master",
        "title": "Test: AI Code Review"
    }'

# 4. 在 MR 页面查看 AI 审查评论
```

---

## 五、AI 自愈构建测试

```bash
# 1. 创建会构建失败的分支
git checkout -b feature/test-self-heal

# 2. 在 requirements.txt 中添加不存在的包
echo "nonexistent-package-xyz>=1.0.0" >> requirements.txt

git add -A && git commit -m "Introduce build error for self-heal test"
git push -u origin feature/test-self-heal

# 3. 构建 Job 失败后，ai-self-heal Job 自动触发
# 4. AI 分析错误日志并尝试修复
```

---

## 六、防死循环与熔断机制

```
                    构建 Job 执行
                         │
                    ┌────┴────┐
                    │ 成功？   │
                    └────┬────┘
                   否 ↓     ↓ 是
              触发 AI 自愈   结束
                   │
            ┌──────┴──────┐
            │当前 commit  │
            │包含[AI-Fix]?│
            └──────┬──────┘
             是 ↓      ↓ 否
            停止     ┌──────────┐
          (防死循环) │分支中已有 │
                    │N个[AI-Fix]?│
                    └─────┬────┘
                  N≥3 ↓    ↓ N<3
                熔断退出  AI 修复
              (不再尝试)  并提交
```

- **`[AI-Fix]` 标记**：AI 提交的 commit message 自动包含此标记，再次遇到时跳过
- **`MAX_RETRY_COUNT`**：控制最大 AI 修复次数（默认 3 次），通过查询分支 commit 历史计数

---

## 七、常见问题排查

### Q1: Runner 无法连接 GitLab

```
ERROR: Verifying runner... failed ... dial tcp: lookup gitlab on ... no such host
```

**原因**：Runner 容器无法解析 GitLab 域名
**解决**：
- 使用 `--network host` 启动 Runner
- 或配置 `clone_url` 为 Runner 可达的地址
- 或添加 `/etc/hosts` 映射

### Q2: Git clone 失败

```
fatal: http://gitlab.example.com/repo.git/info/refs not valid
```

**原因**：GitLab 的 external_url 与 Runner 实际访问地址不一致
**解决**：配置 `git config --global url."实际地址/".insteadOf "external_url/"`

### Q3: pip install 报 externally-managed-environment

```
error: externally-managed-environment
```

**原因**：Python 3.12+ 系统包保护机制
**解决**：使用 `pip3 install --break-system-packages`

### Q4: AI API 调用超时

```
HTTPConnectionPool: Max retries exceeded
```

**原因**：Runner 容器无法访问 AI API 地址
**解决**：
- 检查 AI_API_URL 是否从 Runner 容器内可达
- 如果使用 host 网络模式，确保 AI 服务监听 0.0.0.0 而非 127.0.0.1
- 如果使用 Ollama：`OLLAMA_HOST=0.0.0.0:11434 ollama serve`

### Q5: AI 审查评论未出现在 MR

**原因**：ai-code-review Job 可能失败（但 Pipeline 仍为 success，因为 allow_failure: true）
**解决**：检查 Job 日志，确认 `CI_MERGE_REQUEST_IID` 变量存在

---

## 八、切换 AI 模型

只需更新 GitLab CI/CD 变量即可，无需改代码：

| AI 服务 | AI_API_URL | AI_API_KEY | AI_MODEL_NAME |
|---------|-----------|------------|---------------|
| Ollama (本地) | `http://host:11434/` | `ollama` | `qwen2.5:7b-instruct` |
| DeepSeek | `https://api.deepseek.com/` | `sk-xxx` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/` | `sk-xxx` | `gpt-4o-mini` |
| 内网兼容 API | `http://ai-internal:3000/` | `sk-xxx` | `llm` |

**建议**：代码审查使用 7B+ 参数模型效果更好，0.5B 模型仅用于验证流程。

---

## 九、文件清单

```
ai-cicd-offline-package/
├── deploy.sh                          # 一键部署脚本
├── MIGRATION_GUIDE.md                 # 本文档
├── images/
│   ├── gitlab-runner-latest.tar       # GitLab Runner 镜像 (~340MB)
│   └── python-3.11-slim.tar           # Python 基础镜像 (~150MB，Docker executor 用)
└── project/
    ├── .gitlab-ci.yml                 # CI/CD 流水线配置
    ├── ai_review.py                   # AI 代码审查脚本
    ├── auto_fix.py                    # AI 自愈构建脚本
    ├── requirements.txt               # Python 依赖
    └── README.md                      # 项目说明
```
