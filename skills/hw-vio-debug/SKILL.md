---
name: hw-vio-debug
description: "Interact with VIO debug cores via vivado-mcp or chipscope-mcp. Read input probes, drive output probes, monitor activity, and reset outputs. vivado-mcp supports all device families. chipscope-mcp supports Versal only. Use when user asks to \"read VIO inputs\", \"drive VIO output\", \"assert <signal> via VIO\", \"check signal activity\", \"what is the value of <signal>\", or \"monitor <probe>\". 本工作区注（2026-10-24 修订）：vivado-mcp 按 kit 预设挂为 mcp__vivado__*（工具数一律以**该会话自己的工具清单**为准，不要按文档断言；改了预设要重启宿主才生效）；当前会话若工具清单里没有 mcp__vivado__ 前缀，则走 <vivado-mcp>/mcp_ctl.py CLI 桥或 Vivado batch Tcl（详见文首本机适配注记）。"
license: MIT
compatibility: Requires Vivado 2026.1+, hardware with a VIO core, and access to either vivado-mcp or chipscope-mcp.
metadata:
  version: "1.2.3"
  stage: beta
baseline:
  amd_doc: "2026.1"
  tested_on: null
  status: unverified
  evidence: "SKILL.md:5 compatibility 声明 Requires Vivado 2026.1+；无 2023.1 实测记录（作者本机的 vivado-mcp 核查记录（未随仓库发布） 1.6 节覆盖度表未含 VIO 硬件链路，需真板+VIO core）"
artifacts:
  - REPORT.md
  - vio_snapshot.json
---

> **本机适配注记（非 AMD 原文；2026-10-18 由 DSH 会话追加）**
>
> - 工具链不同：本机用**第三方 vivado-mcp**（现役安装 `<vivado-mcp>`，32 个工具；仓库内 `<EIF 仓库>\vivado-mcp` 是零改动随仓副本、**不是运行实例**），不是官方 `vivado-mcp-server`。
> - 工具映射：`vivadoExecute`/`vivado_execute`→`run_tcl`/`safe_tcl`；`vivado_start`→`start_session`；`vivado_stop`→`stop_session`；`vivado_list_sessions`→`list_sessions`；`vivado_status`→`get_run_progress`；`vivado_log_messages`→`get_critical_warnings`（仅 runme.log）或 `read`/`grep`；`read_file`→`read`；`create_file`→`write`；`replace_string_in_file`→`edit`；`file_search`→`glob`；`grep_search`→`grep`；`run_in_terminal`→`pwsh`；`runSubagent`→`subagent`。
> - 会话没挂 MCP 工具时走 CLI 桥：`python <vivado-mcp>\mcp_ctl.py session "<多行 Tcl>"`（等价 run_tcl）、`call <tool> --args-file <json>`、`list`。**一次调用一个 MCP 进程**，多步会话必须写成单次 `session`。
> - 版本事实：Vivado **2023.1**（官方基线 2026.1）；Python 用 `<python 解释器：见 config.yml 的 python（install.ps1 写入实际值）>`。
> - 文档检索：本机无 `vivado_doc_search`，改用 `web_fetch`（docs.amd.com / 官方 docs）或本项目 `<project_root>\docs`。
> - 硬约束：MCP 安装路径必须纯 ASCII（中文路径经 Vivado Tcl GBK 解码会坏）；客户端必须**显式**设 `PYTHONPATH=<vivado-mcp>\site`，否则 venv 的 `_mcp_pilot_paths.pth` 会命中 `.mcp-pilot` 中文路径副本，导致 `start_session` 静默失败；Vivado 会话与综合/实现/仿真全局串行。
> - **板卡不在场时**：本技能正文假设「有 live session + 真板」。无板时**不要**照下面的方法步骤硬跑，改走 `vivado-workflow-discipline` 技能 §8（dry-run 只落 `.tmp`、复用既有 `.ltx` / CSV 只做离线解包、按离线口径措辞）；本文件的官方方法步骤不因此改动。

<!--
Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
SPDX-License-Identifier: MIT
-->
# VIO Debug (EA)

> **Early Access** — this skill may change before general availability.

Interacts with VIO debug cores on live hardware: discover → read inputs → drive outputs → monitor activity.

See [REFERENCE.md](REFERENCE.md) for VIO property tables and Tcl command reference.

**Routing:** Try Vivado MCP (`vivado_execute` + Hardware Manager Tcl, below) first if a Vivado MCP session is available — it works across all device families. Fall back to chipscope-mcp (`chipscope_vio`) if Vivado MCP is not installed. See [Chipscope-mcp Fallback](#chipscope-mcp-fallback) below.

## Tools Used

**Primary path — Vivado MCP** (plus the agent's own file tools):

| Tool | Purpose |
|------|---------|
| `vivado_execute` | Run all Tcl commands (`get_hw_vios`, `commit_hw_vio`, etc.). Every Tcl block MUST be run via `vivado_execute(session_id=..., command=<tcl>)`. |
| `vivado_doc_search` | Look up unfamiliar VIO properties. No `session_id` needed. |
| `vivado_status` | Check Vivado session health. |
| `vivado_list_sessions` | Find an active session to use (get its `session_id`). |
| Agent file tools | Write output files (vio_snapshot.json, REPORT.md). |

**Fallback path — chipscope-mcp** (when Vivado MCP is unavailable): `chipscope_session`, `chipscope_device`, `chipscope_scan`, `chipscope_vio`. See [Chipscope-mcp Fallback](#chipscope-mcp-fallback).

**No terminal commands, no Python.** Everything goes through Vivado MCP or, as fallback, chipscope-mcp.

---

## Session Setup: Vivado Version Must Match hw_server

- `vivado_list_sessions` → check for an active session.
- Before reusing one, run `version -short` and compare to the target `hw_server`'s version.
- Mismatch → `ERROR: [Labtools 27-3366] Cannot support older hw_server version`.
- **On mismatch: do not retry or restart automatically.** `vivado_start` does not pick a
  matching Vivado version for you — an omitted `vivado_path` just resolves from `PATH`,
  which is often the same mismatched install. Report the exact error, the session's
  version, and the target `hw_server`'s version to the user, and ask them to point at
  the correct Vivado install (`vivado_path`) or the correct `hw_server`.
- This only applies to an **already-running, independently-started** `hw_server`. A
  `hw_server` that Vivado auto-starts itself when connecting to a locally attached board
  is launched from that same Vivado install, so it cannot be version-mismatched — see
  "No hw_server" below.
- Only reuse a session once its version matches.

---

## Efficiency Guidelines

- **Pass `session_id`** to every `vivado_execute` call — get it from `vivado_list_sessions` if unknown.
- **Verify session version against `hw_server` before reuse, and report a mismatch to the user rather than retrying** — see [Session Setup](#session-setup-vivado-version-must-match-hw_server) above.
- **Batch Tcl** — discover all VIO cores in one `vivado_execute`, not separate calls.
- **Write reports to file** — do not dump full probe data in chat. Give a short summary only.
- **Use `vivado_doc_search`** for unfamiliar probe properties.
- **Do NOT** use `shell` commands or Vivado Tcl file I/O. Use agent file tools.
- **Do NOT** retry failed Tcl with different syntax. Search docs first, then report the error.

---

## Monitor & Control Workflow

### Step 1: Discover VIO Cores & Probes

```tcl
puts "=== VIO CORES ==="
foreach vio [get_hw_vios] {
  puts "VIO:$vio INSTANCE:[get_property INSTANCE_NAME $vio] REFRESH:[get_property CORE_REFRESH_RATE_MS $vio]"
  puts "  === INPUT PROBES ==="
  foreach p [get_hw_probes -of_objects $vio -filter {TYPE == vio_input}] {
    refresh_hw_vio $vio
    puts "  IN:$p VALUE:[get_property INPUT_VALUE $p] ACTIVITY:[get_property ACTIVITY_VALUE $p]"
  }
  puts "  === OUTPUT PROBES ==="
  foreach p [get_hw_probes -of_objects $vio -filter {TYPE == vio_output}] {
    puts "  OUT:$p VALUE:[get_property OUTPUT_VALUE $p]"
  }
}
```

**No VIO found** → STOP. Guide: "No VIO cores detected. Ensure the device was programmed with a bitstream containing VIO cores and the correct .ltx probes file is associated."

**⚠️ After programming or reprogramming,** VIO output probe software values may retain stale values from the previous session. Always sync before driving outputs:
```tcl
refresh_hw_vio -update_output_values [get_hw_vios hw_vio_1]
```
or reset all outputs to design-time initial values:
```tcl
reset_hw_vio_outputs [get_hw_vios hw_vio_1]
```
This ensures the software state matches hardware, so that subsequent `set_property OUTPUT_VALUE` + `commit_hw_vio` creates proper signal transitions (e.g., 0→1 edges for pulse-triggered designs).

### Step 2: Read Input Values

```tcl
refresh_hw_vio [get_hw_vios hw_vio_1]
foreach p [get_hw_probes -of_objects [get_hw_vios hw_vio_1] -filter {TYPE == vio_input}] {
  puts "$p INPUT:[get_property INPUT_VALUE $p] ACTIVITY:[get_property ACTIVITY_VALUE $p]"
}
```

### Step 3: Drive Output Values

Map user's NL request to probe + value:

```tcl
set_property OUTPUT_VALUE 1 [get_hw_probes <probe_name> -of_objects [get_hw_vios hw_vio_1]]
commit_hw_vio [get_hw_vios hw_vio_1]
```

**Reset all outputs** to initial values:
```tcl
reset_hw_vio_outputs [get_hw_vios hw_vio_1]
```

**Clear activity detectors:**
```tcl
reset_hw_vio_activity [get_hw_vios hw_vio_1]
```

### Step 4: Write Output Files

**⚠️ Write ALL files before giving any summary.** Use agent file tools.

Write every file below under `vivado_agentic_ai_reports/hw-vio-debug/`. The
file tool creates missing parent directories, so do not shell out to `mkdir`
(this skill forbids terminal commands).

| File | Format | Content |
|------|--------|---------|
| `vio_snapshot.json` | JSON | All probe names, directions, current values, activity |
| `REPORT.md` | Markdown | VIO core status, probe values table, actions taken |

---

## Design-Specific Rules

**All outputs MUST use ACTUAL values.**

| Rule | Wrong | Correct |
|------|-------|---------|
| VIO output | "asserted reset" | "Set OUTPUT_VALUE=1 on rst_n (hw_vio_1), committed" |
| Core info | "found VIO" | "hw_vio_1: 4 input probes, 2 output probes, refresh 500ms" |

---

## Error Handling

| Error | Symptom | Action |
|-------|---------|--------|
| No VIO cores | `get_hw_vios` empty | Check: bitstream has debug cores? .ltx file associated? |
| No hw_server | `get_hw_servers` empty | Guide: `connect_hw_server -url localhost:3121` |
| VIO out-of-sync | Status shows "Outputs out-of-sync" | Run: `refresh_hw_vio -update_output_values [get_hw_vios]` |

---

## Examples

**"What is the VIO reset signal?"** → Discover VIO → `refresh_hw_vio` → read `INPUT_VALUE` of reset probe → report value + activity.

**"Assert reset for 1 cycle"** → `set_property OUTPUT_VALUE 1` on reset probe → `commit_hw_vio` → `set_property OUTPUT_VALUE 0` → `commit_hw_vio`.

---

## Chipscope-mcp Fallback

Use this path only when Vivado MCP is not installed. Session lifecycle per VIVADO-PATTERNS.md Pattern 19 (vivado-skill-creator):

```
chipscope_session(action="connect", hw_server_url="TCP:<host>:3121", cs_server_url="TCP:<host>:3042")
chipscope_device(action="select", device_selector="0")
chipscope_scan(action="scan", ltx_path="<path-to-design>.ltx")
```

**VIO — read inputs, drive outputs:**
```
chipscope_vio(action="read", vio_name="<vio-name>")
chipscope_vio(action="write", vio_name="<vio-name>", probe_values={"<probe>": 1})
```

Exact action/parameter names must be confirmed against the live chipscope-mcp tool schema before use — do not assume the names above are final without checking `chipscope-mcp/src/chipscope_mcp/tools/chipscope_vio.py`.

**NEVER auto-program PDI.** Stop and ask before `chipscope_device(action="program")`.

---

## Integration

**Complementary:** Drives stimulus for `hw-ila-debug` capture (combined debug session)

---

## Metadata

**Keywords:** VIO, probe, input, output, activity, monitor, drive, reset
