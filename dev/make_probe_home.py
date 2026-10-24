# -*- coding: utf-8 -*-
r"""make_probe_home.py -- build a fully isolated DSH_HOME for dsh-vivado acceptance runs.

THE SOURCE PROFILE IS ONLY EVER READ. Every byte this script writes lands inside --home, and
it refuses to run when --home would be the source profile itself (or contain it). That is the
whole point: install.ps1 / uninstall.ps1 must be exercised against a throw-away DSH_HOME, never
against the profile the maintainer actually uses.

Why a real copy instead of junctions
    `install.ps1` runs `dsh plugin add`, which rewrites node_modules. A junction to the live
    profile would write straight through into the user's real install. A full copy is ~350 MB /
    ~11k files, cheap enough to rebuild once per acceptance round.

What the probe home looks like
    <home>/profiles/<name>/
        cordis.yml, cordis.patch.yml     kept: they carry the llm route, so a real session can run
        compatibility.json               kept: the mcp-client exemption install.ps1 expects
        package.json                     kept, minus the bundle rows that belong to the kit
        pnpm-workspace.yaml, pnpm-lock.yaml
        node_modules/                    full copy; kit / previous-generation entries stripped
    <home>/bundles/                      absent - install.ps1 creates its own staging dir
    <home>/skills/                       absent - the installer must never need it

By default the copy is made to look like a machine that has NEVER installed this bundle: the
kit's dependency row, its `dsh.profile.bundles` row and its `node_modules/<pkg>` entry (which a
robocopy dereference turns into a stale plain directory) are removed, otherwise the very first
acceptance assertion - "install actually changed the profile" - would prove nothing.

Usage
    py dev/make_probe_home.py --home <work-dir>/probe-accept --name probe --force
    py dev/make_probe_home.py --profile-source <DSH_HOME>/profiles/<name> --home <dir> --name probe

    --keep-old-bundle   keep @local/dsh-vivado-preset, the previous-generation preset bundle,
                        so a "two bundles declare preset-vivado" collision can be reproduced
    --keep-kit          keep this kit's rows (debugging only; the acceptance matrix wants them gone)

Exit codes: 0 = probe home ready, 1 = refused / failed.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
KIT_ROOT = HERE.parent.parent
WORK_DEFAULT = Path(tempfile.gettempdir()) / "dsh-vivado-dev"

# Previous-generation bundle: a hand-mounted preset directory that declared the same
# `preset-vivado` row. Kept only behind --keep-old-bundle.
OLD_BUNDLE = "@local/dsh-vivado-preset"

# Files the probe profile needs; everything else in the source profile is deliberately dropped.
KEEP = ("cordis.yml", "cordis.patch.yml", "compatibility.json", "package.json",
        "pnpm-workspace.yaml", "pnpm-lock.yaml")

REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


def kit_package_name() -> str:
    """The package name this kit installs under (read from the kit, never hardcoded)."""
    manifest = KIT_ROOT / "package.json"
    try:
        return str(json.loads(manifest.read_text(encoding="utf-8")).get("name") or "dsh-vivado")
    except (OSError, ValueError):
        return "dsh-vivado"


def default_profile_source() -> Path:
    home = os.environ.get("USERPROFILE") or str(Path.home())
    return Path(home) / ".dsh" / "profiles" / "desktop"


def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _is_reparse_point(path: Path) -> bool:
    try:
        return bool(os.lstat(path).st_file_attributes & REPARSE_POINT)
    except (AttributeError, OSError):
        return False


def drop_tree(path: Path, what: str) -> None:
    """Remove a directory/link/junction WITHOUT ever traversing a reparse point."""
    if not (path.exists() or path.is_symlink()):
        return
    if path.is_symlink():
        path.unlink()
        print("[probe] removed {0} (symlink): {1}".format(what, path))
        return
    if _is_reparse_point(path):
        os.rmdir(path)  # rmdir removes the link itself; it never follows the target
        print("[probe] removed {0} (junction): {1}".format(what, path))
        return
    shutil.rmtree(path)
    print("[probe] removed {0} (directory): {1}".format(what, path))


def drop_node_modules_entry(node_modules: Path, package: str) -> None:
    entry = node_modules / package.replace("/", os.sep)
    drop_tree(entry, "node_modules/{0}".format(package))
    # A now-empty scope directory (@scope/) is noise; leave non-empty ones alone.
    parent = entry.parent
    if parent != node_modules and parent.is_dir():
        try:
            if not any(parent.iterdir()):
                parent.rmdir()
        except OSError:
            pass


def repoint_pnpm_bookkeeping(node_modules: Path, dest: Path, source_profile: Path) -> None:
    """A copied node_modules still records the SOURCE profile's virtual store path, and pnpm
    refuses to run with ERR_PNPM_UNEXPECTED_VIRTUAL_STORE. Repoint both bookkeeping files at the
    copy so `dsh plugin add` works inside the probe home."""
    old_vs = str(source_profile / "node_modules" / ".pnpm")
    new_vs = str(node_modules / ".pnpm")
    modules_yaml = node_modules / ".modules.yaml"
    if modules_yaml.is_file():
        text = modules_yaml.read_text(encoding="utf-8")
        escaped_old, escaped_new = json.dumps(old_vs)[1:-1], json.dumps(new_vs)[1:-1]
        hit = escaped_old in text
        if hit:
            text = text.replace(escaped_old, escaped_new)
        for a, b in ((old_vs, new_vs),
                     (old_vs.replace("\\", "/"), new_vs.replace("\\", "/"))):
            if a in text:
                text = text.replace(a, b)
                hit = True
        modules_yaml.write_text(text, encoding="utf-8")
        print("[probe] .modules.yaml virtualStoreDir -> {0} ({1})".format(
            new_vs, "rewritten" if hit else "pattern not found - pnpm may rebuild it"))
    workspace_state = node_modules / ".pnpm-workspace-state-v1.json"
    if workspace_state.is_file():
        try:
            data = json.loads(workspace_state.read_text(encoding="utf-8"))
        except ValueError:
            print("[probe] .pnpm-workspace-state-v1.json is not JSON; left alone")
            return
        projects = data.get("projects")
        if isinstance(projects, dict) and projects:
            data["projects"] = {str(dest): value for value in projects.values()}
            workspace_state.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            print("[probe] .pnpm-workspace-state projects -> {0}".format(dest))


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Copy a live DSH profile into an isolated DSH_HOME for acceptance runs. "
                    "The source profile is only read, never written.",
        epilog="Exit codes: 0 = probe home ready, 1 = refused or failed.",
    )
    ap.add_argument("--profile-source", default=str(default_profile_source()), metavar="DIR",
                    help="profile directory to copy FROM, read-only "
                         "(default: %%USERPROFILE%%\\.dsh\\profiles\\desktop)")
    ap.add_argument("--home", default=str(WORK_DEFAULT / "dshprobe-accept"), metavar="DIR",
                    help="DSH_HOME to build (default: <temp>\\dsh-vivado-dev\\dshprobe-accept)")
    ap.add_argument("--name", default="probe", help="profile name inside the probe home (default: probe)")
    ap.add_argument("--force", action="store_true",
                    help="rebuild an existing probe home (also drops its stale bundles/ staging dir)")
    ap.add_argument("--keep-old-bundle", action="store_true",
                    help="keep %s, the previous-generation preset bundle" % OLD_BUNDLE)
    ap.add_argument("--keep-kit", action="store_true",
                    help="keep this kit's dependency/bundle/node_modules rows in the copy "
                         "(debugging only)")
    args = ap.parse_args()

    source = Path(args.profile_source).expanduser()
    home = Path(args.home).expanduser()
    dest = home / "profiles" / args.name
    pkg_name = kit_package_name()

    # ---- safety: the source profile is read-only, and --home must not be around it ----------
    if not (source / "package.json").is_file():
        print("[ERROR] not a DSH profile (no package.json): {0}".format(source), file=sys.stderr)
        print("        pass --profile-source <DSH_HOME>/profiles/<name>; the default is "
              "%USERPROFILE%\\.dsh\\profiles\\desktop", file=sys.stderr)
        return 1
    if _inside(home, source) or _inside(source, home):
        print("[ERROR] --home and --profile-source overlap; refusing to write into the live "
              "profile:\n        source = {0}\n        home   = {1}".format(source, home),
              file=sys.stderr)
        return 1

    print("[probe] source profile (READ-ONLY) = {0}".format(source))
    print("[probe] probe home               = {0}".format(home))

    # ---- rebuild the probe home --------------------------------------------------------------
    staging = home / "bundles"
    if args.force and staging.exists():
        # A stale <home>/bundles/<kit> would let a later install reuse an old config.yml (exactly
        # how the "second -Config is ignored" installer bug first showed up in acceptance).
        print("[probe] removing stale staging {0}".format(staging))
        shutil.rmtree(staging)
    if dest.exists():
        if not args.force:
            print("[ERROR] {0} exists; pass --force to rebuild".format(dest), file=sys.stderr)
            return 1
        print("[probe] removing {0}".format(dest))
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    for name in KEEP:
        src = source / name
        if src.is_file():
            shutil.copy2(src, dest / name)
            print("[probe] copied {0}".format(name))

    # ---- strip the bundle rows so the copy looks like a virgin machine ----------------------
    pkg_path = dest / "package.json"
    pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
    deps = pkg.setdefault("dependencies", {})
    bundles = pkg.setdefault("dsh", {}).setdefault("profile", {}).setdefault("bundles", [])
    strip = []
    if not args.keep_old_bundle:
        strip.append(OLD_BUNDLE)
    if not args.keep_kit:
        strip.append(pkg_name)
    for package in strip:
        if package in deps:
            del deps[package]
            print("[probe] stripped dependency {0}".format(package))
        while package in bundles:
            bundles.remove(package)
            print("[probe] stripped bundle row {0}".format(package))
    pkg_path.write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # ---- full node_modules copy (robocopy: /E all subdirs, /R:1 /W:1 retry once, quiet) -----
    node_modules = dest / "node_modules"
    print("[probe] copying node_modules (about 350 MB, one to two minutes)...")
    robocopy = ["robocopy", str(source / "node_modules"), str(node_modules),
                "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/R:1", "/W:1"]
    print("$", " ".join(robocopy))
    try:
        rc = subprocess.call(robocopy)
    except FileNotFoundError:
        print("[ERROR] robocopy not found on PATH; this script needs Windows", file=sys.stderr)
        return 1
    if rc >= 8:
        print("[ERROR] robocopy failed with rc={0}".format(rc), file=sys.stderr)
        return 1

    for package in strip:
        drop_node_modules_entry(node_modules, package)

    repoint_pnpm_bookkeeping(node_modules, dest, source)

    print("[probe] DSH_HOME = {0}".format(home))
    print("[probe] profile  = {0}".format(dest))
    print("[probe] next     : py \"{0}\" --home \"{1}\" --profile {2}".format(
        HERE.parent / "accept_all.py", home, args.name))
    print("[probe] reclaim  : delete {0} when you are done".format(home))
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
