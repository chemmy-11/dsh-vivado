# -*- coding: utf-8 -*-
r"""build_preset_package.py -- generate the standalone `packages/dsh-vivado-preset/` plugin.

Why this package exists
    The awesome-plugin list installs plugins with `dsh plugin add`; such a plugin must work with no
    installer and no machine-specific values. The full kit cannot: its `cordis.patch.yml` is rendered
    per machine by install.ps1 (Vivado path, python, TEMP, project root) and carries the vivado-mcp
    row. This subpackage is the installable half: the preset (persona + the shipped standard plugin
    rows) plus the eight bundled skills, mounted at the package's own directory through a `!!js`
    expression, so nothing has to be configured before installing.

What is generated vs authored
    generated : cordis.patch.yml, skills/**            (from templates/preset.patch.yml.tmpl + skills/)
    authored  : package.json, persona.txt, README.md, LICENSE, NOTICE-preset.md

Usage
    py tools\build_preset_package.py            # regenerate (idempotent)
    py tools\build_preset_package.py --check    # verify committed files match; exit 1 on drift
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KIT = HERE.parent
TEMPLATE = KIT / "templates" / "preset.patch.yml.tmpl"
SKILLS_SRC = KIT / "skills"
PKG = KIT / "packages" / "dsh-vivado-preset"
PERSONA = PKG / "persona.txt"
PATCH = PKG / "cordis.patch.yml"
SKILLS_DST = PKG / "skills"
MANIFEST = PKG / "package.json"
# not a skill-root member: the kit's own manifest is a kit artifact, not plugin content
SKILLS_EXCLUDE = {"MANIFEST.json"}

HEADER = """\
# dsh-vivado-preset -- self-contained dsh bundle: a Vivado session preset plus bundled skills.
#
# GENERATED FILE -- do not edit. Regenerate with:
#     py tools\\build_preset_package.py
# Verify (dev/CI):
#     py tools\\build_preset_package.py --check
#
# This package is the `dsh plugin add`-installable form of the kit. It carries NO machine-specific
# values and NO MCP row: the vivado-mcp half needs a per-machine render (Python/Vivado/TEMP paths)
# and lives in the full kit, which is installed with install.ps1 instead.
#
# The 21 non-persona rows below are the shipped standard preset rows, copied verbatim from
# templates/preset.patch.yml.tmpl (single source; the generator fails if they drift). The persona
# and the skill-filesystem mount are this package's own.
- insert:
    - id: preset-vivado
      name: '@deepseek-ai/dsh-agent-preset'
      config:
        id: vivado-preset
        name: Vivado
        description: 'Vivado/FPGA 会话（预设+技能）：全局串行、纯 ASCII 路径、结论必须带证据、长构建脱离进程树；随包 8 个 AMD/FPGA 技能。不含 MCP 工具（装完整 kit 才有 32 个 vivado-mcp 工具）。'
        order: 2
        plugins:
"""

SKILLFS_OLD = """\
          - id: skill-filesystem
            name: '@deepseek-ai/dsh-skill-filesystem'
            config:
              # rank 300「custom」根：kit 随包技能。includeDefaultRoots 保持默认 true，
              # 使用者自己的项目/用户技能根照旧生效，不被本包挤掉。
              customSkillDirs:
                - '{{SKILLS_DIR}}'
"""

SKILLFS_NEW = """\
          - id: skill-filesystem
            name: '@deepseek-ai/dsh-skill-filesystem'
            config:
              # rank 300 "custom" root: the skills shipped inside this package. Resolved at load
              # time to the installed package directory, so the plugin needs no configuration.
              # includeDefaultRoots stays at its default true, so the user's own project/user skill
              # roots keep working and are not shadowed.
              customSkillDirs:
                - !!js >-
                  process.getBuiltinModule('node:path').join(
                    process.getBuiltinModule('node:path').dirname(
                      process.getBuiltinModule('node:module').createRequire(baseUrl).resolve('dsh-vivado-preset/package.json')),
                    'skills')
"""

# Every row after the persona, up to the kit's MCP section, is shipped content.
ROWS_START = "          - id: agent-instructions\n"
ROWS_END = "          # --- vivado-mcp"


def persona_block() -> str:
    lines = PERSONA.read_text(encoding="utf-8").splitlines()
    out = [
        "          - id: persona",
        "            name: '@deepseek-ai/dsh-persona'",
        "            config:",
        "              prefix: |",
    ]
    out.extend("                " + line if line else "" for line in lines)
    return "\n".join(out) + "\n"


def shipped_rows() -> str:
    text = TEMPLATE.read_text(encoding="utf-8")
    start = text.find(ROWS_START)
    end = text.find(ROWS_END)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("template layout changed: cannot locate the shipped rows")
    rows = text[start:end].rstrip("\n") + "\n"
    if SKILLFS_OLD not in rows:
        raise SystemExit("template skill-filesystem row changed: update SKILLFS_OLD in this generator")
    return rows.replace(SKILLFS_OLD, SKILLFS_NEW)


def generated_patch() -> str:
    return HEADER + persona_block() + shipped_rows()


def skill_files() -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for p in sorted(SKILLS_SRC.rglob("*")):
        if not p.is_file() or p.name in SKILLS_EXCLUDE:
            continue
        rel = p.relative_to(SKILLS_SRC).as_posix()
        out[rel] = p.read_bytes()
    return out


def write_all() -> None:
    PKG.mkdir(parents=True, exist_ok=True)
    PATCH.write_text(generated_patch(), encoding="utf-8", newline="\n")
    if SKILLS_DST.exists():
        shutil.rmtree(SKILLS_DST)
    for rel, data in skill_files().items():
        dst = SKILLS_DST / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
    print("[ok] wrote {0}".format(PATCH.relative_to(KIT)))
    print("[ok] wrote {0} ({1} files)".format(SKILLS_DST.relative_to(KIT), len(skill_files())))


def check() -> int:
    problems: list[str] = []
    if not PATCH.is_file():
        problems.append("missing {0}".format(PATCH.relative_to(KIT)))
    else:
        want = generated_patch()
        have = PATCH.read_text(encoding="utf-8")
        if want != have:
            problems.append("{0} is stale (run the generator)".format(PATCH.relative_to(KIT)))
    want_skills = skill_files()
    have_skills: dict[str, bytes] = {}
    if SKILLS_DST.is_dir():
        for p in sorted(SKILLS_DST.rglob("*")):
            if p.is_file():
                have_skills[p.relative_to(SKILLS_DST).as_posix()] = p.read_bytes()
    missing = sorted(set(want_skills) - set(have_skills))
    extra = sorted(set(have_skills) - set(want_skills))
    differ = sorted(k for k in set(want_skills) & set(have_skills) if want_skills[k] != have_skills[k])
    if missing:
        problems.append("{0} skill file(s) missing in the package: {1}".format(len(missing), missing[:5]))
    if extra:
        problems.append("{0} stale skill file(s) in the package: {1}".format(len(extra), extra[:5]))
    if differ:
        problems.append("{0} skill file(s) differ from skills/: {1}".format(len(differ), differ[:5]))
    # package.json contract: installable bundle, version locked to the kit's
    try:
        pkg = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        problems.append("package.json unreadable: {0}".format(exc))
        pkg = {}
    if not isinstance(pkg.get("dsh", {}).get("bundle", {}), dict) or "patch" not in pkg.get("dsh", {}).get("bundle", {}):
        problems.append("package.json has no dsh.bundle.patch")
    elif pkg["dsh"]["bundle"]["patch"] != "./cordis.patch.yml":
        problems.append("dsh.bundle.patch must be ./cordis.patch.yml")
    root = json.loads((KIT / "package.json").read_text(encoding="utf-8"))
    if pkg.get("version") != root.get("version"):
        problems.append(
            "version mismatch: package {0} vs kit {1}".format(pkg.get("version"), root.get("version"))
        )
    if pkg.get("name") != "dsh-vivado-preset":
        problems.append("package name must be dsh-vivado-preset")
    if problems:
        for p in problems:
            print("[FAIL] " + p, file=sys.stderr)
        print("=== PRESET PACKAGE: FAIL ===", file=sys.stderr)
        return 1
    print("[PASS] preset package in sync: patch + {0} skill files; version {1}".format(
        len(want_skills), pkg.get("version")))
    print("=== PRESET PACKAGE: PASS ===")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="generate the standalone dsh-vivado-preset package")
    ap.add_argument("--check", action="store_true", help="verify only; do not write")
    args = ap.parse_args()
    if args.check:
        return check()
    write_all()
    return check()


if __name__ == "__main__":
    sys.exit(main())
