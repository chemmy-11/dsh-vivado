# -*- coding: utf-8 -*-
r"""make_template.py — 从已实证的现役预设 bundle 原样抽取 22 条 shipped 插件行，
生成 dsh-vivado 的**唯一**模板 `templates/preset.patch.yml.tmpl`（带 {{PLACEHOLDER}}）。

为什么这样生成（不是手抄）：
  现役 `作者本机笔记库\.dsh\bundles\vivado-preset\cordis.patch.yml` 的 22 行是上一轮
  (作者本机的规范化取证记录（未随仓库发布）§2.2) 用 asar 解析器从 shipped
  `dsh-web-app/presets/standard.patch.yml` 原样导出、并断言逐字节一致的产物。
  本脚本**只做两处允许的改动**，其余字符逐字节保留：
    ① 把 persona 行那一块替换成 {{PERSONA_BLOCK}}（由 templates/persona/<tier>.frag.yml 提供）；
    ② 给 skill-filesystem 行加 config.customSkillDirs（rank 300 自定义技能根）。
  末尾再追加 mcp-vivado 行（同样来自现役 bundle，硬件相关值参数化）。

用法：
  py tools\make_template.py            # 重新生成（幂等；不改就字节不变）
  py tools\make_template.py --check    # 只校验，不一致则 exit 1

约束：
  * 只用 stdlib（py 3.9+）。
  * 行尾统一 LF；读入时先把 CRLF 归一，并对「归一后与原文件逐行相等」做断言。
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KITROOT = HERE.parent
TPL = KITROOT / "templates"
# The provenance source is a project-local bundle patch on the *authoring* machine, so it is a
# required argument instead of a constant: a hardcoded home path must never ship inside the kit.
# Recorded fact (for the maintainer): it was 作者本机笔记库\.dsh\bundles\vivado-preset\cordis.patch.yml
DEFAULT_SRC = None
# Any "<drive>:\Users\<name>\" home path: catches a personal path without hardcoding this
# author's account name in the shipped tool.
HOME_PATH_RE = re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\\/\s\"']+[\\/]")

SHIPPED_OUT = TPL / "shipped-standard-22rows.yml"
TMPL_OUT = TPL / "preset.patch.yml.tmpl"

PERSONA_MARK = "          - id: persona"
ROW_PREFIX = "          - id: "
MCP_ID = "mcp-vivado"
# 审计件里 persona 行的替身：pre-kit 的 persona 含作者机器绝对路径，不作为随包内容分发
PERSONA_AUDIT_MARK = (
    "          # <persona row omitted from this audit copy: the pre-kit persona carried the author's "
    "absolute paths.>\n"
    "          # <It is replaced by templates/persona/<tier>.frag.yml at render time.>\n"
)
SKILLFS_ID = "skill-filesystem"


def norm(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def read_src(src: Path) -> str:
    if not src.is_file():
        raise SystemExit(f"[ERROR] 现役 bundle 不存在: {src}")
    raw = src.read_bytes()
    # 归一断言：CRLF 归一前后只差行尾字节，内容逐行一致
    text = norm(raw.decode("utf-8"))
    raw_lf = raw.replace(b"\r\n", b"\n")
    assert text.encode("utf-8") == raw_lf, "CRLF 归一后与原始字节不一致（不是纯 CRLF 文件）"
    return text


def split_sections(text: str):
    lines = text.split("\n")
    ins = next(i for i, ln in enumerate(lines) if ln.startswith("- insert:"))
    # 只数 `plugins:` 下第 10 列（10 空格缩进）的顶层插件行；group 内的嵌套 id 缩进更深，不算
    ids = [(i, re.match(r"^ {10}- id: (\S+)$", ln)) for i, ln in enumerate(lines)]
    rows = [(i, m.group(1)) for i, m in ids if m]
    names = [n for _, n in rows]
    if len(names) != 23 or MCP_ID not in names:
        raise SystemExit(f"[ERROR] 期望 22 条 shipped 插件行 + mcp 行（共 23 条顶层行），实际 {len(names)}: {names}")
    if names.index(MCP_ID) != 22:
        raise SystemExit(f"[ERROR] mcp-vivado 不是最后一行：{names}")
    plugin_rows = rows[:22]  # 22 条 shipped 插件行（不含 mcp 行）
    return lines, ins, plugin_rows, rows[22]


def build(src: Path) -> dict[str, str]:
    text = read_src(src)
    lines, ins, plugin_rows, mcp_row = split_sections(text)
    body_start = plugin_rows[0][0]
    body_end = plugin_rows[-1][0]
    # 22 条插件行块：从第一条 `- id:` 起，到下一条（mcp 行）之前的最后一个非空/非注释行
    mcp_start = mcp_row[0]
    # 回溯 mcp 行之前属于 mcp 注释块的连续 `#` 行（不属 shipped 22 行）
    end = mcp_start
    while end > body_end + 1 and lines[end - 1].lstrip().startswith("#"):
        end -= 1
    # shipped 22 行：去掉尾部空行
    block = lines[body_start:end]
    while block and block[-1].strip() == "":
        block.pop()
    shipped = "\n".join(block) + "\n"
    n_rows = len(re.findall(r"^          - id: ", shipped, re.M))
    assert n_rows == 22, f"[ERROR] shipped 行数 {n_rows} != 22"

    # --- ① persona 块 -> {{PERSONA_BLOCK}} ---
    persona_start = shipped.index(PERSONA_MARK)
    after_persona = shipped.index("          - id: agent-instructions")
    persona_block = shipped[persona_start:after_persona]
    shipped_no_persona = (
        shipped[:persona_start]
        + "{{PERSONA_BLOCK}}\n"
        + shipped[after_persona:]
    )
    # 审计件（随包的那份）不含 persona：pre-kit 的 persona 里写着作者机器的绝对路径，
    # 它本来就是我们自己的文本、不是 shipped 内容，所以只对「其余 21 行」做逐字节溯源。
    audit = (
        shipped[:persona_start]
        + PERSONA_AUDIT_MARK
        + shipped[after_persona:]
    )
    # --- ② skill-filesystem 行加 customSkillDirs ---
    sf = (
        "          - id: skill-filesystem\n"
        "            name: '@deepseek-ai/dsh-skill-filesystem'\n"
    )
    if sf not in shipped_no_persona:
        raise SystemExit("[ERROR] 找不到 skill-filesystem 行原样文本")
    sf_new = (
        sf
        + "            config:\n"
        + "              # rank 300「custom」根：kit 随包技能。includeDefaultRoots 保持默认 true，\n"
        + "              # 使用者自己的项目/用户技能根照旧生效，不被本包挤掉。\n"
        + "              customSkillDirs:\n"
        + "                - '{{SKILLS_DIR}}'\n"
    )
    shipped_final = shipped_no_persona.replace(sf, sf_new, 1)

    # --- mcp-vivado 行：从现役 bundle 原样取，把机器相关值换成占位符 ---
    mcp_block = lines[mcp_start:]
    # 去掉末尾空行
    while mcp_block and mcp_block[-1].strip() == "":
        mcp_block.pop()
    mcp = "\n".join(mcp_block) + "\n"
    # 机器相关值按**模式**参数化，而不是按作者本机的字面值：这样任何人的 bundle patch
    # （同一套 shipped 行、只是路径不同）都能被本工具重新抽取成模板。
    subs = [
        (r"(?m)^(\s+command: )'[^'\n]*'", r"\1'{{MCP_PYTHON}}'"),
        (r"(?m)^(\s+PYTHONPATH: )'[^'\n]*'", r"\1'{{MCP_SITE}}'"),
        (r"(?m)^(\s+VIVADO_PATH: )'[^'\n]*'", r"\1'{{VIVADO_BAT}}'"),
        (r"(?m)^(\s+cwd: )'[^'\n]*'", r"\1'{{MCP_CWD}}'"),
        (r"(?m)^(\s+TEMP: )'[^'\n]*'", r"\1'{{TEMP_DIR}}'"),
        (r"(?m)^(\s+TMP: )'[^'\n]*'", r"\1'{{TEMP_DIR}}'"),
    ]
    for pattern, repl in subs:
        mcp, n = re.subn(pattern, repl, mcp)
        if n != 1:
            raise SystemExit(f"[ERROR] mcp 行里 {pattern!r} 命中 {n} 次（应为 1）")
    # 注释里的机器事实改成 kit 中立表述（保留「为什么」，去掉「哪台机」）
    mcp = re.sub(
        r"                # 4\) TEMP/TMP.*?\n(?=                TEMP:)",
        "                # 4) TEMP/TMP 必须纯 ASCII —— 不靠系统默认，由本行钉死。\n"
        "                #    换机/换用户即可能带中文，Vivado Tcl 的 GBK 解码会坏；\n"
        "                #    故指向 config.yml 的 temp_dir（install.ps1 已校验纯 ASCII，doctor 复检）。\n",
        mcp,
        flags=re.S,
    )
    mcp_header = (
        "          # --- vivado-mcp（32 工具）挂成本地 stdio MCP server，工具名 mcp__vivado__*。\n"
        "          # dsh-vivado：下面 6 个机器相关值全部由 install.ps1 从 config.yml 渲染，勿手改渲染产物。\n"
        "          # 三条硬约束（都是踩过的坑，别改）：\n"
        "          #   1) PYTHONPATH 必须显式指向 vivado-mcp 的 site 目录；否则 venv 内的 .pth 可能把 import\n"
        "          #      引到别处的副本 → start_session 静默失败。\n"
        "          #   2) toolCallTimeoutMs 必须远大于默认 60000：run_synthesis 默认 wait=True，全量综合可跑几分钟。\n"
        "          #   3) cwd 必须纯 ASCII（中文路径经 Vivado Tcl 的 GBK 解码会坏）。\n"
        "          # 排障：工具不出现先查 ① 会话是否用了 Vivado 预设 ② compatibility.json 是否带 mcp-client 版本豁免；\n"
        "          #       兜底走 CLI 桥 py <vivado-mcp>\\mcp_ctl.py list|call|session。\n"
    )
    if re.search(r"D:\\|C:\\Users\\", mcp):
        raise SystemExit("[ERROR] mcp 行仍残留硬编码绝对路径")
    mcp = mcp_header + mcp

    header = f"""# dsh-vivado — Vivado 会话预设（bundle 层，DSH bundle patch 方言）
#
# 【不要手改本文件】它由 tools/render_patch.ps1 从 templates/preset.patch.yml.tmpl 渲染。
# 模板由 tools/make_template.py 生成：22 条 shipped 插件行原样取自已实证的现役 bundle
#   作者本机笔记库\\.dsh\\bundles\\vivado-preset\\cordis.patch.yml（作者本机路径，不属于本分发件）
#   （该文件已自证与 shipped dsh-web-app/presets/standard.patch.yml 逐字节一致，
#     见 作者本机的规范化取证记录（未随仓库发布） §2.2）
# 只做两处允许的改动：persona 换成本 kit 的版本分档片段、skill-filesystem 加 customSkillDirs；
# 末尾追加 mcp-vivado 行（硬件相关值参数化）。
#
# shipped-22 行 sha256（归一 LF 后，不含 persona/skill-filesystem 改动）：
#   {hashlib.sha256(shipped.encode()).hexdigest()}
# 生效需**重启宿主**（Electron 下 dsh-hmr 不生效）；新会话创建时选 `Vivado` 预设。
- insert:
    - id: preset-vivado
      name: '@deepseek-ai/dsh-agent-preset'
      config:
        id: vivado
        name: Vivado
        description: 'Vivado/FPGA 会话：挂 vivado-mcp（{{{{TOOL_COUNT}}}} 工具）+ 全局串行/ASCII 路径/证据纪律 + kit 自带技能（dsh-vivado {{{{KIT_VERSION}}}}）。'
        order: 2
        plugins:
{shipped_final}{mcp}"""
    # 分发件卫生：随包文本里不许出现某台机器的用户目录或非 ASCII 路径
    for name, blob in (("tmpl", header), ("shipped-22rows", audit)):
        hit = HOME_PATH_RE.search(blob)
        if hit:
            raise SystemExit(f"[ERROR] {name} 仍含个人路径片段 {hit.group(0)!r}，拒绝生成")
    audit_doc = AUDIT_HEADER + f"#   {hashlib.sha256(shipped.encode()).hexdigest()}\n" + audit
    return {"shipped": shipped, "audit": audit_doc, "tmpl": header}


AUDIT_HEADER = """# shipped-standard-22rows.yml -- provenance audit copy (NOT an install input).
#
# This file exists to prove that the 22 plugin rows inside the rendered patch are the shipped
# `@deepseek-ai/dsh-web-app/presets/standard.patch.yml` content, not hand-copied text.
# Source: the previously verified project-local bundle patch
#   作者本机笔记库\\.dsh\\bundles\\vivado-preset\\cordis.patch.yml
#   (proven byte-identical to the shipped preset in
#    作者本机的规范化取证记录（未随仓库发布） §2.2)
# Rows 2-22 below are byte-identical to that source (line endings normalized to LF).
# The persona row is intentionally replaced by a comment: the pre-kit persona was OUR text and
# carried the author's absolute paths, so it must not travel inside a distributed kit.
# sha256 of the full verbatim 22 rows (persona included, LF-normalized):

"""


EXPECTED_PLACEHOLDERS = {'PERSONA_BLOCK', 'SKILLS_DIR', 'MCP_PYTHON', 'MCP_SITE', 'VIVADO_BAT',
                         'MCP_CWD', 'TEMP_DIR', 'TOOL_COUNT', 'KIT_VERSION'}


def self_check() -> int:
    """Verify the committed template/audit pair without the (author-only) source bundle.

    Checks: both files exist; the audit copy carries 21 shipped rows + the mcp row and the
    template carries the same row ids in the same order plus {{PERSONA_BLOCK}}; the recorded
    shipped-22 sha256 line is present in both; the template's placeholder set is exactly the
    renderer's contract; no author home path leaks into either file.
    """
    problems: list[str] = []
    if not TMPL_OUT.is_file():
        problems.append(f"missing {TMPL_OUT}")
    if not SHIPPED_OUT.is_file():
        problems.append(f"missing {SHIPPED_OUT}")
    if problems:
        for p in problems:
            print(f"[FAIL] {p}")
        return 1
    tmpl = TMPL_OUT.read_text(encoding="utf-8")
    audit = SHIPPED_OUT.read_text(encoding="utf-8")
    audit_rows = re.findall(r"^ {10}- id: (\S+)$", audit, re.M)
    got_rows = re.findall(r"^ {10}- id: (\S+)$", tmpl, re.M)
    # the audit copy holds the 21 shipped rows that survive (the persona row is replaced by a
    # comment); the template additionally carries the appended mcp-vivado row.
    if got_rows != audit_rows + [MCP_ID]:
        problems.append(f"template rows {got_rows} != audit rows + {MCP_ID} {audit_rows + [MCP_ID]}")
    if "{{PERSONA_BLOCK}}" not in tmpl:
        problems.append("template lost the {{PERSONA_BLOCK}} marker")
    if len(audit_rows) != 21:
        problems.append(f"audit copy should carry 21 shipped rows (persona excluded), got {len(audit_rows)}")
    if "persona row omitted" not in audit:
        problems.append("audit copy lost the persona-omission note")
    sha_tmpl = re.search(r"sha256[\s\S]{0,300}?([0-9a-f]{64})", tmpl)
    sha_audit = re.search(r"sha256[\s\S]{0,300}?([0-9a-f]{64})", audit)
    if not sha_tmpl or not sha_audit:
        problems.append("shipped-22 sha256 line missing in template or audit copy")
    elif sha_tmpl.group(1) != sha_audit.group(1):
        problems.append(f"sha256 mismatch: template {sha_tmpl.group(1)} vs audit {sha_audit.group(1)}")
    got_ph = set(re.findall(r"\{\{(\w+)\}\}", tmpl))
    if got_ph != EXPECTED_PLACEHOLDERS:
        problems.append(f"placeholder set changed: {sorted(got_ph)} != {sorted(EXPECTED_PLACEHOLDERS)}")
    for name, blob in (("template", tmpl), ("audit", audit)):
        hit = HOME_PATH_RE.search(blob)
        if hit:
            problems.append(f"{name} leaks an absolute user path: {hit.group(0)!r}")
    if problems:
        for p in problems:
            print(f"[FAIL] {p}")
        print("=== TEMPLATE CHECK: FAIL ===")
        return 1
    print(f"[PASS] template/audit consistent: {len(got_rows)} rows, sha256 {sha_tmpl.group(1)[:12]}..., "
          f"{len(got_ph)} placeholders, no personal paths")
    print("=== TEMPLATE CHECK: PASS ===")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--source", default=None,
                    help="path to the already-verified presets bundle patch (cordis.patch.yml); "
                         "required unless --check is given")
    args = ap.parse_args()
    if args.check and args.source is None:
        return self_check()
    if args.source is None:
        print("[ERROR] --source is required: point it at the verified bundle patch "
              "(cordis.patch.yml with the 22 shipped plugin rows)", file=sys.stderr)
        return 2
    built = build(Path(args.source))
    problems = []
    for key, path in (("audit", SHIPPED_OUT), ("tmpl", TMPL_OUT)):
        want = built[key]
        if args.check:
            have = path.read_text(encoding="utf-8") if path.is_file() else None
            if have != want:
                problems.append(f"{path} 与生成结果不一致（先跑 py tools\\make_template.py 重生成）")
            else:
                print(f"[PASS] {path.name}: 与生成结果逐字节一致 ({len(want.encode())} B)")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(want, encoding="utf-8", newline="\n")
            print(f"[OK] wrote {path} ({len(want.encode())} B)")
    if args.check:
        for p in problems:
            print(f"[FAIL] {p}")
        return 1 if problems else 0
    # 生成后再自检一遍
    print("[verify] 占位符清单：", sorted(set(re.findall(r"\{\{(\w+)\}\}", built["tmpl"]))))
    rows = re.findall(r"^          - id: (\S+)$", built["tmpl"], re.M)
    print(f"[verify] 插件行 {len(rows)} 条：{rows}")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
