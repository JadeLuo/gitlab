#!/bin/bash
# ============================================================
# AI 驱动的 GitLab CI/CD 流水线 - 离线部署脚本
# 适用场景：内网 GitLab CE 环境离线部署
# ============================================================

set -e

# ==================== 配置区域 ====================
# 请根据实际环境修改以下变量
GITLAB_URL="${GITLAB_URL:-http://your-gitlab:80}"
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-your-token-here}"
AI_API_URL="${AI_API_URL:-http://your-ai-api:3000/}"
AI_API_KEY="${AI_API_KEY:-sk-your-api-key}"
AI_MODEL_NAME="${AI_MODEL_NAME:-llm}"
PROJECT_NAME="${PROJECT_NAME:-ai-cicd-pipeline}"
RUNNER_CONCURRENT="${RUNNER_CONCURRENT:-2}"
MAX_RETRY_COUNT="${MAX_RETRY_COUNT:-3}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "================================================"
echo " AI CI/CD Pipeline 离线部署脚本"
echo "================================================"
echo "GitLab URL:      $GITLAB_URL"
echo "AI API URL:      $AI_API_URL"
echo "AI Model:        $AI_MODEL_NAME"
echo "Project Name:    $PROJECT_NAME"
echo "================================================"

# ==================== 步骤 1: 加载 Docker 镜像 ====================
echo ""
echo "[步骤 1/6] 加载 Docker 镜像..."

if [ -f "$SCRIPT_DIR/images/gitlab-runner-latest.tar" ]; then
    docker load -i "$SCRIPT_DIR/images/gitlab-runner-latest.tar"
    echo "  gitlab-runner 镜像加载完成"
else
    echo "  [WARN] gitlab-runner-latest.tar 不存在，跳过"
fi

if [ -f "$SCRIPT_DIR/images/python-3.11-slim.tar" ]; then
    docker load -i "$SCRIPT_DIR/images/python-3.11-slim.tar"
    echo "  python:3.11-slim 镜像加载完成"
else
    echo "  [WARN] python-3.11-slim.tar 不存在，跳过"
fi

# ==================== 步骤 2: 创建 GitLab 项目 ====================
echo ""
echo "[步骤 2/6] 创建 GitLab 项目..."

PROJECT_RESULT=$(curl -s -X POST "${GITLAB_URL}/api/v4/projects" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${PROJECT_NAME}\",
        \"description\": \"AI 驱动的智能 CI/CD 流水线\",
        \"visibility\": \"private\",
        \"initialize_with_readme\": false
    }")

PROJECT_ID=$(echo "$PROJECT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','ERROR'))" 2>/dev/null || echo "ERROR")

if [ "$PROJECT_ID" = "ERROR" ] || [ -z "$PROJECT_ID" ]; then
    echo "  [ERROR] 项目创建失败，请检查 GITLAB_URL 和 GITLAB_TOKEN"
    echo "  响应: $PROJECT_RESULT"
    exit 1
fi
echo "  项目创建成功! ID: $PROJECT_ID"

# ==================== 步骤 3: 配置 CI/CD 变量 ====================
echo ""
echo "[步骤 3/6] 配置 CI/CD 变量..."

add_var() {
    local key=$1 value=$2 masked=${3:-false}
    local result
    result=$(curl -s -X POST "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${key}\",\"value\":\"${value}\",\"masked\":${masked},\"variable_type\":\"env_var\"}")
    local status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'key' in d else d.get('message','FAIL'))" 2>/dev/null || echo "FAIL")
    echo "  ${key}: ${status}"
}

add_var "AI_API_KEY" "$AI_API_KEY" true
add_var "AI_API_URL" "$AI_API_URL"
add_var "AI_MODEL_NAME" "$AI_MODEL_NAME"
add_var "GITLAB_ACCESS_TOKEN" "$GITLAB_TOKEN" true
add_var "MAX_RETRY_COUNT" "$MAX_RETRY_COUNT"
add_var "GITLAB_URL" "$GITLAB_URL"

# ==================== 步骤 4: 推送代码到项目 ====================
echo ""
echo "[步骤 4/6] 推送项目代码..."

# 从 API 获取 clone URL
CLONE_URL=$(echo "$PROJECT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('http_url_to_repo',''))" 2>/dev/null)

# 在 URL 中注入 token
if echo "$CLONE_URL" | grep -q "://"; then
    AUTH_URL=$(echo "$CLONE_URL" | sed "s|://|://oauth2:${GITLAB_TOKEN}@|")
else
    AUTH_URL="${GITLAB_URL}/root/${PROJECT_NAME}.git"
    AUTH_URL=$(echo "$AUTH_URL" | sed "s|://|://oauth2:${GITLAB_TOKEN}@|")
fi

TMP_DIR=$(mktemp -d)
cp -r "$SCRIPT_DIR/project/"* "$TMP_DIR/"
cd "$TMP_DIR"
git init
git config user.email "deployer@local"
git config user.name "Deployer"
git add -A
git commit -m "Initial commit: AI-driven CI/CD pipeline"
git remote add origin "$AUTH_URL"
git push -u origin master

echo "  代码推送完成!"
cd "$SCRIPT_DIR"
rm -rf "$TMP_DIR"

# ==================== 步骤 5: 启动 GitLab Runner ====================
echo ""
echo "[步骤 5/6] 部署 GitLab Runner..."

# 获取 Runner 注册 token
RUNNERS_TOKEN=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('runners_token',''))" 2>/dev/null)

if [ -z "$RUNNERS_TOKEN" ]; then
    echo "  [ERROR] 无法获取 Runner 注册 Token"
    exit 1
fi
echo "  Runner 注册 Token: ${RUNNERS_TOKEN:0:10}..."

# 注册 Runner（通过 API）
RUNNER_RESULT=$(curl -s -X POST "${GITLAB_URL}/api/v4/runners" \
    -d "token=${RUNNERS_TOKEN}" \
    -d "description=shell-runner" \
    -d "tag_list=shell,python" \
    -d "run_untagged=true")

RUNNER_TOKEN=$(echo "$RUNNER_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token','ERROR'))" 2>/dev/null || echo "ERROR")

if [ "$RUNNER_TOKEN" = "ERROR" ] || [ -z "$RUNNER_TOKEN" ]; then
    echo "  [ERROR] Runner 注册失败"
    echo "  响应: $RUNNER_RESULT"
    exit 1
fi
echo "  Runner 注册成功! Token: ${RUNNER_TOKEN:0:10}..."

# 启动 Runner 容器（host 网络模式）
docker rm -f gitlab-runner 2>/dev/null || true
docker run -d --name gitlab-runner --restart always \
    --network host \
    -v /srv/gitlab-runner/config:/etc/gitlab-runner \
    gitlab/gitlab-runner:latest

echo "  Runner 容器启动完成"

# 在 Runner 容器中安装依赖
echo "  安装 Runner 容器依赖..."
docker exec gitlab-runner bash -c "apt-get update -qq && apt-get install -y -qq python3 python3-pip git curl > /dev/null 2>&1"
docker exec gitlab-runner pip3 install --break-system-packages requests

# 配置 Runner
echo "  配置 Runner..."
docker exec gitlab-runner bash -c "cat > /etc/gitlab-runner/config.toml << 'TOML'
concurrent = ${RUNNER_CONCURRENT}
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = \"shell-runner\"
  url = \"${GITLAB_URL}\"
  clone_url = \"${GITLAB_URL}\"
  id = 0
  token = \"${RUNNER_TOKEN}\"
  token_obtained_at = 0001-01-01T00:00:00Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = \"shell\"
  shell = \"bash\"
  [runners.cache]
    MaxUploadedArchiveSize = 0
TOML"

# 配置 git insteadOf（处理 GitLab external_url 与实际访问地址不一致的问题）
GITLAB_HOST=$(echo "$GITLAB_URL" | python3 -c "import sys; from urllib.parse import urlparse; u=urlparse(sys.stdin.read().strip()); print(u.hostname)" 2>/dev/null)
if [ -n "$GITLAB_HOST" ] && [ "$GITLAB_HOST" != "localhost" ] && [ "$GITLAB_HOST" != "127.0.0.1" ]; then
    docker exec gitlab-runner bash -c "git config --global url.\"${GITLAB_URL}/\".insteadOf \"http://${GITLAB_HOST}/\""
    docker exec gitlab-runner bash -c "cp /root/.gitconfig /home/gitlab-runner/.gitconfig 2>/dev/null; chown gitlab-runner:gitlab-runner /home/gitlab-runner/.gitconfig 2>/dev/null"
    echo "  已配置 git URL 重定向: http://${GITLAB_HOST}/ -> ${GITLAB_URL}/"
fi

echo "  Runner 配置完成!"

# ==================== 步骤 6: 验证 ====================
echo ""
echo "[步骤 6/6] 验证部署..."

# 验证 Runner 连接
VERIFY_RESULT=$(docker exec gitlab-runner gitlab-runner verify 2>&1 || true)
if echo "$VERIFY_RESULT" | grep -q "is alive"; then
    echo "  Runner 连接验证: 通过"
else
    echo "  Runner 连接验证: 未通过，请检查网络配置"
    echo "  提示: 如果 Runner 无法连接 GitLab，请检查 GITLAB_URL 是否从 Runner 容器内可达"
fi

# 检查最新 Pipeline
sleep 3
PIPELINES=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "[]")
PIPE_COUNT=$(echo "$PIPELINES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "  Pipeline 数量: $PIPE_COUNT"

echo ""
echo "================================================"
echo " 部署完成!"
echo "================================================"
echo ""
echo " 项目地址: ${GITLAB_URL}/root/${PROJECT_NAME}"
echo " Runner 容器: docker logs gitlab-runner"
echo ""
echo " 后续操作："
echo " 1. 创建特性分支并推送到 GitLab"
echo " 2. 创建 Merge Request 以触发 AI 代码审查"
echo " 3. 构建 Job 失败时 AI 自愈构建会自动触发"
echo ""
echo " 如需切换 AI 模型，更新以下 CI/CD 变量："
echo "   - AI_API_URL"
echo "   - AI_API_KEY"
echo "   - AI_MODEL_NAME"
echo "================================================"
