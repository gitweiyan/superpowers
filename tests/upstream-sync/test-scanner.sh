#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
# G1：harness 自检。lib-assert.sh 没加载成功时断言会退化成空操作，整个套件会"零失败"
# 地退出 0——那比失败更危险。
command -v assert_eq >/dev/null 2>&1 || { printf 'harness missing: lib-assert.sh did not load\n' >&2; exit 2; }
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
SCAN="$MECH/scan-sensitive.sh"
. "$MECH/sync-lib.sh"
command -v sync_git >/dev/null 2>&1 || { printf 'sync-lib missing\n' >&2; exit 2; }

scratch_setup
trap scratch_teardown EXIT
FIX="$SCRATCH/fixtures"
mkdir -p "$FIX"

# 所有敏感字面量在运行时拼接，保证测试文件自身能通过扫描器
aws="$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')"
gh="$(printf 'gh%s_%s' 'p' '0123456789abcdefghijklmnop')"
mail="$(printf '%s@%s' 'someone' 'example.invalid')"
home="$(printf '/%s/%s/%s' 'Users' 'someone' 'proj')"
endpoint="$(printf '%s:%s' '127.0.0.1' '12345')"

printf 'aws_key = %s\n' "$aws" > "$FIX/aws.txt"
assert_exit 1 "AWS 访问密钥命中" -- "$SCAN" --paths "$FIX/aws.txt"

printf 'token = %s\n' "$gh" > "$FIX/gh.txt"
assert_exit 1 "GitHub token 命中" -- "$SCAN" --paths "$FIX/gh.txt"

printf 'contact %s\n' "$mail" > "$FIX/mail.txt"
assert_exit 1 "邮箱命中" -- "$SCAN" --paths "$FIX/mail.txt"

printf 'cloned %s/x\n' "$home" > "$FIX/home.txt"
assert_exit 1 "绝对家目录路径命中" -- "$SCAN" --paths "$FIX/home.txt"

printf 'listening on %s\n' "$endpoint" > "$FIX/endpoint.txt"
assert_exit 1 "本地服务端点命中" -- "$SCAN" --paths "$FIX/endpoint.txt"

printf 'name: safe\ndescription: 正常内容，提到 api_key 但这个值是 the_VALUE_placeholder 以外都正常\n' > "$FIX/clean.txt"
assert_exit 0 "干净文件不误报" -- "$SCAN" --paths "$FIX/clean.txt"

printf 'x\n' > "$FIX/credentials.json"
assert_exit 1 "凭据类文件名命中（仅凭文件名）" -- "$SCAN" --paths "$FIX/credentials.json"

# 白名单：本地文件，只豁免"规则+路径"这一对
mkdir -p "$SCRATCH_REPO/.sync"
printf 'env-abs-home\t%s\tsomeone 的本机路径示例，已确认无风险\n' "$FIX/home.txt" > "$SCRATCH_REPO/.sync/allowlist.txt"
assert_exit 0 "白名单内的命中被豁免" -- "$SCAN" --paths "$FIX/home.txt"
assert_exit 1 "白名单只豁免列出的那一对，其他规则照常拦截" -- "$SCAN" --paths "$FIX/aws.txt"
rm -f "$SCRATCH_REPO/.sync/allowlist.txt"

# ---------------------------------------------------------------------------
# D：白名单必须精确到"规则 + 路径"这一对，而不是子串命中。
# 子串匹配会白送豁免：(1) 条目路径只要是被扫路径的前缀（…/a.txt.bak 顺带豁免 …/a.txt）；
# (2) 原因列里人类抄了一遍"rule-id<TAB>路径"，备注本身就变成了授权。
# ---------------------------------------------------------------------------
mkdir -p "$FIX/allow"
printf 'aws_key = %s\n' "$aws" > "$FIX/allow/a.txt"
printf 'aws_key = %s\n' "$aws" > "$FIX/allow/a.txt.bak"
printf 'cred-aws-access-key\t%s\t只豁免这一份\n' "$FIX/allow/a.txt.bak" > "$SCRATCH_REPO/.sync/allowlist.txt"
assert_exit 1 "D：更长的条目不得豁免它的前缀路径" -- "$SCAN" --paths "$FIX/allow/a.txt"
assert_exit 0 "D：条目自身的精确路径仍被豁免" -- "$SCAN" --paths "$FIX/allow/a.txt.bak"
printf 'cred-aws-access-key\t%s\t备注：cred-aws-access-key\t%s 已人工确认\n' \
  "$FIX/aws.txt" "$FIX/allow/a.txt" > "$SCRATCH_REPO/.sync/allowlist.txt"
assert_exit 1 "D：原因列里抄的一组键不得授予豁免" -- "$SCAN" --paths "$FIX/allow/a.txt"

# D：白名单键在每种模式下都必须归一化成"仓库相对路径"。否则同一个文件被 --paths 以绝对
# 路径交给闸门、又被 --staged 以 git 相对路径列出时，要写两条不同的条目。
mkdir -p "$SCRATCH_REPO/skills/allowsec"
printf 'aws_key = %s\n' "$aws" > "$SCRATCH_REPO/skills/allowsec/abs.txt"
printf 'cred-aws-access-key\tskills/allowsec/abs.txt\t已确认\n' > "$SCRATCH_REPO/.sync/allowlist.txt"
assert_exit 0 "D：--paths 传绝对路径时套用的是仓库相对键" \
  -- "$SCAN" --paths "$SCRATCH_REPO/skills/allowsec/abs.txt"
git -C "$SCRATCH_REPO" add skills/allowsec/abs.txt
assert_exit 0 "D：同一文件在 --staged 下共用同一条仓库相对键" -- "$SCAN" --staged
# 符号链接前缀：macOS 上 /var 就是 /private/var 的链接，而 sync_repo_root 给的是物理路径。
# 不物理化的话，同一个文件经由链接前缀传进来会算成另一个键，白名单又得写第二条。
ln -s "$SCRATCH_REPO" "$SCRATCH/repolink"
assert_exit 0 "D：经由符号链接前缀传路径时仍是同一个仓库相对键" \
  -- "$SCAN" --paths "$SCRATCH/repolink/skills/allowsec/abs.txt"
git -C "$SCRATCH_REPO" reset -q skills/allowsec/abs.txt
rm -rf "$SCRATCH_REPO/skills/allowsec"
rm -f "$SCRATCH_REPO/.sync/allowlist.txt"

# ---------------------------------------------------------------------------
# 规则表覆盖：上面 9 条只走通 7 条规则（另有 9 条一条都没被夹具碰过），而这张表是
# "挡住凭据"的全部依据——写错一个字符就是静默放行。这里给每条剩余规则一个正例：
# 值一律运行时拼接，且拼接点落在 %s 上，测试文件自身因此不会被自己的规则命中。
# ---------------------------------------------------------------------------
rule_case() { # 描述 期望规则 id 夹具原文 夹具文件
  local desc="$1" rid="$2" secret="$3" file="$4" out
  assert_exit 1 "$desc" -- "$SCAN" --paths "$file"
  out="$("$SCAN" --paths "$file" 2>/dev/null)"
  case "$out" in
    *"$rid"*) assert_eq "ok" "ok" "${desc}：输出含规则 ${rid}" ;;
    *)        assert_eq "ok" "missing: $out" "${desc}：输出含规则 ${rid}" ;;
  esac
  # 正例本身也必须真的被脱敏：夹具原文一次都不许出现在输出里。
  # 否则闸门是通的，但诊断行自己成了第二个泄漏点。
  case "$out" in
    *"$secret"*) assert_eq "已脱敏" "泄漏原文" "${desc}：命中行不得回显原文" ;;
    *)           assert_eq "已脱敏" "已脱敏" "${desc}：命中行不得回显原文" ;;
  esac
}

v_openai="$(printf 'sk-%s' 'abcdefghijklmnopqrstuvwx')"
printf '%s\n' "$v_openai" > "$FIX/openai.txt"
rule_case "OpenAI 风格密钥命中" cred-openai-style "$v_openai" "$FIX/openai.txt"

v_pat="$(printf 'github_pat_%s' 'abcdefghijklmnopqrstuv')"
printf '%s\n' "$v_pat" > "$FIX/pat.txt"
rule_case "GitHub 细粒度 PAT 命中" cred-github-pat "$v_pat" "$FIX/pat.txt"

v_slack="$(printf 'xoxb-%s' '1234567890abc')"
printf '%s\n' "$v_slack" > "$FIX/slack.txt"
rule_case "Slack 令牌命中" cred-slack-token "$v_slack" "$FIX/slack.txt"

v_goog="$(printf 'AIza%s' 'abcdefghijklmnopqrstuvwxyz0123456789')"
printf '%s\n' "$v_goog" > "$FIX/google.txt"
rule_case "Google API 密钥命中" cred-google-api-key "$v_goog" "$FIX/google.txt"

v_pk="$(printf -- '-----BEGIN %s PRIVATE KEY-----' 'RSA')"
printf '%s\n' "$v_pk" > "$FIX/private.txt"
rule_case "私钥块命中" cred-private-key-block "$v_pk" "$FIX/private.txt"

v_mobile="$(printf '%s%s' '138' '00138000')"
printf '联系人 %s\n' "$v_mobile" > "$FIX/mobile.txt"
rule_case "中国大陆手机号命中" id-cn-mobile "$v_mobile" "$FIX/mobile.txt"

v_lnx="$(printf '/%s/%s/%s' 'home' 'someone' 'proj')"
printf 'cloned %s/x\n' "$v_lnx" > "$FIX/lnx.txt"
rule_case "Linux 绝对家目录路径命中" env-abs-linux-home "$v_lnx" "$FIX/lnx.txt"

v_privip="$(printf '%s.%s.%s.%s' '10' '0' '0' '7')"
printf 'peer %s\n' "$v_privip" > "$FIX/privip.txt"
rule_case "内网 IP 命中" env-private-ip "$v_privip" "$FIX/privip.txt"

v_sess="$(printf '%s_%s = %s' 'session' 'id' 'abcdefgh1234')"
printf '%s\n' "$v_sess" > "$FIX/sess.txt"
rule_case "会话标识命中" env-session-id "$v_sess" "$FIX/sess.txt"

# ---------------------------------------------------------------------------
# 输出契约：命中行本身绝不能再把原文吐出来。截断（cut -c1-60）不是脱敏：短密钥
# 会被整行照抄，闸门的诊断输出会变成第二次泄漏。
# ---------------------------------------------------------------------------
aws_out="$("$SCAN" --paths "$FIX/aws.txt" 2>/dev/null)"
case "$aws_out" in
  "$FIX/aws.txt:1:cred-aws-access-key: aws_key = "*) AWS_FMT="ok" ;;
  *) AWS_FMT="MISSING: $aws_out" ;;
esac
assert_eq "ok" "$AWS_FMT" "输出行为 <path>:<line>:<rule-id>: <片段>"

# 掩码必须真的在片段里生效，而不是每次都退化成"整行隐去"。整行隐去虽然安全，却把
# "敏感的是哪一段"这条最重要的线索一并丢了；退化只应发生在兜底路径上。
case "$aws_out" in
  *"***"*) assert_eq "ok" "ok" "命中片段按掩码脱敏（未退化为整行隐去）" ;;
  *)       assert_eq "ok" "masked-marker-missing" "命中片段按掩码脱敏（未退化为整行隐去）" ;;
esac

case "$aws_out" in
  *"$aws"*) assert_eq "已脱敏" "泄漏原文" "命中行不得回显完整密钥" ;;
  *)        assert_eq "已脱敏" "已脱敏" "命中行不得回显完整密钥" ;;
esac

mail_out="$("$SCAN" --paths "$FIX/mail.txt" 2>/dev/null)"
case "$mail_out" in
  *"$mail"*) assert_eq "已脱敏" "泄漏原文" "命中行不得回显完整邮箱" ;;
  *)         assert_eq "已脱敏" "已脱敏" "命中行不得回显完整邮箱" ;;
esac

# 同一行里可能同时有两种敏感信息。诊断行是按规则逐条输出的，若只脱敏"本条规则的匹配"，
# 另一条规则的那份原文就会被原样带出来——等于换个规则再泄漏一次。
printf 'mail %s key %s\n' "$mail" "$aws" > "$FIX/both.txt"
both_out="$("$SCAN" --paths "$FIX/both.txt" 2>/dev/null)"
case "$both_out" in
  *"$aws"*)  assert_eq "已脱敏" "泄漏原文" "一行命中多条规则时不得带出其它规则的完整密钥" ;;
  *)         assert_eq "已脱敏" "已脱敏" "一行命中多条规则时不得带出其它规则的完整密钥" ;;
esac
case "$both_out" in
  *"$mail"*) assert_eq "已脱敏" "泄漏原文" "一行命中多条规则时不得带出其它规则的完整邮箱" ;;
  *)         assert_eq "已脱敏" "已脱敏" "一行命中多条规则时不得带出其它规则的完整邮箱" ;;
esac

# 文件名类规则的行格式：<path>::<rule-id>: <basename>
json_out="$("$SCAN" --paths "$FIX/credentials.json" 2>/dev/null)"
case "$json_out" in
  "$FIX/credentials.json::path-secret-file: credentials.json") JSON_FMT="ok" ;;
  *) JSON_FMT="MISSING: $json_out" ;;
esac
assert_eq "ok" "$JSON_FMT" "文件名类命中行为 <path>::<rule-id>: <basename>"

# ---------------------------------------------------------------------------
# 模式：--paths 必须递归目录；--staged / --range 是 plan/apply 真正使用的两个入口。
# ---------------------------------------------------------------------------
mkdir -p "$FIX/deep/deeper"
printf 'aws_key = %s\n' "$aws" > "$FIX/deep/deeper/aws.txt"
deep_out="$("$SCAN" --paths "$FIX/deep" 2>/dev/null)"
case "$deep_out" in
  "$FIX/deep/deeper/aws.txt:1:cred-aws-access-key: "*) DEEP="ok" ;;
  *) DEEP="MISSING: $deep_out" ;;
esac
assert_eq "ok" "$DEEP" "--paths 递归目录"

printf 'token = %s\n' "$gh" > "$SCRATCH_REPO/scratch-range.txt"
git -C "$SCRATCH_REPO" add scratch-range.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围扫描夹具"
assert_exit 1 "--range 报出范围差异中的命中" -- "$SCAN" --range "main...local"

printf 'contact %s\n' "$mail" > "$SCRATCH_REPO/scratch-staged.txt"
git -C "$SCRATCH_REPO" add scratch-staged.txt
assert_exit 1 "--staged 报出暂存区中的命中" -- "$SCAN" --staged
# 撤销暂存，避免污染后面 sync_state_hash 的判别断言
git -C "$SCRATCH_REPO" reset -q scratch-staged.txt
rm -f "$SCRATCH_REPO/scratch-staged.txt"

# ---------------------------------------------------------------------------
# A：staged/range 必须检查"将要被推上去的那份字节"（索引 blob / 该范围引入的 blob），
# 而不是工作区此刻的样子。旧实现读工作区，于是把密钥 `git add` 进去、再把工作区改回
# 干净内容，闸门就报 0 干净——它没有检查它声称担保的东西。G2（暂存）与 G3（push 范围）
# 都吃这一口，而这两个场景恰恰是"我先提交/暂存，之后再清理工作区"的真实次序。
# ---------------------------------------------------------------------------
mkdir -p "$SCRATCH_REPO/skills/stagedsec"
printf 'aws_key = %s\n' "$aws" > "$SCRATCH_REPO/skills/stagedsec/SKILL.md"
git -C "$SCRATCH_REPO" add skills/stagedsec/SKILL.md
printf 'aws_key = (removed)\n' > "$SCRATCH_REPO/skills/stagedsec/SKILL.md"
assert_exit 1 "A：--staged 读索引 blob（工作区已改写仍须命中）" -- "$SCAN" --staged
case "$("$SCAN" --staged 2>/dev/null)" in
  *"skills/stagedsec/SKILL.md:1:cred-aws-access-key: "*) STAGED_A="ok" ;;
  *) STAGED_A="MISSING" ;;
esac
assert_eq "ok" "$STAGED_A" "A：--staged 命中行给出仓库相对路径、索引行号与规则 id"
git -C "$SCRATCH_REPO" reset -q skills/stagedsec/SKILL.md
rm -rf "$SCRATCH_REPO/skills/stagedsec"

# G3：gitlink（子模块指针）不是文本。`git show :submod` 打出来的是那个 commit 对象的头部
# （含 Author 邮箱），于是"指针"被当成"内容"扫，凭空命中 id-email。
git -C "$SCRATCH_REPO" update-index --add --cacheinfo "160000,$(git -C "$SCRATCH_REPO" rev-parse HEAD),submod"
assert_exit 0 "G3：gitlink 路径不得被当成文本内容扫描（不得因作者邮箱误报）" -- "$SCAN" --staged
git -C "$SCRATCH_REPO" update-index --force-remove submod

mkdir -p "$SCRATCH_REPO/skills/rangesec"
printf 'aws_key = %s\n' "$aws" > "$SCRATCH_REPO/skills/rangesec/SKILL.md"
git -C "$SCRATCH_REPO" add skills/rangesec/SKILL.md
git -C "$SCRATCH_REPO" commit -qm "local: 范围夹具（提交时命中）"
# 把工作区里两份带密钥的副本都擦掉：范围里只剩"提交中的那份字节"，判别力就落在这点上。
printf 'aws_key = (removed)\n' > "$SCRATCH_REPO/skills/rangesec/SKILL.md"
printf '(removed)\n' > "$SCRATCH_REPO/scratch-range.txt"
# （4b 把 range 的单位从"右端修订上的路径"改成了"该范围引入的对象"，这条断言的判别点未变：
# 工作区被改写、要推的那份字节只存在于 git 对象库里，命中必须仍然出现。）
assert_exit 1 "A：--range 读 git 对象库里该范围引入的 blob（工作区已改写仍须命中）" -- "$SCAN" --range "main...local"
assert_exit 1 "A：--range 支持 A..B 写法" -- "$SCAN" --range "main..local"

# G1：--range 只接受真正的 rev-range。传单个修订（无 ..）时，`git diff <rev>` 比的是修订与
# 工作区，而内容从 <rev> 读：于是"索引/工作区里新增、修订里还没有"的路径被判成"已删除"
# 跳过，报 0 干净——修复前这一形状读的是工作区，本来还能命中。语义含混的形状一律拒掉。
# 为了让这条断言真的落在"静默干净"上，先把工作区恢复成与 local 一致，使索引里那个新增
# 文件成为唯一差异来源。
printf 'aws_key = %s\n' "$aws" > "$SCRATCH_REPO/skills/rangesec/SKILL.md"
printf 'token = %s\n' "$gh" > "$SCRATCH_REPO/scratch-range.txt"
assert_eq "" "$(git -C "$SCRATCH_REPO" status --porcelain=v1)" "G1 前提：工作区与 local 一致"
printf 'aws_key = %s\n' "$aws" > "$SCRATCH_REPO/bare-rev.txt"
git -C "$SCRATCH_REPO" add bare-rev.txt
assert_exit 2 "G1：--range 传单个修订（无 ..）时为用法错误" -- "$SCAN" --range "local"
git -C "$SCRATCH_REPO" reset -q bare-rev.txt
rm -f "$SCRATCH_REPO/bare-rev.txt"

# G2：解析得出对象 ≠ 读得出内容。对象损坏/缺失/IO 错时读不出来，旧实现把它和"该路径在这个
# 修订上不存在"混为一谈，一律跳过 → 0 干净。这里真的损坏一个已提交 blob：对象仍然可解析
#（rev-parse 拿到 oid），但读不出来，必须报 2。范围收窄到那一个提交，让 G2 的夹具成为范围里
# 的唯一内容，判别力才落在"读不出来"这件事上。
#
# 4b 起还有一个必须说清的前提：`--range` 按"该范围引入的对象"枚举（`rev-list --objects B --not A`），
# 而 git 是按**内容**寻址的 —— 若这份字节在左端（local~1 那一侧）已经可达，rev-list 根本不会列出
# 这个 blob，扫描器也就无"读不出来"可言，断言会退化成"报干净"（这正是 4b 首轮实测到的假通过：
# 当时这份夹具抄的是 skills/rangesec/SKILL.md 里那同一个密钥）。故这里用一条与其它夹具都不同
# 的密钥，并用紧接着的前置断言钉住"这个损坏的 blob 确实在枚举集里"。
g2_aws="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL9')"
printf 'aws_key = %s\n' "$g2_aws" > "$SCRATCH_REPO/g2-corrupt.txt"
git -C "$SCRATCH_REPO" add g2-corrupt.txt
git -C "$SCRATCH_REPO" commit -qm "local: G2 损坏对象夹具"
g2_oid="$(git -C "$SCRATCH_REPO" rev-parse --verify --quiet "local:g2-corrupt.txt")"
g2_obj="$SCRATCH_REPO/.git/objects/${g2_oid:0:2}/${g2_oid:2}"
if [ -n "$g2_oid" ] && [ -f "$g2_obj" ]; then
  cp "$g2_obj" "$SCRATCH_REPO/g2-object.bak"
  chmod 644 "$g2_obj"
  printf 'not-a-valid-zlib-object' > "$g2_obj"
  # 前置：损坏的 blob 必须真的在扫描器要枚举的那批对象里。少了这条，下面那条断言在
  # "枚举集里根本没有它"时会静默通过（want 2 / got 0 是同一件事的另一面）。
  g2_enum="$(git -C "$SCRATCH_REPO" -c core.quotePath=false rev-list --objects "local~1..local")"
  g2_in_list="no"
  case "$g2_enum" in *"$g2_oid"*) g2_in_list="yes" ;; esac
  assert_eq "yes" "$g2_in_list" "G2 前置：损坏的 blob 在范围枚举集里（否则断言退化成报干净）"
  assert_exit 2 "G2：对象可解析但读不出来时必须报错（不得当成已删除跳过）" \
    -- "$SCAN" --range "local~1..local"
  # 复原对象：后面还有断言要用这个仓库
  cp "$SCRATCH_REPO/g2-object.bak" "$g2_obj"
  rm -f "$SCRATCH_REPO/g2-object.bak"
  g2_done="ok"
else
  g2_done="loose-object-missing:$g2_obj"
fi
assert_eq "ok" "$g2_done" "G2：夹具构造成立（缓存里有该 blob 的松散对象）"

assert_exit 2 "无参数为用法错误" -- "$SCAN"
assert_exit 2 "--range 缺参数为用法错误" -- "$SCAN" --range
assert_exit 2 "--paths 缺参数为用法错误" -- "$SCAN" --paths
# 路径不存在时必须报用法错误，绝不能"扫了 0 个文件然后报干净"——那是闸门静默失效。
assert_exit 2 "--paths 指向不存在的路径为用法错误" -- "$SCAN" --paths "$FIX/no-such-path.txt"
# 同理：枚举文件这一步骤失败（非法 rev-range、SYNC_REPO_ROOT 指向非仓库）时，git 只留下
# 空清单，闸门会静默判干净。这正是最危险的失败方向，必须显式拦成用法错误。
assert_exit 2 "--range 取值非法时必须报错而非判干净" -- "$SCAN" --range "no-such-rev...local"
assert_exit 2 "仓库根不是 git 仓库时必须报错而非判干净" \
  -- env SYNC_REPO_ROOT="$FIX" "$SCAN" --staged

# ---------------------------------------------------------------------------
# E：枚举到的路径必须都被真正检查过。读不了的文件（权限、竞态删除、grep 报错）不能默默
# 算进"命中 0 处"——那是最危险的失败方向，必须是退出码 2。
# ---------------------------------------------------------------------------
printf 'aws_key = %s\n' "$aws" > "$FIX/unreadable.txt"
chmod 000 "$FIX/unreadable.txt"
assert_exit 2 "E：枚举到的文件读不了时必须报错" -- "$SCAN" --paths "$FIX/unreadable.txt"
chmod 644 "$FIX/unreadable.txt"

# ---------------------------------------------------------------------------
# B/C：规则表不可用时必须 fail closed（退出码 2），绝不能"加载了 0 条规则或一条坏正则
# 然后报干净"。测法是复制机制脚本、只换掉它旁边的 patterns.tsv：这样测的是真扫描器的
# 加载逻辑，而不是测试里另写一段模仿代码。退出码必须是 2 而不是 1——1 的含义是"命中"，
# 三个消费者会照着它打印一套根本处理不了命中的补救指引。
# ---------------------------------------------------------------------------
mk_engine() { # 目标目录：只复制机制脚本，不带规则表
  mkdir -p "$1"
  cp "$MECH/sync-lib.sh" "$MECH/scan-sensitive.sh" "$1/"
}
mk_engine_valid() { # 目标目录：写一张"两种 kind 都有"的最小合法规则表
  mk_engine "$1"
  {
    printf 'cred-aws-access-key\tcontent\tAKIA[0-9A-Z]{16}\tAWS 访问密钥 id\n'
    printf 'path-secret-file\tpathname\t[.]pem$\t凭据类文件名\n'
  } > "$1/patterns.tsv"
}

mk_engine "$SCRATCH/eng-empty"
: > "$SCRATCH/eng-empty/patterns.tsv"
assert_exit 2 "B：规则表为空（0 条规则）时必须报错而非判干净" \
  -- "$SCRATCH/eng-empty/scan-sensitive.sh" --paths "$FIX/aws.txt"

mk_engine_valid "$SCRATCH/eng-space"
printf 'x-space-rule pathname [.]key$ 空格分隔的一行\n' >> "$SCRATCH/eng-space/patterns.tsv"
assert_exit 2 "B：空格分隔（非 TAB）的行必须报错" \
  -- "$SCRATCH/eng-space/scan-sensitive.sh" --paths "$FIX/aws.txt"

# 整张表都是空格分隔（例如从文档里粘出来的）：旧实现一条规则都读不出来，于是判"干净"。
mk_engine "$SCRATCH/eng-allspace"
{
  printf 'cred-aws-access-key content AKIA[0-9A-Z]{16} AWS 访问密钥 id\n'
  printf 'path-secret-file pathname [.]pem$ 凭据类文件名\n'
} > "$SCRATCH/eng-allspace/patterns.tsv"
assert_exit 2 "B：整张空格分隔的表必须报错（旧实现加载 0 条规则后判干净）" \
  -- "$SCRATCH/eng-allspace/scan-sensitive.sh" --paths "$FIX/aws.txt"

mk_engine_valid "$SCRATCH/eng-kind"
printf 'x-bad-kind\tbogus\tAKIA[0-9A-Z]{16}\tkind 不合法\n' >> "$SCRATCH/eng-kind/patterns.tsv"
assert_exit 2 "B：kind 既非 content 也非 pathname 时必须报错" \
  -- "$SCRATCH/eng-kind/scan-sensitive.sh" --paths "$FIX/aws.txt"

mk_engine_valid "$SCRATCH/eng-short"
printf 'x-short\tcontent\tAKIA[0-9A-Z]{16}\n' >> "$SCRATCH/eng-short/patterns.tsv"
assert_exit 2 "B：字段数不是 4 时必须报错" \
  -- "$SCRATCH/eng-short/scan-sensitive.sh" --paths "$FIX/aws.txt"

mk_engine_valid "$SCRATCH/eng-badre"
printf 'x-bad-regex\tcontent\tAKIA(\t正则无法编译\n' >> "$SCRATCH/eng-badre/patterns.tsv"
assert_exit 2 "B：有一条正则无法编译时必须报错（不得只让脱敏静默失效）" \
  -- "$SCRATCH/eng-badre/scan-sensitive.sh" --paths "$FIX/aws.txt"

mk_engine "$SCRATCH/eng-missing"
assert_exit 2 "C：规则表缺失时必须报用法错误 2" \
  -- "$SCRATCH/eng-missing/scan-sensitive.sh" --paths "$FIX/aws.txt"

# ---------------------------------------------------------------------------
# 4b：--range 的语义是"该范围新引入的全部 blob"，而不是"右端修订上的那份内容"。
# git push 发布的是范围内**所有提交可达的**对象：提交 A 加入密钥、提交 B 把文件删掉或把那行
# 改干净时，右端（旧实现唯一读的那份内容）根本看不到密钥，而那个 blob 照样会随推送永久进入
# 远端历史。旧实现在这两个形状上报 0 干净——这正是本机制要防的最典型泄漏方式，也是人最容易
# 踩的次序：提交、发现、清理、推送。
# 每个夹具用**互不相同**的密钥字面量：同一个 blob 只要在前面的提交里出现过，它就已被左端
# 可达、不算"范围内新引入"，断言会悄悄失去判别力——这是本组夹具最容易写错的地方。
# ---------------------------------------------------------------------------
mkdir -p "$SCRATCH_REPO/skills/rangefix"
sec_del="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL2')"
sec_rew="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL3')"
sec_dup="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL4')"
sec_pub="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL5')"

# 夹具判别力前置：这条路径必须真的出现在范围内（`git log --name-only` 会为范围内每个提到过
# 它的提交各输出一行，故这里判"至少一次"）。
range_mentions() { # 路径 范围
  local n
  n="$(git -C "$SCRATCH_REPO" log --format= --name-only "$2" | grep -c "^$1\$")"
  [ "${n:-0}" -ge 1 ] && printf '1' || printf '0'
}

# (1) 范围内"加了又删"：右端连这个路径都没有，密钥只存在于中间那次提交的 blob 里。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
range_del_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'key = %s\n' "$sec_del" > "$SCRATCH_REPO/skills/rangefix/gone.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/gone.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围内加入密钥（稍后删除该文件）"
git -C "$SCRATCH_REPO" rm -q skills/rangefix/gone.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围内删除该文件"
assert_eq "" "$(git -C "$SCRATCH_REPO" ls-tree -r --name-only local -- skills/rangefix/gone.txt)" \
  "4b 前置：右端修订里该路径确实不存在（判别力不在右端）"
assert_eq "1" "$(range_mentions "skills/rangefix/gone.txt" "$range_del_base..local")" \
  "4b 前置：该夹具确实落在范围内（否则命中与不命中都无从谈起）"
assert_exit 1 "4b：范围内加入又删除的密钥必须命中（修复前报 0 干净）" \
  -- "$SCAN" --range "$range_del_base..local"
del_out="$("$SCAN" --range "$range_del_base..local" 2>/dev/null)"
case "$del_out" in
  "skills/rangefix/gone.txt:1:cred-aws-access-key: "*) DEL_FMT="ok" ;;
  *) DEL_FMT="MISSING: ${del_out}" ;;
esac
assert_eq "ok" "$DEL_FMT" "4b：命中行给出 git 打印的路径与 blob 内的行号"
DEL_LEAK="no"
case "$del_out" in *"$sec_del"*) DEL_LEAK="yes" ;; esac
assert_eq "no" "$DEL_LEAK" "4b：范围内历史 blob 的命中同样只给掩码片段"

# (2) 文件还在，但范围内那行被改干净了：右端内容是干净的，密钥只在中间那次提交的 blob 里。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
range_rew_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'key = %s\n' "$sec_rew" > "$SCRATCH_REPO/skills/rangefix/rewritten.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/rewritten.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围内加入密钥（稍后改写该行）"
printf 'key = (removed)\n' > "$SCRATCH_REPO/skills/rangefix/rewritten.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/rewritten.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围内把那行改干净"
REW_RAW="no"
grep -qF "$sec_rew" "$SCRATCH_REPO/skills/rangefix/rewritten.txt" 2>/dev/null && REW_RAW="yes"
assert_eq "no" "$REW_RAW" "4b 前置：右端那份文件里确实没有原文（判别力落在中间 blob 上）"
assert_eq "1" "$(range_mentions "skills/rangefix/rewritten.txt" "$range_rew_base..local")" \
  "4b 前置：该夹具确实落在范围内"
assert_exit 1 "4b：范围内被改干净的密钥必须命中（修复前报 0 干净）" \
  -- "$SCAN" --range "$range_rew_base..local"
rew_out="$("$SCAN" --range "$range_rew_base..local" 2>/dev/null)"
case "$rew_out" in
  "skills/rangefix/rewritten.txt:1:cred-aws-access-key: "*) REW_FMT="ok" ;;
  *) REW_FMT="MISSING: ${rew_out}" ;;
esac
assert_eq "ok" "$REW_FMT" "4b：命中行指向被改写前那份 blob（右端内容已干净）"

# (3) 只引入干净内容的范围：必须报干净（新语义不得把范围内的一切都当成命中）。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
range_clean_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'unrelated plain content\n' > "$SCRATCH_REPO/skills/rangefix/plain.md"
git -C "$SCRATCH_REPO" add skills/rangefix/plain.md
git -C "$SCRATCH_REPO" commit -qm "local: 范围内只有干净内容"
assert_eq "1" "$(range_mentions "skills/rangefix/plain.md" "$range_clean_base..local")" \
  "4b 前置：干净夹具确实落在范围内（否则“报干净”就是同义反复）"
assert_exit 0 "4b：只引入干净内容的范围报干净" -- "$SCAN" --range "$range_clean_base..local"
assert_eq "" "$("$SCAN" --range "$range_clean_base..local" 2>/dev/null)" \
  "4b：干净范围不产生任何命中行"

# (4) 左端（已经发布的那一侧）就有的密钥不在本次要扫的对象集里：范围内没有引入它，就不该报。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
printf 'key = %s\n' "$sec_pub" > "$SCRATCH_REPO/skills/rangefix/published.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/published.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围之外就已加入的密钥"
range_pub_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'still unrelated plain content\n' > "$SCRATCH_REPO/skills/rangefix/plain2.md"
git -C "$SCRATCH_REPO" add skills/rangefix/plain2.md
git -C "$SCRATCH_REPO" commit -qm "local: 之后再提交干净内容"
assert_eq "1" "$(range_mentions "skills/rangefix/plain2.md" "$range_pub_base..local")" \
  "4b 前置：新提交的干净文件确实落在范围内（范围不是空的）"
SEC_PUB_ON_LEFT="no"
git -C "$SCRATCH_REPO" grep -qF "$sec_pub" "$range_pub_base" -- skills/rangefix/published.txt 2>/dev/null \
  && SEC_PUB_ON_LEFT="yes"
assert_eq "yes" "$SEC_PUB_ON_LEFT" "4b 前置：左端那一侧确实有密钥（这条断言才有东西可排除）"
assert_exit 0 "4b：左端已有的密钥不重复报（范围内未引入的 blob 不扫）" \
  -- "$SCAN" --range "$range_pub_base..local"
assert_eq "" "$("$SCAN" --range "$range_pub_base..local" 2>/dev/null)" \
  "4b：范围内未变化的已发布 blob 不产生命中行"

# (5) 同一份密钥 blob 出现在两个路径（两个提交）里：只报一次，且报的是 git 打印的路径。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
range_dup_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'key = %s\n' "$sec_dup" > "$SCRATCH_REPO/skills/rangefix/dup-one.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/dup-one.txt
git -C "$SCRATCH_REPO" commit -qm "local: 范围内加入密钥（第一处）"
cp "$SCRATCH_REPO/skills/rangefix/dup-one.txt" "$SCRATCH_REPO/skills/rangefix/dup-two.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/dup-two.txt
git -C "$SCRATCH_REPO" commit -qm "local: 同一份内容出现在第二个路径"
assert_eq "1" "$(range_mentions "skills/rangefix/dup-one.txt" "$range_dup_base..local")" \
  "4b 前置：第一个路径确实落在范围内"
assert_eq "1" "$(range_mentions "skills/rangefix/dup-two.txt" "$range_dup_base..local")" \
  "4b 前置：第二个路径确实落在范围内（两个路径引用同一个 blob）"
dup_out="$("$SCAN" --range "$range_dup_base..local" 2>/dev/null)"
assert_eq "1" "$(printf '%s\n' "$dup_out" | grep -c .)" \
  "4b：同一 blob 出现在两个路径/两个提交时只报一次（按对象 id 去重）"
case "$dup_out" in
  "skills/rangefix/dup-one.txt:1:cred-aws-access-key: "*) DUP_PATH="ok" ;;
  "skills/rangefix/dup-two.txt:1:cred-aws-access-key: "*) DUP_PATH="ok" ;;
  *) DUP_PATH="MISSING: ${dup_out}" ;;
esac
assert_eq "ok" "$DUP_PATH" "4b：去重后报告的路径是 git 打印的那个（不是对象 id 兜底）"

# (6) `A...B` 在 git 里是**对称差**：把整串参数直接交给 `rev-list --objects` 会把左端一侧独有的
# 对象也列出来，于是远端早已发布的密钥被算成本次推送的问题、干净推送被凭空阻断——与钩子 F2
# 那条"范围之外的既有命中不阻断"正相反。故范围必须自己写成"B 引入、A 那一侧没有的对象"。
# 这条断言是**防错修复**的锚点（旧实现在这一形状上本来就报干净，故它在修复前也会通过；
# 它拦的是"用对称差实现的新实现"）。
# 两侧各放一份**不同**的密钥：左端那份**必须不报**、右端那份**必须报且恰好一次**。只放右端
# 干净内容的话，"正确排除了左端"与"什么都没枚举到"两种情况都会通过，断言就没有判别力了。
# 它同时是"提交/树一律不当文本扫"在 range 模式下的回归锚点：下面这个范围里的提交对象带着
# 夹具作者的邮箱（lib-assert 在运行时拼装的那个地址，命中 id-email），真被当成内容扫就会报。
sec_side="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL6')"
sec_right="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL7')"
git -C "$SCRATCH_REPO" switch -qc side-rangefix local
printf 'key = %s\n' "$sec_side" > "$SCRATCH_REPO/skills/rangefix/side-only.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/side-only.txt
git -C "$SCRATCH_REPO" commit -qm "side: 左端一侧的密钥（远端已有，不该再报）"
git -C "$SCRATCH_REPO" switch -q local
printf 'key = %s\n' "$sec_right" > "$SCRATCH_REPO/skills/rangefix/right-side.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/right-side.txt
git -C "$SCRATCH_REPO" commit -qm "local: 右端一侧的密钥（本次会发布，必须报）"
SYM_RAW="$(git -C "$SCRATCH_REPO" rev-list --objects side-rangefix...local)"
SIDE_IN_SYM="no"
case "$SYM_RAW" in *skills/rangefix/side-only.txt*) SIDE_IN_SYM="yes" ;; esac
assert_eq "yes" "$SIDE_IN_SYM" \
  "4b 前置：git 的对称差确实列出左端那份密钥（否则这条断言没有判别力）"
SIDE_ON_LEFT="no"
git -C "$SCRATCH_REPO" grep -qF "$sec_side" side-rangefix -- skills/rangefix/side-only.txt 2>/dev/null \
  && SIDE_ON_LEFT="yes"
assert_eq "yes" "$SIDE_ON_LEFT" "4b 前置：左端那一侧确实有这份密钥（才有东西可排除）"
assert_eq "1" "$(range_mentions "skills/rangefix/right-side.txt" "side-rangefix...local")" \
  "4b 前置：右端那一侧确实引入了新对象（范围不是空的）"
assert_exit 1 "4b：A...B 必须报出右端引入的密钥（只取右端引入的对象）" \
  -- "$SCAN" --range "side-rangefix...local"
sym_out="$("$SCAN" --range "side-rangefix...local" 2>/dev/null)"
assert_eq "1" "$(printf '%s\n' "$sym_out" | grep -c .)" \
  "4b：A...B 命中恰好一条（左端那份密钥若被算进来就会是两条）"
case "$sym_out" in
  "skills/rangefix/right-side.txt:1:cred-aws-access-key: "*) SYM_PATH="ok" ;;
  *) SYM_PATH="MISSING: ${sym_out}" ;;
esac
assert_eq "ok" "$SYM_PATH" "4b：命中的是右端那个路径（左端路径不得出现在输出里）"
SYM_LEFT_LEAK="no"
case "$sym_out" in *side-only.txt*) SYM_LEFT_LEAK="yes" ;; esac
assert_eq "no" "$SYM_LEFT_LEAK" "4b：输出里没有左端那个路径"
SIDE_LEAK="no"
case "$sym_out" in *"$sec_side"*) SIDE_LEAK="yes" ;; esac
assert_eq "no" "$SIDE_LEAK" "4b：A...B 的命中同样只给掩码片段"
assert_exit 1 "4b：A..B 同样只取右端引入的对象（右端密钥照报）" -- "$SCAN" --range "side-rangefix..local"
assert_eq "1" "$("$SCAN" --range "side-rangefix..local" 2>/dev/null | grep -c .)" \
  "4b：A..B 命中恰好一条"
assert_eq "1" "$("$SCAN" --range "side-rangefix..local" 2>/dev/null \
  | grep -c "^skills/rangefix/right-side.txt:1:cred-aws-access-key: ")" \
  "4b：A..B 命中的也是右端那个路径"

# ---------------------------------------------------------------------------
# (7) 对象清单**不是**路径清单：`rev-list --objects` 对每个对象只打印一个路径（git 自己挑的）。
# 4b 首版把 pathname 规则挂在对象循环里，于是"同一份字节同时出现在无辜路径与凭据类路径上、
# git 挑中无辜的那个"时，凭据路径永远没被评估过 → 报 0 干净。旧实现按路径枚举本来是拦得住的，
# 所以这是 4b 引入的回归（review 的 I1）。修法不是改去重顺序（路径是 git 给的），而是让
# pathname 规则改在**全名清单**上评估；下面用前置断言把"git 确实只挑了一个、且挑的是无辜那个"
# 钉死——否则夹具会在某天悄悄失去判别力（G2 那次的教训）。
# 夹具内容刻意**不含任何密钥形状**：这样唯一能命中的就只有 pathname 规则，命中若丢失不会被
# 内容规则的命中掩盖。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
range_pn_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'opaque payload, no credential shape in here\n' > "$SCRATCH_REPO/skills/rangefix/aaa.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/aaa.txt
git -C "$SCRATCH_REPO" commit -qm "local: 无辜路径（内容本身不命中任何规则）"
cp "$SCRATCH_REPO/skills/rangefix/aaa.txt" "$SCRATCH_REPO/skills/rangefix/server.key"
git -C "$SCRATCH_REPO" add skills/rangefix/server.key
git -C "$SCRATCH_REPO" commit -qm "local: 同一份字节出现在凭据类文件名下"
PN_NAMES="$(git -C "$SCRATCH_REPO" diff --name-only --diff-filter=ACMR "$range_pn_base..local")"
assert_eq "2" "$(printf '%s\n' "$PN_NAMES" | grep -c -e '^skills/rangefix/aaa.txt$' -e '^skills/rangefix/server.key$')" \
  "4b 前置：两个路径确实都在范围内（否则这条断言没有判别力）"
assert_eq "$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/aaa.txt)" \
          "$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/server.key)" \
          "4b 前置：两个路径指向同一份字节（去重后只剩一条对象单元）"
PN_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/server.key)"
PN_PRINTED="$(git -C "$SCRATCH_REPO" rev-list --objects "$range_pn_base..local" \
  | awk -v o="$PN_OID" '$1 == o { p = $0; sub(/^[^ ]+ /, "", p); print p }')"
assert_eq "skills/rangefix/aaa.txt" "$PN_PRINTED" \
  "4b 前置：对象清单只为这份字节打印一个路径，且是无辜那个（凭据路径只存在于全名清单里）"
assert_exit 1 "4b：同一份字节在凭据类文件名下必须命中（修复前报 0 干净）" \
  -- "$SCAN" --range "$range_pn_base..local"
pn_out="$("$SCAN" --range "$range_pn_base..local" 2>/dev/null)"
case "$pn_out" in
  "skills/rangefix/server.key::path-secret-file: server.key"*) PN_FMT="ok" ;;
  *) PN_FMT="MISSING: ${pn_out}" ;;
esac
assert_eq "ok" "$PN_FMT" "4b：命中行是凭据类路径 + pathname 规则（不是内容规则）"
assert_eq "1" "$(printf '%s\n' "$pn_out" | grep -c .)" \
  "4b：这份夹具只产生一条命中（内容规则不参与，判别力落在 pathname 规则上）"

# (7b) 同一根因的第二个后果：git 挑中的那一个路径恰好在**跳过清单**上（仓库根 `.sync/` 下的路径、
# 或机制自己的规则表文件）时，整份字节**不得**被跳过 —— 可它同时发布在另一个不被跳过的路径上，
# 照样会随推送进入远端历史。判定必须问"这份字节在范围内有没有不被跳过的名字"。
# 注：本夹具用的名字是 `patterns.tsv`，而 F1 之后**只有机制自己那一个**规则表文件才被豁免
#（任何别处的同名文件都照扫），故它今天的作用退化成"git 只给一个路径、另一个只能从全名清单来"
# 这条通用锚点；保留它是因为它仍然钉着"全名清单 ∪ 对象清单"的合并语义。跳过清单**本身**的
# 回归锚点在 §11（两条必须命中 + 一条对照），`oid_has_scan_name` 这条旁路则由 §11e 单独钉住。
mkdir -p "$SCRATCH_REPO/skills/rangefix/skippub"
range_sk_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
sec_sk="$(printf 'AKIA%s' 'IOSFODNN7EXAMPLD')"
printf 'aws_key = %s\n' "$sec_sk" > "$SCRATCH_REPO/skills/rangefix/skippub/patterns.tsv"
git -C "$SCRATCH_REPO" add skills/rangefix/skippub/patterns.tsv
git -C "$SCRATCH_REPO" commit -qm "local: 落在跳过清单上的路径（内容含密钥）"
cp "$SCRATCH_REPO/skills/rangefix/skippub/patterns.tsv" \
   "$SCRATCH_REPO/skills/rangefix/skippub/zzz-visible.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/skippub/zzz-visible.txt
git -C "$SCRATCH_REPO" commit -qm "local: 同一份字节出现在普通路径上"
SK_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/skippub/zzz-visible.txt)"
assert_eq "$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/skippub/patterns.tsv)" "$SK_OID" \
  "4b 前置：跳过清单上的路径与普通路径是同一份字节"
SK_PRINTED="$(git -C "$SCRATCH_REPO" rev-list --objects "$range_sk_base..local" \
  | awk -v o="$SK_OID" '$1 == o { p = $0; sub(/^[^ ]+ /, "", p); print p }')"
assert_eq "skills/rangefix/skippub/patterns.tsv" "$SK_PRINTED" \
  "4b 前置：对象清单只为这份字节打印一个路径（另一个只存在于全名清单里）"
assert_exit 1 "4b：跳过清单路径上的同字节副本也必须扫（修复前整份字节被跳过）" \
  -- "$SCAN" --range "$range_sk_base..local"
sk_out="$("$SCAN" --range "$range_sk_base..local" 2>/dev/null)"
SK_RULE="no"
case "$sk_out" in *cred-aws-access-key*) SK_RULE="yes" ;; esac
assert_eq "yes" "$SK_RULE" "4b：命中的是内容规则（这份字节确实被读过）"
SK_LEAK="no"
case "$sk_out" in *"$sec_sk"*) SK_LEAK="yes" ;; esac
assert_eq "no" "$SK_LEAK" "4b：跳过清单形状的夹具命中同样只给掩码片段"

# (8) 名字清单里有一个名字、而它的字节**不在对象集里**（左端已可达 = "新路径、旧字节"）：
# pathname 规则照样评估（这个路径本身会随推送发布），但绝**不能**因此产生内容命中 ——
# 内容只来自对象清单。两条断言一起把这条边界钉住。
mkdir -p "$SCRATCH_REPO/skills/rangefix"
printf 'published payload, no credential shape\n' > "$SCRATCH_REPO/skills/rangefix/payload.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/payload.txt
git -C "$SCRATCH_REPO" commit -qm "local: 先发布这份字节"
range_old_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
cp "$SCRATCH_REPO/skills/rangefix/payload.txt" "$SCRATCH_REPO/skills/rangefix/deploy.pem"
git -C "$SCRATCH_REPO" add skills/rangefix/deploy.pem
git -C "$SCRATCH_REPO" commit -qm "local: 新路径、旧字节"
OLD_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/deploy.pem)"
assert_eq "0" "$(git -C "$SCRATCH_REPO" rev-list --objects "$range_old_base..local" \
  | awk -v o="$OLD_OID" '$1 == o { n += 1 } END { print n + 0 }')" \
  "4b 前置：这份字节不在对象清单里（左端已可达，属'新路径、旧字节'）"
assert_eq "1" "$(git -C "$SCRATCH_REPO" diff --name-only --diff-filter=ACMR "$range_old_base..local" \
  | grep -c '^skills/rangefix/deploy.pem$')" "4b 前置：这个新路径确实在名字清单里"
assert_exit 1 "4b：新路径（字节已发布）仍按 pathname 规则命中" \
  -- "$SCAN" --range "$range_old_base..local"
old_out="$("$SCAN" --range "$range_old_base..local" 2>/dev/null)"
case "$old_out" in
  "skills/rangefix/deploy.pem::path-secret-file: deploy.pem"*) OLD_FMT="ok" ;;
  *) OLD_FMT="MISSING: ${old_out}" ;;
esac
assert_eq "ok" "$OLD_FMT" "4b：命中行是新路径 + pathname 规则"
assert_eq "1" "$(printf '%s\n' "$old_out" | grep -c .)" \
  "4b：名字不在对象集里时不得产生内容命中（恰好只有这条 pathname 命中）"

# (9) 空范围：什么都没引入 → 报干净、退出 0（同时是新的名字清单/对账代码在"清单为空"时的锚点：
# 0 条对象单元、0 个名字、空的 SCAN_OIDS 都必须走通而不是报错）。
assert_exit 0 "4b：空范围（<rev>..<rev>）必须报干净并退出 0" -- "$SCAN" --range "local..local"
assert_eq "" "$("$SCAN" --range "local..local" 2>/dev/null)" "4b：空范围不产生任何命中行"

# ---------------------------------------------------------------------------
# (10) 目录不是文件（review N1，修复轮 2 的 Important 回归）。`rev-list --objects` 会**带路径**
# 打印被改动的树：范围里只要改了某个目录下的文件，那个目录名就进了名字清单。目录名恰好像凭据类
# 文件名（env、credentials*、*.key …）时，旧实现会报一条 `n1dir/deploy/env::path-secret-file: env`
# 并把一次**内容全干净**的推送挡掉——而 --staged/--paths 从不枚举目录，所以这是 range 独有的
# 假阳性（还会把这条假命中写进 sync_state_hash 的 stdout）。
# 判别力由**成对**前置钉住：两个目录确实出现在对象清单里（且是 tree），而同一个 basename 换成
# **真文件**时规则必须照常命中——否则"不报"也可能只是"规则坏了"（G2 那次的教训）。
# ---------------------------------------------------------------------------
mkdir -p "$SCRATCH_REPO/n1dir/deploy/env" "$SCRATCH_REPO/n1dir/config/credentials" "$SCRATCH_REPO/n1dir/notes"
printf 'plain settings\n' > "$SCRATCH_REPO/n1dir/deploy/env/settings.txt"
printf 'plain readme\n' > "$SCRATCH_REPO/n1dir/config/credentials/readme.md"
printf 'plain notes\n' > "$SCRATCH_REPO/n1dir/notes/plain.txt"
git -C "$SCRATCH_REPO" add n1dir
git -C "$SCRATCH_REPO" commit -qm "local: 三个干净文件（两个落在 env/ 与 credentials/ 目录下）"
range_dir_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'changed settings\n' > "$SCRATCH_REPO/n1dir/deploy/env/settings.txt"
git -C "$SCRATCH_REPO" add n1dir/deploy/env/settings.txt
git -C "$SCRATCH_REPO" commit -qm "local: 只改 env/ 下那个文件"
printf 'changed readme\n' > "$SCRATCH_REPO/n1dir/config/credentials/readme.md"
git -C "$SCRATCH_REPO" add n1dir/config/credentials/readme.md
git -C "$SCRATCH_REPO" commit -qm "local: 只改 credentials/ 下那个文件"
DIR_PATHS="$(git -C "$SCRATCH_REPO" rev-list --objects "$range_dir_base..local" \
  | awk 'NF >= 2 { p = $0; sub(/^[^ ]+ /, "", p); print p }')"
assert_eq "2" "$(printf '%s\n' "$DIR_PATHS" \
  | grep -c -e '^n1dir/deploy/env$' -e '^n1dir/config/credentials$')" \
  "4b 前置：范围的对象清单里确实带上了这两个目录路径（否则这条断言没有判别力）"
DIR_ENV_TYPE="$(git -C "$SCRATCH_REPO" cat-file -t "$(git -C "$SCRATCH_REPO" rev-parse "local:n1dir/deploy/env")" 2>/dev/null)"
assert_eq "tree" "$DIR_ENV_TYPE" "4b 前置：n1dir/deploy/env 在该修订上是目录（tree）而不是文件"
assert_exit 0 "4b：目录名像凭据类文件名时不得报命中（内容全干净）" \
  -- "$SCAN" --range "$range_dir_base..local"
assert_eq "" "$("$SCAN" --range "$range_dir_base..local" 2>/dev/null)" \
  "4b：干净推送不产生任何命中行（env/ 与 credentials/ 是目录，不是文件）"
# 同一份内容经由 --staged：本来就干净（目录从来不是 staged 的单位）。这条说明上面那个形状是
# range 独有的，而不是规则本身太宽。
printf 'changed settings again\n' > "$SCRATCH_REPO/n1dir/deploy/env/settings.txt"
git -C "$SCRATCH_REPO" add n1dir/deploy/env/settings.txt
assert_exit 0 "4b：同一份内容经 --staged 不报（目录从不是 staged 的单位）" -- "$SCAN" --staged
git -C "$SCRATCH_REPO" reset -q n1dir/deploy/env/settings.txt
git -C "$SCRATCH_REPO" checkout -q -- n1dir/deploy/env/settings.txt
# 反面：同样的 basename 换成真文件时，规则必须照常命中（两个 basename 各一条）
range_dir_file_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
mkdir -p "$SCRATCH_REPO/n1dir/misc"
printf 'plain, no credential shape\n' > "$SCRATCH_REPO/n1dir/misc/credentials"
printf 'plain, no credential shape\n' > "$SCRATCH_REPO/n1dir/misc/env"
git -C "$SCRATCH_REPO" add n1dir/misc/credentials n1dir/misc/env
git -C "$SCRATCH_REPO" commit -qm "local: 两个真文件，basename 与那两个目录同名"
assert_exit 1 "4b：basename 相同的**真文件**仍必须命中（证明规则是活的）" \
  -- "$SCAN" --range "$range_dir_file_base..local"
dir_file_out="$("$SCAN" --range "$range_dir_file_base..local" 2>/dev/null)"
case "$dir_file_out" in
  *"n1dir/misc/credentials::path-secret-file: credentials"*) DIR_FILE_A="ok" ;;
  *) DIR_FILE_A="MISSING: ${dir_file_out}" ;;
esac
assert_eq "ok" "$DIR_FILE_A" "4b：真文件 credentials 的命中行是 <路径>::path-secret-file: credentials"
case "$dir_file_out" in
  *"n1dir/misc/env::path-secret-file: env"*) DIR_FILE_B="ok" ;;
  *) DIR_FILE_B="MISSING: ${dir_file_out}" ;;
esac
assert_eq "ok" "$DIR_FILE_B" "4b：真文件 env 同样命中（两条规则分支都是活的）"
assert_eq "2" "$(printf '%s\n' "$dir_file_out" | grep -c .)" \
  "4b：真文件夹具恰好两条命中（两个文件各一条，目录那条不再出现）"

# (10b) 范围里**加了又删**的凭据类路径：它不在右端 ACMR diff 里，只能靠对象清单进来；而它的对象
# 类型是 blob，故目录过滤（只留 blob）必须把它留下。这条钉住"过滤目录时不能顺手把删掉的文件也
# 滤掉"——修复轮 2 的实现专门用了**单位对象的类型**而不是"右端能不能解析"，就是为了保住它。
# 夹具内容必须**独一无二**：若这份字节在左端已可达（例如与前面某个文件同字节），对象清单根本
# 不会列出它（4b 起按对象寻址，见 §7.6），那时没有任何名字可用——那是这条设计边界，不是回归。
# 第一版夹具就是踩了这个坑（内容抄了前面两个文件），断言当场失败，故这里显式用独有字节。
range_dir_del_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'plain gone-key payload, unique to this deleted file\n' > "$SCRATCH_REPO/n1dir/misc/gone.key"
git -C "$SCRATCH_REPO" add n1dir/misc/gone.key
git -C "$SCRATCH_REPO" commit -qm "local: 加一个凭据类文件名（稍后删除）"
git -C "$SCRATCH_REPO" rm -q n1dir/misc/gone.key
git -C "$SCRATCH_REPO" commit -qm "local: 删掉它"
assert_eq "" "$(git -C "$SCRATCH_REPO" ls-tree -r --name-only local -- n1dir/misc/gone.key)" \
  "4b 前置：右端确实没有这个路径（所以它只能从对象清单进名字清单）"
assert_eq "1" "$(git -C "$SCRATCH_REPO" rev-list --objects "$range_dir_del_base..local" \
  | grep -c '^[0-9a-f]* n1dir/misc/gone.key$')" \
  "4b 前置：对象清单里确实有这条路径（独有字节 → 对象被枚举）"
assert_exit 1 "4b：范围内加了又删的凭据类文件名仍按 pathname 规则命中" \
  -- "$SCAN" --range "$range_dir_del_base..local"
case "$("$SCAN" --range "$range_dir_del_base..local" 2>/dev/null)" in
  "n1dir/misc/gone.key::path-secret-file: gone.key"*) DEL_KEY="ok" ;;
  *) DEL_KEY="MISSING" ;;
esac
assert_eq "ok" "$DEL_KEY" "4b：命中行是那个已被删掉的路径 + pathname 规则"
assert_eq "1" "$("$SCAN" --range "$range_dir_del_base..local" 2>/dev/null | grep -c .)" \
  "4b：这条夹具只产生 pathname 那一条命中（内容不含凭据形状）"

# ---------------------------------------------------------------------------
# (11) 跳过清单必须精确到"**这一个**文件"，不能是 basename/anywhere 的形状。
# `is_skipped` 的两条豁免各有正当理由：规则表自身必然匹配它自己的正则；`.sync/` 里放的就是
# "规则 + 路径 + 原因"，其中的路径正是某条路径类/环境类规则要匹配的东西。但旧写法是
# `*/patterns.tsv` 与 `*/"$SYNC_STATE_DIR"/*`——**任意目录、任意层级**。而两道 .sync/ 守卫都是
# **根锚定**的（apply.sh 的跟踪集检查用 pathspec `.sync/`，推送范围检查只认行首的 `.sync/`），
# 于是 `skills/<x>/patterns.tsv` 与嵌套的 `skills/<x>/.sync/**` 正好落进一条缝：G1/G2/G3 都不扫、
# 两道守卫都不拦——一份凭据形状的内容就这样被签发 PLAN_ID 并推上远端（review 实测的三个形状）。
# 本组用三条夹具钉住它：**两条必须命中**（旧写法整份跳过）+ **一条对照必须仍然命中**（否则
# "两条命中"也可能只是"内容规则坏了"）。每条夹具的字节都必须**独有**——与别的夹具同字节时，
# 对象清单根本不会枚举它，断言会因此失去判别力（§10b 与 G2 都踩过这个坑；本组第一版就把
# 字面量抄成了 G2 那一份，下面那条"确是新引入的"前置断言当场判红，这正是它存在的意义）。
# ---------------------------------------------------------------------------
skip_obj_in_range() { # oid range：该对象是否"范围内新引入"（否则名字清单里根本没有它）
  git -C "$SCRATCH_REPO" rev-list --objects "$2" \
    | awk -v o="$1" '$1 == o { n += 1 } END { print (n > 0 ? "yes" : "no") }'
}
sec_ctl="$(printf 'AKIA%s' 'IOSFODNN7EXAMPLB')"
sec_pat="$(printf 'AKIA%s' 'IOSFODNN7EXAMPLC')"
sec_nes="$(printf 'AKIA%s' 'IOSFODNN7EXAMPLA')"

# (11a) 对照：**普通路径**上的凭据形状必须命中。它同时是另外两条的前置——它绿，才说明
# "内容规则是活的、范围夹具是成立的"，另两条的失败才只可能是跳过清单太宽。
range_skip_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
mkdir -p "$SCRATCH_REPO/skills/rangefix/skipnarrow"
printf 'aws_key = %s\n' "$sec_ctl" > "$SCRATCH_REPO/skills/rangefix/skipnarrow/plain.txt"
git -C "$SCRATCH_REPO" add skills/rangefix/skipnarrow/plain.txt
git -C "$SCRATCH_REPO" commit -qm "local: 对照夹具（普通路径 + 独有字节的凭据形状）"
SKIP_CTL_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/skipnarrow/plain.txt)"
assert_eq "yes" "$(skip_obj_in_range "$SKIP_CTL_OID" "$range_skip_base..local")" \
  "F1 前置：对照夹具的字节在范围内确是新引入的（否则它不进名字清单，断言是同义反复）"
assert_exit 1 "F1 对照：普通路径上的凭据形状必须命中（内容规则与夹具都活着）" \
  -- "$SCAN" --range "$range_skip_base..local"
skip_ctl_out="$("$SCAN" --range "$range_skip_base..local" 2>/dev/null)"
case "$skip_ctl_out" in
  *"skills/rangefix/skipnarrow/plain.txt:1:cred-aws-access-key: "*) CTL_FMT="ok" ;;
  *) CTL_FMT="MISSING: ${skip_ctl_out}" ;;
esac
assert_eq "ok" "$CTL_FMT" "F1 对照：命中的是内容规则（这份字节确实被读过）"

# (11b) `skills/<x>/patterns.tsv`：名字与机制自己的规则表同名，但它**不是**那个文件。
# 旧写法把它整份跳过（既不扫内容，也不评估它的 pathname），而它会随推送发布。
range_pat_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'aws_key = %s\n' "$sec_pat" > "$SCRATCH_REPO/skills/rangefix/skipnarrow/patterns.tsv"
git -C "$SCRATCH_REPO" add skills/rangefix/skipnarrow/patterns.tsv
git -C "$SCRATCH_REPO" commit -qm "local: 名字与规则表同名的夹具（独有字节 + 凭据形状）"
SKIP_PAT_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/skipnarrow/patterns.tsv)"
assert_eq "yes" "$(skip_obj_in_range "$SKIP_PAT_OID" "$range_pat_base..local")" \
  "F1 前置：这份字节在范围内确是新引入的（同字节夹具不会被枚举，也就测不出跳过清单）"
assert_exit 1 "F1：skills/<x>/patterns.tsv 上的凭据形状必须命中（旧写法整份跳过，报 0 干净）" \
  -- "$SCAN" --range "$range_pat_base..local"
skip_pat_out="$("$SCAN" --range "$range_pat_base..local" 2>/dev/null)"
case "$skip_pat_out" in
  "skills/rangefix/skipnarrow/patterns.tsv:1:cred-aws-access-key: "*) PAT_FMT="ok" ;;
  *) PAT_FMT="MISSING: ${skip_pat_out}" ;;
esac
assert_eq "ok" "$PAT_FMT" "F1：命中行是那个路径 + 内容规则（字节确实被读过，不是只按文件名放过）"

# (11c) 嵌套的 `.sync/`：它既不在仓库根的 `.sync/`（两道守卫都只锚定根，管不到它），
# 也不是机制自己的规则表（不该被豁免），故它必须被扫到 —— 否则就是一处 G1/G2/G3 全失守、
# 两道守卫也全不管的静默绕过。
range_nes_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
mkdir -p "$SCRATCH_REPO/skills/rangefix/nested/.sync"
printf 'aws_key = %s\n' "$sec_nes" > "$SCRATCH_REPO/skills/rangefix/nested/.sync/leak.txt"
# -f：plan.sh 会把 `.sync/` 写进 .git/info/exclude 排除它（那是**仓库根**状态目录的守卫方式），
# 而这里的嵌套目录只是夹具的一部分，必须能入库。
git -C "$SCRATCH_REPO" add -f skills/rangefix/nested/.sync/leak.txt
git -C "$SCRATCH_REPO" commit -qm "local: 嵌套 .sync/ 下的夹具（独有字节 + 凭据形状）"
SKIP_NES_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/nested/.sync/leak.txt)"
assert_eq "yes" "$(skip_obj_in_range "$SKIP_NES_OID" "$range_nes_base..local")" \
  "F1 前置：这份字节在范围内确是新引入的"
assert_exit 1 "F1：嵌套 skills/<x>/.sync/** 下的凭据形状必须命中（旧写法报 0 干净）" \
  -- "$SCAN" --range "$range_nes_base..local"
skip_nes_out="$("$SCAN" --range "$range_nes_base..local" 2>/dev/null)"
case "$skip_nes_out" in
  "skills/rangefix/nested/.sync/leak.txt:1:cred-aws-access-key: "*) NES_FMT="ok" ;;
  *) NES_FMT="MISSING: ${skip_nes_out}" ;;
esac
assert_eq "ok" "$NES_FMT" "F1：命中行是嵌套 .sync/ 那个路径 + 内容规则"

# (11d) F4：范围扫描的起止进度必须打在 **stderr**。成本随范围线性（本仓库实测约 37ms/blob、
# 整段范围约 10s；长期分叉的首次推送到分钟级），全程静默会被读成"卡死了"——而那种误判正是
# `--no-verify` 的入口。stdout 是命中契约（`<path>:<line>:<rule-id>: …`），一个字都不能多。
PROG_OUT="$SCRATCH/prog.out"
PROG_ERR="$SCRATCH/prog.err"
PROG_RC=0
"$SCAN" --range "$range_skip_base..local" > "$PROG_OUT" 2> "$PROG_ERR" || PROG_RC=$?
assert_eq "1" "$PROG_RC" "F4 前置：这条范围确实命中（要测的是命中时进度照样可见）"
assert_eq "1" "$(grep -c '^范围扫描开始：' "$PROG_ERR")" \
  "F4：范围扫描开始时打一行进度到 stderr"
assert_eq "1" "$(grep -c '^范围扫描完成：用时 ' "$PROG_ERR")" \
  "F4：范围扫描结束时打一行进度（含用时）到 stderr"
assert_eq "1" "$(grep -c "^范围扫描开始：.*$range_skip_base..local" "$PROG_ERR")" \
  "F4：开始那行报出本次扫的范围（否则读的人不知道卡的是哪一段）"
assert_eq "0" "$(grep -c '范围扫描' "$PROG_OUT")" \
  "F4：进度行绝不混进 stdout（那是命中契约，解析方按行取路径）"

# (11e) 跳过清单收窄之后，**旁路**（`oid_has_scan_name`）仍然必须活着：它管的是"git 给这份字节
# 打印的那个路径恰好在跳过清单上，而同一份字节在范围内还有别的、不被跳过的名字"。这类形状今天
# 只剩**仓库根 `.sync/`** 一种，而它仍然可能真的发生（状态目录先被误提交、内容又出现在别处）。
# 去掉这条旁路（改成"打印的路径在清单上就整份跳过"）会静默漏扫——本组就是它的回归锚点。
# 判别力前置：git 必须真的为这份字节打印那一个 `.sync/` 路径，否则"扫到了"不构成旁路的证据。
# 字节还必须**独有**：这里刻意换了一条**别的形状**的凭据（不是本文件里用了一路的 `aws_key = …`
# 与 `AKIA…` 字面量），否则撞上前面某个夹具的同一份字节时，对象根本不会被枚举——本组第一版
# 就是这么撞上的（与 §7b 的夹具同字节，下面那条前置断言当场判红）。
SKIP2_ROOT="$SCRATCH_REPO/.sync/skipdup.txt"
SKIP2_VIS="$SCRATCH_REPO/skills/rangefix/skipdup/visible.txt"
mkdir -p "$SCRATCH_REPO/skills/rangefix/skipdup"
range_dup2_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
sec_dup2="$(printf 'AIza%s' 'SysDup2Fixture0123456789abcdefghijkl')"
printf 'google_api_key = %s\n' "$sec_dup2" > "$SKIP2_ROOT"
cp "$SKIP2_ROOT" "$SKIP2_VIS"
# 先提 .sync/ 那份、再提普通那份：git 的 `rev-list --objects` 对同一个 blob 只打印**一个**路径
#（这里是先遇到的那一个），下面用前置断言把这个事实钉死。
# -f：plan.sh 会把 `.sync/` 写进 .git/info/exclude（那是根状态目录的守卫方式），夹具必须能入库。
git -C "$SCRATCH_REPO" add -f .sync/skipdup.txt
git -C "$SCRATCH_REPO" commit -qm "local: 根 .sync/ 下放一份字节（跳过清单形状）"
git -C "$SCRATCH_REPO" add skills/rangefix/skipdup/visible.txt
git -C "$SCRATCH_REPO" commit -qm "local: 同一份字节出现在普通路径上"
SKIP2_OID="$(git -C "$SCRATCH_REPO" rev-parse local:.sync/skipdup.txt)"
assert_eq "$(git -C "$SCRATCH_REPO" rev-parse local:skills/rangefix/skipdup/visible.txt)" "$SKIP2_OID" \
  "F1 前置：\.sync/ 那一份与普通路径是同一份字节"
SKIP2_PRINTED="$(git -C "$SCRATCH_REPO" rev-list --objects "$range_dup2_base..local" \
  | awk -v o="$SKIP2_OID" '$1 == o { p = $0; sub(/^[^ ]+ /, "", p); print p }')"
assert_eq ".sync/skipdup.txt" "$SKIP2_PRINTED" \
  "F1 前置：对象清单为这份字节打印的正是被跳过清单命中的那个路径（否则这条没有判别力）"
assert_exit 1 "F1：跳过清单上的路径 + 别处的同字节副本 → 整份字节仍必须扫" \
  -- "$SCAN" --range "$range_dup2_base..local"
skip_dup2_out="$("$SCAN" --range "$range_dup2_base..local" 2>/dev/null)"
DUP2_RULE="no"
case "$skip_dup2_out" in *cred-google-api-key*) DUP2_RULE="yes" ;; esac
assert_eq "yes" "$DUP2_RULE" "F1：命中的是内容规则（旁路生效：这份字节确实被读过）"
DUP2_LEAK="no"
case "$skip_dup2_out" in *"$sec_dup2"*) DUP2_LEAK="yes" ;; esac
assert_eq "no" "$DUP2_LEAK" "F1：旁路夹具的命中同样只给掩码片段"

# ---------------------------------------------------------------------------
# (12) 规则表豁免**删除**：跳过集现在只剩"**仓库根**的 `.sync/*`"一项，与守卫集逐点一致。
# 旧实现把"机制自己的那一个规则表文件"也豁免掉（仓库相对与绝对两种写法）—— 而那条豁免
# **没有任何守卫兜底**：写进规则表的凭据被三道闸门全部跳过，apply 的两道守卫（都只锚定
# `.sync/`）也都不管它，于是它会拿到 PLAN_ID 并被推上远端。豁免的理由是"表正文里写着全部
# 正则与示例，将来某条规则可能匹配到规则表文本"—— 实测（控制器复验 R221）今天这张表
# **并不自我命中**，故那条豁免只是"精确的保险"而非必需（12a 把这条事实钉成回归锚点）。
# 删掉它还顺带把 `--paths skills/upstream-sync` 这条**自净检查**从半空转变成了真扫描：
# 此前它每次都跳过自己那张表，"被跳过"与"真的干净"不可区分。
#
# 本组锚点：
#   12a 出厂规则表在**任何**路径下都必须干净（含机制自己的那一个路径）—— 删豁免不得把表
#       本身变成假阳性；
#   12b/12c/12d 把一份**真凭据**写进机制自己的那一个规则表文件，三种传法（`--paths` 的
#       两种写法、`--staged`、`--range`）都必须命中 —— 判别性的 RED→GREEN 锚点；
#   12e 仓库根 `.sync/` 的豁免**保留**，它是有守卫的那一条（配对说明见本组末尾）。
# 每条夹具的字节都独有（`…EXAMPL8` / `…EXAMPL0`，与 §9–§11 用过的字面量互不相同），并带
# "这份字节真的进了待扫集合"的前置断言 —— 本项目两次踩过"夹具字节与别的夹具重复 → 按对象
# 或按路径枚举根本列不到它"的坑（§10b 与 §11e 的第一版）。
# ---------------------------------------------------------------------------
MECHFIX_REL="skills/upstream-sync/scripts"
MECHFIX="$SCRATCH_REPO/$MECHFIX_REL"
mkdir -p "$MECHFIX"
cp "$MECH/scan-sensitive.sh" "$MECH/sync-lib.sh" "$MECH/patterns.tsv" "$MECHFIX/"
MECHFIX_SCAN="$MECHFIX/scan-sensitive.sh"
MECHFIX_PAT="$MECHFIX/patterns.tsv"
# 只有把机制复制到**同一个仓库相对路径**上，规则表才既落在 ROOT 之下（仓库相对写法可比），
# 又能被 `--paths` 以绝对路径传进来（绝对写法可比）—— 旧实现那两条 arm 恰好各认一种写法。
assert_eq "$MECHFIX_REL/patterns.tsv" "${MECHFIX_PAT#"$SCRATCH_REPO"/}" \
  "12 前置：夹具里的规则表与机制本体处在同一个仓库相对路径上（两种写法才都能被审到）"

# (12a) 出厂规则表不自我命中：把它原样复制到**非豁免**路径上扫，必须干净且零输出。
cp "$MECH/patterns.tsv" "$FIX/patcopy.tsv"
cmp -s "$MECH/patterns.tsv" "$FIX/patcopy.tsv" && PAT_SAME=ok || PAT_SAME=differs
assert_eq "ok" "$PAT_SAME" "12a 前置：非豁免路径上那份是出厂表的逐字节副本（结论才能迁回仓库里那张表）"
assert_exit 0 "12a：出厂规则表的字节本身不自我命中（复制到非豁免路径扫仍然干净）" \
  -- "$SCAN" --paths "$FIX/patcopy.tsv"
assert_eq "0" "$("$SCAN" --paths "$FIX/patcopy.tsv" 2>/dev/null | grep -c . || true)" \
  "12a：而且一个字都不输出（干净是无输出，不是有输出但退出码为 0）"
# 出厂表在**机制自己那个路径**上同样必须干净 —— 这条就是"删豁免不产生假阳性"的锚点，也是
# `--paths skills/upstream-sync` 那条自净检查在删豁免之后真的在扫这张表的等价物。
assert_exit 0 "12a：出厂规则表在机制自己的路径上也必须干净（删豁免不得带来假阳性）" \
  -- "$MECHFIX_SCAN" --paths "$MECHFIX_PAT"
assert_eq "0" "$("$MECHFIX_SCAN" --paths "$MECHFIX_PAT" 2>/dev/null | grep -c . || true)" \
  "12a：机制自己那个路径上的出厂表同样零输出"

# (12b) 把一行**真凭据**写进机制自己的规则表。写法必须让表仍然是**合法**规则表（4 个 TAB
# 字段、kind 合法、正则能编译）—— 否则扫描器会以 2"规则表不可用"fail closed，那是另一条
# 路径，测不到"这份字节被读到了"。故把凭据写进一条新规则的 desc：表有效，而字节里确实有
# 一份真凭据（这也是最可能真实发生的形状：有人把要豁免的原文抄进了表里）。
sec_tab="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL8')"
printf 'x-tab-fixture\tcontent\tzzz-tab-fixture-no-match\t现场示例：aws_key = %s（事后应删除）\n' \
  "$sec_tab" >> "$MECHFIX_PAT"
assert_eq "4" "$(awk -F"$(printf '\t')" 'END { print NF }' "$MECHFIX_PAT")" \
  "12b 前置：新写进去的那一行仍是 4 个 TAB 字段（表仍然合法，走的不是 exit 2 那条路）"
assert_eq "1" "$(find "$MECHFIX" -type f | LC_ALL=C grep -cxF -- "$MECHFIX_PAT" || true)" \
  "12b 前置：这张表确实在 --paths 传目录时枚举到的集合里（否则目录那条断言是同义反复）"
TAB_REL_RC=0
( cd "$SCRATCH_REPO" && bash "$MECHFIX_SCAN" --paths "skills/upstream-sync/scripts/patterns.tsv" ) \
  > "$SCRATCH/tabrel.out" 2>/dev/null || TAB_REL_RC=$?
assert_eq "1" "$TAB_REL_RC" \
  "12b：凭据写进机制自己的规则表 + 仓库相对写法 → 必须命中（旧实现整份跳过，报 0 干净）"
assert_eq "1" "$(awk -F: '$1 == "skills/upstream-sync/scripts/patterns.tsv" && $3 == "cred-aws-access-key" { n += 1 } END { print n + 0 }' "$SCRATCH/tabrel.out")" \
  "12b：命中行报出仓库相对路径 + 内容规则（字节确实被读过，不是只按文件名放过）"
assert_exit 1 "12b：同一份字节以**绝对路径**交给 --paths → 同样必须命中（旧实现两条写法各豁免一次）" \
  -- "$MECHFIX_SCAN" --paths "$MECHFIX_PAT"
assert_exit 1 "12b：把整个机制目录交给 --paths → 也必须命中（自净检查从此真的扫规则表）" \
  -- "$MECHFIX_SCAN" --paths "$MECHFIX"

# (12c) 同一个形状走 `--staged`（G2 读的是**索引 blob**）：索引此刻必须干净，否则命中就不再
# 是这一份字节的证据。
assert_eq "" "$(git -C "$SCRATCH_REPO" diff --cached --name-only)" \
  "12c 前置：索引在这一刻是空的（否则 --staged 会连带扫到别的夹具，命中失去判别力）"
git -C "$SCRATCH_REPO" add -f skills/upstream-sync/scripts/patterns.tsv
assert_eq "skills/upstream-sync/scripts/patterns.tsv" \
  "$(git -C "$SCRATCH_REPO" diff --cached --name-only)" \
  "12c 前置：这份字节确实进了 --staged 的枚举集合（否则断言是同义反复）"
# 用**夹具里那个**扫描器：只有它的 `$PATTERNS` 落在 ROOT 之下（仓库相对写法才成立）。用
# 本仓库那一个 `$SCAN` 测这一条是**同义反复** —— 本仓库不在夹具仓库里，它的 `$PATTERNS_REL`
# 恒为空，那条豁免根本不会被评估（12c/12d 的第一版就是这么假绿的）。
assert_exit 1 "12c：凭据写进机制自己的规则表 + 已 git add → --staged 必须命中（旧实现整份跳过）" \
  -- "$MECHFIX_SCAN" --staged
git -C "$SCRATCH_REPO" reset -q skills/upstream-sync/scripts/patterns.tsv

# (12d) 同一个形状走 `--range`（该范围**新引入的全部 blob**，也就是 git push 会发布的那批）。
range_tab_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
git -C "$SCRATCH_REPO" add skills/upstream-sync/scripts/scan-sensitive.sh \
  skills/upstream-sync/scripts/sync-lib.sh skills/upstream-sync/scripts/patterns.tsv
git -C "$SCRATCH_REPO" commit -qm "local: 机制副本 + 规则表里的一项真凭据"
TAB_OID="$(git -C "$SCRATCH_REPO" rev-parse local:skills/upstream-sync/scripts/patterns.tsv)"
assert_eq "yes" "$(skip_obj_in_range "$TAB_OID" "$range_tab_base..local")" \
  "12d 前置：这份字节在范围内确是新引入的（否则对象清单不列它，断言没有判别力）"
assert_exit 1 "12d：同一个形状在 --range 下必须命中" \
  -- "$MECHFIX_SCAN" --range "$range_tab_base..local"
assert_eq "1" "$("$MECHFIX_SCAN" --range "$range_tab_base..local" 2>/dev/null \
  | awk -F: '$1 == "skills/upstream-sync/scripts/patterns.tsv" && $3 == "cred-aws-access-key" { n += 1 } END { print n + 0 }')" \
  "12d：命中行报出仓库相对路径 + 内容规则"

# (12e) 仓库根 `.sync/` 的豁免**保留**：它的理由没有被推翻（白名单条目按定义就是"规则 + 路径 +
# 原因"，其中的路径正是路径类规则要匹配的东西；不排除它，allowlist.txt 会被它自己豁免的那条
# 规则抓住，而且没法给自己再写一条豁免）。它也不是"跳过但无守卫"的缝：跳过侧在下面断言，
# 守卫侧由 test-apply-gate.sh 的既有锚点钉住（本任务不改动那些锚点，只靠套件整体回归）——
# A1b：`.sync/` 已进跟踪集 → apply exit 5；A1 与 N1c：推送范围里含行首 `.sync/` → apply exit 5。
range_sync_base="$(git -C "$SCRATCH_REPO" rev-parse local)"
sec_sync="$(printf 'AKIA%s' 'IOSFODNN7EXAMPL0')"
printf 'aws_key = %s\n' "$sec_sync" > "$SCRATCH_REPO/.sync/keeponly.txt"
# -f：plan.sh 会把根 `.sync/` 写进 .git/info/exclude（那是根状态目录的守卫方式），夹具必须能入库。
git -C "$SCRATCH_REPO" add -f .sync/keeponly.txt
git -C "$SCRATCH_REPO" commit -qm "local: 根 .sync/ 下只放这一份凭据"
SYNC_ONLY_OID="$(git -C "$SCRATCH_REPO" rev-parse local:.sync/keeponly.txt)"
assert_eq "yes" "$(skip_obj_in_range "$SYNC_ONLY_OID" "$range_sync_base..local")" \
  "12e 前置：这份字节在范围内确是新引入的（否则对象清单不列它，断言失去判别力）"
assert_exit 0 "12e：仓库根 .sync/ 下的凭据仍被跳过（有意保留的那一条豁免）" \
  -- "$SCAN" --range "$range_sync_base..local"
assert_eq "0" "$("$SCAN" --range "$range_sync_base..local" 2>/dev/null | grep -c . || true)" \
  "12e：这一段范围里没有别的字节，输出必须为空（即确是被跳过，而非扫过但没命中）"
assert_exit 0 "12e：--paths 传仓库根的 .sync/ 文件同样被跳过（保留的那条 arm 仍然生效）" \
  -- "$SCAN" --paths "$SCRATCH_REPO/.sync/keeponly.txt"
# 对照：同一份字节换个**非豁免**路径就必须命中 —— 否则"跳过"也可能只是这份字节根本抓不住。
printf 'aws_key = %s\n' "$sec_sync" > "$FIX/syncctl.txt"
assert_exit 1 "12e 对照：同一份字节放在非豁免路径上必须命中（说明跳过的确是路径在起作用）" \
  -- "$SCAN" --paths "$FIX/syncctl.txt"
# 12e 的配对（跳过 ↔ 守卫）：跳过侧在上面。守卫侧是 test-apply-gate.sh 里的 A1b 与 A1/N1c
# （`.sync/` 已进跟踪集 → 5；推送范围含行首 `.sync/` → 5）。跳过集与守卫集在**这一项**上
# 配对，才使这条豁免是"有守卫的豁免"；规则表那一项没有这样的守卫，故它被删除（见 12b–12d）。

# ---------------------------------------------------------------------------
# 规则表结构：read 按 TAB 拆字段，字段错位会让规则静默失效（例如描述里多一个 TAB
# 就会把正则挤到 desc 上，规则从此不再命中）。id 重复则白名单的"规则+路径"不再是唯一对。
# ---------------------------------------------------------------------------
PATTERNS="$MECH/patterns.tsv"
P_SHAPE="$(awk -F"$(printf '\t')" '
  NF != 4 { bad = bad " fields:" NR }
  $2 != "content" && $2 != "pathname" { bad = bad " kind:" NR }
  $3 == "" { bad = bad " empty-regex:" NR }
  $1 == "" { bad = bad " empty-id:" NR }
  seen[$1]++ == 1 { bad = bad " dup-id:" $1 }
  END { print (bad == "" ? "ok" : "bad" bad) }
' "$PATTERNS")"
assert_eq "ok" "$P_SHAPE" "规则表每行 4 个 TAB 字段、kind 合法、id 唯一、正则非空"

# ---------------------------------------------------------------------------
# 扫描结果必须真正进入 sync_state_hash。判别方式：把机制脚本与规则表复制到仓库外，
# 只往"副本"规则表里追加一条规则 —— 工作区、提交、状态一律不动，因此哈希若变化，
# 变化只可能来自扫描结果。用真脚本直接改仓库里的 patterns.tsv 会污染工作区。
# ---------------------------------------------------------------------------
SEC_DIR="$SCRATCH/sec"
mkdir -p "$SEC_DIR"
cp "$MECH/sync-lib.sh" "$MECH/scan-sensitive.sh" "$MECH/patterns.tsv" "$SEC_DIR/"
mkdir -p "$SCRATCH_REPO/skills/scanfixture"
printf 'syncscanfx-present\n' > "$SCRATCH_REPO/skills/scanfixture/SKILL.md"
git -C "$SCRATCH_REPO" add skills/scanfixture
git -C "$SCRATCH_REPO" commit -qm "local: 扫描哈希夹具"

. "$SEC_DIR/sync-lib.sh"
h_scan_base="$(sync_state_hash)"
printf 'scan-fx\tcontent\tsyncscanfx[-]present\t测试用规则：只存在于副本\n' >> "$SEC_DIR/patterns.tsv"
h_scan_rule="$(sync_state_hash)"
if [ "$h_scan_base" = "$h_scan_rule" ]; then
  assert_eq "变化" "未变化" "扫描结果必须进入 sync_state_hash"
else
  assert_eq "changed" "changed" "扫描结果必须进入 sync_state_hash"
fi

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
