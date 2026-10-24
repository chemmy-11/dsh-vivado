---
name: vivado-workflow-discipline
description: "Vivado 工作流纪律（本 kit 自带，非 AMD 原文）：定「先读工程 → xdc_lint → 复用既有综合/实现结果 → 确实必要时才综合并轮询进度」的顺序，以及 is_error=false 仍可能是 [ERROR]、CLI 桥一进程一调用、Vivado 全局串行、cwd 与 TEMP 必须纯 ASCII、结论必须带 file:line、大 Tcl stdout 先落文件再读 tail、safe_tcl 占位符必须独占一个词、检查类工具默认无损不得静默截断、版本分档（2023.1 有本仓记录 / 2025.2+ 必须重探）等判据。当任务要打开或运行 Vivado 工程、综合、实现、时序/CDC 分析、XDC 约束检查、ILA 调试，或需要判断「工具说成功是不是真的成功」时使用。"
license: MIT
metadata:
  version: "1.0.0"
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
5. **收尾四项一起给**：run 状态、WNS/WHS、关键 `CRITICAL WARNING` 条数、报告文件路径。只回「跑完了」等于没跑。

## 2. 判据纪律（这些「看起来成功」其实是失败）

- **`is_error=false` 不等于成功**：MCP 协议层的 `is_error` 只反映传输/协议失败；Vivado 把 `[ERROR] ...` 打进返回文本时它仍是 `false`。判据必须同时扫文本：`[ERROR]` / `ERROR:` / `CRITICAL WARNING` / `MCPError`。**见 `[ERROR]` 就是失败**，无论 `is_error` 说什么。
- **CLI 桥一进程一调用**：桥类客户端（`mcp_ctl.py` 之类）每次调用都新起一个 MCP server 进程，会话**不跨进程** —— `start_session` 返回 ready 只在当次进程有效，下一条 `run_tcl` 必报「会话不存在」。多步操作写成**单进程脚本**；桥下只做单命令与离线工具。
- **大 stdout 先落文件**：一次 `run_tcl`（如 `open_run synth_1`）可吐数千行 XDC/Unisim/CDC 日志。优先用 `report_*` / `get_run_progress`；必须跑 Tcl 时把 stdout 重定向到文件再读 tail。长构建经 PowerShell 管道捕获还会因子进程 stdout 被缓冲堵住而**假死**。
- **`safe_tcl` 占位符必须独占一个词**：`tcl_quote()` 会把每个参数包成双引号，而 Tcl 的 `"` 只在一词之始才是引号。故 `puts "X={0}"` 会双重引号 → `extra characters after close-quote`；`puts X={0}` 会拼成 `X="a b"` → `can not find channel named ...`。正确写法：`puts {0}`、`set_property PACKAGE_PIN {0} [get_ports {1}]`。**这两种报错像工具坏了，其实是模板错** —— 别去改工具。
- **检查/诊断类工具默认必须无损**：`xdc_lint`、`get_cdc_report` 之类默认全量（`max_items=0` / `max_details=0`）；聚合摘要只能作**附加**信息，不得替代明细。要省上下文由调用方显式传 `severity=` 或小上限；**不许**给检查类工具加默认截断 —— 截断会静默吞掉真正要修的那几条，而 agent 通常不会想到再补一次全量。唯一合理的默认限流是波形事件流（`query_waveform.max_events`，自身界 1000 属内存保护，且返回里明写 `result_truncated`）。

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
- 命令 shell 用 `win_bash`。若 `pwsh` 报 `unknown tool`（宿主会在会话中途摘除它），改 `win_bash`、**不要重试**。
- 仿真在 Win11 24H2+ 可能因 `NoDefaultCurrentDirectoryInExePath` 导致 `compile.bat` 找不到而全挂（`本仓记录`，PITFALLS #73；本技能未复测）：修法为 `reg add HKCU\Environment /v NoDefaultCurrentDirectoryInExePath /d 0 /f`（下次登录生效），或会话内 `set NoDefaultCurrentDirectoryInExePath=0`。

## 5. 文档检索的两条通路（先知道自己把 query 发给了谁）

1. **`amd-doc-search` 技能（CLI 桥）**：跑 `<amd-doc-search 技能目录>/doc_search.py "<query>"`，检索 AMD 官方文档（Vivado/Vitis/UG/PG/Answer Record）。
   - **query 会外发到 AMD 的 hosted 服务**（`本仓记录`：amd-doc-search 的 baseline 记 2026-10-24 实跑、服务端自报 `AMD Doc Search`；本技能未复测）。
   - ⇒ **NDA / 未公开项目不许用**：要么禁用本技能，要么改走本地知识库（工程内 `docs/`、离线 KB、厂商随包手册）。**不要**把信号名、器件序列号、内部工程路径写进 query。
2. **可选 hosted `mcp-amd-doc-search`**：工具名 `mcp__amd_doc_search__vivado_doc_search`，需要**用户自己的 AMD entitlement** + 重启宿主；是可选件，不是本包必装。
   - 加了 `family` / `version` 过滤参数**不等于**结果真被过滤（`本仓记录`，PITFALLS #64；本技能未复测）：返回块仍会混 `family: All` / `version: All` 的通用条目，引用前逐条核对字段。

## 6. 贴结论前的五项自检

- [ ] 每条结论有 `文件:行` 或「命令原文 + 输出」；没有就是没做。
- [ ] `[ERROR]` / `CRITICAL WARNING` 是**扫文本**扫出来的，不是只看 `is_error`。
- [ ] 版本档写清了（2023.1 = `本仓记录`（未复测）/ 2025.2+ = `按文档/未实测`）。
- [ ] 是否该复用既有 run 却重跑了？重跑要写明理由。
- [ ] 用过文档检索就说明 query 去了哪里；NDA 项目应当没用外发通路。

> 纪律条目抽自本仓库 PITFALLS #69–#76（#64/#67/#72/#73 为相关补充）；本技能由本 kit 自研，无第三方代码。
