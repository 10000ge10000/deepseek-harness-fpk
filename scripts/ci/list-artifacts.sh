#!/usr/bin/env bash
set -euo pipefail

# 找出构建产物中的 x86 / ARM 安装包并写出到 GITHUB_OUTPUT。
# 缺任一架构都直接失败——此前用 ls|head 静默容错，缺文件会生成
# 缺文件名的坏下载链接并发布到应用源页面。

X86_FPK=""
ARM_FPK=""
for f in *_x86.fpk; do
    [ -e "$f" ] || continue
    X86_FPK="$f"
    break
done
for f in *_arm.fpk; do
    [ -e "$f" ] || continue
    ARM_FPK="$f"
    break
done

if [ -z "$X86_FPK" ] || [ -z "$ARM_FPK" ]; then
    echo "缺少构建产物：x86=${X86_FPK:-无} arm=${ARM_FPK:-无}" >&2
    ls -lh ./*.fpk 2>/dev/null || true
    exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "x86_fpk=${X86_FPK}"
        echo "arm_fpk=${ARM_FPK}"
    } >> "$GITHUB_OUTPUT"
fi
echo "x86=${X86_FPK}; arm=${ARM_FPK}"
