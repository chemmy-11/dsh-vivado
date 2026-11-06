# -*- coding: utf-8 -*-
r"""make_template.py — 生成 dsh-vivado 的**唯一**模板 `templates/preset.patch.yml.tmpl`
（带 {{PLACEHOLDER}}），并同时落一份 22 条 shipped 插件行的溯源审计件
`templates/shipped-standard-22rows.yml`。

两条生成路径（都**只做两处允许的改动**，其余字符逐字节保留）：
  ① `--sync-shipped --dsh-install <DSH 安装根>`（2026-11-06 新增；DSH 升级后的标准动作）
     直接从已装 DSH 的 `<DSH>\resources\app.asar`
     :: `dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml`
     取 22 条 shipped 行。这是**唯一机器可读的权威源**：换 DSH 版本后先跑这一步，
     再 `git diff templates/` 看上游到底改了哪几行（0.2.2-rc.1 实测改了 3 行，见 dev/README §2.4）。
  ② `--source <bundle patch>`（历史路径：作者本机已实证的现役 bundle，须含 23 条顶层行 = 22 + mcp）。
允许的改动：
     - 把 persona 行那一块替换成 {{PERSONA_BLOCK}}（由 templates/persona/<tier>.frag.yml 提供）；
     - 给 skill-filesystem 行加 config.customSkillDirs（rank 300 自定义技能根）。
末尾再追加 mcp-vivado 行（`--sync-shipped` 从现有模板原样保留；`--source` 从 bundle 提取并参数化）。

用法：
  py tools\make_template.py --check                                     # 只校验模板/审计件一致（不需要 DSH）
  py tools\make_template.py --sync-shipped --dsh-install <DSH 安装根>    # 从已装 DSH 重新同步（写文件）
  py tools\make_template.py --sync-shipped --check --dsh-install <根>    # 只比对，不写
  py tools\make_template.py --source <bundle patch> [--check]           # 历史路径

约束：
  * 只用 stdlib（py 3.9+）：asar 头是公开格式，用 struct/json 直接解析，不需要 Node。
  * 行尾统一 LF；读入时先把 CRLF 归一，并对「归一后与原文件逐行相等」做断言。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KITROOT = HERE.parent
TPL = KITROOT / "templates"
# 历史路径的 provenance 源是作者本机的一个项目内 bundle patch，所以它是必填参数而不是常量：
# 绝不把用户主目录写死在随包工具里。记录事实（给维护者）：作者本机笔记库\.dsh\bundles\vivado-preset\cordis.patch.yml
DEFAULT_SRC = None
# 任何 "<盘符>:\Users\<名字>\" 形态的个人路径：用来兜住作者账号名，而不把名字硬编码进随包工具。
HOME_PATH_RE = re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\\/\s\"']+[\\/]")

SHIPPED_OUT = TPL / "shipped-standard-22rows.yml"
TMPL_OUT = TPL / "preset.patch.yml.tmpl"

PERSONA_MARK = "          - id: persona"
ROW_PREFIX = "          - id: "
MCP_ID = "mcp-vivado"
# 审计件里 persona 行的替身：shipped 的 persona 行渲染时会被 kit 的版本分档片段替换，
# 不属于要溯源的「随包内容」。
PERSONA_AUDIT_MARK = (
    "          # <persona row omitted from this audit copy: the shipped persona row is replaced\n"
    "          #  at render time by templates/persona/<tier>.frag.yml, so it is not kit content.>\n"
)
SKILLFS_ID = "skill-filesystem"
# skill-filesystem 行追加的那段 config（模板里有、审计件里没有；--check 用它做双向还原比对）
SKILLS_INSERT = (
    "            config:\n"
    "              # rank 300「custom」根：kit 随包技能。includeDefaultRoots 保持默认 true，\n"
    "              # 使用者自己的项目/用户技能根照旧生效，不被本包挤掉。\n"
    "              customSkillDirs:\n"
    "                - '{{SKILLS_DIR}}'\n"
)
# shipped 行的权威源在已装 DSH 的 app.asar 里（路径相对 asar 根）
SHIPPED_ASAR_ENTRY = "dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml"


# ---------------------------------------------------------------------------
# provenance 文案（模板头 / 审计件头），两条生成路径各一份
# ---------------------------------------------------------------------------
LEGACY_TMPL_PROVENANCE = (
    "# 模板由 tools/make_template.py 生成：22 条 shipped 插件行原样取自已实证的现役 bundle\n"
    "#   作者本机笔记库\\.dsh\\bundles\\vivado-preset\\cordis.patch.yml（作者本机路径，不属于本分发件）\n"
    "#   （该文件已自证与 shipped dsh-web-app/presets/standard.patch.yml 逐字节一致，\n"
    "#     见 作者本机的规范化取证记录（未随仓库发布） §2.2）\n"
)
ASAR_TMPL_PROVENANCE = (
    "# 模板由 tools/make_template.py 生成：22 条 shipped 插件行原样取自已装 DSH 的 app.asar\n"
    "#   <DSH 安装根>\\resources\\app.asar\n"
    "#     :: dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml\n"
    "#   换 DSH 版本后重跑 py tools\\make_template.py --sync-shipped --dsh-install <DSH 安装根>，\n"
    "#   再 review templates/ 的 git diff（上游改了哪几行一目了然）。\n"
)

LEGACY_AUDIT_HEADER = """# shipped-standard-22rows.yml -- provenance audit copy (NOT an install input).
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
ASAR_AUDIT_HEADER = """# shipped-standard-22rows.yml -- provenance audit copy (NOT an install input).
#
# This file exists to prove that the 22 plugin rows inside the rendered patch are the shipped
# `@deepseek-ai/dsh-web-app/presets/standard.patch.yml` content, not hand-copied text.
# Source: <DSH>/resources/app.asar
#   :: dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml
#   (extracted from the installed DSH; replay:
#    py tools\\make_template.py --sync-shipped --dsh-install <DSH>)
# Rows 2-22 below are byte-identical to that source (line endings normalized to LF).
# persona row omitted from this audit copy: the shipped persona row is replaced at render time
# by templates/persona/<tier>.frag.yml, so it is not kit content.
# sha256 of the full verbatim 22 rows (persona included, LF-normalized):

"""


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


# ---------------------------------------------------------------------------
# app.asar 只读解析（Electron asar 公开格式：u32 pickle 长度 / u32 头长度 /
# u32 头 pickle 载荷长度 / u32 字符串长度 / JSON 头 / 文件数据区）
# ---------------------------------------------------------------------------
def find_asar(dsh_install: str | None) -> Path:
    if not dsh_install:
        raise SystemExit("[ERROR] --sync-shipped 需要 --dsh-install <DSH 安装根>（或 --asar <app.asar>）")
    root = Path(dsh_install)
    for cand in (root / "resources" / "app.asar", root / "app.asar"):
        if cand.is_file():
            return cand
    raise SystemExit(f"[ERROR] 在 {root} 下找不到 resources\\app.asar")


def read_asar_entry(asar: Path, entry_suffix: str) -> bytes:
    data = asar.read_bytes()
    if len(data) < 16:
        raise SystemExit(f"[ERROR] {asar} 太短，不是 asar")
    header_size = struct.unpack_from("<I", data, 4)[0]
    data_offset = 8 + header_size
    header = json.loads(data[16:data_offset].decode("utf-8"))

    def walk(node: dict, prefix: str):
        for name, meta in (node.get("files") or {}).items():
            p = f"{prefix}/{name}" if prefix else name
            if "files" in meta:
                yield from walk(meta, p)
            else:
                yield p, meta

    want = "/" + entry_suffix.lstrip("/")
    for p, meta in walk(header, ""):
        if ("/" + p).endswith(want):
            start = data_offset + int(meta["offset"])
            return data[start:start + int(meta["size"])]
    raise SystemExit(f"[ERROR] {asar} 里找不到条目 {entry_suffix}")


def shipped_rows_block(text: str) -> str:
    """从 shipped `standard.patch.yml` 里取出 22 条插件行（10 空格缩进）的逐字节文本。"""
    lines = norm(text).split("\n")
    try:
        start = next(i for i, ln in enumerate(lines) if re.match(r"^ {10}- id: (\S+)$", ln))
    except StopIteration:
        raise SystemExit("[ERROR] shipped preset 里找不到 10 空格缩进的插件行")
    block: list[str] = []
    for ln in lines[start:]:
        if ln.strip() == "":
            block.append(ln)
            continue
        cur = len(ln) - len(ln.lstrip())
        if cur < 10:
            break
        block.append(ln)
    while block and block[-1].strip() == "":
        block.pop()
    shipped = "\n".join(block) + "\n"
    ids = re.findall(r"^ {10}- id: (\S+)$", shipped, re.M)
    if len(ids) != 22:
        raise SystemExit(f"[ERROR] shipped 行数 {len(ids)} != 22: {ids}")
    return shipped


def extract_mcp_block(tmpl_text: str) -> str:
    """从现有模板里原样保留 mcp-vivado 行（含解释性注释块）。"""
    lines = tmpl_text.split("\n")
    try:
        start = next(i for i, ln in enumerate(lines)
                     if ln.startswith("          # --- vivado-mcp"))
    except StopIteration:
        raise SystemExit("[ERROR] 现有模板里找不到 mcp-vivado 注释块，无法保留该行")
    block = lines[start:]
    while block and block[-1].strip() == "":
        block.pop()
    return "\n".join(block) + "\n"


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


def compose(shipped: str, mcp: str, provenance: str, audit_header: str) -> dict[str, str]:
    """把 22 条 shipped 行 + mcp 块拼成模板/审计件（两条生成路径共用的唯一出口）。"""
    n_rows = len(re.findall(r"^          - id: ", shipped, re.M))
    assert n_rows == 22, f"[ERROR] shipped 行数 {n_rows} != 22"

    # --- ① persona 块 -> {{PERSONA_BLOCK}} ---
    persona_start = shipped.index(PERSONA_MARK)
    after_persona = shipped.index("          - id: agent-instructions")
    # 审计件（随包的那份）不含 persona：shipped 的 persona 行在渲染时会被版本分档片段替换。
    audit = (
        shipped[:persona_start]
        + PERSONA_AUDIT_MARK
        + shipped[after_persona:]
    )
    shipped_no_persona = (
        shipped[:persona_start]
        + "{{PERSONA_BLOCK}}\n"
        + shipped[after_persona:]
    )
    # --- ② skill-filesystem 行加 customSkillDirs ---
    sf = (
        "          - id: skill-filesystem\n"
        "            name: '@deepseek-ai/dsh-skill-filesystem'\n"
    )
    if sf not in shipped_no_persona:
        raise SystemExit("[ERROR] 找不到 skill-filesystem 行原样文本")
    shipped_final = shipped_no_persona.replace(sf, sf + SKILLS_INSERT, 1)

    sha = hashlib.sha256(shipped.encode()).hexdigest()
    header = (
        "# dsh-vivado — Vivado 会话预设（bundle 层，DSH bundle patch 方言）\n"
        "#\n"
        "# 【不要手改本文件】它由 tools/render_patch.ps1 从 templates/preset.patch.yml.tmpl 渲染。\n"
        + provenance +
        "# 只做两处允许的改动：persona 换成本 kit 的版本分档片段、skill-filesystem 加 customSkillDirs；\n"
        "# 末尾追加 mcp-vivado 行（硬件相关值参数化）。\n"
        "#\n"
        "# shipped-22 行 sha256（归一 LF 后；persona 行按 shipped 原文计入，不含 skill-filesystem 改动）：\n"
        f"#   {sha}\n"
        "# 生效需**重启宿主**（Electron 下 dsh-hmr 不生效）；新会话创建时选 `Vivado` 预设。\n"
        "- insert:\n"
        "    - id: preset-vivado\n"
        "      name: '@deepseek-ai/dsh-agent-preset'\n"
        "      config:\n"
        "        id: vivado\n"
        "        name: Vivado\n"
        "        description: 'Vivado/FPGA 会话：挂 vivado-mcp（{{TOOL_COUNT}} 工具）+ 全局串行/ASCII 路径/证据纪律 + kit 自带技能（dsh-vivado {{KIT_VERSION}}）。'\n"
        "        order: 2\n"
        "        plugins:\n"
        f"{shipped_final}{mcp}"
    )
    # 分发件卫生：随包文本里不许出现某台机器的用户目录或非 ASCII 路径
    for name, blob in (("tmpl", header), ("shipped-22rows", audit)):
        hit = HOME_PATH_RE.search(blob)
        if hit:
            raise SystemExit(f"[ERROR] {name} 仍含个人路径片段 {hit.group(0)!r}，拒绝生成")
    audit_doc = audit_header + f"#   {sha}\n" + audit
    return {"shipped": shipped, "audit": audit_doc, "tmpl": header}


def build(src: Path) -> dict[str, str]:
    """历史路径：从已实证的现役 bundle patch（22 shipped + mcp）重新抽取。"""
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
    return compose(shipped, mcp_header + mcp, LEGACY_TMPL_PROVENANCE, LEGACY_AUDIT_HEADER)


def sync_shipped(dsh_install: str | None, asar_path: str | None, check_only: bool) -> int:
    """从已装 DSH 的 app.asar 重新同步 22 条 shipped 行（写模板 + 审计件）。"""
    asar = Path(asar_path) if asar_path else find_asar(dsh_install)
    shipped = shipped_rows_block(read_asar_entry(asar, SHIPPED_ASAR_ENTRY).decode("utf-8"))
    tmpl_old = TMPL_OUT.read_text(encoding="utf-8")
    built = compose(shipped, extract_mcp_block(tmpl_old), ASAR_TMPL_PROVENANCE, ASAR_AUDIT_HEADER)

    old_ids = [x for x in re.findall(r"^ {10}- id: (\S+)$", tmpl_old, re.M) if x != MCP_ID]
    new_ids = [x for x in re.findall(r"^ {10}- id: (\S+)$", shipped, re.M) if x != "persona"]
    print(f"source = {asar} :: {SHIPPED_ASAR_ENTRY}")
    print(f"shipped ids: {new_ids}")
    print(f"row ids added  : {[x for x in new_ids if x not in old_ids]}")
    print(f"row ids removed: {[x for x in old_ids if x not in new_ids]}")

    problems: list[str] = []
    for key, path in (("audit", SHIPPED_OUT), ("tmpl", TMPL_OUT)):
        want = built[key]
        if check_only:
            have = path.read_text(encoding="utf-8") if path.is_file() else None
            if have != want:
                problems.append(f"{path} 与 asar 里的 shipped 行不同步（跑 --sync-shipped 重生成）")
            else:
                print(f"[PASS] {path.name}: 与 {asar.name} 里的 shipped 行逐字节一致")
        else:
            path.write_text(want, encoding="utf-8", newline="\n")
            print(f"[OK] wrote {path} ({len(want.encode())} B)")
    if check_only:
        for p in problems:
            print(f"[FAIL] {p}")
        print("=== SHIPPED SYNC CHECK: {0} ===".format("FAIL" if problems else "PASS"))
        return 1 if problems else 0
    return 0


AUDIT_HEADER = LEGACY_AUDIT_HEADER  # 向后兼容旧引用名（历史路径用）
EXPECTED_PLACEHOLDERS = {'PERSONA_BLOCK', 'SKILLS_DIR', 'MCP_PYTHON', 'MCP_SITE', 'VIVADO_BAT',
                         'MCP_CWD', 'TEMP_DIR', 'TOOL_COUNT', 'KIT_VERSION'}


def self_check() -> int:
    """Verify the committed template/audit pair without the (author-only) source bundle.

    Checks: both files exist; the audit copy carries 21 shipped rows + the mcp row and the
    template carries the same row ids in the same order plus {{PERSONA_BLOCK}}; the shipped rows
    are byte-identical between the template and the audit copy (after restoring the skills config
    insertion); the recorded shipped-22 sha256 line is present in both; the template's placeholder
    set is exactly the renderer's contract; no author home path leaks into either file.
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
    # template 的 shipped 行（删掉 kit 的 skill-filesystem config 插入后）与审计件必须逐字节相同
    row_anchor = f"{ROW_PREFIX}agent-instructions"
    try:
        audit_body = audit[audit.index(row_anchor):].rstrip("\n")
        tmpl_body = tmpl[tmpl.index(row_anchor):tmpl.index("          # --- vivado-mcp")].rstrip("\n")
    except ValueError:
        problems.append("cannot locate the shipped-row block in template/audit")
    else:
        if SKILLS_INSERT not in tmpl_body:
            problems.append("template lost the customSkillDirs insertion block")
        else:
            if tmpl_body.replace(SKILLS_INSERT, "", 1) != audit_body:
                problems.append("template shipped rows differ from the audit copy "
                                "(re-run --sync-shipped, then git diff templates/)")
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
                         "required unless --check or --sync-shipped is given")
    ap.add_argument("--sync-shipped", action="store_true",
                    help="resync the 22 shipped plugin rows from the installed DSH's app.asar")
    ap.add_argument("--dsh-install", default=None, metavar="DIR",
                    help="DSH install root (contains resources\\\\app.asar); used by --sync-shipped")
    ap.add_argument("--asar", default=None, metavar="FILE",
                    help="explicit app.asar path; overrides --dsh-install")
    args = ap.parse_args()
    if args.sync_shipped:
        return sync_shipped(args.dsh_install, args.asar, args.check)
    if args.check and args.source is None:
        return self_check()
    if args.source is None:
        print("[ERROR] --source is required: point it at the verified bundle patch "
              "(cordis.patch.yml with the 22 shipped plugin rows), or use --sync-shipped "
              "--dsh-install <DSH>", file=sys.stderr)
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
