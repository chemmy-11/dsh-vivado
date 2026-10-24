#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_skills_manifest.py — dsh-vivado 的 skills/MANIFEST.json 生成器 + 门禁。

MANIFEST **禁手写**：本脚本是唯一生产者，`--check` 是唯一判据。
适配自 `D:\\FPGA\\scripts\\gen_skills_manifest.py`（vault 版），保持**同一种 JSON 形状**，
换成 kit 自己的作用域并以脚本位置为锚（cwd 随意）：

    <kit>/tools/gen_skills_manifest.py      ← 本文件
    <kit>/skills/<skill>/SKILL.md           ← 唯一真源（frontmatter）
    <kit>/skills/MANIFEST.json              ← 产物

用法：
    py tools/gen_skills_manifest.py                     # 生成（默认 <kit>/skills/MANIFEST.json）
    py tools/gen_skills_manifest.py --check             # 只校验，不写盘
    py tools/gen_skills_manifest.py --skills-root <d> --out <f>   # 换作用域（反例测试用）

`--check` = 「结构自检」+「逐字节比对」，任一不过 exit 1（全过 exit 0，不写任何文件）：
  1. 磁盘上每个技能目录都有 SKILL.md，且 frontmatter 可解析、`name:` **等于目录名**；
  2. MANIFEST.skills 的 `dir` 集合 == 磁盘目录集合（on-disk set mismatch）；
  3. source_hash 与现场按 SKILL.md 重算的值相等（source_hash mismatch）；
  4. baseline 四键齐全（amd_doc / tested_on / status / evidence），status ∈ {verified, unverified}；
     `verified` 必须同时有 `tested_on` 与 `evidence`；`unverified` 的 `tested_on` 必须为 null
     （结论 §3 D3：没实测就不许填版本，填了就是伪造）；
  5. 重新生成到临时文件后与盘上文件**逐字节**相等（手改 description/evidence/references 也会被抓到）。

诚实基线（结论 §3.2 / D3）：`amd_doc` = 上游自述基线（AMD 6 件 2026.1；amd-doc-search 与自研技能
unspecified），`tested_on`/`status`/`evidence` 一律来自 SKILL.md frontmatter —— 本脚本**不注入**、
**不美化**任何基线；本机没跑过的就是 `unverified`。

为什么 tool_catalog 不再现场探测：vault 版从 `D:\\vivado-mcp\\mcp_ctl.py list` 取 32 个工具名，
那会把「作者机器的绝对路径 + 当时的工具面」钉进一个要分发的产物里，且让 `--check` 依赖外部进程
（不确定、慢）。kit 里工具面由 `doctor.ps1` 在真机探测（KIT-SPEC §7 检查 7），故此处只留
`available: false` + 原因，不编造列表。

只依赖标准库；输出 UTF-8（宿主控制台是 GBK，故自己 reconfigure）。无时间戳 ⇒ 幂等。
退出码：0 = 生成成功 / --check 全过；1 = 结构错误或漂移。
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

KIT_ROOT = Path(__file__).resolve().parent.parent  # <kit>
DEFAULT_SKILLS_ROOT = KIT_ROOT / "skills"
GENERATED_BY = "tools/gen_skills_manifest.py"
SCHEMA_VERSION = 1
BASELINE_KEYS = ("amd_doc", "tested_on", "status", "evidence")
STATUS_OK = ("verified", "unverified")
DESC_MAX = 200
DIFF_MAX_LINES = 60

# 占位符 / 演示路径：不当作真实引用（与 vault 版同口径，保证同形状）
PLACEHOLDER = re.compile(r"path/to|\.\.\.|xxx|[<>*{}]")
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
BACKTICK = re.compile(r"`([^`\n]+)`")
SCRIPT_SUFFIXES = {".py", ".tcl", ".ps1"}
REF_PREFIXES = ("references/", "scripts/", "examples/")
REF_FILENAME = re.compile(r"^[\w][\w.\-]*\.(md|py|tcl|ps1|json|v|sv|rpt)$")


def warn(msg: str) -> None:
    print(f"  [warn] {msg}")


# --------------------------------------------------------------------------- #
# frontmatter：自带的 YAML 子集解析器（**故意不用 PyYAML**）
# --------------------------------------------------------------------------- #
# 用 PyYAML 会引入「装了 PyYAML 的机器与没装的机器产物不同」的风险（例：`"a \\"b\\""` 的
# 反转义只有真 YAML 会做），而 MANIFEST 要跨机器逐字节可比。所以这里只实现技能 frontmatter
# 实际用到的子集：顶层 `key: value`、一层嵌套 mapping、`- item` 列表、`>`/`|` 块标量、
# 双/单引号标量。不认识的构造不猜——直接报结构错误（--check 会 FAIL）。


class FrontmatterError(RuntimeError):
    pass


def _unescape_double(raw: str) -> str:
    """双引号标量内的转义：只处理 YAML 常用子集，其余保持字面。"""
    out = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if ch == "\\" and i + 1 < len(raw):
            nxt = raw[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/", "0": "\0"}
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def _scalar(val: str):
    """把一个右侧值解析成 str / bool / None。"""
    val = val.strip()
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        return _unescape_double(val[1:-1])
    if len(val) >= 2 and val[0] == "'" and val[-1] == "'":
        return val[1:-1].replace("''", "'")
    low = val.lower()
    if low in ("", "~", "null"):
        return None
    if low in ("true", "false"):
        return low == "true"
    return val


def _fold(block_lines: list[str], style: str) -> str:
    """`>` 用空格折叠、`|` 保留换行；`-` 后缀去掉末尾空行（调用方已剥离指示符）。"""
    parts = [ln.strip() for ln in block_lines]
    if style == "|":
        return "\n".join(parts).rstrip("\n")
    return " ".join(p for p in parts if p).strip()


def split_frontmatter(text: str) -> tuple[str, str]:
    """返回 (frontmatter 原文, 正文)。frontmatter 必须从第 1 字节起就是 `---`。"""
    if not text.startswith("---"):
        raise FrontmatterError("首行不是 `---`（frontmatter 必须从文件第 1 个字节开始）")
    end = text.find("\n---", 3)
    if end < 0:
        raise FrontmatterError("frontmatter 没有闭合的 `---`")
    return text[3:end], text[end + 4 :]


def parse_frontmatter(raw: str) -> dict:
    """解析 frontmatter 原文（不含首尾 `---`）。"""
    meta: dict = {}
    lines = raw.splitlines()
    i = 0
    cur_top: str | None = None
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        if indent == 0:
            if ":" not in body:
                raise FrontmatterError(f"顶层行无法解析: {body!r}")
            key, _, rest = body.partition(":")
            key, rest = key.strip(), rest.strip()
            if rest[:1] in (">", "|"):
                style = rest[0]
                block = []
                i += 1
                while i < len(lines):
                    nxt = lines[i]
                    if nxt.strip() and (len(nxt) - len(nxt.lstrip())) == 0:
                        break
                    block.append(nxt)
                    i += 1
                meta[key] = _fold(block, style)
                cur_top = key
                continue
            if rest == "":
                # 可能是嵌套 mapping 或列表，交给后续缩进行填充
                meta[key] = {}
                cur_top = key
                i += 1
                continue
            meta[key] = _scalar(rest)
            cur_top = None
            i += 1
            continue
        # 缩进行：属于 cur_top
        if cur_top is None:
            raise FrontmatterError(f"缩进行无所属的顶层键: {body!r}")
        if body.startswith("- "):
            if not isinstance(meta.get(cur_top), list):
                meta[cur_top] = []
            meta[cur_top].append(_scalar(body[2:]))
            i += 1
            continue
        if ":" not in body:
            raise FrontmatterError(f"嵌套行无法解析: {body!r}")
        key, _, rest = body.partition(":")
        key, rest = key.strip(), rest.strip()
        if not isinstance(meta.get(cur_top), dict):
            meta[cur_top] = {}
        if rest[:1] in (">", "|"):
            style = rest[0]
            block = []
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                block.append(nxt)
                i += 1
            meta[cur_top][key] = _fold(block, style)
            continue
        meta[cur_top][key] = _scalar(rest)
        i += 1
    return meta


def read_skill_md(path: Path) -> tuple[dict, str]:
    """读 SKILL.md → (frontmatter dict, 正文)。BOM 视为错误（会让 `---` 判定失败）。"""
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        raise FrontmatterError("SKILL.md 含 UTF-8 BOM（frontmatter 会被判成没有）")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FrontmatterError(f"SKILL.md 不是 UTF-8: {exc}") from exc
    raw, body = split_frontmatter(text)
    return parse_frontmatter(raw), body


# --------------------------------------------------------------------------- #
# 采集：references / artifacts / scripts / source_hash（与 vault 版同口径）
# --------------------------------------------------------------------------- #
def collect_refs(body: str) -> list[str]:
    refs: set[str] = set()
    candidates = [m.group(1).strip() for m in LINK.finditer(body)]
    candidates += [m.group(1).strip() for m in BACKTICK.finditer(body)]
    for cand in candidates:
        if not cand or PLACEHOLDER.search(cand):
            continue
        if re.match(r"^[A-Za-z]:[\\/]", cand) or cand.startswith(("/", "\\")):
            continue  # 绝对路径不是技能内引用
        if cand.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = cand.split("#", 1)[0].strip()
        if not target or PLACEHOLDER.search(target):
            continue
        if target.startswith(REF_PREFIXES) or REF_FILENAME.match(target):
            refs.add(target.replace("\\", "/"))
    return sorted(refs)


def collect_artifacts(meta: dict) -> list[str]:
    """frontmatter `artifacts:` = 技能运行时**产出**的文件名（不随包发布，不要求存在）。"""
    raw = meta.get("artifacts")
    if not isinstance(raw, list):
        return []
    return sorted({str(x).strip().replace("\\", "/") for x in raw if str(x).strip()})


def collect_scripts(skill_dir: Path) -> list[str]:
    return sorted(
        p.relative_to(skill_dir).as_posix()
        for p in skill_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in SCRIPT_SUFFIXES
    )


def source_hash(skill_dirs: list[Path]) -> str:
    """各 SKILL.md 字节 sha256（按目录名排序）拼接后再 sha256。"""
    digest = hashlib.sha256()
    for d in skill_dirs:
        digest.update(hashlib.sha256((d / "SKILL.md").read_bytes()).hexdigest().encode("ascii"))
    return digest.hexdigest()


# --------------------------------------------------------------------------- #
# 组装
# --------------------------------------------------------------------------- #
class StructuralError(RuntimeError):
    """退出码 1：输入/产物本身不成立（不写盘）。"""


def list_skill_dirs(skills_root: Path) -> tuple[list[Path], list[str]]:
    """返回 (技能目录, 不是技能的目录名)。后者非空 ⇒ on-disk set mismatch。"""
    if not skills_root.is_dir():
        raise StructuralError(f"skills_root 不存在: {skills_root}")
    dirs, strays = [], []
    for p in sorted(skills_root.iterdir(), key=lambda x: x.name):
        if not p.is_dir():
            continue
        if (p / "SKILL.md").is_file():
            dirs.append(p)
        else:
            strays.append(p.name)
    if not dirs:
        raise StructuralError(f"{skills_root} 下没有含 SKILL.md 的技能目录")
    return dirs, strays


def build_skill(skill_dir: Path) -> dict:
    name = skill_dir.name
    try:
        meta, body = read_skill_md(skill_dir / "SKILL.md")
    except FrontmatterError as exc:
        raise StructuralError(f"{name}/SKILL.md: {exc}") from exc

    fm_name = meta.get("name")
    fm_name = fm_name.strip() if isinstance(fm_name, str) else ""
    if not fm_name:
        raise StructuralError(f"{name}/SKILL.md: frontmatter 缺 name（DSH 按 name 加载，不能缺）")
    if fm_name != name:
        raise StructuralError(
            f"{name}/SKILL.md: frontmatter name={fm_name!r} 与目录名 {name!r} 不一致"
            " ⇒ 改 frontmatter `name` 或改目录名，二者必须相等"
        )

    inner = meta.get("metadata") if isinstance(meta.get("metadata"), dict) else {}
    version = inner.get("version") if inner.get("version") is not None else meta.get("version")
    desc = meta.get("description")
    if isinstance(desc, str):
        desc = " ".join(desc.split())
        if len(desc) > DESC_MAX:
            desc = desc[:DESC_MAX] + "…"
    elif desc is not None:
        raise StructuralError(f"{name}/SKILL.md: description 不是字符串")

    baseline = meta.get("baseline")
    if not isinstance(baseline, dict):
        raise StructuralError(f"{name}/SKILL.md: frontmatter 缺 baseline（四键 {BASELINE_KEYS}）")

    artifacts = collect_artifacts(meta)
    refs = collect_refs(body)
    if artifacts:
        refs = [r for r in refs if r not in set(artifacts)]

    return {
        "name": fm_name,
        "dir": name,
        "version": version,
        "description": desc,
        "license": meta.get("license"),
        "references": refs,
        "artifacts": artifacts,
        "scripts": collect_scripts(skill_dir),
        # 原样搬运 frontmatter 的 baseline（不注入、不美化）
        "baseline": {k: baseline.get(k) for k in BASELINE_KEYS},
    }


def tool_catalog() -> dict:
    """不现场探测（见模块 docstring）：只声明「本清单不固化工具面」+ 真机由 doctor 探测。"""
    return {
        "available": False,
        "source": "not-embedded",
        "note": (
            "本包随包发布的是技能，工具面不写进清单；真机由 doctor.ps1 探测"
            "（KIT-SPEC §7 检查 7：mcp_ctl.py list 应列出 32 个 mcp__vivado__*）"
        ),
        "mcp_vivado": [],
    }


def render_manifest(skills_root: Path) -> tuple[dict, list[str]]:
    """「读 SKILL.md → 组装 MANIFEST」的唯一实现（生成与 --check 共用，纯内存）。"""
    dirs, strays = list_skill_dirs(skills_root)
    if strays:
        raise StructuralError(
            f"{skills_root} 下有 {len(strays)} 个目录没有 SKILL.md（不许混进 skills/）: {strays}"
        )
    skills = [build_skill(d) for d in dirs]
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_by": GENERATED_BY,
        "source_hash": source_hash(dirs),
        "tool_catalog": tool_catalog(),
        "skills": skills,
    }
    return manifest, [d.name for d in dirs]


def serialize_manifest(manifest: dict) -> str:
    """唯一序列化实现（生成与 --check 共用）。"""
    return json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"


def write_manifest_text(path: Path, text: str) -> None:
    """唯一落盘实现（生成与 --check 都走它，--check 指到临时文件）。

    `newline="\\n"` 显式写 LF：不随平台变（Windows 上按 os.linesep 会写成 CRLF），
    这样 `--check` 的逐字节比较在任何机器上都成立。用 open() 而非 write_text(newline=)
    是为了兼容 Python 3.9（kit 的 doctor 只要求 ≥3.9）。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# --------------------------------------------------------------------------- #
# 校验
# --------------------------------------------------------------------------- #
def validate_manifest(manifest: dict, skills_root: Path) -> list[str]:
    """对**盘上** MANIFEST 做结构自检（不信任它自己的说法）。返回问题列表。"""
    errs: list[str] = []
    if not isinstance(manifest, dict):
        return ["MANIFEST 顶层不是对象"]

    if manifest.get("schema_version") != SCHEMA_VERSION:
        errs.append(f"schema_version 应为 {SCHEMA_VERSION}，实际 {manifest.get('schema_version')!r}")
    if manifest.get("generated_by") != GENERATED_BY:
        errs.append(f"generated_by 应为 {GENERATED_BY!r}，实际 {manifest.get('generated_by')!r}")

    skills = manifest.get("skills")
    if not isinstance(skills, list) or not skills:
        return errs + ["skills 缺失或为空"]

    # on-disk set mismatch
    try:
        dirs, strays = list_skill_dirs(skills_root)
    except StructuralError as exc:
        return errs + [str(exc)]
    if strays:
        errs.append(f"磁盘上有 {len(strays)} 个目录缺 SKILL.md（on-disk set mismatch）: {strays}")
    disk = {d.name for d in dirs}
    listed = {s.get("dir") for s in skills}
    if disk != listed:
        errs.append(
            "on-disk set mismatch：磁盘技能目录与 MANIFEST.skills[].dir 不一致 "
            f"（仅磁盘 {sorted(disk - listed)} / 仅清单 {sorted(listed - disk)}）"
        )

    # source_hash mismatch
    try:
        actual_hash = source_hash(dirs)
    except OSError as exc:
        errs.append(f"重算 source_hash 失败: {exc}")
        actual_hash = ""
    if manifest.get("source_hash") != actual_hash:
        errs.append(
            "source_hash mismatch：清单 "
            f"{manifest.get('source_hash')!r} != 现场重算 {actual_hash!r}"
            "（有 SKILL.md 被改过/增删过）"
        )

    for s in skills:
        if not isinstance(s, dict):
            errs.append(f"skills[] 含非对象项: {s!r}")
            continue
        name, sdir = s.get("name"), s.get("dir")
        if name != sdir:
            errs.append(f"name != dir：name={name!r} dir={sdir!r}（DSH 按 name 加载，二者必须相等）")
        if not s.get("version"):
            errs.append(f"{name}: version 为空（frontmatter metadata.version 缺失）")
        if s.get("license") is None:
            warn(f"{name}: license 为 null（自有技能请补 `license:`，第三方请核对）")
        for key in ("references", "artifacts", "scripts"):
            if not isinstance(s.get(key), list):
                errs.append(f"{name}: {key} 不是列表")
        base = s.get("baseline")
        if not isinstance(base, dict):
            errs.append(f"{name}: baseline 缺失/不是对象（四键 {BASELINE_KEYS}）")
            continue
        missing = [k for k in BASELINE_KEYS if k not in base]
        if missing:
            errs.append(f"{name}: baseline 缺键 {missing}（必须四键齐全）")
            continue
        status = base.get("status")
        if status not in STATUS_OK:
            errs.append(f"{name}: baseline.status={status!r} 非法（只允许 {STATUS_OK}）")
        tested_on, evidence = base.get("tested_on"), base.get("evidence")
        if status == "verified":
            # 结论 §3 D3：verified 必须有实测版本 + 证据出处
            if tested_on in (None, "", []):
                errs.append(f"{name}: baseline.status=verified 但 tested_on 为空 ⇒ 伪造实测，改回 unverified")
            if not (isinstance(evidence, str) and evidence.strip()):
                errs.append(f"{name}: baseline.status=verified 但 evidence 为空 ⇒ 无法复核")
        elif status == "unverified":
            if tested_on not in (None, ""):
                errs.append(
                    f"{name}: baseline.status=unverified 但 tested_on={tested_on!r}"
                    "（没实测就不许填版本，按 D3 应为 null）"
                )
        if base.get("amd_doc") in (None, ""):
            errs.append(f"{name}: baseline.amd_doc 为空（上游自述基线，未知也要写 unspecified）")
    return errs


def first_byte_mismatch(expected: bytes, actual: bytes) -> str:
    limit = min(len(expected), len(actual))
    for i in range(limit):
        if expected[i] != actual[i]:
            return f"首个差异在字节偏移 {i}（期望 {expected[i]:#04x} / 实际 {actual[i]:#04x}）"
    if len(expected) != len(actual):
        longer = "期望" if len(expected) > len(actual) else "实际"
        return f"前 {limit} 字节相同但长度不同（期望 {len(expected)} / 实际 {len(actual)} 字节，{longer}侧更长）"
    return "字节完全一致"


def describe_difference(expected: bytes, actual: bytes) -> str:
    exp = expected.decode("utf-8", errors="replace").splitlines()
    act = actual.decode("utf-8", errors="replace").splitlines()
    diff = list(
        difflib.unified_diff(exp, act, fromfile="期望（由 SKILL.md 重新生成）", tofile="实际（盘上）",
                             lineterm="", n=2)
    )
    if not diff:
        return "行内容完全一致 —— 差异只在字节层（BOM / 行尾 / 编码）"
    out = diff[:DIFF_MAX_LINES]
    if len(diff) > DIFF_MAX_LINES:
        out.append(f"...（diff 共 {len(diff)} 行，只显示前 {DIFF_MAX_LINES} 行）")
    return "\n".join(out)


def print_table(skills: list) -> None:
    """acceptance 用：逐技能打印 name / dir / version / baseline，一眼看 name==dir。"""
    print()
    print(f"{'#':>2}  {'frontmatter name':<34}{'目录':<34}{'version':<9}{'status':<12}amd_doc / tested_on")
    print("-" * 118)
    for i, s in enumerate(skills, 1):
        if not isinstance(s, dict):
            print(f"{i:>2}  <<< 非对象项: {s!r}")
            continue
        base = s.get("baseline") if isinstance(s.get("baseline"), dict) else {}
        mine = "" if s.get("name") == s.get("dir") else "   <<< name != dir"
        print(
            f"{i:>2}  {str(s.get('name')):<34}{str(s.get('dir')):<34}"
            f"{str(s.get('version')):<9}{str(base.get('status')):<12}"
            f"{base.get('amd_doc')} / {base.get('tested_on')}{mine}"
        )
    print("-" * 118)


def main() -> int:
    try:  # 宿主控制台是 GBK，中文/差异正文统一按 UTF-8 写
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="生成/校验 dsh-vivado 的 skills/MANIFEST.json")
    ap.add_argument("--skills-root", default=str(DEFAULT_SKILLS_ROOT), help="技能根目录（默认 <kit>/skills）")
    ap.add_argument("--out", default="", help="输出文件（默认 <skills-root>/MANIFEST.json）")
    ap.add_argument("--check", action="store_true", help="只校验：结构自检 + 逐字节比对，不写任何文件")
    args = ap.parse_args()

    skills_root = Path(args.skills_root).expanduser().resolve()
    out_path = Path(args.out).expanduser().resolve() if args.out else skills_root / "MANIFEST.json"

    print(f"kit 根目录 : {KIT_ROOT}")
    print(f"技能根目录 : {skills_root}")
    print(f"清单文件   : {out_path}")
    print(f"模式       : {'--check（只读）' if args.check else '生成'}")

    # 生成 / 内存重算（两条路径共用 render_manifest，保证「生成器不再另算一套」）
    try:
        manifest, dir_names = render_manifest(skills_root)
    except StructuralError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    text = serialize_manifest(manifest)
    skills = manifest["skills"]

    if not args.check:
        problems = validate_manifest(manifest, skills_root)
        if problems:
            print(f"[ERROR] 产物自检未过（{len(problems)} 处），**未写盘**：", file=sys.stderr)
            for p in problems:
                print(f"  - {p}", file=sys.stderr)
            return 1
        write_manifest_text(out_path, text)
        print_table(skills)
        print(f"技能数 : {len(skills)}  ({', '.join(dir_names)})")
        print(f"已写出 : {out_path}（{len(text.encode('utf-8'))} 字节）")
        print(f"source_hash: {manifest['source_hash']}")
        print("[OK] 生成完成；提交前请先跑 --check")
        return 0

    # ---------------- --check ----------------
    if not out_path.is_file():
        print(f"[FAIL] --check 目标不存在: {out_path}（先跑 `py tools/gen_skills_manifest.py`）",
              file=sys.stderr)
        return 1

    on_disk_bytes = out_path.read_bytes()
    try:
        on_disk = json.loads(on_disk_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"[FAIL] 盘上 MANIFEST 不是合法 UTF-8 JSON: {exc}", file=sys.stderr)
        return 1

    # ① 结构自检（对着磁盘现场，不信任 MANIFEST 自述）
    problems = validate_manifest(on_disk, skills_root)

    # ② 逐字节比对（盘上 MANIFEST 是否 == 现渲染结果）
    fd, tmp_name = tempfile.mkstemp(prefix="skills-manifest-check-", suffix=".json")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        write_manifest_text(tmp_path, text)
        expected = tmp_path.read_bytes()
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass

    drift = expected != on_disk_bytes

    print_table(on_disk.get("skills") if isinstance(on_disk.get("skills"), list) else [])

    if problems or drift:
        print(f"[FAIL] --check 未过：结构问题 {len(problems)} 处，字节漂移 {'是' if drift else '否'}",
              file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        if drift:
            print(f"  {first_byte_mismatch(expected, on_disk_bytes)}", file=sys.stderr)
            print("  --- 差异（期望 = 由 SKILL.md 重新生成；实际 = 盘上 MANIFEST）---", file=sys.stderr)
            for line in describe_difference(expected, on_disk_bytes).splitlines():
                print(f"  {line}", file=sys.stderr)
        print("  ⇒ MANIFEST 禁手写。处置：`py tools/gen_skills_manifest.py` 重新生成后复查 diff",
              file=sys.stderr)
        return 1

    print(f"[PASS] 结构自检 0 问题；与重新生成结果逐字节一致")
    print(f"       sha256={hashlib.sha256(on_disk_bytes).hexdigest()}")
    print(f"       字节数={len(on_disk_bytes)}  技能数={len(skills)}  source_hash={manifest['source_hash']}")
    print("=== 技能清单门禁：PASS ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
