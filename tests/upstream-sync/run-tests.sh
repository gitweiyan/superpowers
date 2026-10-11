#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
failed=0
ran=0
for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue   # 没有匹配到任何测试文件时，glob 会原样保留，必须显式跳过
  ran=$((ran + 1))
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done
if [ "$ran" -eq 0 ]; then
  printf '没有找到任何测试文件：%s/test-*.sh\n' "$HERE" >&2
  exit 2
fi
printf '\n%s\n' "----------------------------------------"
if [ "$failed" -ne 0 ]; then
  # C：有测试失败一律只返回 1。失败文件数不能当退出码（3/4/5/6/7 在该仓库另有含义）。
  printf '有 %s 个测试文件失败\n' "$failed"
  exit 1
fi
printf '全部测试通过\n'
exit 0
