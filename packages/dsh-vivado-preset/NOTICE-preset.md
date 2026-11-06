# NOTICE — dsh-vivado-preset

This package is part of the **dsh-vivado** kit and is distributed under the MIT licence
(`LICENSE` in this directory).

## Bundled third-party content

| Content | Licence | Origin |
|---|---|---|
| `cordis.patch.yml` — the 21 shipped DSH preset plugin rows (persona row replaced by this package's own) | **MIT**, © 2026 DeepSeek | Extracted verbatim from the DeepSeek Harness desktop app (`app.asar :: dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml`), the same shipped rows the app's own `standard` preset uses. Evidence and the full licence text: the dsh-vivado kit `NOTICE` §3.1 + appendix C. |
| `skills/hw-ila-debug`, `skills/hw-vio-debug`, `skills/vivado-revision-control`, `skills/vivado-rtl-elaboration-analysis`, `skills/vivado-rtl-lint`, `skills/vivado-simulate-rtl` | **MIT** | AMD ROSS AI assistant agent skills (`Xilinx/ross-ai-assistant` lineage, shipped in `vivado-ai-extension-2026.9.1.vsix` → `resources/plugin-bundled/skills/`), copied unmodified apart from the kit's local adaptation notes. Attribution and per-skill notes: `skills/NOTICE-skills.md`. |
| `skills/amd-doc-search` | **MIT** | Kit-authored client for AMD's hosted document-search endpoint. Query text is sent to AMD when used; not for NDA/restricted material. |

## Not bundled

`vivado-mcp` (Apache-2.0, third-party) is **not** part of this package. The full kit ships
`.patch` files against it under `patches/vivado-mcp/` and never redistributes its sources.

## Trademarks

AMD, Xilinx, Vivado, Vitis and Kintex are trademarks of Advanced Micro Devices, Inc. This package
is not affiliated with or endorsed by AMD. The names are used only to describe compatibility.
