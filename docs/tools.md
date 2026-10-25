# 32 个 MCP 工具：清单、离线/会话依赖、以及"哪种活走哪个工具"

> 读者：已经装好 `Vivado` 预设、准备真正干活的人（也供助手在选工具前对照）。
> 工具名一律带前缀：MCP server 名是 `vivado`，所以会话里是 `mcp__vivado__<名字>`。名字与参数取自 `vivado-mcp` 0.3.26 的 `@mcp.tool` 签名（2026-10-25 用 AST 扫源码得到，共 **32** 个，与 `doctor.ps1` 第 7 项的判据一致）。
> **分类依据**：签名里有没有文件参数（`file_path` / `report_file` / `xdc_paths` / `wcfg` / `files`）与有没有 `session_id`。带文件参数的可以不连会话；只带 `session_id` 的必须先 `start_session`。这是**按签名与 docstring 判定**，除下表标 `实测` 的三项外没有逐个实调。

---

## 1. 先决策，再动手（2026-10-24 实测：7 类操作里只有 3 类适合 MCP 运行类工具）

| 你要做的事 | 首选 |
|---|---|
| 工程 run 的综合 / 实现（标准流，`synth_1` / `impl_1`） | `run_synthesis` / `run_implementation`，**`wait: false`** 提交后用 `get_run_progress` 轮询 |
| 脚本化插 ILA、指定 place directive、checkpoint 续跑、自定义实现段 | **项目 Tcl 脚本 + `tools/vivado-run.ps1 -Detach`**（MCP 的运行类工具盖不住这些） |
| 只读分析：时序报告 / runme.log / `.ltx` / `.xpr` / `.bit` / VCD | `get_timing_report(report_file=...)`、`get_critical_warnings`、`parse_ltx`、`parse_xpr`、`parse_bit_header`、`query_waveform` |
| XDC 静态检查 / 能安全自修的约束问题 | `xdc_lint`（纯 Python，不占 Vivado）、`xdc_auto_fix(dry_run=True)` |
| 跑脚本前先验 Tcl 语法 | **`tools/tcl-check.ps1`**（本包脚本，不占 MCP 工具面，也不起 Vivado） |
| 上板烧写 / ILA 抓取 | `program_device` + 板上工具链（`hw-ila-debug` / `hw-vio-debug` 技能） |
| 探活"这台机能不能起 Vivado" | **`tools/vivado-probe.ps1`**；`vivado.bat -version` **不算**探针 |

---

## 2. 纯离线（8 个：给文件就能用，不需要活会话）

| 工具 | 关键参数 | 说明（实测标注） |
|---|---|---|
| `parse_xpr` | `file_path` | 解析 `.xpr`：part / 顶层 / 文件集 / IP / run 列表 |
| `parse_bit_header` | `file_path` | 解析 `.bit` 头部（器件、时间戳、bootgen 字段） |
| `parse_ltx` | `file_path` | 解析 ILA `.ltx` 探针配置（核心、probe、位宽）**实测可用** |
| `compare_xci` | `file_a`, `file_b` | 对比两个 IP 的 `.xci` 配置差异 |
| `verilog_compile_check` | `files`, `tool` | 用 iverilog / verilator 做语法+连接性检查（需本机装其中之一） |
| `query_waveform` | `file_path` (+ 时间窗/信号/条件) | 离线发现 VCD 信号、查询有界变化 |
| `xdc_lint` | `xdc_paths`, `severity`, `max_items` | 纯 Python 静态检查，**不依赖 Vivado 综合****实测可用**；上游默认 `max_items=20`，本包补丁可改默认全量 |
| `xdc_auto_fix` | `xdc_paths`, `board`, `dry_run` | 只自修 `MISSING_IOSTANDARD` / `CLOCK_NO_PERIOD` 两类；先 `dry_run=True` 看计划 |

## 3. 半离线（3 个：给报告文件就离线，不给才要活会话）

| 工具 | 离线形态 | 会话形态 |
|---|---|---|
| `get_timing_report` | `report_file=` 指向已有 `*_timing_summary_*.rpt`（**实测可用**；本包靠它抓到过 WNS 口径 bug） | `session_id` + `output_format` 现场取 |
| `get_cdc_report` | `report_file=` 指向已有 CDC 报告 | `session_id` 现场跑 |
| `get_critical_warnings` | `run_name` 读既有 `runme.log`（"仅 runme.log"） | `session_id` + `tail_n` 现场取 |

## 4. 必须活会话（21 个：先 `start_session`，否则会报会话不存在）

| 分组 | 工具 |
|---|---|
| 会话生命周期 | `start_session`、`stop_session`、`list_sessions` |
| 任意 Tcl | `run_tcl`、`safe_tcl`（注意下面的"预算/体积"两条） |
| 标准流运行 | `run_synthesis`、`run_implementation`、`generate_bitstream`、`program_device` |
| 工程/报告读取 | `get_project_info`、`get_io_report`、`get_utilization_report`、`get_ip_status`、`get_run_progress`、`check_bitstream_readiness`、`get_next_suggestion`、`get_pre_commit_summary` |
| 诊断/校验 | `verify_io_placement_tool`、`inspect_ip_params` |
| 波形会话操作 | `set_wave_zoom`、`set_wave_analog`（改 wcfg 后要 `close -force` + `open` 重载） |

---

## 5. 用这 32 个工具前必须知道的四条

1. **`is_error: false` 不等于成功**：Vivado 的业务错误以 `[ERROR] ...` 出现在正文里，协议层仍是成功。判据看文本。
2. **`run_tcl` / `safe_tcl` 的 30 分钟预算**：MCP 行上 `toolCallTimeoutMs=1800000`。实测一次实现段 **34 min** ⇒ 单次阻塞调用必超时，超时后命令可能仍在跑。长段一律用 `wait:false` 或本包 `vivado-run.ps1 -Detach`。
3. **`run_tcl` 原样返回 stdout**：一次 `open_project` 就能约 8k tokens。省上下文的顺序是：先用 `report_*` / `get_run_progress`；必须跑 Tcl 就把 stdout 落到文件再读尾部；打了 `patches/vivado-mcp` 补丁后可以用 `max_lines` / `save_full_to`。
4. **`safe_tcl` 的占位符必须独占一个词**：`puts {0}` 对，`puts X={0}` 会双重引号 → `can not find channel named` / `extra characters after close-quote`。

## 6. 和本包脚本的分工

`tools/*.ps1` 是**会话里的 shell 侧**工具，不占这 32 个 MCP 工具名额，也不依赖 `start_session`：

| 场景 | 用谁 |
|---|---|
| 探活 / 起一份 batch Tcl / 长构建脱离 / Tcl 语法门禁 | `tools/vivado-probe.ps1`、`tools/vivado-run.ps1`、`tools/tcl-check.ps1` |
| 结构化的工程/报告/波形分析 | 上表的 MCP 工具（它们把输出解析成 JSON/摘要，比读日志省上下文） |
| 上板 / ILA 抓取 | `program_device` + 板上工具链 |

## 7. 未核实项（别当结论引用）

- 每个工具**全部参数**的默认值没有逐个核对；本文只用了参数名与 docstring。
- `get_critical_warnings` 在"只给 `run_name`、不给 `session_id`"时能否定位工程目录，未实测。
- `set_wave_zoom` / `set_wave_analog` 在无会话时能否只改文件，未实测（docstring 写的是改完要重载）。
- `xdc_auto_fix` 的 `board` 取值集合未实测，先 `dry_run=True` 看计划再落地。
