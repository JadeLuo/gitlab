#!/bin/bash
# ============================================================
# deploy.sh 空运行（Dry Run）测试脚本
# 原理：通过 PATH 劫持，用 mock 命令替换 docker/curl/git/sleep，
#       使 deploy.sh 在无真实服务的情况下完整走完所有步骤，
#       不会产生任何副作用（不会创建项目、启动容器等）
# 用法：bash tests/dry_run_deploy.sh
# ============================================================

# 创建临时目录存放 mock 命令脚本
MOCK_DIR=$(mktemp -d)
# 退出时自动清理临时目录
trap 'rm -rf "$MOCK_DIR"' EXIT

# ==================== 创建 mock 命令 ====================

# --- mock docker ---
# 拦截 docker 子命令，仅打印日志不执行实际操作
cat > "$MOCK_DIR/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "load" ]; then echo "[DRY-RUN] docker load -i $3"; fi
if [ "$1" = "ps" ]; then echo ""; fi
if [ "$1" = "run" ]; then echo "[DRY-RUN] docker run $@"; fi
if [ "$1" = "rm" ]; then echo "[DRY-RUN] docker rm $@"; fi
if [ "$1" = "exec" ]; then echo "[DRY-RUN] docker exec $@"; fi
EOF
chmod +x "$MOCK_DIR/docker"

# --- mock curl ---
# 根据请求的 URL 路径返回对应的模拟 JSON 响应
# 模拟 GitLab REST API 的各种接口返回值
cat > "$MOCK_DIR/curl" << 'CURL_EOF'
#!/bin/bash

# 解析命令行参数，提取 URL 和 -d 请求体
URL=""
DATA=""
for arg in "$@"; do
    case "$arg" in
        http*) URL="$arg" ;;           # 提取请求 URL
        -d) NEXT_IS_DATA=1 ;;          # 下一个参数是请求体数据
        *)
            if [ "${NEXT_IS_DATA:-0}" = "1" ]; then
                DATA="$arg"
                NEXT_IS_DATA=0
            fi
            ;;
    esac
done

# 根据 URL 路径匹配不同的 API 端点，返回模拟响应
# 注意：variables 必须在 projects 之前匹配，因为 variables URL 也包含 projects

# CI/CD 变量接口：返回包含 key 的 JSON（模拟创建成功）
if echo "$URL" | grep -q "variables"; then
    KEY=$(echo "$DATA" | grep -oP '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "{\"key\":\"${KEY}\",\"value\":\"***\"}"

# Runner 注册接口：返回模拟的 Runner 认证 Token
elif echo "$URL" | grep -q "api/v4/runners"; then
    echo '{"token":"glrt-fake-runner-auth-token"}'

# Pipeline 列表接口：返回 3 条模拟 Pipeline 记录
elif echo "$URL" | grep -q "pipelines"; then
    echo '[{"id":1,"status":"running"},{"id":2,"status":"success"},{"id":3,"status":"failed"}]'

# 创建项目接口（POST api/v4/projects）：返回模拟的项目信息
# 包含项目 ID、clone URL 和 Runner 注册 Token
elif echo "$URL" | grep -q "api/v4/projects$"; then
    echo '{"id":42,"http_url_to_repo":"http://your-gitlab:80/root/ai-cicd-pipeline.git","runners_token":"glrt-fake-runner-token-12345"}'

# 项目详情接口（GET api/v4/projects/:id）：返回 Runner 注册 Token
elif echo "$URL" | grep -q "api/v4/projects"; then
    echo '{"id":42,"runners_token":"glrt-fake-runner-token-12345","http_url_to_repo":"http://your-gitlab:80/root/ai-cicd-pipeline.git"}'

# 未匹配的 curl 请求：直接打印日志
else
    echo "[DRY-RUN] curl $*"
fi
CURL_EOF
chmod +x "$MOCK_DIR/curl"

# --- mock git ---
# 拦截 git push（避免真正推送代码），其他 git 命令使用真实二进制执行
# 原因：git init/commit 等本地操作需要真正执行，只有 push 涉及远程交互
cat > "$MOCK_DIR/git" << 'GIT_EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "[DRY-RUN] git push $*"
else
    /usr/bin/git "$@"
fi
GIT_EOF
chmod +x "$MOCK_DIR/git"

# --- mock sleep ---
# 跳过等待时间，避免空运行时不必要的延迟
cat > "$MOCK_DIR/sleep" << 'EOF'
#!/bin/bash
echo "[DRY-RUN] sleep $1 (skipped)"
EOF
chmod +x "$MOCK_DIR/sleep"

# ==================== 执行空运行 ====================

# 将 mock 目录置于 PATH 最前面，优先于系统命令
export PATH="$MOCK_DIR:$PATH"

# 设置测试用的环境变量（模拟实际部署配置）
export GITLAB_URL="http://test-gitlab:80"
export GITLAB_TOKEN="glpat-dryrun-test-token"
export AI_API_URL="http://test-ai-api:3000/"
export AI_API_KEY="sk-dryrun-test-key"

# 执行 deploy.sh，捕获退出码
echo "======= DRY RUN START ======="
bash /root/ai-cicd-offline-package/deploy.sh
DRY_EXIT=$?
echo "======= DRY RUN END ======="
echo "退出码: $DRY_EXIT"
