#!/usr/bin/env bash
# 从仓库根 .env 的 EXAMPLE_KEY_STAGING 生成 Example/Retriever.local.xcconfig（gitignored）。
# 不打印 key。用法：./gen-local-xcconfig.sh [env 文件路径，默认仓库根 .env]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${1:-$here/../../../.env}"
out="$here/Retriever.local.xcconfig"

if [[ ! -f "$env_file" ]]; then
  echo "找不到 env 文件：${env_file}" >&2
  exit 1
fi
key="$(grep -E '^EXAMPLE_KEY_STAGING=' "$env_file" | tail -n 1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
if [[ -z "$key" ]]; then
  echo "EXAMPLE_KEY_STAGING 缺失或为空（${env_file}）" >&2
  exit 1
fi
if [[ ! "$key" =~ ^lk_test_[A-Za-z0-9_-]+$ ]]; then
  echo "EXAMPLE_KEY_STAGING 格式不对：staging 只接受 lk_test_ 开头的 key（值未打印）" >&2
  exit 1
fi

umask 077
{
  echo "// 由 gen-local-xcconfig.sh 生成；gitignored，勿提交。"
  echo "RETRIEVER_KEY = $key"
  echo 'RETRIEVER_BASE_URL = https:/$()/logs-staging.revdog.org'
} > "$out"
echo "已写入 ${out}（key 未打印）"
