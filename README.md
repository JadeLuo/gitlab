# AI 驱动的 GitLab CI/CD 离线部署包

基于 GitLab CI/CD 的 AI 智能代码审查与自愈构建系统，专为内网 GitLab CE 环境的离线部署场景设计。

## 功能概览

| 功能 | 触发条件 | 说明 |
|------|----------|------|
| AI 智能代码审查 | 创建/更新 Merge Request | 自动获取 MR Diff，AI 审查后发布为 MR 评论 |
| AI 自愈构建 | 构建 Job 失败 | 解析构建错误日志，AI 生成修复方案并自动推送 |
| 防死循环 | AI 修复提交 | `[AI-Fix]` 标记检测，避免 AI 反复修复同一问题 |
| 熔断机制 | AI 修复次数达上限 | `MAX_RETRY_COUNT` 控制最大重试次数，防止无限循环 |

## 架构

```
  开发者                GitLab CI/CD              AI 模型
    │                       │                       │
    │── 推送代码 ──────────>│                       │
    │                       │── build ─────────────>│
    │                       │                       │
    │                       │  (构建成功)             │
    │                       │── AI 代码审查 ────────>│
    │<────── MR 评论 ───────│<──── 审查结果 ─────────│
    │                       │                       │
    │                       │  (构建失败)             │
    │                       │── AI 自愈构建 ────────>│
    │                       │<──── 修复方案 ─────────│
    │                       │── 自动提交修复 ───────>│
```

## 目录结构

```
ai-cicd-offline-package/
├── deploy.sh               # 一键部署脚本（6 步自动化）
├── images/                 # Docker 镜像离线包
│   ├── gitlab-runner-latest.tar    # GitLab Runner 镜像
│   └── python-3.11-slim.tar       # Python 3.11 Slim 镜像
├── project/                # 推送到 GitLab 的项目代码
│   ├── .gitlab-ci.yml     # CI/CD 流水线定义（3 阶段）
│   ├── ai_review.py       # AI 代码审查脚本
│   ├── auto_fix.py        # AI 自愈构建脚本
│   └── requirements.txt   # Python 依赖
├── tests/
│   └── dry_run_deploy.sh  # 空运行测试脚本（无副作用验证部署流程）
└── MIGRATION_GUIDE.md     # 详细部署与迁移指南
```

## 快速开始

### 前置条件

- GitLab CE 16.x+（内网环境）
- Docker 已安装
- OpenAI 兼容的 AI API 服务（Ollama / DeepSeek / 自建 API）
- 至少 2GB 可用磁盘空间

### 一键部署

```bash
# 1. 解压离线部署包
tar xzf ai-cicd-offline-package.tar.gz
cd ai-cicd-offline-package

# 2. 配置环境变量（根据实际环境修改）
export GITLAB_URL="http://your-gitlab:80"
export GITLAB_TOKEN="glpat-your-token-here"
export AI_API_URL="http://your-ai-api:3000/"
export AI_API_KEY="sk-your-api-key"
export AI_MODEL_NAME="llm"

# 3. 执行部署脚本
bash deploy.sh
```

部署脚本会自动完成以下 6 个步骤：

1. 加载 Docker 镜像（gitlab-runner、python:3.11-slim）
2. 创建 GitLab 项目
3. 配置 CI/CD 变量（6 个，含敏感信息遮罩）
4. 推送项目代码到 GitLab
5. 部署 GitLab Runner（Shell 执行器，Host 网络模式）
6. 验证部署结果

### 手动部署

如需逐步操作或自定义配置，请参考 [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md)。

## 环境变量配置

在 GitLab **Settings → CI/CD → Variables** 中配置（`deploy.sh` 会自动设置）：

| 变量名 | 说明 | 是否遮罩 | 默认值 |
|--------|------|----------|--------|
| `AI_API_KEY` | AI 模型 API Key | 是 | `sk-your-api-key` |
| `AI_API_URL` | AI 模型 API 地址 | 是 | `http://your-ai-api:3000/` |
| `AI_MODEL_NAME` | AI 模型名称 | 否 | `llm` |
| `GITLAB_ACCESS_TOKEN` | GitLab 访问令牌 | 是 | — |
| `MAX_RETRY_COUNT` | AI 修复最大重试次数 | 否 | `3` |
| `GITLAB_URL` | GitLab 服务地址 | 是 | — |

## 流水线阶段

项目包含 3 个 CI/CD 阶段：

| 阶段 | Job | 触发条件 | 说明 |
|------|-----|----------|------|
| `build` | `build` | 每次推送 | 安装依赖、验证构建 |
| `review` | `ai-code-review` | Merge Request 事件 | AI 审查 MR 代码变更 |
| `self-heal` | `ai-self-heal` | 构建 Job 失败时 | AI 分析错误并自动修复 |

## AI 模型切换

支持任意 OpenAI 兼容的 API，常用配置：

| AI 服务 | `AI_API_URL` | `AI_MODEL_NAME` |
|---------|-------------|-----------------|
| Ollama | `http://ollaba-host:11434/v1/` | `qwen2.5-coder:7b` |
| DeepSeek | `https://api.deepseek.com/v1/` | `deepseek-coder` |
| OpenAI | `https://api.openai.com/v1/` | `gpt-4o` |
| 自建 API | `http://your-api:3000/` | 自定义 |

建议使用 7B+ 参数量的代码模型以获得较好效果。

## 测试验证

### 空运行测试

无需真实 GitLab 环境，使用 mock 命令验证部署流程：

```bash
bash tests/dry_run_deploy.sh
```

### AI 代码审查测试

1. 创建特性分支并推送包含代码变更的 MR
2. 观察 MR 中是否出现 AI 审查评论

### AI 自愈构建测试

1. 在 `requirements.txt` 中添加一个不存在的包
2. 推送代码触发构建失败
3. 观察 `ai-self-heal` Job 是否自动修复并推送

## 下载

离线部署包及 Docker 镜像可从 [GitHub Release v1.0.0](https://github.com/JadeLuo/gitlab/releases/tag/v1.0.0) 下载：

| 文件 | 说明 |
|------|------|
| [ai-cicd-offline-package.tar.gz](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/ai-cicd-offline-package.tar.gz) | 完整离线部署包（含镜像、部署脚本、项目文件） |
| [gitlab-runner-latest.tar](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/gitlab-runner-latest.tar) | GitLab Runner Docker 镜像 |
| [python-3.11-slim.tar](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/python-3.11-slim.tar) | Python 3.11 Slim Docker 镜像 |

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| Runner 无法连接 GitLab | 检查 `GITLAB_URL` 从 Runner 容器内是否可达 |
| git clone 失败 | 检查 `GITLAB_URL` 与 GitLab `external_url` 是否一致 |
| AI API 超时 | 检查网络连通性，或增大 AI 模型超时时间 |
| MR 中无 AI 评论 | 确认 `GITLAB_ACCESS_TOKEN` 有 `api` 权限 |
| pip 报 externally-managed-environment | 已在 Runner 中使用 `--break-system-packages` 参数 |

更多问题排查请参考 [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md) 中的故障排除章节。

## 许可证

MIT License
