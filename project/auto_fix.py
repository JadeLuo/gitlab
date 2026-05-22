#!/usr/bin/env python3
"""
AI 自愈构建模块
功能：解析构建日志 -> 调用 AI 分析修复 -> Git 提交推送 -> 触发新流水线
防死循环：检查 [AI-Fix] 标记和重试次数上限
"""

import os
import sys
import json
import subprocess
import requests

# ============ 环境变量 ============
GITLAB_URL = os.environ.get("GITLAB_URL", "http://gitlab:8899")
GITLAB_TOKEN = os.environ.get("GITLAB_ACCESS_TOKEN")
PROJECT_ID = os.environ.get("CI_PROJECT_ID")
CI_COMMIT_BRANCH = os.environ.get("CI_COMMIT_BRANCH")
CI_COMMIT_MESSAGE = os.environ.get("CI_COMMIT_MESSAGE", "")
CI_COMMIT_SHA = os.environ.get("CI_COMMIT_SHA", "")
AI_API_KEY = os.environ.get("AI_API_KEY")
AI_API_URL = os.environ.get("AI_API_URL")
AI_MODEL = os.environ.get("AI_MODEL_NAME", "llm")
MAX_RETRY_COUNT = int(os.environ.get("MAX_RETRY_COUNT", "3"))

AI_FIX_TAG = "[AI-Fix]"


def run_git(cmd, check=True):
    """执行 Git 命令"""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"[ERROR] Git 命令失败: {cmd}")
        print(f"  stderr: {result.stderr}")
        raise RuntimeError(f"Git 命令失败: {result.stderr}")
    return result.stdout.strip()


def gitlab_api_get(path, params=None):
    """通用 GitLab GET 请求"""
    url = f"{GITLAB_URL}/api/v4{path}"
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN}
    resp = requests.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def check_ai_fix_count():
    """检查当前分支中 [AI-Fix] commit 的数量，实现熔断机制"""
    print(f"[INFO] 检查当前分支 [AI-Fix] 提交次数 ...")
    try:
        commits = gitlab_api_get(
            f"/projects/{PROJECT_ID}/repository/commits",
            params={"ref_name": CI_COMMIT_BRANCH, "per_page": 20},
        )
    except Exception as e:
        print(f"[WARN] 无法获取提交历史: {e}，默认允许修复")
        return 0

    ai_fix_count = 0
    for commit in commits:
        msg = commit.get("message", "")
        if AI_FIX_TAG in msg:
            ai_fix_count += 1

    print(f"[INFO] 当前分支 [AI-Fix] 提交数: {ai_fix_count}, 上限: {MAX_RETRY_COUNT}")
    return ai_fix_count


def check_current_commit_is_ai_fix():
    """检查当前 commit 是否已包含 [AI-Fix] 标记（防死循环）"""
    if AI_FIX_TAG in CI_COMMIT_MESSAGE:
        print(f"[INFO] 当前 Commit 已包含 {AI_FIX_TAG} 标记，跳过修复以防止死循环")
        return True
    return False


def read_build_log():
    """读取构建失败日志"""
    print("[INFO] 读取构建失败日志 ...")

    # 方式1: 读取 artifacts 传递的日志文件
    log_file = os.environ.get("BUILD_LOG_FILE", "build_error.log")
    if os.path.exists(log_file):
        with open(log_file, "r", encoding="utf-8", errors="replace") as f:
            log_content = f.read()
        print(f"[INFO] 从 {log_file} 读取到日志，长度: {len(log_content)}")
        return log_content

    # 方式2: 通过 GitLab API 获取上一 Job 的日志
    pipeline_id = os.environ.get("CI_PIPELINE_ID")
    if pipeline_id and GITLAB_TOKEN and PROJECT_ID:
        try:
            jobs = gitlab_api_get(
                f"/projects/{PROJECT_ID}/pipelines/{pipeline_id}/jobs"
            )
            for job in jobs:
                if job.get("stage") == "build" and job.get("status") in ("failed",):
                    job_id = job["id"]
                    url = f"{GITLAB_URL}/api/v4/projects/{PROJECT_ID}/jobs/{job_id}/trace"
                    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN}
                    resp = requests.get(url, headers=headers, timeout=30)
                    if resp.status_code == 200:
                        log_content = resp.text
                        print(f"[INFO] 从 GitLab API 获取到 Job {job_id} 日志，长度: {len(log_content)}")
                        return log_content
        except Exception as e:
            print(f"[WARN] 通过 API 获取日志失败: {e}")

    # 方式3: 读取环境变量中的错误信息
    build_error = os.environ.get("BUILD_ERROR_OUTPUT", "")
    if build_error:
        print(f"[INFO] 从环境变量读取到错误信息，长度: {len(build_error)}")
        return build_error

    print("[WARN] 无法获取构建日志")
    return "无法获取构建日志，请手动检查。"


def get_relevant_code():
    """获取最近的代码变更"""
    print("[INFO] 获取最近代码变更 ...")
    try:
        diff = run_git(f"git diff HEAD~1", check=False)
        if not diff:
            diff = run_git(f"git diff", check=False)
        return diff[:3000] if diff else "无法获取代码变更"
    except Exception:
        return "无法获取代码变更"


def call_ai_fix(error_log, code_diff):
    """调用 AI 分析错误并生成修复方案"""
    print("[INFO] 调用 AI 分析构建错误并生成修复 ...")
    prompt = f"""你是一位资深 DevOps 工程师，请分析以下构建失败日志并给出修复方案。

## 构建错误日志
```
{error_log[:4000]}
```

## 最近代码变更
```diff
{code_diff[:2000]}
```

请按以下格式输出：
1. **错误原因分析**：简要说明失败原因
2. **修复代码**：给出修复后的完整文件内容（用代码块包裹，并标注文件路径）
3. **修复命令**（如有）：需要执行的修复命令

请用中文回复。如果无法确定修复方案，请说明原因。"""

    api_url = AI_API_URL.rstrip("/")
    if not api_url.endswith("/v1"):
        api_url += "/v1"
    api_url += "/chat/completions"

    headers = {
        "Authorization": f"Bearer {AI_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": AI_MODEL,
        "messages": [
            {"role": "system", "content": "你是一位资深 DevOps 工程师，擅长诊断构建错误并提供精确的修复代码。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
        "max_tokens": 3000,
    }

    try:
        resp = requests.post(api_url, headers=headers, json=payload, timeout=90)
        resp.raise_for_status()
        result = resp.json()
        fix_text = result["choices"][0]["message"]["content"]
        return fix_text
    except Exception as e:
        print(f"[ERROR] AI 调用失败: {e}")
        if hasattr(e, "response") and e.response is not None:
            print(f"[ERROR] 响应内容: {e.response.text}")
        return None


def apply_fix_and_commit(fix_text):
    """应用 AI 修复并提交"""
    print("[INFO] 尝试应用 AI 修复建议 ...")

    # 配置 Git
    run_git('git config user.name "AI-CI-Bot"')
    run_git('git config user.email "ai-cicd-bot@ai-cicd.local"')

    # 提取修复的代码块并应用
    import re

    # 尝试提取代码块中的修复内容
    code_blocks = re.findall(r"```(\w*)\n(.*?)```", fix_text, re.DOTALL)
    files_modified = False

    for lang, code in code_blocks:
        # 尝试从代码内容中识别文件路径
        # 查找文件路径注释，如 # File: xxx 或 // File: xxx
        path_match = re.search(r"(?:#|//)\s*(?:File|file|文件路径?)[：:]\s*(\S+)", code)
        if path_match:
            file_path = path_match.group(1).strip()
            # 去掉路径注释行
            code_lines = code.split("\n")
            clean_lines = [l for l in code_lines if not re.match(r"\s*(#|//)\s*(File|file|文件路径?)[：:]", l)]
            code = "\n".join(clean_lines)
        else:
            # 尝试从上下文找文件名
            path_match2 = re.search(r"(?:修复|修改|文件)[：:]\s*`?(\S+\.\w+)`?", fix_text[:fix_text.find(code) if code in fix_text else 0])
            if path_match2:
                file_path = path_match2.group(1)
            else:
                print(f"[WARN] 无法识别代码块对应的文件路径，跳过此块")
                continue

        # 写入文件
        try:
            dir_path = os.path.dirname(file_path)
            if dir_path:
                os.makedirs(dir_path, exist_ok=True)
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(code.strip() + "\n")
            files_modified = True
            print(f"[INFO] 已写入修复文件: {file_path}")
        except Exception as e:
            print(f"[WARN] 写入文件 {file_path} 失败: {e}")
            continue

    if not files_modified:
        print("[WARN] AI 未能生成可直接应用的修复代码")
        print("[INFO] AI 修复建议如下：")
        print(fix_text)
        return False

    # Git add, commit, push
    run_git("git add -A")

    commit_msg = f"{AI_FIX_TAG} AI 自动修复构建错误\n\nAI 分析建议:\n{fix_text[:500]}"
    # 对 commit message 中的特殊字符做转义
    commit_msg = commit_msg.replace('"', '\\"').replace("$", "\\$")
    run_git(f'git commit -m "{commit_msg}"')

    # Push
    remote_url = f"http://oauth2:{GITLAB_TOKEN}@{GITLAB_URL.replace("http://", "").replace("https://", "")}/{os.environ.get("CI_PROJECT_PATH", "")}.git"
    run_git(f"git push {remote_url} HEAD:{CI_COMMIT_BRANCH}")

    print("[INFO] AI 修复已提交并推送！新的流水线将自动触发。")
    return True


def main():
    # 参数校验
    missing = []
    if not GITLAB_TOKEN:
        missing.append("GITLAB_ACCESS_TOKEN")
    if not PROJECT_ID:
        missing.append("CI_PROJECT_ID")
    if not CI_COMMIT_BRANCH:
        missing.append("CI_COMMIT_BRANCH")
    if not AI_API_KEY:
        missing.append("AI_API_KEY")
    if not AI_API_URL:
        missing.append("AI_API_URL")
    if missing:
        print(f"[ERROR] 缺少必要环境变量: {', '.join(missing)}")
        sys.exit(1)

    print("=" * 50)
    print("AI 自愈构建 - 开始分析")
    print("=" * 50)

    # 1. 防死循环检查
    if check_current_commit_is_ai_fix():
        print("[INFO] 当前提交已是 AI 修复，终止以防止死循环")
        sys.exit(0)

    # 2. 熔断检查
    ai_fix_count = check_ai_fix_count()
    if ai_fix_count >= MAX_RETRY_COUNT:
        print(f"[ERROR] AI 修复次数已达上限 ({MAX_RETRY_COUNT})，熔断触发！请手动修复。")
        sys.exit(1)

    # 3. 读取构建日志
    error_log = read_build_log()
    if not error_log or error_log.strip() == "无法获取构建日志，请手动检查。":
        print("[ERROR] 无法获取构建日志，无法自动修复")
        sys.exit(1)

    # 4. 获取相关代码
    code_diff = get_relevant_code()

    # 5. 调用 AI 分析修复
    fix_text = call_ai_fix(error_log, code_diff)
    if not fix_text:
        print("[ERROR] AI 未能生成修复方案")
        sys.exit(1)

    print(f"[INFO] AI 修复方案长度: {len(fix_text)} 字符")
    print("[INFO] AI 修复建议预览:")
    print(fix_text[:1000])

    # 6. 应用修复并提交
    success = apply_fix_and_commit(fix_text)
    if not success:
        print("[WARN] AI 修复未能自动应用，请根据建议手动修复")
        sys.exit(1)

    print("[INFO] AI 自愈构建流程完成！")


if __name__ == "__main__":
    main()
