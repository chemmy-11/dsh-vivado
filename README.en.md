# dsh-vivado — a Vivado workflow pack for DeepSeek Harness

[简体中文](README.md) | **English**

[![powered by dsh](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
![Vivado 2023.1](https://img.shields.io/badge/Vivado-2023.1%20tested-BE1E2D?style=flat-square&logo=amd&logoColor=white)
![Vivado 2025.2+](https://img.shields.io/badge/Vivado-2025.2%2B%20unverified-9e9e9e?style=flat-square)
![MCP tools](https://img.shields.io/badge/MCP%20tools-32-6E4AFF?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)

One command and one restart to give DeepSeek Harness a working Vivado environment:
a session preset that carries FPGA engineering discipline, 32 tools that actually drive Vivado,
and 8 official and first-party skills.

After installing you can talk to the assistant the way you normally would — "open `my_proj.xpr` and
show me the synthesis status and utilization", "run `xdc_lint` over the constraints", "start synthesis
but don't block on it, poll the progress". It will reuse existing reports first, and only launch a new
synthesis / implementation run when the task really needs one.

> This repository does **not** contain Vivado itself, Vivado licenses, AMD accounts or entitlements,
> or any keys. It does not accept any AMD agreement on your behalf. You need your own licensed Vivado
> installation, plus the third-party [`vivado-mcp`](https://github.com/mapleleavessssssss-wq/vivado-mcp) server.

---

## What you get

| You get | Details |
|---|---|
| A session preset named **`Vivado`** | Pick it when you create a session (the default stays `standard`). It teaches the assistant the order "read the project → `xdc_lint` → reuse existing synthesis/implementation results → only then run a build", plus rules such as "every Vivado path must be ASCII", "Vivado is globally serial", "every conclusion carries evidence" |
| **32** `mcp__vivado__*` tools | Synthesis and implementation, timing, utilization, CDC, XDC linting, ILA waveforms, session management — all through a stdio MCP server that talks to your local Vivado (provided by the third-party `vivado-mcp`) |
| **8 skills** | Six AMD official skills (RTL elaboration-log analysis, lint, simulation, revision control, ILA, VIO; MIT) and two first-party ones (AMD documentation search, Vivado workflow discipline). They are **mounted from this package — nothing is written into your `~/.dsh/skills`** |
| A health check and a clean uninstall | `doctor.ps1` runs 13 checks with PASS/WARN/FAIL and a one-line fix each; `uninstall.ps1` restores your profile and removes what it installed |

**Who this is for**: people doing Xilinx/AMD FPGA work on Windows who already use the DeepSeek Harness
desktop app and want the assistant to actually operate Vivado instead of only talking about it.

**Who this is not for**: setups that refuse a third-party MCP server, or NDA / air-gapped projects —
the documentation-search skill sends its query to AMD's hosted service (it is optional and can be left unused).

## Prerequisites

| Item | Requirement |
|---|---|
| OS | Windows 10 / 11 |
| DeepSeek Harness | **desktop app ≥ 0.2.1-rc.2** (the Electron host) |
| Vivado | installed and `vivado.bat` runnable. **2023.1 is tested**; 2025.2+ is untested (see [Version tiers](#version-tiers)) |
| Python | **≥ 3.10** (`vivado-mcp` 0.3.26 requires it) — use the interpreter that runs `vivado-mcp` |
| vivado-mcp | `pip install vivado-mcp==0.3.26` into an **ASCII-only directory**, and `import vivado_mcp` must work |
| Paths | project root, `TEMP`, `TMP` and the vivado-mcp install path must be **pure ASCII** (Vivado's Tcl layer decodes paths as GBK and breaks on anything else) |
| License | your own valid Vivado license |

## Install

```powershell
git clone https://github.com/chemmy-11/dsh-vivado.git
cd dsh-vivado
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer detects your Vivado / Python / vivado-mcp locations; you only confirm the `part`
(device part number). To see exactly what it would do without touching anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WhatIf
```

**Restart DeepSeek Harness afterwards.** The profile and bundle patches are read at host startup,
and the Electron host has no hot reload — this is a precondition, not a suggestion. Then create a new
session and switch the preset to **`Vivado`**.

> **Updating an existing install**: quit the desktop app completely, then `git pull` and re-run
> `install.ps1` (idempotent). While the host runs, the official CLI refuses to manage the desktop
> profile on purpose. See [`docs/install.md` §1.5](docs/install.md).
> Installing into another profile / `DSH_HOME`: `.\install.ps1 -Profile work -DshHome D:\dsh-home`.
> All flags (`-Config`, `-Mode cli|manual`, `-StageDir`, `-RenderOnly`, `-SkipCompatibility`, …) and the
> nine-step flow: [`docs/install.md`](docs/install.md) (Chinese).

The installer does exactly three visible things: copies itself to `<DSH_HOME>\bundles\dsh-vivado`,
renders the bundle patch there from your configuration, and registers that layer in your profile
(backing up the touched files as `*.bak-<date>` first). It does **not** modify your `cordis.patch.yml`,
does **not** write `~/.dsh/skills`, needs **no** administrator rights, and rolls back automatically
if any step fails.

## Using it

1. New session → preset **`Vivado`** (a `standard` session has no `mcp__vivado__*` tools; that is intentional).
2. Self-check in one sentence each:
   - "list every `mcp__vivado__*` tool you have" → should be **32**;
   - "list the skills you can see" → should be **8**;
   - "does your system prompt contain `Vivado is GLOBALLY SERIAL`" → should be yes.
3. Then just talk normally, for example:
   - "open `D:\work\prj\project_1.xpr` and show the synthesis status and utilization";
   - "run `xdc_lint` over `constraints_1`, full detail please";
   - "start synthesis with `wait=false`, then report progress every round".
4. Do not block on long builds: start `run_synthesis` / `run_implementation` with `wait: false` and poll
   `get_run_progress`.

## When something is wrong

Run the health check first — it names the broken item and the one-line fix:

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

The four most common cases (full list in [`docs/troubleshooting.md`](docs/troubleshooting.md), Chinese):

| Symptom | First thing to do |
|---|---|
| No `Vivado` preset after restart | Confirm you really restarted; confirm you installed into the profile you are opening (`-Profile`); then run `doctor.ps1` and read checks 9/10 |
| Preset exists but there is no `mcp__vivado__*` tool at all | Usually the `compatibility.json` version exemption is missing → re-run `install.ps1` (**without** `-SkipCompatibility`) and restart |
| `start_session` fails / Tcl reports `File not found` | Almost always a **non-ASCII path**; `doctor.ps1` check 5 names the offending config key |
| `xdc_lint` / `get_cdc_report` details are truncated | The optional `patches/vivado-mcp` patches are not applied (they are never applied automatically) — see [`patches/vivado-mcp/README.md`](patches/vivado-mcp/README.md) |

Three rules worth remembering up front: **restart after any config change**, **every Vivado path must be
ASCII**, **only one Vivado process at a time**.

## Version tiers

`vivado_version` in `config.yml` selects which set of version truths the assistant is told:

| Tier | What you get |
|---|---|
| `2023.1` (anything `< 2025.2`) | Measured facts for this tier: Tcl 8.5.14, `open_project -noprogress` does not exist, ILA `C_DATA_DEPTH` minimum is 1024, `report_*` arguments as of 2023.1 |
| `2025.2+` | **Nothing is measured**: every version-dependent fact must be probed before use, and labelled as measured when it is reported |

Evidence for each cell, the probe commands and a re-probe checklist for a new machine:
[`docs/version-matrix.md`](docs/version-matrix.md) (Chinese).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
# restart the host afterwards
```

It unbinds this layer from the profile (from the install-time backup, or an equivalent precise removal),
deletes the copy under `bundles\dsh-vivado`, and leaves your own plugin rows and skill directories alone.
For the manual, line-by-line rollback (and to keep the staged copy): [`docs/install.md`](docs/install.md).

## Repository layout

```text
dsh-vivado/
  package.json              bundle manifest (a configuration-only DSH bundle)
  install.ps1  uninstall.ps1  doctor.ps1  lib/   install, uninstall, health check
  config.example.yml        config template (the installer turns it into config.yml)
  tools/                    patch renderer, template generator, skills-manifest generator
  templates/                preset template, shipped-22-rows audit copy, persona/ tier fragments
  skills/                   8 skills + MANIFEST.json + provenance notes
  patches/vivado-mcp/       4 optional patches + the Apache-2.0 text + apply/verify notes
  docs/                     install, doctor, version matrix, architecture, troubleshooting, licensing
  NOTICE  LICENSE  README.md  README.en.md
```

> There is deliberately **no** `cordis.patch.yml` in the repository: it is rendered from your machine's
> configuration and only exists after installation.

## Documentation

| Document | Content |
|---|---|
| [`docs/install.md`](docs/install.md) | every installer/uninstaller flag, the nine-step flow, manual rollback |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | symptom → cause → fix, the 13 checks at a glance, what to attach in a report |
| [`docs/doctor-checks.md`](docs/doctor-checks.md) | the threshold behind each of the 13 checks (and why some only WARN) |
| [`docs/version-matrix.md`](docs/version-matrix.md) | Vivado version truths, measured vs unverified |
| [`docs/architecture.md`](docs/architecture.md) | how it works: bundle composition, skill mounting, rendering, install path, how to extend |
| [`docs/licensing.md`](docs/licensing.md) | upstream license audit (AMD / DeepSeek / vivado-mcp) and our obligations |
| [`NOTICE`](NOTICE) · [`LICENSE`](LICENSE) | provenance and change list; MIT grant plus third-party carve-outs |

The detailed documents under `docs/` are currently written in Chinese; the summaries above and the
installer/doctor output are English-friendly.

## License and credits

Our own code and documentation in this repository are **MIT** (© 2026 chemmy-11). Third-party content
shipped with the package keeps its own license:

- **Six AMD official skills**: MIT (© 2026 Advanced Micro Devices, Inc.), taken from Vivado AI Extension's
  `plugin-bundled/skills/`; the files we changed are listed one by one in `NOTICE` §1.3;
- **22 preset plugin rows taken from DeepSeek Harness**: MIT (© 2026 DeepSeek);
- **`vivado-mcp`**: a third-party project under Apache-2.0; this repository contains **none of its source**,
  only 4 `.patch` files (the license text ships with them).

MIT covers only the parts we wrote; the third-party terms are listed in [`NOTICE` §3.0](NOTICE) and
[`docs/licensing.md`](docs/licensing.md). This project is not affiliated with or endorsed by AMD, Xilinx
or DeepSeek; product names are used only to refer to those products.

## Feedback

Please open an [issue](https://github.com/chemmy-11/dsh-vivado/issues) and attach the output of
`doctor.ps1 -Json` (**never paste license contents, keys or tokens**).

---

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
