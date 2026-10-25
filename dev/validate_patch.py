# -*- coding: utf-8 -*-
r"""validate_patch.py -- structural validation of a rendered dsh-vivado cordis.patch.yml.

Why this exists
    tools/render_patch.ps1 already self-checks the patch it writes. This script is the
    INDEPENDENT oracle: it parses the file the way the DSH loader would and asserts the shape
    the kit promises, so a regression in the template, in the renderer or in a persona fragment
    is caught by a second implementation instead of by the renderer agreeing with itself.

What it asserts
    * the file is YAML with DSH's custom `!!js` tag (registered, not rejected), LF, no BOM;
    * top level is a one-element list holding `- insert:`;
    * the single inserted row is the `preset-vivado` agent preset (id / name / order);
    * the preset carries exactly the 22 shipped plugin rows, in shipped order, plus
      `mcp-vivado` last;
    * the persona is a long block scalar, keeps every required discipline phrase, and states
      the version-tier facts that `--tier` expects;
    * `skill-filesystem.customSkillDirs` is a one-element ABSOLUTE ASCII list that equals
      `--expect-skills-dir` when that flag is given, and `includeDefaultRoots` stays default
      (absent) so the user's own skill roots keep working;
    * `mcp-vivado` is a stdio server named `vivado`, with the expected env keys, TEMP == TMP,
      ASCII command/cwd, and a tool timeout large enough for run_synthesis(wait=True);
    * no unrendered `{{...}}` placeholder remains except DSH's own `{{model}}`, no `!include`,
      and no FOREIGN user-home path (a home path belonging to whoever runs this check is fine:
      their venv may legitimately live there; another account name means an author path leaked
      into a shipped template).

Requirements
    Python >= 3.9 and PyYAML. This script does NOT vendor a YAML parser, and PyYAML is not
    installed by the kit: when it is missing we stop with the install hint and exit 2 instead
    of silently pretending the patch was checked.

Usage
    py dev/validate_patch.py <rendered-cordis.patch.yml> [--tier 2023.1|2025.2plus]
                             [--expect-skills-dir <kit>/skills]

Exit codes
    0 = PASS, 1 = FAIL (every problem is printed), 2 = environment / setup error.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml  # noqa: F401  (optional third-party dependency, see the docstring)
except ModuleNotFoundError:
    sys.stderr.write(
        "[ERROR] PyYAML is not importable by this interpreter:\n"
        "            {0}\n"
        "        validate_patch.py does not vendor a YAML parser. Install it once into the\n"
        "        SAME interpreter you use to run this script:\n"
        "            {0} -m pip install pyyaml\n"
        "        (on Windows the py launcher form is also fine: py -m pip install pyyaml)\n".format(
            sys.executable
        )
    )
    raise SystemExit(2)

# The 22 shipped plugin rows of the DSH `standard` preset, in shipped order. They are a
# byte-for-byte extraction (templates/shipped-standard-22rows.yml); the preset appends
# `mcp-vivado` as row 23.
SHIPPED_ROWS = [
    "persona", "agent-instructions", "time-context", "tool-bash", "tool-pwsh", "tool-fs",
    "tool-fs-search", "tool-jobs", "tool-schedule", "skill-filesystem", "tool-skill",
    "command-goal", "tool-goal", "planning", "compaction", "delegation", "tool-ask-user",
    "tool-todo", "tool-web", "present", "tool-plugin-manager", "tool-plugin-market",
]

# Discipline phrases the persona must keep whatever the tier is. Losing one of these is a
# behavioural regression, not a cosmetic one. The last three lock in the 2026-10-25 fix: the
# preset must drive the shell the session actually lists (never a third-party add-on), must name
# the launcher/TCL_OK success criterion, and must describe detached long builds.
PERSONA_PHRASES = ("GLOBALLY SERIAL", "ASCII", "file:line", "is_error: false", "safe_tcl",
                   "pwsh", "TCL_OK", "Start-Process", "Detach")

# Text that must NOT come back: these were the win_bash-coupled instructions removed on
# 2026-10-25 (they told the agent to depend on a plugin that is absent in other people's
# environments and that withdrew the official `pwsh` tool).
PERSONA_FORBIDDEN = ("is the shell for command work", "fall back to `win_bash`")

# Per-tier measured facts (docs/version-matrix.md).
TIER_PHRASES = {
    "2023.1": ("8.5.14", "-noprogress", "1024"),
    "2025.2plus": ("NOT measured", "Re-probe", "unverified"),
}

MCP_ENV_KEYS = ("PYTHONPATH", "VIVADO_PATH", "PYTHONUTF8", "TEMP", "TMP")
MCP_REQUIRED_KEYS = ("serverName", "transport", "command", "cwd", "toolCallTimeoutMs")

PLACEHOLDER_RE = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
HOME_PATH_RE = re.compile(r"[A-Za-z]:[\\/]Users[\\/]([^\\/\s\"']+)")
ALLOWED_PLACEHOLDERS = ("model",)


class Loader(yaml.SafeLoader):
    """SafeLoader plus DSH's custom `!!js` tag."""


def _construct_js(loader, node):
    return "<js:{}>".format(loader.construct_scalar(node))


Loader.add_constructor("tag:yaml.org,2002:js", _construct_js)


def _same_path(a: str, b: str) -> bool:
    return os.path.normcase(os.path.normpath(str(a))) == os.path.normcase(os.path.normpath(str(b)))


def _foreign_home_paths(text: str) -> list[str]:
    """Home paths in `text` that do NOT belong to the account running this check."""
    me = (os.environ.get("USERNAME") or os.environ.get("USER") or "").strip().lower()
    seen: list[str] = []
    for match in HOME_PATH_RE.finditer(text):
        account = match.group(1).strip().lower()
        if me and account == me:
            continue
        hit = match.group(0)
        if hit not in seen:
            seen.append(hit)
    return seen


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Structurally validate a rendered dsh-vivado cordis.patch.yml.",
        epilog="Exit codes: 0 = PASS, 1 = FAIL, 2 = environment/setup error.",
    )
    ap.add_argument("patch", help="rendered cordis.patch.yml to validate")
    ap.add_argument(
        "--tier",
        default=None,
        choices=sorted(TIER_PHRASES),
        help="also assert the version-tier measured facts of this persona tier",
    )
    ap.add_argument(
        "--expect-skills-dir",
        default=None,
        metavar="DIR",
        help="require skill-filesystem.customSkillDirs to equal this directory "
             "(normally <kit>/skills)",
    )
    args = ap.parse_args()

    path = Path(args.patch)
    if not path.is_file():
        print("  [FAIL] no such file: {0}".format(path))
        print("=== VALIDATE: FAIL (1 problem(s)) ===")
        return 2

    raw_bytes = path.read_bytes()
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        print("  [FAIL] rendered patch is not valid UTF-8: {0}".format(exc))
        print("=== VALIDATE: FAIL (1 problem(s)) ===")
        return 1

    problems: list[str] = []
    checks: list[str] = []

    def ok(msg: str) -> None:
        checks.append(msg)

    # ---- encoding / line endings -----------------------------------------------------------
    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        problems.append("rendered patch starts with a UTF-8 BOM (render_patch.ps1 writes none)")
    if b"\r\n" in raw_bytes:
        problems.append("rendered patch contains CRLF; render_patch.ps1 writes LF")

    # ---- parse -----------------------------------------------------------------------------
    try:
        doc = yaml.load(text, Loader=Loader)
    except yaml.YAMLError as exc:
        problems.append("YAML parse failed: {0}".format(str(exc).replace("\n", " ")[:300]))
        return report(checks, problems)

    if not isinstance(doc, list) or len(doc) != 1 or not isinstance(doc[0], dict) or "insert" not in doc[0]:
        problems.append(
            "top level must be a one-element list holding an `insert` key, got {0}".format(type(doc).__name__)
        )
        return report(checks, problems)

    inserts = doc[0]["insert"]
    if not isinstance(inserts, list):
        problems.append("`insert:` must be a list of rows, got {0}".format(type(inserts).__name__))
        return report(checks, problems)
    ids = [(r or {}).get("id") for r in inserts if isinstance(r, dict)]
    ok("insert rows: {0}".format(ids))
    if len(inserts) != 1:
        problems.append("keep exactly one inserted row (the preset), got {0}: {1}".format(len(inserts), ids))
        return report(checks, problems)

    # ---- the preset row --------------------------------------------------------------------
    row = inserts[0]
    if row.get("name") != "@deepseek-ai/dsh-agent-preset":
        problems.append(
            "inserted row name must be @deepseek-ai/dsh-agent-preset, got {0!r}".format(row.get("name"))
        )
    cfg = row.get("config") or {}
    for key, want in (("id", "vivado"), ("name", "Vivado"), ("order", 2)):
        if cfg.get(key) != want:
            problems.append("preset config.{0}: want {1!r}, got {2!r}".format(key, want, cfg.get(key)))
    plugins = cfg.get("plugins")
    if not isinstance(plugins, list):
        problems.append("preset config.plugins must be a list")
        return report(checks, problems)

    # ---- the 22 shipped rows + mcp-vivado --------------------------------------------------
    row_ids = [p.get("id") for p in plugins if isinstance(p, dict)]
    want_ids = SHIPPED_ROWS + ["mcp-vivado"]
    if row_ids != want_ids:
        missing = [x for x in want_ids if x not in row_ids]
        extra = [x for x in row_ids if x not in want_ids]
        problems.append(
            "plugin row list mismatch; missing={0} extra={1} (order matters: shipped order, then "
            "mcp-vivado last)".format(missing, extra)
        )
    else:
        ok("{0} plugin rows in shipped order (+ mcp-vivado last)".format(len(row_ids)))

    by_id = {p.get("id"): p for p in plugins if isinstance(p, dict)}

    # ---- persona ---------------------------------------------------------------------------
    persona_row = by_id.get("persona") or {}
    persona = (persona_row.get("config") or {}).get("prefix")
    if not isinstance(persona, str) or len(persona) < 400:
        problems.append("persona.config.prefix missing or too short")
    else:
        ok("persona: {0} lines, {1} chars".format(len(persona.splitlines()), len(persona)))
        for must in PERSONA_PHRASES:
            if must not in persona:
                problems.append("persona lost required discipline phrase: {0!r}".format(must))
        for banned in PERSONA_FORBIDDEN:
            if banned in persona:
                problems.append(
                    "persona still depends on a third-party shell: {0!r} (the preset must work "
                    "with the harness's own shell tools only)".format(banned)
                )
        if args.tier:
            for must in TIER_PHRASES[args.tier]:
                if must not in persona:
                    problems.append(
                        "tier {0}: persona must state the measured fact {1!r}".format(args.tier, must)
                    )
            ok("tier {0}: persona states {1}".format(args.tier, ", ".join(TIER_PHRASES[args.tier])))

    sf_row = by_id.get("skill-filesystem") or {}
    sf = sf_row.get("config") or {}
    dirs = sf.get("customSkillDirs")
    if not isinstance(dirs, list) or len(dirs) != 1:
        problems.append(
            "skill-filesystem.config.customSkillDirs must be a 1-element list, got {0!r}".format(dirs)
        )
    else:
        d = dirs[0]
        if not (d.startswith("/") or (len(d) > 2 and d[1] == ":")):
            problems.append("customSkillDirs entry must be absolute, got {0!r}".format(d))
        if args.expect_skills_dir and not _same_path(d, args.expect_skills_dir):
            problems.append(
                "customSkillDirs points at {0!r}, expected {1!r}".format(d, args.expect_skills_dir)
            )
        if any(ord(c) > 127 for c in d):
            problems.append("customSkillDirs is not ASCII: {0!r}".format(d))
        if sf.get("includeDefaultRoots") is not None:
            problems.append(
                "includeDefaultRoots should stay default (absent) so the user's own skill roots "
                "keep working"
            )
        ok("skill-filesystem customSkillDirs = {0}".format(d))

    # ---- mcp-vivado ------------------------------------------------------------------------
    mcp_row = by_id.get("mcp-vivado") or {}
    mcp = mcp_row.get("config") or {}
    for key in MCP_REQUIRED_KEYS:
        if key not in mcp:
            problems.append("mcp-vivado.config missing {0}".format(key))
    if mcp.get("serverName") != "vivado":
        problems.append(
            "mcp serverName must be vivado (tool prefix mcp__vivado__), got {0!r}".format(mcp.get("serverName"))
        )
    if mcp.get("transport") != "stdio":
        problems.append("mcp transport must be stdio, got {0!r}".format(mcp.get("transport")))
    if mcp.get("args") != ["-m", "vivado_mcp"]:
        problems.append("mcp args unexpected: {0!r}".format(mcp.get("args")))
    env = mcp.get("env") or {}
    for key in MCP_ENV_KEYS:
        if key not in env:
            problems.append("mcp env missing {0}".format(key))
    for key in ("command", "cwd"):
        value = mcp.get(key) or ""
        if any(ord(c) > 127 for c in str(value)):
            problems.append("mcp {0} is not ASCII: {1!r}".format(key, value))
    if env.get("TEMP") != env.get("TMP"):
        problems.append("mcp TEMP and TMP must be the same directory")
    try:
        timeout = int(mcp.get("toolCallTimeoutMs") or 0)
    except (TypeError, ValueError):
        timeout = 0
    if timeout < 600000:
        problems.append(
            "toolCallTimeoutMs too low for run_synthesis(wait=True): {0}".format(mcp.get("toolCallTimeoutMs"))
        )
    ok("mcp-vivado: {0} {1} cwd={2}".format(mcp.get("command"), mcp.get("args"), mcp.get("cwd")))

    # ---- raw text: placeholders, includes, foreign home paths ------------------------------
    stripped = text.replace("{{model}}", "")
    leftover = sorted(set(PLACEHOLDER_RE.findall(stripped)))
    if leftover:
        problems.append("unrendered placeholder(s) remain: {0}".format(", ".join(leftover)))
    if "!include" in text:
        problems.append("rendered patch still contains an `!include` directive")
    leaked = _foreign_home_paths(text)
    if leaked:
        problems.append("rendered patch carries a foreign user-home path: {0}".format(", ".join(leaked)))

    return report(checks, problems)


def report(checks: list[str], problems: list[str]) -> int:
    for c in checks:
        print("  [ok] {0}".format(c))
    if problems:
        for p in problems:
            print("  [FAIL] {0}".format(p))
        print("=== VALIDATE: FAIL ({0} problem(s)) ===".format(len(problems)))
        return 1
    print("=== VALIDATE: PASS ===")
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
