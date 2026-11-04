---
name: vivado-workflow-discipline
description: "Vivado 工作流纪律（本 kit 自带，非 AMD 原文）：定「先读工程 → xdc_lint → 复用既有综合/实现结果 → 确实必要时才综合并轮询进度」的顺序，以及 is_error=false 仍可能是 [ERROR]、CLI 桥一进程一调用、Vivado 全局串行、cwd 与 TEMP 必须纯 ASCII、结论必须带 file:line、大 Tcl stdout 先落文件再读 tail、safe_tcl 占位符必须独占一个词、检查类工具默认无损不得静默截断、版本分档（2023.1 有本仓记录 / 2025.2+ 必须重探）、长构建必须脱离进程树并用标记行判进度、板卡不在场时的离线/dry-run 口径、报告文件与即时查询必须交叉核对等判据。当任务要打开或运行 Vivado 工程、综合、实现、时序/CDC 分析、XDC 约束检查、ILA 调试，或需要判断「工具说成功是不是真的成功」时使用。"
license: MIT
metadata:
  version: "1.2.0"
baseline:
  amd_doc: "unspecified"
  tested_on: null
  status: unverified
  evidence: "本技能是流程/判据说明，无脚本、无可执行产物，故自身无基线可测；文中标 `本仓记录` 的版本事实转述自 PITFALLS #64/#67/#72/#73/#74，本技能未复测，故整条记 unverified"
---

# Vivado 工作流纪律

> 用来换掉「上来就综合/实现」的默认反射。本技能只定**顺序、判据、证据格式**，不教 Vivado 语法（语法走 AMD 官方 6 技能与文档）。
> 机器相关值一律从 kit 的 `config.yml` 读（`part` / `project_root` / `vivado_version` / `vivado_path` / `temp_dir` / `python`），体检跑 `<kit>/doctor.ps1`。本文件**不写死**任何路径、器件或用户名。
> 标记约定：`本仓记录` = 本仓 PITFALLS / 结论里有本机实测与证据，**但本技能没有复测**（转述）；`按文档/未实测` = 只有厂商文档或第三方说法。
> **本文件没有任何一条结论是本技能亲自跑 Vivado 得到的** —— 转述可以引用，不得升格成「已验证」。

## 0. 进 Vivado 之前（30 秒自检，缺一项别开工）

- [ ] **串行**：`tasklist | grep -i vivado` 必须为空。Vivado 是**全局串行**的（GUI、综合、实现、仿真、ILA 抓取共用一台机器一个 license）；第二个进程只会给你 stale lock、假进度和「文件被占用」。
- [ ] **纯 ASCII**：当前 cwd、`TEMP`、`TMP`、工程根、MCP 安装路径全为纯 ASCII。中文路径经 Vivado Tcl 的 GBK 解码会坏，表现为「文件找不到 / IP 生成失败」这类误导性错误。
- [ ] **版本对齐**：`config.yml` 的 `vivado_version` 与磁盘一致（`<vivado_path>/vivado.bat` 存在）。不一致就改配置，不要靠猜。
- [ ] **落盘**：本轮所有输出写文件（`... > out.log 2>&1`），长构建**不要**经管道/终端缓冲捕获。

## 1. 工作流顺序（按此顺序，不许跳步）

1. **先读工程，而不是先跑工具**
   - 工程文件：`<project>.xpr`（`parse_xpr` / `get_project_info`）→ `part`、top、约束集、IP 清单；
   - 既有 run：`<proj>.runs/*/` 状态、`synth_1/runme.log`、`impl_1/runme.log`（首行自证版本，形如 `****** Vivado v2023.1 (64-bit)`）；
   - 既有报告：`*_utilization_synth.rpt`、`*_timing_summary_routed.rpt`、`*.rpx`；
   - 既有产物：`.bit`（`parse_bit_header`）、`.ltx`（`parse_ltx`）。
   - 目的：先弄清「跑到哪一步、上次成没成」。这一步通常能直接回答大半问题，且**不起 Vivado 进程**。
2. **约束先检**：`xdc_lint`（默认全量、逐条带行号）。引脚冲突、重复端口这类问题在综合前修是分钟级，综合后才发现是小时级。
3. **能复用就复用**：`get_run_progress` 显示 run 完整、且 RTL/约束/IP 未变（比对 mtime 与报告头）→ 直接用既有报告下结论，**不要重跑**。重跑前先说明「既有结果为什么不能用」。
4. **确实要跑才启动**：`run_synthesis` / `run_implementation` 传 `wait:false` 启动，随后轮询 `get_run_progress`（间隔递增），不要用长超时的同步等待。
5. **数字必须双源**：每次引用 WNS / WHS / 资源数（LUT / FF / BRAM / DSP），必须同时给**来源**与**交叉结论**——
   - 来源二选一**写明**：报告文件路径（`*_timing_summary_*.rpt` / `*_utilization_*.rpt`），或即时查询原文（`get_timing_report` / `report_*` / 一行 Tcl 命令）；
   - **两路都要真取一次**：以报告文件为准，即时查询作旁证；只报一路等于没做（口径与原因见 §9）。
   - 反例（`本仓记录`，2026-10-24 prj12）：Tcl 用 `-delay_type min_max -max_paths 1` 得 WNS=**0.004**，报告文件 Setup WNS=**+0.032** —— 单源引用会把 hold 当 setup 报出去。
6. **收尾四项一起给**：run 状态、WNS/WHS、关键 `CRITICAL WARNING` 条数、报告文件路径。只回「跑完了」等于没跑。

## 2. 判据纪律（这些「看起来成功」其实是失败）

- **`is_error=false` 不等于成功**：MCP 协议层的 `is_error` 只反映传输/协议失败；Vivado 把 `[ERROR] ...` 打进返回文本时它仍是 `false`。判据必须同时扫文本：`[ERROR]` / `ERROR:` / `CRITICAL WARNING` / `MCPError`。**见 `[ERROR]` 就是失败**，无论 `is_error` 说什么。
- **CLI 桥一进程一调用**：桥类客户端（`mcp_ctl.py` 之类）每次调用都新起一个 MCP server 进程，会话**不跨进程** —— `start_session` 返回 ready 只在当次进程有效，下一条 `run_tcl` 必报「会话不存在」。多步操作写成**单进程脚本**；桥下只做单命令与离线工具。
- **大 stdout 先落文件**：一次 `run_tcl`（如 `open_run synth_1`）可吐数千行 XDC/Unisim/CDC 日志。优先用 `report_*` / `get_run_progress`；必须跑 Tcl 时把 stdout 重定向到文件再读 tail。长构建经 PowerShell 管道捕获还会因子进程 stdout 被缓冲堵住而**假死**。
- **`safe_tcl` 占位符必须独占一个词**：`tcl_quote()` 会把每个参数包成双引号，而 Tcl 的 `"` 只在一词之始才是引号。故 `puts "X={0}"` 会双重引号 → `extra characters after close-quote`；`puts X={0}` 会拼成 `X="a b"` → `can not find channel named ...`。正确写法：`puts {0}`、`set_property PACKAGE_PIN {0} [get_ports {1}]`。**这两种报错像工具坏了，其实是模板错** —— 别去改工具。
- **检查/诊断类工具默认必须无损**：`xdc_lint`、`get_cdc_report` 之类默认全量（`max_items=0` / `max_details=0`）；聚合摘要只能作**附加**信息，不得替代明细。要省上下文由调用方显式传 `severity=` 或小上限；**不许**给检查类工具加默认截断 —— 截断会静默吞掉真正要修的那几条，而 agent 通常不会想到再补一次全量。唯一合理的默认限流是波形事件流（`query_waveform.max_events`，自身界 1000 属内存保护，且返回里明写 `result_truncated`）。
  - `xdc_lint` 的「已知良性族」分组（GT refclk / MIG DDR4 的 `MISSING_IOSTANDARD`）只是**分组**，不改默认输出量：引用结论时要连头部的 benign 计数和「阻断判定」一起抄，`show_benign` / `benign_allowlist` 是**显式**参数。良性 ≠ 无问题：把族之外的非良性条数也写出来。

## 3. 版本分档（照抄文档前先看档）

**2023.1 档 —— `本仓记录`（PITFALLS #67/#72 记的是本机实测，本技能未复测）**
- Tcl 解释器 **8.5.14**（`puts [info patchlevel]`），**不是** 8.6 —— 不要用 8.6 的扩展语法。
- `open_project -noprogress` **不存在** → `ERROR: [Common 17-170] Unknown option '-noprogress'`（这是新版手册的写法，照抄即挂）。
- ILA `C_DATA_DEPTH` 合法值最小 **1024**（512 报 `[Vivado 12-206] Invalid value '512' ... Valid values are 1024 2048 ...`）⇒ 降深度只能 2048→1024，再省只能裁 probe 或换更小核。

**2025.2+ 档 —— `按文档/未实测`**
- 上面三条**全部不可假设**：`-noprogress` 是否存在、Tcl 版本、`C_DATA_DEPTH` 合法集合、`report_*` 参数差异，都要在本机**重新探一次**再写结论。
- 探法：`puts [info patchlevel]`；`help <command>`；故意给一次非法值，读报错里的 `Valid values are ...`。
- 结论里必须写清「哪一档、在哪台机器上探的」；**不许**把 2023.1 的结论搬到 2025.2 上，也不许把没探过的写成已验证。

## 4. 工具面：直连 MCP 优先，CLI 桥兜底

- 会话里有 `mcp__vivado__*`（kit 预设提供）就直连：多步会话成立、`wait:false` 可用。
- 没有该前缀（未重启宿主 / 用标准预设）→ 走 CLI 桥，并记住「一进程一调用」。
- **命令 shell 用会话里真实存在的那个**：Windows 上通常是官方 `pwsh`（本机实测它可能后端就是 Windows PowerShell 5.1，别假设 PowerShell 7 语法），POSIX 上是 `bash`。第三方常驻 shell（`win_bash` 之类）是**可选件**：本 kit 不依赖它，别人环境里没有它是常态；它中途消失也不要重试，换官方 shell 或直接走 MCP。会话里一个 shell 都没有时不要编命令——走 `mcp__vivado__*`，或把要跑的命令写成脚本文件交给用户执行。
- **起 Vivado 不要现写命令**：用本包 `tools/vivado-probe.ps1`（探活）与 `tools/vivado-run.ps1 -Source <tcl> [-Detach]`（batch 运行）。两者按本机实测可用的 `Start-Process -FilePath <bat> -ArgumentList @(...)` 形态实现，绕开 `cmd /c "<带引号整串>"` 的二次套引号陷阱。MCP 侧的等价形态是 `run_tcl(script_path=..., background=..., log_file=...)`（**不需要 `start_session`**，但会起一个 Vivado batch 进程），查状态用 `job_id`，别把它当"已完成"。每个工具有没有离线形态，以 `docs/tools.md` 为准；**某个会话到底挂没挂 `mcp__vivado__*`，只能看该会话自己的工具清单**，不要按文档断言"已挂 N 个"。
- 仿真在 Win11 24H2+ 可能因 `NoDefaultCurrentDirectoryInExePath` 导致 `compile.bat` 找不到而全挂（`本仓记录`，PITFALLS #73；本技能未复测）：修法为 `reg add HKCU\Environment /v NoDefaultCurrentDirectoryInExePath /d 0 /f`（下次登录生效），或会话内 `set NoDefaultCurrentDirectoryInExePath=0`。

## 5. 文档检索的两条通路（先知道自己把 query 发给了谁）

1. **`amd-doc-search` 技能（CLI 桥）**：跑 `<amd-doc-search 技能目录>/doc_search.py "<query>"`，检索 AMD 官方文档（Vivado/Vitis/UG/PG/Answer Record）。
   - **query 会外发到 AMD 的 hosted 服务**（`本仓记录`：amd-doc-search 的 baseline 记 2026-10-24 实跑、服务端自报 `AMD Doc Search`；本技能未复测）。
   - ⇒ **NDA / 未公开项目不许用**：要么禁用本技能，要么改走本地知识库（工程内 `docs/`、离线 KB、厂商随包手册）。**不要**把信号名、器件序列号、内部工程路径写进 query。
2. **可选 hosted `mcp-amd-doc-search`**：工具名 `mcp__amd_doc_search__vivado_doc_search`，需要**用户自己的 AMD entitlement** + 重启宿主；是可选件，不是本包必装。
   - 加了 `family` / `version` 过滤参数**不等于**结果真被过滤（`本仓记录`，PITFALLS #64；本技能未复测）：返回块仍会混 `family: All` / `version: All` 的通用条目，引用前逐条核对字段。

## 6. 贴结论前的自检清单

- [ ] 每条结论有 `文件:行` 或「命令原文 + 输出」；没有就是没做。
- [ ] `[ERROR]` / `CRITICAL WARNING` 是**扫文本**扫出来的，不是只看 `is_error`。
- [ ] 版本档写清了（2023.1 = `本仓记录`（未复测）/ 2025.2+ = `按文档/未实测`）。
- [ ] 是否该复用既有 run 却重跑了？重跑要写明理由。
- [ ] 用过文档检索就说明 query 去了哪里；NDA 项目应当没用外发通路。
- [ ] 长构建是不是会话后台作业？必须脱离进程树，且只按标记行判进度（§7）。
- [ ] 没上板时：dry-run 产物是否只落 `.tmp`、工程/仓库零改动？负向对照三组是否真给出 **PASS/FAIL/FAIL**（§8）？
- [ ] 没上板时，措辞有没有偷换成「验证通过」（§8.4）。
- [ ] 每个 WNS/WHS/资源数是否同时给了来源（报告文件路径 or 即时查询命令）且两路交叉过（§1 步 5 / §9）？

## 7. 长构建：脱离进程树 + 标记行 + 分段

`本仓记录`（2026-10-24 实测，PITFALLS 相邻条目；本技能未复测）：

- 会话 `run_in_background` 作业**随回合中断而死**：21:02 起的 synth 在下一条用户消息后 `job_output` 报 `unknown job`，`tasklist` 里也没有 Vivado 了。
- **WMI 有两条路，行为可以相反**（2026-10-24 / 2026-10-28 本机实测）：2026-10-24 用 `Invoke-CimMethod -ClassName Win32_Process -MethodName Create` 起的进程 3/3 存活到回合之后；**2026-10-28 同一台机上该 CIM 路由对任何命令行都返回 `ReturnValue=8`**（`Get-CimInstance` 查询正常 ⇒ 是路由故障，不是引号问题）。**但老式 COM 路由 `[wmiclass]'Win32_Process'.Create($commandLine)` 仍返回 `RV=0`**，且实测其子进程能在 `KILL_ON_JOB_CLOSE` 的 Job Object 关闭后 +30 s 仍存活（`COM_RESULT=ESCAPED`）⇒ 脱离出口用 **COM 路由**（必须在 `.ps1` + `powershell -File` 里调用）。
- **Task Scheduler 不能当长构建的出口**：默认 schtasks 任务带 `IdleSettings{Duration=PT10M, StopOnIdleEnd=true}` 且无 `ExecutionTimeLimit` 覆盖；实测 34 分钟实现段用它跑到 **9m20s 被静默中止**（无 rc 文件、日志停在 `place_design Phase 3.2`、没有 `Exiting Vivado`）。只能作最后兜底，且用了要盯 `-log` 是否突然停更。
- 代价：脱离进程**没有工具返回值**，必须让构建自己写状态行，外部只读状态行。

做法（本包已给现成件）：

1. `tools/vivado-run.ps1 -Source <tcl> -Detach`：生成 `<base>.run.cmd` + `build_status.txt`，立即返回 `RUN_LAUNCHER=wmi-com|wmi-cim|schtasks` / `RUN_PID` / `RUN_STATUS`；三级链已按上面的实测排序。
2. 构建 Tcl 里 `source <kit>/templates/build-markers.tcl`，在关键节点 `kit_mark SYNTH_OK ...`、`kit_mark IMPL_OK ...`；失败路径 `kit_fail ...` 会落 `BUILD_FAILED`。
3. 轮询只看 `build_status.txt` 尾几行 + `-log` 尾；标记行缺失表示「还在跑或已死」，**不是**「成功」。
4. **能分段就分段**：synth 后 `write_checkpoint pre_impl.dcp`，实现段单独重跑。实测一次外部 `^C` 打断实现后只重跑 34 min，synth 没重做。
5. 杀进程：先 `tasklist` 定位 PID，只杀那一个；`taskkill /T` 会波及无关子进程（本会话有一次 `/T` 的波及面没核清）。
6. **PS 5.1 陷阱**：`schtasks` 的 `WARNING: Task may not run because /ST is earlier than current time` 是 stderr 输出，在 `$ErrorActionPreference='Stop'` 下会被当成 terminating error（实测第一次兜底就这么被打断）；判成败只看 `$LASTEXITCODE`。

## 8. 板卡不在场时的离线流程（无 live session / 无板）

`hw-ila-debug` / `hw-vio-debug` 的技能正文假设「有 live session、有真板」。**板卡不在场时不要照抄它们的步骤**，也不要用"脚本跑通了"代替硬件结论；改用本节三段：先划 dry-run 边界（§8.2）→ 再做可证伪的负向对照（§8.3）→ 最后按 §8.4 的措辞交付。有板时本节不适用，回到 `hw-*` 技能原文步骤。

### 8.1 分层：哪些能离线、哪些要起 Vivado、哪些必须有板

| 层 | 不在场也能做（不占 Vivado） | 要 Vivado 进程（不一定占会话） | 必须有板 |
|---|---|---|---|
| 工程/约束 | `xdc_lint`、`parse_xpr`、`get_project_info`、`compare_xci` | — | — |
| 时序/资源/日志 | `get_timing_report(report_file=...)`、`get_critical_warnings(run_name=...)`、`get_utilization_report` 的既有报告 | `get_timing_report(session_id=...)` 现场取 | — |
| 调试核心 | `parse_ltx(file_path=...)`、既有 CSV / VCD 离线解包（`query_waveform`） | — | `get_hw_ilas` / `run_hw_ila` / `commit_hw_vio` 等 Hardware Manager Tcl |
| 位流 | `parse_bit_header`、就绪性检查的离线形态（无工程 run 时见 §8.2 第 3 条） | `generate_bitstream` | `program_device` |

判据：一条调用只要需要 `hw_server` / `get_hw_*`，就在「必须有板」这一列——**不在无板会话里试**，它的失败信息会伪装成"驱动 / IP 问题"。

### 8.2 dry-run 约定（脚本 / 位流 / 抓取一律 dry-run）

1. **产物只落 `<project_root>\.tmp\dryrun-<YYYYMMDD>\`**：纯 ASCII、在仓库与工程 run 目录之外；不覆盖既有 `.bit` / `.ltx` / `.dcp`，不改工程 XDC。
2. **脚本层**：dry-run 走显式分支（`-DryRun` / `DRY_RUN=1`），把"将要执行的命令"逐条写进 `plan.txt`，只真正执行**只读**命令（`get_property` / `report_*` / 写到 `.tmp` 的 `write_*`）；写操作只打印不执行。
3. **位流层**：不 `generate_bitstream`，只做 `check_bitstream_readiness` 的离线判断。**run 不存在（checkpoint 式自定义实现）时它返回 `N/A（不适用）`——按 N/A 记录，不许改写成 BLOCK，也不许改写成 PASS**；该流程本工具不覆盖，报告里写"未检查（本工具不覆盖 checkpoint 式自定义实现）"。给了 `dcp_path` / `run_name` 就写清用的是哪一个。
4. **抓取层**：不 `program_device`、不 `run_hw_ila`；只解包**既有** `.ltx` / CSV / VCD（替代路径见 §8.5）。
5. **长脚本用脱离式形态**：`run_tcl(script_path=<.tcl>, background=true, log_file=<.tmp 下日志>)` 起独立 batch 进程，轮询 `job_id` 拿状态与日志尾部；`stdout_tail_bytes` 只裁**返回正文**（ERROR 行不丢），不裁日志文件。**"job 已提交" ≠ "任务已完成"**，判进度只认日志里的标记行（§7）。
6. **收尾自检**：跑 `git status --porcelain` + 列 `.tmp` 产物清单；仓库或工程目录有任何改动都算 dry-run 失败。

### 8.3 负向对照：判据必须能被证伪

`本仓记录`（2026-10-24）：本会话用假 pcap 做过一组三用例对照——1 组应 PASS、2 组应 FAIL，工具分别给出 PASS/FAIL/FAIL，判据才算成立。

固定成三列表写进报告（`实际` 一栏填真实输出，不填"应该"）：

| # | 输入（人造，故意踩判据） | 期望 | 实际 |
|---|---|---|---|
| N1 | 正常输入（能过） | PASS | （实测值） |
| N2 | 破坏判据 A（截断 / 缺字段 / 错 magic） | FAIL | （实测值） |
| N3 | 破坏判据 B（错时间戳 / 错长度 / 越界值） | FAIL | （实测值） |

- **「判据未触发 ≠ 通过」**：N2 / N3 也打 PASS，说明判据是假的（阈值太宽 / 根本没读那个字段 / 读了没用）。这时要改的是**判据**，不是结论。
- 三组全 PASS 时不许写"已覆盖"，只写"判据未生效，未能证明"。
- 假输入放 `.tmp` 并与真实输入分开命名（`fake_*`），避免被后续步骤当成真数据引用。

### 8.4 措辞：不宣称上板结论

| 别写（上板措辞） | 写（离线口径） |
|---|---|
| "功能正常 / 验证通过" | "未上板；脚本 dry-run 与静态检查通过" |
| "ILA 抓到 X"（无板） | "无板，未抓取；仅解析既有 `.ltx`（N 个 probe）" |
| "时序没问题" | "报告文件（路径：…）Setup WNS=+0.032 ns —— 离线读取，未上板" |
| "位流可用" | "位流已生成、头部字段一致；**未烧写**" |

一句话：**结论的强度不能超过证据的强度**。缺的是板就写"缺板"，不要写成"工具不支持"，更不要写成"没问题"。

### 8.5 有板技能的替代路径（只做离线解包）

`hw-ila-debug` / `hw-vio-debug` 里"抓"的步骤都要板，但**读配置/读既有抓取**不需要：

1. **`.ltx` 解包**：`parse_ltx(file_path=...)` 拿 core 名与 probe 名/位宽/类型；再对照既有 `capture_data.csv` 的列名，确认上次抓取的 probe 集合。这是**复用既有抓取**，不是新抓取。
2. **既有波形**：VCD 用 `query_waveform(file_path=...)` 在时间窗内查信号变化；CSV 用会话的 read / grep 直接解析。
3. **先复制再解析**：把 `.ltx` / CSV 复制到 `\.tmp\dryrun-*\` 再读，避免任何工具写回工程目录。
4. **必须"新抓一次"才能回答的问题**：标 `UNKNOWN（缺板）`，写清"需要板 + 位流 + `.ltx` 三者同时在位"，不要用仿真或脚本推断冒充抓取结论。

## 9. 报告文件 vs 即时查询：必须交叉核对

（本节是 §1 步 5 的判据来源；它管的是**每个数字**，不只时序。）

`本仓记录`（2026-10-24 实测，prj12 实现段）：

```tcl
set wns [get_property SLACK [get_timing_paths -delay_type min_max -max_paths 1 -sort_by slack]]
# 脚本自报 WNS=0.004；随后 get_timing_report(report_file=<...>impl_timing_summary_routed.rpt)
# 读到 Setup WNS=+0.032 / Hold WHS=+0.004 ⇒ 差 0.028 ns
```

- 原因：`min_max` 取的是 setup/hold 里**最差的那一条**，这里取到的是 hold 路径，不是 setup WNS。
- 正确口径：setup 用 `-delay_type max`、hold 用 `-delay_type min`；**报告一律以 timing summary 文件为准**，即时查询只作旁证。
- **资源数同规矩**：`get_utilization_report` 的即时数据必须与 `*_utilization_*.rpt`（或 `*_utilization_placed.rpt`）对一遍；两边的层级不同（synth vs placed）时要写明比的是哪一份。
- 结论里写清数字来源（报告路径 or 即时查询命令原文）；两路不一致时**先查自己的取数口径**，再怀疑工具。
- 同一轮里如果有两个来源都答了同一个数，报告里必须同时出现这两条来源，不能只留"看起来对"的那条。

> 纪律条目抽自本仓库 PITFALLS #69–#76（#64/#67/#72/#73 为相关补充）；本技能由本 kit 自研，无第三方代码。
