# -*- coding: utf-8 -*-
r"""accept_all.py -- end-to-end acceptance run for the dsh-vivado kit.

What it is for
    The repo's `--check` gates (tools/make_template.py, tools/gen_skills_manifest.py) prove that
    the sources are self-consistent. They cannot prove that `install.ps1` still installs, that
    `uninstall.ps1` still removes everything, or that `doctor.ps1` still fails when it should.
    This script drives the shipped entry points exactly as a user would - inside a THROW-AWAY
    DSH_HOME - and asserts on their output. Nothing else in the kit is allowed to be the judge of
    its own install.

Isolation
    Every path this script writes lives under --work-dir (default: the OS temp directory plus
    `dsh-vivado-dev`): the probe DSH_HOME, the rendered patches, the config fixtures, the log.
    The live profile (default %USERPROFILE%\.dsh\profiles\desktop) is only ever read: its
    package.json / pnpm-lock.yaml / compatibility.json / cordis.patch.yml fingerprints are
    compared before and after the run and any change fails the run (the [GUARD] line).
    install.ps1 / uninstall.ps1 / doctor.ps1 / dsh all receive -DshHome and DSH_HOME pointing at
    the probe home.

The matrix (49 assertions; see dev/README.md for what each group covers)
    static     8  generator/renderer check, skills manifest, BOTH persona tiers render+validate,
                  no build junk, no author home path in repo text files
    install   18  cli install, profile/composition markers, idempotency, -WhatIf, skills untouched
    uninstall  7  clean removal, composition still works, second run is a no-op
    manual     4  -Mode manual (no pnpm) install
    stranger   7  different part/project_root, plus the "second -Config is re-rendered" regression
    doctor     5  healthy run, three injected failures, -Json contract

Usage
    py dev/accept_all.py                          # full matrix (rebuilds the probe home)
    py dev/accept_all.py --only static            # cheap, no DSH install needed
    py dev/accept_all.py --only install,uninstall --home <work-dir>/probe-accept
    py dev/accept_all.py --keep-home              # reuse an existing probe home

Exit codes
    0 = every assertion passed and the live profile is byte-identical,
    1 = at least one assertion failed (or the live-profile guard tripped),
    2 = setup problem (missing entry point, non-ASCII scratch path, no DSH CLI).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
try:  # Windows-only, and only used to mirror Find-DshCli's App Paths probe
    import winreg
except ImportError:  # pragma: no cover - non-Windows host
    winreg = None

HERE = Path(__file__).resolve()
KIT = HERE.parent.parent
WORK = Path(tempfile.gettempdir()) / "dsh-vivado-dev"
HOME = WORK / "dshprobe-accept"
PROFILE = "probe"
PART = ""
CONFIG_SRC = KIT / "config.example.yml"
INSTALL_ROOT = None
DSH_CMD = None
LIVE_PROFILE = "desktop"
KEEP_HOME = False

POWERSHELL = "powershell.exe"
KIT_PACKAGE = "dsh-vivado"
# A real 7-series part from the vendor's own tables: the "stranger machine" scenario.
ALTERNATE_PART = "xc7a35tftg256-1"
# Non-ASCII probe for the doctor ascii-paths injection: written as escapes so this file stays
# pure ASCII while the generated config fixture is genuinely non-ASCII.
NON_ASCII_PROBE = "\u4e2d\u6587"

TEXT_SUFFIXES = (".ps1", ".py", ".json", ".yml", ".yaml", ".tmpl", ".md", ".txt", ".patch")
TEXT_NAMES = (".gitignore", ".gitattributes", "NOTICE", "LICENSE")
HOME_PATH_RE = re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\\/\s\"'<>]+")
# The original author's machine account name must not survive anywhere in the shipped tree.
# It is assembled from code points on purpose: this scanner must not be the last file in the
# repo that still carries the very string it is looking for.
AUTHOR_ACCOUNT = "".join(chr(c) for c in (0x31, 0x35, 0x32, 0x36, 0x36))
# Anything that looks like a credential is redacted before it reaches stdout or the log.
SECRET_RE = re.compile(
    r"(?i)\b(api[_-]?key|token|secret|password|passwd|authorization)\b(\s*[:=]\s*)(\S+)")
LIVE_FILES = ("package.json", "pnpm-lock.yaml", "compatibility.json", "cordis.patch.yml")

results = []  # type: list[tuple[str, bool, str]]


# ---------------------------------------------------------------------------
#  plumbing
# ---------------------------------------------------------------------------
def record(name: str, ok: bool, detail: str = "") -> bool:
    results.append((name, ok, detail))
    print("  [{0}] {1}{2}".format("PASS" if ok else "FAIL", name, " -- " + detail if detail else ""))
    return ok


def run(cmd, env_extra=None, timeout=900, cwd=None):
    env = dict(os.environ)
    env.setdefault("PYTHONUTF8", "1")
    if env_extra:
        env.update(env_extra)
    t0 = time.time()
    proc = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=env, timeout=timeout, cwd=str(cwd) if cwd else None,
        shell=isinstance(cmd, str),
    )
    return proc.returncode, proc.stdout, proc.stderr, time.time() - t0


def ps(script: Path, *args, env_extra=None):
    cmd = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *args]
    rc, out, err, _ = run(cmd, env_extra=env_extra)
    return rc, (out or "") + (("\n[stderr]\n" + err) if err.strip() else "")


def dsh(*args, home=None):
    rc, out, err, _ = run([str(DSH_CMD), *args],
                          env_extra={"DSH_HOME": str(home or HOME)}, timeout=1800)
    return rc, (out or "") + (("\n[stderr]\n" + err) if err.strip() else "")


def dump_config(home=None):
    rc, text = dsh("--profile", PROFILE, "--dump-config", home=home)
    if rc != 0:
        print("    ! --dump-config rc={0}\n{1}".format(rc, redact(text[-1500:])))
    return text


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def redact(text: str) -> str:
    """Never print a credential: `--dump-config` may echo whatever a profile carries."""
    return SECRET_RE.sub(lambda m: m.group(1) + m.group(2) + "<redacted>", text or "")


def tail(text: str, lines: int = 12) -> str:
    return "\n".join((text or "").strip().splitlines()[-lines:])


def snapshot_dir(path: Path):
    """Read-only fingerprint of a directory listing: (name, mtime_ns, size) per entry."""
    if not path.is_dir():
        return None
    out = []
    for entry in sorted(path.iterdir()):
        try:
            st = entry.stat()
            out.append((entry.name, st.st_mtime_ns, st.st_size))
        except OSError:
            out.append((entry.name, -1, -1))
    return out


def inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def make_home(force=None) -> None:
    if force is None:
        force = not KEEP_HOME
    args = [sys.executable, str(HERE.parent / "make_probe_home.py"),
            "--home", str(HOME), "--name", PROFILE]
    if force:
        args.append("--force")
    rc, out, err, elapsed = run(args, timeout=1800)
    print("    probe home built in {0:.0f}s (rc={1})".format(elapsed, rc))
    if rc != 0:
        print(tail(out, 8), tail(err, 8))


# ---------------------------------------------------------------------------
#  config fixture helpers (flat `key: value` dialect, no PyYAML needed)
# ---------------------------------------------------------------------------
def cfg_parse(text: str) -> dict:
    cfg = {}
    for raw in text.replace("\r\n", "\n").split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        idx = line.find(":")
        if idx < 1:
            continue
        key, val = line[:idx].strip(), line[idx + 1:].strip()
        if val and not val.startswith(("'", '"')):
            hash_idx = val.find(" #")
            if hash_idx >= 0:
                val = val[:hash_idx].strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        cfg[key] = val
    return cfg


def cfg_set(text: str, key: str, value: str) -> str:
    pattern = re.compile(r"(?m)^(\s*" + re.escape(key) + r"\s*):.*$")
    line = "{0}: {1}".format(key, value)
    if pattern.search(text):
        return pattern.sub(lambda m: line, text, count=1)
    return text.rstrip("\n") + "\n" + line + "\n"


def write_cfg(name: str, text: str) -> Path:
    path = WORK / "cfg" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def base_config_text() -> str:
    return CONFIG_SRC.read_text(encoding="utf-8")


def as_path(value: str) -> str:
    """Render a scratch path the way the kit's config files spell paths (forward slashes)."""
    return str(value).replace("\\", "/")


# ---------------------------------------------------------------------------
#  DSH CLI / install root discovery (mirrors lib/common.ps1 Find-DshCli)
# ---------------------------------------------------------------------------
def _cli_candidates(explicit):
    out = []
    if explicit:
        out.append(Path(explicit))
    env_dir = os.environ.get("DSH_INSTALL_DIR")
    if env_dir:
        out.append(Path(env_dir))
    if winreg is not None:
        key = r"Software\Microsoft\Windows\CurrentVersion\App Paths\DeepSeek Harness.exe"
        for hive in (getattr(winreg, "HKEY_CURRENT_USER", None), getattr(winreg, "HKEY_LOCAL_MACHINE", None)):
            if hive is None:
                continue
            try:
                with winreg.OpenKey(hive, key) as handle:
                    exe, _ = winreg.QueryValueEx(handle, "")
                if exe:
                    out.append(Path(str(exe)).parent)
            except OSError:
                continue
    conventional = []
    local = os.environ.get("LOCALAPPDATA")
    programs = os.environ.get("ProgramFiles")
    programs_x86 = os.environ.get("ProgramFiles(x86)")
    if local:
        conventional.append(Path(local) / "Programs" / "DeepSeek Harness")
    if programs:
        conventional.append(Path(programs) / "DeepSeek Harness")
    if programs_x86:
        conventional.append(Path(programs_x86) / "DeepSeek Harness")
    for drive in ("C:", "D:", "E:", "F:"):
        conventional.append(Path(drive + os.sep + "dsh"))
    out.extend(conventional)
    return out


def _install_root_of(cli: Path) -> Path:
    node = cli.parent
    while node.parent != node:
        if node.name.lower() == "resources":
            return node.parent
        node = node.parent
    return cli.parent


def find_dsh_cli(explicit):
    for candidate in _cli_candidates(explicit):
        try:
            if candidate.is_file() and candidate.name.lower() == "dsh.cmd":
                return _install_root_of(candidate), candidate
            cli = candidate / "resources" / "runtime" / "cli" / "bin" / "dsh.cmd"
            if cli.is_file():
                return candidate, cli
        except OSError:
            continue
    return None, None


# ---------------------------------------------------------------------------
#  live-profile guard (out of the 49-assertion matrix, but fails the run)
# ---------------------------------------------------------------------------
def live_dsh_home() -> Path:
    root = os.environ.get("USERPROFILE") or str(Path.home())
    return Path(root) / ".dsh"


def live_fingerprint():
    if not LIVE_PROFILE:
        return None, None
    profile = live_dsh_home() / "profiles" / LIVE_PROFILE
    if not profile.is_dir():
        return profile, None
    fp = {}
    for name in LIVE_FILES:
        path = profile / name
        if path.is_file():
            st = path.stat()
            fp[name] = (st.st_mtime_ns, sha(path))
    fp["skills/"] = snapshot_dir(live_dsh_home() / "skills")
    return profile, fp


def print_guard(profile: Path, fp) -> None:
    if not LIVE_PROFILE:
        print("[GUARD] live-profile guard disabled (--live-profile \"\")")
        return
    if fp is None:
        print("[GUARD] no live profile at {0}; nothing to protect (skipped)".format(profile))
        return
    files = [k for k in fp if k != "skills/"]
    print("[GUARD] live profile {0}: {1} file(s) + skills/ fingerprinted (read-only)".format(
        profile, len(files)))


# ---------------------------------------------------------------------------
#  static group (8)
# ---------------------------------------------------------------------------
def group_static() -> bool:
    print("\n== static: template / renderer / skills / hygiene ==")
    ok = True
    py = sys.executable

    rc, out, err, _ = run([py, str(KIT / "tools" / "make_template.py"), "--check"])
    ok &= record("template self-check", rc == 0, "" if rc == 0 else tail(out + err, 6))

    rc, out, err, _ = run([py, str(KIT / "tools" / "gen_skills_manifest.py"), "--check"])
    ok &= record("skills MANIFEST --check", rc == 0, "" if rc == 0 else tail(out + err, 6))

    # Both persona tiers must render AND validate: a fragment edited on one tier only is a
    # silent behavioural drift between 2023.1 and 2025.2plus.
    source_text = base_config_text()
    validate = HERE.parent / "validate_patch.py"
    for tier, version in (("2023.1", "2023.1"), ("2025.2plus", "2025.2")):
        cfg = write_cfg("accept-cfg-{0}.yml".format(tier),
                        cfg_set(source_text, "vivado_version", version))
        out_patch = WORK / "render" / "accept-{0}.yml".format(tier)
        out_patch.parent.mkdir(parents=True, exist_ok=True)
        rc, txt = ps(KIT / "tools" / "render_patch.ps1",
                     "-ConfigPath", str(cfg), "-OutFile", str(out_patch),
                     "-BundleDir", str(KIT), "-SkillsDir", str(KIT / "skills"))
        ok &= record("render tier {0}".format(tier), rc == 0,
                     "" if rc == 0 else tail(txt, 4))
        rc2, vout, verr, _ = run([py, str(validate), str(out_patch), "--tier", tier,
                                  "--expect-skills-dir", str(KIT / "skills")])
        picked = [line for line in vout.splitlines()
                  if "persona:" in line or "VALIDATE" in line or "[FAIL]" in line]
        ok &= record("validate tier {0}".format(tier), rc2 == 0,
                     (picked[-1].strip() if picked else tail(vout + verr, 3)))

    junk = []
    for path in KIT.rglob("*"):
        if ".git" in path.relative_to(KIT).parts:
            continue
        if path.is_file() and ("__pycache__" in path.parts or path.suffix == ".pyc"
                               or ".bak-" in path.name or path.name == "config.yml"):
            junk.append(str(path.relative_to(KIT)))
    ok &= record("no build junk / no committed config.yml", not junk, ", ".join(junk[:5]))

    # Distribution red line: no author home path, no leftover developer account name in any
    # text file that ships. `dev/` is the maintainer's own harness (not installed by install.ps1)
    # and `skills/` is vendored upstream content, so both are exempt.
    leaked = []
    for path in KIT.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(KIT)
        if rel.parts and rel.parts[0] in ("skills", "dev"):
            continue
        if ".git" in rel.parts:
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name not in TEXT_NAMES:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if HOME_PATH_RE.search(text) or AUTHOR_ACCOUNT in text:
            leaked.append(str(rel))
    ok &= record("no author home path / account leak in repo text files", not leaked,
                 ", ".join(leaked[:5]))
    return ok


# ---------------------------------------------------------------------------
#  install group (18)
# ---------------------------------------------------------------------------
def _install_args(cfg: Path, *extra, part: str = ""):
    args = ["-DshHome", str(HOME), "-Profile", PROFILE, "-NonInteractive",
            "-InstallDir", str(INSTALL_ROOT), "-Config", str(cfg)]
    if part:
        args += ["-Part", part]
    return args + list(extra)


def group_install() -> bool:
    print("\n== install (cli mode) + composition ==")
    make_home()
    prof = HOME / "profiles" / PROFILE
    cfg = write_cfg("accept-config.yml", base_config_text())
    env = {"DSH_HOME": str(HOME)}
    before = {n: sha(prof / n) for n in ("package.json",) if (prof / n).is_file()}
    user_skills = live_dsh_home() / "skills"
    skills_before = snapshot_dir(user_skills)

    rc, txt = ps(KIT / "install.ps1", *_install_args(cfg, part=PART), env_extra=env)
    ok = record("install.ps1 exit 0", rc == 0, "" if rc == 0 else tail(txt, 14))
    ok &= record("installer prints the restart requirement",
                 bool(re.search(r"restart", txt, re.I)), tail(txt, 1))

    pkg = json.loads((prof / "package.json").read_text(encoding="utf-8"))
    dep = pkg.get("dependencies", {}).get(KIT_PACKAGE, "")
    ok &= record("dependency recorded as link:", str(dep).startswith("link:"), str(dep))
    bundles = pkg.get("dsh", {}).get("profile", {}).get("bundles", [])
    ok &= record("bundle appended exactly once", bundles.count(KIT_PACKAGE) == 1,
                 "{0} bundles".format(len(bundles)))

    stage = HOME / "bundles" / KIT_PACKAGE
    patch_path = stage / "cordis.patch.yml"
    ok &= record("staging bundle exists", patch_path.is_file(), str(stage))
    patch = patch_path.read_text(encoding="utf-8") if patch_path.is_file() else ""
    ok &= record("staged patch has no unrendered placeholder",
                 "{{" not in patch.replace("{{model}}", ""))
    skill_docs = list((stage / "skills").glob("*/SKILL.md")) if (stage / "skills").is_dir() else []
    ok &= record("staged skills complete", len(skill_docs) == 8,
                 "{0} SKILL.md".format(len(skill_docs)))

    dump = dump_config()
    ok &= record("dump-config: kit bundle layer present", "# == " + KIT_PACKAGE in dump)
    ok &= record("dump-config: preset-vivado row", "- id: preset-vivado" in dump)
    ok &= record("dump-config: persona discipline text",
                 "GLOBALLY SERIAL" in dump and "file:line" in dump)
    # The composed dump is YAML *as the host prints it*: other presets elsewhere in the tree
    # carry their own customSkillDirs (some as !!js), and a long probe-home path is emitted as a
    # `>-` block scalar instead of a plain `- value` line. So compare value-presence insensitively
    # to whitespace/line breaks: the staged skills directory is unique to this kit, which is what
    # the marker means ("skill-filesystem is mounted at the staging dir, rank 300").
    want_dir = str(stage / "skills").replace("\\", "/")
    squashed_want = re.sub(r"\s+", "", want_dir).lower()
    hits = re.findall(r"customSkillDirs:", dump)
    ok &= record("dump-config: customSkillDirs -> staged skills",
                 bool(hits) and squashed_want in re.sub(r"\s+", "", dump).lower(),
                 want_dir if hits else "no customSkillDirs row in the composed dump")
    ok &= record("dump-config: mcp-vivado row", "- id: mcp-vivado" in dump)
    ok &= record("dump-config: mcp tools prefixed vivado", "serverName: vivado" in dump)

    # idempotency: a second run over the same config must not touch the profile
    h1 = {n: sha(prof / n) for n in ("package.json",) if (prof / n).is_file()}
    rc2, txt2 = ps(KIT / "install.ps1", *_install_args(cfg, part=PART), env_extra=env)
    h2 = {n: sha(prof / n) for n in ("package.json",) if (prof / n).is_file()}
    ok &= record("second install exit 0", rc2 == 0, "" if rc2 == 0 else tail(txt2, 8))
    ok &= record("second install did not change package.json", h1 == h2,
                 "{0} vs {1}".format(h1.get("package.json", "")[:12], h2.get("package.json", "")[:12]))
    ok &= record("pristine -> installed package.json changed", before != h2,
                 "{0} -> {1}".format(before.get("package.json", "")[:12], h2.get("package.json", "")[:12]))

    # -WhatIf must not change a single byte
    snap_paths = [p for p in (prof / "package.json", patch_path) if p.is_file()]
    snap = {str(p): sha(p) for p in snap_paths}
    rc3, txt3 = ps(KIT / "install.ps1", *_install_args(cfg, "-WhatIf", part=PART), env_extra=env)
    snap2 = {str(p): sha(p) for p in snap_paths}
    ok &= record("-WhatIf exit 0 and changes nothing", rc3 == 0 and snap == snap2,
                 "" if rc3 == 0 else tail(txt3, 6))

    # red line: the installer must never write into the user skill roots
    skills_after = snapshot_dir(user_skills)
    ok &= record("~/.dsh/skills untouched by the installer", skills_before == skills_after,
                 "before={0} after={1}".format(
                     len(skills_before or []), len(skills_after or [])))
    return ok


# ---------------------------------------------------------------------------
#  uninstall group (7)
# ---------------------------------------------------------------------------
def group_uninstall() -> bool:
    print("\n== uninstall (clean removal) ==")
    prof = HOME / "profiles" / PROFILE
    stage = HOME / "bundles" / KIT_PACKAGE
    env = {"DSH_HOME": str(HOME)}
    args = ["-DshHome", str(HOME), "-Profile", PROFILE, "-NonInteractive",
            "-InstallDir", str(INSTALL_ROOT)]
    rc, txt = ps(KIT / "uninstall.ps1", *args, env_extra=env)
    ok = record("uninstall.ps1 exit 0", rc == 0, "" if rc == 0 else tail(txt, 14))
    pkg_text = (prof / "package.json").read_text(encoding="utf-8")
    ok &= record("dependency row removed", KIT_PACKAGE not in pkg_text)
    ok &= record("staging dir removed", not stage.exists(), str(stage))
    link = prof / "node_modules" / KIT_PACKAGE
    ok &= record("node_modules link removed", not link.exists() and not link.is_symlink(), str(link))
    dump = dump_config()
    ok &= record("dump-config: preset-vivado gone", "preset-vivado" not in dump)
    ok &= record("dump-config: still composes (no startup error)", dump.count("== ") > 5)
    rc2, txt2 = ps(KIT / "uninstall.ps1", *args, env_extra=env)
    ok &= record("second uninstall is a no-op success", rc2 == 0, "" if rc2 == 0 else tail(txt2, 8))
    return ok


# ---------------------------------------------------------------------------
#  manual-mode group (4)
# ---------------------------------------------------------------------------
def group_manual() -> bool:
    print("\n== manual mode (no pnpm) ==")
    make_home()
    cfg = write_cfg("accept-config.yml", base_config_text())
    rc, txt = ps(KIT / "install.ps1", *_install_args(cfg, "-Mode", "manual", part=PART),
                 env_extra={"DSH_HOME": str(HOME)})
    ok = record("manual install exit 0", rc == 0, "" if rc == 0 else tail(txt, 14))
    pkg = json.loads((HOME / "profiles" / PROFILE / "package.json").read_text(encoding="utf-8"))
    ok &= record("manual: dependency recorded", KIT_PACKAGE in pkg.get("dependencies", {}))
    ok &= record("manual: bundle listed",
                 KIT_PACKAGE in pkg.get("dsh", {}).get("profile", {}).get("bundles", []))
    dump = dump_config()
    ok &= record("manual: preset composes",
                 "- id: preset-vivado" in dump and "- id: mcp-vivado" in dump)
    return ok


# ---------------------------------------------------------------------------
#  stranger group (7)
# ---------------------------------------------------------------------------
def group_stranger() -> bool:
    print("\n== stranger perspective (different part / project_root) ==")
    make_home()
    env = {"DSH_HOME": str(HOME)}
    work_root = WORK / "fpga_work"
    (work_root / ".tmp").mkdir(parents=True, exist_ok=True)
    stranger = cfg_set(base_config_text(), "part", ALTERNATE_PART)
    stranger = cfg_set(stranger, "project_root", as_path(work_root))
    stranger = cfg_set(stranger, "vivado_mcp_cwd", as_path(work_root))
    stranger = cfg_set(stranger, "temp_dir", as_path(work_root / ".tmp"))
    cfg = write_cfg("accept-cfg-stranger.yml", stranger)
    rc, out = ps(KIT / "install.ps1", *_install_args(cfg), env_extra=env)
    ok = record("stranger install exit 0", rc == 0, "" if rc == 0 else tail(out, 14))
    dump = dump_config()
    ok &= record("stranger: persona carries the new part", ALTERNATE_PART in dump)
    ok &= record("stranger: persona carries the new project root", as_path(work_root) in dump)
    ok &= record("stranger: no leftover of the previous part",
                 (PART not in dump) if PART else True,
                 "" if PART else "no `part` in the config fixture")

    # Regression guard for the "second -Config is ignored when staging already exists" bug (P0):
    # re-install with the original config over the existing staging dir and require the rendered
    # persona AND the staging config to switch back.
    original = write_cfg("accept-config.yml", base_config_text())
    rc2, out2 = ps(KIT / "install.ps1", *_install_args(original, part=PART), env_extra=env)
    stage_patch = HOME / "bundles" / KIT_PACKAGE / "cordis.patch.yml"
    stage_text = stage_patch.read_text(encoding="utf-8") if stage_patch.is_file() else ""
    ok &= record("re-config: install exit 0", rc2 == 0, "" if rc2 == 0 else tail(out2, 8))
    ok &= record("re-config: staged patch re-rendered with the new config",
                 bool(PART) and PART in stage_text and ALTERNATE_PART not in stage_text,
                 "want={0} has_want={1} has_prev={2}".format(
                     PART, PART in stage_text, ALTERNATE_PART in stage_text))
    dump2 = dump_config()
    ok &= record("re-config: composed persona follows the new config",
                 bool(PART) and PART in dump2 and ALTERNATE_PART not in dump2)
    return ok


# ---------------------------------------------------------------------------
#  doctor group (5)
# ---------------------------------------------------------------------------
def _bad_vivado_path(value: str) -> str:
    match = re.match(r"^(.*[/\\]Vivado[/\\])([^/\\]+)([/\\]bin)$", value, re.I)
    if match:
        return match.group(1) + "9999.9" + match.group(3)
    return value.rstrip("/\\") + "/9999.9/bin"


def group_doctor() -> bool:
    print("\n== doctor: clean run + 3 injected failures ==")
    installed = (HOME / "bundles" / KIT_PACKAGE / "cordis.patch.yml").is_file()
    if not installed:
        make_home()
        cfg = write_cfg("accept-config.yml", base_config_text())
        ps(KIT / "install.ps1", *_install_args(cfg, part=PART), env_extra={"DSH_HOME": str(HOME)})
    env = {"DSH_HOME": str(HOME)}
    base = base_config_text()
    cfg = cfg_parse(base)
    healthy = write_cfg("accept-config.yml", base)
    doctor = ["-DshHome", str(HOME), "-Profile", PROFILE, "-NonInteractive",
              "-InstallDir", str(INSTALL_ROOT), "-Config", str(healthy)]

    rc, out = ps(KIT / "doctor.ps1", *doctor, env_extra=env)
    fails = re.findall(r"\[FAIL\]\s*(\S+)", out)
    warns = re.findall(r"\[WARN\]\s*(\S+)", out)
    ok = record("doctor exit 0 on a healthy machine", rc == 0, "FAIL={0} WARN={1}".format(fails, warns))

    # One injected failure per check that has a machine-checkable judgement. The value to corrupt
    # is read from the config, so this works with config.example.yml and with a real config.yml.
    cases = (
        ("ascii-paths", "temp_dir", lambda v: v + "/" + NON_ASCII_PROBE),
        ("vivado-install", "vivado_path", _bad_vivado_path),
        ("mcp-import", "vivado_mcp_site", lambda v: v.rstrip("/\\") + "_typo"),
    )
    for check_id, key, mutate in cases:
        value = cfg.get(key, "")
        if not value:
            ok &= record("doctor catches broken " + check_id, False,
                         "the config has no `{0}` value to corrupt".format(key))
            continue
        bad = write_cfg("accept-bad-{0}.yml".format(check_id), cfg_set(base, key, mutate(value)))
        rc2, out2 = ps(KIT / "doctor.ps1", "-DshHome", str(HOME), "-Profile", PROFILE,
                       "-Config", str(bad), "-InstallDir", str(INSTALL_ROOT), "-NonInteractive",
                       env_extra=env)
        hit = re.search(r"\[FAIL\]\s*" + re.escape(check_id) + r"\b(.*)", out2)
        ok &= record("doctor catches broken " + check_id, rc2 != 0 and bool(hit),
                     (hit.group(1).strip()[:110] + " | exit=" + str(rc2)) if hit
                     else "exit={0}".format(rc2))

    rc3, out3 = ps(KIT / "doctor.ps1", *doctor, "-Json", env_extra=env)
    try:
        data = json.loads(out3[out3.index("["):])
        fields = all({"id", "title", "status", "detail", "fix"} <= set(row) for row in data)
        ok &= record("doctor -Json is valid JSON with the 5 fields", rc3 == 0 and fields,
                     "{0} checks".format(len(data)))
    except (ValueError, IndexError) as exc:
        ok &= record("doctor -Json is valid JSON with the 5 fields", False,
                     "{0}: {1}".format(exc, out3[:200].replace("\n", " ")))
    return ok


GROUPS = (
    ("static", group_static),
    ("install", group_install),
    ("uninstall", group_uninstall),
    ("manual", group_manual),
    ("stranger", group_stranger),
    ("doctor", group_doctor),
)

GROUP_NEEDS = {
    "static": (),
    "install": ("install.ps1",),
    "uninstall": ("uninstall.ps1",),
    "manual": ("install.ps1",),
    "stranger": ("install.ps1",),
    "doctor": ("doctor.ps1",),
}


class Tee:
    """Mirror stdout into the log file under <work-dir>/logs/ (UTF-8, LF)."""

    def __init__(self, stream, path: Path):
        self.stream = stream
        path.parent.mkdir(parents=True, exist_ok=True)
        self.file = open(path, "w", encoding="utf-8", newline="\n")

    def write(self, text):
        self.stream.write(text)
        self.file.write(text)
        self.file.flush()
        return len(text)

    def flush(self):
        self.stream.flush()
        self.file.flush()

    def isatty(self):
        return False

    @property
    def encoding(self):
        return "utf-8"


# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------
def main() -> int:
    global KIT, WORK, HOME, PROFILE, PART, CONFIG_SRC, INSTALL_ROOT, DSH_CMD, LIVE_PROFILE
    global KEEP_HOME

    ap = argparse.ArgumentParser(
        description="End-to-end acceptance for the dsh-vivado kit: 6 groups, 49 assertions, "
                    "always inside an isolated DSH_HOME.",
        epilog="Exit codes: 0 = all assertions passed, 1 = a failure (or the live-profile guard "
               "tripped), 2 = setup problem.",
    )
    ap.add_argument("--kit", default=str(KIT), metavar="DIR",
                    help="kit directory under test (default: the repo this script lives in)")
    ap.add_argument("--work-dir", default=str(WORK), metavar="DIR",
                    help="scratch root for probe homes / rendered patches / logs "
                         "(default: <temp>\\dsh-vivado-dev)")
    ap.add_argument("--home", default=None, metavar="DIR",
                    help="probe DSH_HOME (default: <work-dir>\\dshprobe-accept)")
    ap.add_argument("--profile", default=PROFILE, metavar="NAME",
                    help="profile name inside the probe home (default: probe)")
    ap.add_argument("--dsh-install", default=None, metavar="DIR",
                    help="DSH installation root, or its dsh.cmd (default: auto-detect)")
    ap.add_argument("--config", default=None, metavar="FILE",
                    help="machine config to derive fixtures from "
                         "(default: <kit>\\config.example.yml)")
    ap.add_argument("--live-profile", default=LIVE_PROFILE, metavar="NAME",
                    help="live profile to fingerprint read-only and never write "
                         "(default: desktop; empty string disables the guard)")
    ap.add_argument("--only", default="", help="comma separated group names")
    ap.add_argument("--keep-home", action="store_true",
                    help="reuse the existing probe home instead of rebuilding it")
    ap.add_argument("--no-log", action="store_true", help="do not write a log file")
    args = ap.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    KIT = Path(args.kit).resolve()
    WORK = Path(args.work_dir).resolve()
    HOME = Path(args.home).resolve() if args.home else WORK / "dshprobe-accept"
    PROFILE = args.profile
    LIVE_PROFILE = args.live_profile
    KEEP_HOME = args.keep_home

    # ---- setup checks ----------------------------------------------------------------------
    if not (KIT / "package.json").is_file():
        print("[ERROR] --kit is not a dsh-vivado checkout: {0}".format(KIT), file=sys.stderr)
        return 2
    CONFIG_SRC = Path(args.config).resolve() if args.config else KIT / "config.example.yml"
    if not CONFIG_SRC.is_file():
        print("[ERROR] no config to derive fixtures from: {0}".format(CONFIG_SRC), file=sys.stderr)
        return 2
    PART = cfg_parse(CONFIG_SRC.read_text(encoding="utf-8")).get("part", "")

    for path, what in ((WORK, "--work-dir"), (HOME, "--home")):
        if any(ord(c) > 127 for c in str(path)):
            print("[ERROR] {0} is not ASCII: {1}\n        Vivado's Tcl layer breaks on non-ASCII "
                  "paths (and the installer refuses them); pass an ASCII --work-dir.".format(
                      what, path), file=sys.stderr)
            return 2
    WORK.mkdir(parents=True, exist_ok=True)
    for sub in ("cfg", "render", "logs"):
        (WORK / sub).mkdir(parents=True, exist_ok=True)

    INSTALL_ROOT, DSH_CMD = find_dsh_cli(args.dsh_install)

    names = [n.strip() for n in args.only.split(",") if n.strip()] or [n for n, _ in GROUPS]
    unknown = [n for n in names if n not in dict(GROUPS)]
    if unknown:
        print("[ERROR] unknown group(s): {0}; known: {1}".format(
            unknown, ", ".join(n for n, _ in GROUPS)), file=sys.stderr)
        return 2
    if DSH_CMD is None and any(n != "static" for n in names):
        print("[ERROR] no DSH CLI found; pass --dsh-install <DSH install root> "
              "(a directory holding resources\\runtime\\cli\\bin\\dsh.cmd). "
              "Only the static group works without one.", file=sys.stderr)
        return 2
    wanted = sorted({f for n in names for f in GROUP_NEEDS[n]})
    missing = [f for f in wanted if not (KIT / f).is_file()]
    extra_files = [HERE.parent / "make_probe_home.py", HERE.parent / "validate_patch.py"]
    missing += [p.name for p in extra_files if not p.is_file()]
    if missing:
        print("[ERROR] missing shipped entry points in {0}: {1}".format(KIT, missing), file=sys.stderr)
        return 2
    if inside(HOME, live_dsh_home()) or inside(WORK, live_dsh_home() / "profiles"):
        print("[ERROR] the scratch paths overlap the live DSH home; refusing to run:\n"
              "        home = {0}\n        work = {1}".format(HOME, WORK), file=sys.stderr)
        return 2

    log_path = None
    tee = None
    if not args.no_log:
        log_path = WORK / "logs" / "accept-{0}.log".format(time.strftime("%Y%m%d-%H%M%S"))
        tee = Tee(sys.stdout, log_path)
        sys.stdout = tee

    print("kit        = {0}".format(KIT))
    print("work dir   = {0}".format(WORK))
    print("probe home = {0}".format(HOME))
    print("profile    = {0}".format(PROFILE))
    print("config src = {0}".format(CONFIG_SRC))
    print("part       = {0}".format(PART or "(none)"))
    print("python     = {0}".format(sys.executable))
    print("dsh cli    = {0}".format(DSH_CMD or "(not found: static checks only)"))
    print("install dir= {0}".format(INSTALL_ROOT or "(not found)"))
    if log_path:
        print("log        = {0}".format(log_path))
    if args.keep_home and "install" in names:
        print("note       : --keep-home given, install group will NOT rebuild the probe home")
    if "uninstall" in names and "install" not in names:
        print("note       : uninstall without install expects an already installed probe home")

    live_path, live_before = live_fingerprint()
    print_guard(live_path, live_before)

    failed_groups = []
    for name in names:
        started = time.time()
        try:
            if not dict(GROUPS)[name]():
                failed_groups.append(name)
        except Exception as exc:  # noqa: BLE001 - one broken group must not hide the others
            record("group {0} crashed".format(name), False, repr(exc))
            failed_groups.append(name)
        print("  -- group {0} finished in {1:.1f}s".format(name, time.time() - started))

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print("\n=== ACCEPTANCE: {0}/{1} passed ===".format(passed, total))
    for name, ok, detail in results:
        if not ok:
            print("  FAILED: {0} :: {1}".format(name, detail))

    guard_ok = True
    if LIVE_PROFILE:
        live_path, live_after = live_fingerprint()
        if live_before is None or live_after is None:
            print("[GUARD] live-profile guard skipped (no profile at {0})".format(live_path))
        elif live_before == live_after:
            print("[GUARD] live profile UNCHANGED: {0} (package.json mtime+sha identical)".format(
                live_path))
        else:
            guard_ok = False
            changed = [k for k in set(live_before) | set(live_after)
                       if live_before.get(k) != live_after.get(k)]
            print("[GUARD] LIVE PROFILE CHANGED - the harness must never do this: {0}".format(changed))
    if log_path:
        print("log        = {0}".format(log_path))

    return 0 if (passed == total and guard_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
