# dsh-vivado-preset

A **Vivado session preset for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh)**:
a version-aware FPGA engineering-discipline persona plus eight bundled AMD/FPGA skills, mounted as an
ordinary dsh bundle. Installable with `dsh plugin add` — **no installer, no environment variables, and
no Vivado installation are required to install the preset itself**.

> This is the **plugin-only** half of the [dsh-vivado kit](https://github.com/chemmy-11/dsh-vivado).
> The kit additionally wires the 32-tool `vivado-mcp` server, the `Vivado` tiered persona (2023.1 /
> 2025.2+), launcher scripts and a 13-check doctor — but its preset is rendered per machine by
> `install.ps1`, so the kit as a whole is not a `dsh plugin add` package. Install **either** this
> package **or** the kit, not both: both declare a preset whose displayed name is `Vivado`, and the
> kit already provides everything here.

## What it adds

| Item | Detail |
|---|---|
| Preset `Vivado` | `@deepseek-ai/dsh-agent-preset` (`order: 2`), the shipped standard plugin rows plus a Vivado/FPGA engineering persona |
| Persona | Vivado is globally serial · pure-ASCII paths · version facts must be re-probed (2023.1-measured truths called out) · evidence is `file:line` or command+output · `is_error: false` with `[ERROR]` in the text is still a failure · lossless diagnostic defaults · long builds must be detached, not session background jobs · board-absent offline discipline |
| Skills | 8 skills mounted at rank 300 `customSkillDirs`, resolved to this package's own directory at load time: `vivado-workflow-discipline` (self-authored) + `amd-doc-search` + 6 AMD ROSS skills (`hw-ila-debug`, `hw-vio-debug`, `vivado-revision-control`, `vivado-rtl-elaboration-analysis`, `vivado-rtl-lint`, `vivado-simulate-rtl`) |
| Not included | `mcp__vivado__*` tools, Vivado launchers, the per-machine render, the install/doctor scripts — see the [kit](https://github.com/chemmy-11/dsh-vivado) |

## Install

```sh
# preferred: the prebuilt tarball attached to the release (no local HTTPS git needed)
dsh plugin add https://github.com/chemmy-11/dsh-vivado/releases/download/v0.2.0/dsh-vivado-preset-0.2.0.tgz

# alternative: the GitHub subdirectory URL (pnpm resolves it over HTTPS git; a host that can
# only reach github.com over SSH fails here -- use the tarball above)
dsh plugin add https://github.com/chemmy-11/dsh-vivado/tree/main/packages/dsh-vivado-preset
```

Then **restart the host** (Electron has no hot reload) and start a new session with the `Vivado` preset.

- Requires dsh **≥ 0.2.1-rc.2** (built and tested against **0.2.1-rc.5**).
- The persona's commands are written for **Windows** (PowerShell 5.1-safe); the bundle itself is
  platform-neutral, but the discipline assumptions are Windows/Vivado.
- No configuration step: the skills mount resolves to the installed package directory through a
  `!!js` expression, so there are no paths to fill in.

## Skills: baseline and honesty

The AMD ROSS skills are MIT content written against a **Vivado 2026.1** documentation baseline; this
package ships them unmodified apart from the kit's local adaptation notes. Their `baseline` status is
`unverified` for Vivado 2023.1 except where a skill cites a local measurement. When skill text and
measured local behaviour disagree, measured local behaviour wins — and the persona says so.

## License

MIT for this package's own content (persona, generator wiring, `vivado-workflow-discipline`).
The bundled AMD ROSS skills are MIT and carry their own attribution/licence notes in
[`skills/NOTICE-skills.md`](skills/NOTICE-skills.md); see also [`NOTICE-preset.md`](NOTICE-preset.md).
