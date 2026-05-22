#!/usr/bin/env python3
"""
AI 智能代码审查模块
功能：获取 MR Diff -> 调用 AI 审查 -> 发布 MR 评论
"""

import os
import sys
import json
import requests

# ============ 环境变量 ============
GITLAB_URL = os.environ.get("GITLAB_URL", "http://gitlab:8899")
GITLAB_TOKEN = os.environ.get("GITLAB_ACCESS_TOKEN")
PROJECT_ID = os.environ.get("CI_PROJECT_ID")
MR_IID = os.environ.get("CI_MERGE_REQUEST_IID")
AI_API_KEY = os.environ.get("AI_API_KEY")
AI_API_URL = os.environ.get("AI_API_URL")
AI_MODEL = os.environ.get("AI_MODEL_NAME", "llm")


def gitlab_api_get(path, params=None):
    """通用 GitLab GET 请求"""
    url = f"{GITLAB_URL}/api/v4{path}"
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN}
    resp = requests.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def gitlab_api_post(path, data=None):
    """通用 GitLab POST 请求"""
    url = f"{GITLAB_URL}/api/v4{path}"
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN, "Content-Type": "application/json"}
    resp = requests.post(url, headers=headers, json=data, timeout=30)
    resp.raise_for_status()
    return resp.json()


def get_mr_diff():
    """获取 MR 的变更 Diff"""
    print(f"[INFO] 获取 MR !{MR_IID} 的 Diff ...")
    changes = gitlab_api_get(f"/projects/{PROJECT_ID}/merge_requests/{MR_IID}/changes")
    diffs = changes.get("changes", [])
    if not diffs:
        print("[WARN] 没有找到变更内容")
        return ""
    diff_text = ""
    for diff in diffs:
        old_path = diff.get("old_path", "")
        new_path = diff.get("new_path", "")
        diff_content = diff.get("diff", "")
        diff_text += f"\n--- File: {new_path} (was: {old_path}) ---\n{diff_content}\n"
    return diff_text


def call_ai_review(diff_text):
    """调用 AI 模型进行代码审查"""
    print("[INFO] 调用 AI 进行代码审查 ...")
    prompt = f"""你是一位资深代码审查专家，请对以下 Git Diff 进行审查。
请从以下三个维度给出具体建议：
1. **代码规范**：命名、格式、最佳实践等
2. **潜在 Bug**：逻辑错误、边界条件、异常处理等
3. **性能问题**：资源浪费、不必要的计算、可优化点等

请用中文回复，按维度分类，每个问题标注严重程度（严重/建议/提示）。
如果代码质量良好，请简要说明即可。

```diff
{diff_text}
```"""

    # 构建 OpenAI 兼容请求
    api_url = AI_API_URL.rstrip("/")
    # 兼容不同路径：如果 URL 以 /v1 结尾则直接用，否则补充
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
            {"role": "system", "content": "你是一位拥有10年经验的资深代码审查专家，擅长发现代码中的规范、Bug 和性能问题。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.3,
        "max_tokens": 2000,
    }

    try:
        resp = requests.post(api_url, headers=headers, json=payload, timeout=60)
        resp.raise_for_status()
        result = resp.json()
        review_text = result["choices"][0]["message"]["content"]
        return review_text
    except Exception as e:
        print(f"[ERROR] AI 调用失败: {e}")
        if hasattr(e, "response") and e.response is not None:
            print(f"[ERROR] 响应内容: {e.response.text}")
        return f"AI 审查调用失败: {e}"


def post_mr_comment(review_text):
    """将审查意见发布为 MR Discussion 评论"""
    print("[INFO] 发布 AI 审查评论到 MR ...")
    # 截断过长内容（GitLab API 限制）
    if len(review_text) > 6000:
        review_text = review_text[:5900] + "\n\n... (内容过长已截断)"

    body = f"""## AI 代码审查报告

{review_text}

---
*此评论由 AI 自动生成，仅供参考。如有误报请忽略。*"""

    try:
        result = gitlab_api_post(
            f"/projects/{PROJECT_ID}/merge_requests/{MR_IID}/discussions",
            data={"body": body},
        )
        print("[INFO] 评论发布成功！")
        return result
    except Exception as e:
        print(f"[ERROR] 评论发布失败: {e}")
        # 降级：尝试用 notes API
        try:
            url = f"{GITLAB_URL}/api/v4/projects/{PROJECT_ID}/merge_requests/{MR_IID}/notes"
            headers = {"PRIVATE-TOKEN": GITLAB_TOKEN, "Content-Type": "application/json"}
            resp = requests.post(url, headers=headers, json={"body": body}, timeout=30)
            resp.raise_for_status()
            print("[INFO] 通过 Notes API 评论发布成功！")
            return resp.json()
        except Exception as e2:
            print(f"[ERROR] Notes API 评论也失败: {e2}")
            return None


def main():
    # 参数校验
    missing = []
    if not GITLAB_TOKEN:
        missing.append("GITLAB_ACCESS_TOKEN")
    if not PROJECT_ID:
        missing.append("CI_PROJECT_ID")
    if not MR_IID:
        missing.append("CI_MERGE_REQUEST_IID")
    if not AI_API_KEY:
        missing.append("AI_API_KEY")
    if not AI_API_URL:
        missing.append("AI_API_URL")
    if missing:
        print(f"[ERROR] 缺少必要环境变量: {', '.join(missing)}")
        sys.exit(1)

    print(f"=" * 50)
    print(f"AI 代码审查 - 项目: {PROJECT_ID}, MR: !{MR_IID}")
    print(f"=" * 50)

    # 1. 获取 Diff
    diff_text = get_mr_diff()
    if not diff_text.strip():
        print("[WARN] Diff 为空，跳过审查")
        post_mr_comment("本次 MR 没有代码变更，无需审查。")
        return

    print(f"[INFO] 获取到 Diff，长度: {len(diff_text)} 字符")

    # 2. 调用 AI 审查
    review_text = call_ai_review(diff_text)
    print(f"[INFO] AI 审查完成，结果长度: {len(review_text)} 字符")

    # 3. 发布评论
    post_mr_comment(review_text)
    print("[INFO] AI 代码审查流程完成！")


if __name__ == "__main__":
    main()
