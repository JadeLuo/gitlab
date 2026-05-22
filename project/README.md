# AI 驱动的智能 CI/CD 流水线

基于 GitLab CI/CD 的 AI 智能代码审查与自愈构建系统。

## 功能模块

### 1. AI 智能代码审查 (ai_review.py)
- MR 创建/更新时自动触发
- 获取 MR Diff 并发送给 AI 审查
- 审查结果自动发布为 MR 评论

### 2. AI 自愈构建 (auto_fix.py)
- 构建失败时自动触发 (`when: on_failure`)
- 解析构建日志，AI 生成修复方案
- 自动提交修复代码并推送
- 防死循环：`[AI-Fix]` 标记检测
- 熔断机制：`MAX_RETRY_COUNT` 控制最大重试次数

## 下载

离线部署包及 Docker 镜像可从 [GitHub Release v1.0.0](https://github.com/JadeLuo/gitlab/releases/tag/v1.0.0) 下载：

| 文件 | 说明 |
|------|------|
| [ai-cicd-offline-package.tar.gz](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/ai-cicd-offline-package.tar.gz) | 完整离线部署包（含镜像、部署脚本、项目文件） |
| [gitlab-runner-latest.tar](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/gitlab-runner-latest.tar) | GitLab Runner Docker 镜像 |
| [python-3.11-slim.tar](https://github.com/JadeLuo/gitlab/releases/download/v1.0.0/python-3.11-slim.tar) | Python 3.11 Slim Docker 镜像 |

## 环境变量配置

在 GitLab **Settings -> CI/CD -> Variables** 中配置：

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `AI_API_KEY` | AI 模型 API Key | `sk-xxx` |
| `AI_API_URL` | AI 模型 API 地址 | `http://172.16.2.133:3000/` |
| `AI_MODEL_NAME` | AI 模型名称 | `llm` |
| `GITLAB_ACCESS_TOKEN` | GitLab 访问令牌 | `glpat-xxx` |
| `MAX_RETRY_COUNT` | AI 修复最大重试次数 | `3` |
