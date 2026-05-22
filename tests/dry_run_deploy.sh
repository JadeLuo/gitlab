#!/bin/bash

# Dry-run wrapper: intercepts all external commands via PATH
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# --- Create mock commands ---
# docker
cat > "$MOCK_DIR/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "load" ]; then echo "[DRY-RUN] docker load -i $3"; fi
if [ "$1" = "ps" ]; then echo ""; fi
if [ "$1" = "run" ]; then echo "[DRY-RUN] docker run $@"; fi
if [ "$1" = "rm" ]; then echo "[DRY-RUN] docker rm $@"; fi
if [ "$1" = "exec" ]; then echo "[DRY-RUN] docker exec $@"; fi
EOF
chmod +x "$MOCK_DIR/docker"

# curl - returns fake JSON responses based on the API endpoint
cat > "$MOCK_DIR/curl" << 'CURL_EOF'
#!/bin/bash
# Find the URL (last arg that starts with http) and the -d payload
URL=""
DATA=""
for arg in "$@"; do
    case "$arg" in
        http*) URL="$arg" ;;
        -d) NEXT_IS_DATA=1 ;;
        *)
            if [ "${NEXT_IS_DATA:-0}" = "1" ]; then
                DATA="$arg"
                NEXT_IS_DATA=0
            fi
            ;;
    esac
done

# Variables (must be checked before generic projects URL)
if echo "$URL" | grep -q "variables"; then
    KEY=$(echo "$DATA" | grep -oP '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "{\"key\":\"${KEY}\",\"value\":\"***\"}"
# Runner registration
elif echo "$URL" | grep -q "api/v4/runners"; then
    echo '{"token":"glrt-fake-runner-auth-token"}'
# Pipelines
elif echo "$URL" | grep -q "pipelines"; then
    echo '[{"id":1,"status":"running"},{"id":2,"status":"success"},{"id":3,"status":"failed"}]'
# Create project (POST to api/v4/projects)
elif echo "$URL" | grep -q "api/v4/projects$"; then
    echo '{"id":42,"http_url_to_repo":"http://your-gitlab:80/root/ai-cicd-pipeline.git","runners_token":"glrt-fake-runner-token-12345"}'
# Project info (GET api/v4/projects/:id)
elif echo "$URL" | grep -q "api/v4/projects"; then
    echo '{"id":42,"runners_token":"glrt-fake-runner-token-12345","http_url_to_repo":"http://your-gitlab:80/root/ai-cicd-pipeline.git"}'
else
    echo "[DRY-RUN] curl $*"
fi
CURL_EOF
chmod +x "$MOCK_DIR/curl"

# git - intercept push, allow local ops
cat > "$MOCK_DIR/git" << 'GIT_EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "[DRY-RUN] git push $*"
else
    /usr/bin/git "$@"
fi
GIT_EOF
chmod +x "$MOCK_DIR/git"

# sleep - skip
cat > "$MOCK_DIR/sleep" << 'EOF'
#!/bin/bash
echo "[DRY-RUN] sleep $1 (skipped)"
EOF
chmod +x "$MOCK_DIR/sleep"

# Run deploy.sh with mocked PATH
export PATH="$MOCK_DIR:$PATH"
export GITLAB_URL="http://test-gitlab:80"
export GITLAB_TOKEN="glpat-dryrun-test-token"
export AI_API_URL="http://test-ai-api:3000/"
export AI_API_KEY="sk-dryrun-test-key"

echo "======= DRY RUN START ======="
bash /root/ai-cicd-offline-package/deploy.sh
DRY_EXIT=$?
echo "======= DRY RUN END ======="
echo "Exit code: $DRY_EXIT"
