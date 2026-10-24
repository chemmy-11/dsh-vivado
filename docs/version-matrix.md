# 版本真值分档表（T4） — Vivado `2023.1` vs `2025.2+`

> 归属：`dsh-vivado` · 作者：`ps-docs` · 2026-10-24
> 目的：把「Vivado 版本相关的真值」从 persona/技能里抽出来、按档标注，**不让使用者把 2026.1 文档当 2023.1 事实用**。
> 配套：`README.md`（安装）、`NOTICE`（来源/许可）、`templates/persona/2023.1.frag.yml` / `2025.2plus.frag.yml`（片段）、`patches/vivado-mcp/README.md`（MCP 补丁）。

> **读法（公开版）**：文中出现的 `<project_root>` = 你在 `config.yml` 里配置的工程根；`<vivado-mcp>` = 你的 vivado-mcp 安装目录；
> `PITFALLS.md` / `AGENTS.md` 指公开的工程笔记仓库 [`chemmy-11/EIF`](https://github.com/chemmy-11/EIF) 里的坑账本与规范文件
> （本仓库不复制它们，只引用编号）。所有绝对路径都是**示例**，权威值永远来自 `config.yml` + `doctor.ps1`。

## 0. 本表怎么读（标记约定，先看这一节）

| 标记 | 含义 | 要求 |
|---|---|---|
| **实测** | 在**本机**真跑过并留下可复核证据 | 必须写「命令/观察原文 + 证据位置（`file:line`）」，并注明机器档位 |
| **文档/未实测** | 只有官方文档、技能自述或他人记录，**本机没量过** | 必须写「待实测」，不得据此下结论；引用时要说明是文档基线 |
| **历史记录（不算实测）** | 本机在**过去**某档真跑过（该 Vivado 已卸载，不可复现） | 只作旁证，不改写成本档实测 |

> 本仓库口径（`<project_root>\AGENTS.md` §二「两轴采信规则」、作者本机的规范化取证记录（未随仓库发布）§0）：
> 官方文档与官方技能的基线是 **2026.1**，而**本机现装的是 2023.1** —— 两者冲突时以**本机实测**为准，并明确说出「这是实测，不是文档保证」。

## 1. 档位选择规则（kit 侧唯一规则）

`config.yml` 的 `vivado_version` 决定渲染哪一份 persona 片段：

| `vivado_version` 的值 | 档位 id | 渲染用的片段 |
|---|---|---|
| `< 2025.2`（如 `2023.1`、`2023.2`、`2024.1`） | `2023.1` | `templates/persona/2023.1.frag.yml` |
| `>= 2025.2` | `2025.2plus` | `templates/persona/2025.2plus.frag.yml` |

- 实现：`D:\dsh-vivado\tools\render_patch.ps1:76-87`（`[version]` 解析后与 `2025.2` 比较；片段不存在直接 `throw`）。
- 契约：`D:\dsh-vivado\KIT-SPEC.md:79`（`vivado_version` → tier）。
- **注意档位名不是精确版本**：`2023.1` 档覆盖 `2023.x/2024.x`，而本档的实测事实**只在 2023.1 上量过**。渲染后的 persona 第 2 条已写明这一点：若渲染出的 `vivado_version` 不是 2023.1，**先重探**再引用本表。

## 2. 真值矩阵

### 2.1 Tcl 解释器版本

| 档 | 值 | 标记与证据 |
|---|---|---|
| `2023.1` | **Tcl 8.5.14** | **实测**·本机 Windows 10/11 + Vivado 2023.1：`puts [info patchlevel]` → `8.5.14`（`PITFALLS.md:82`，坑 #72）。**不得假设 8.6 的扩展语法** |
| `2025.2+` | **未知** | **文档/未实测**。不假设 8.5，也不假设 8.6；上机第一件事就是 `puts [info patchlevel]` |

### 2.2 `open_project -noprogress` 是否存在

| 档 | 值 | 标记与证据 |
|---|---|---|
| `2023.1` | **不存在** | **实测**·本机 2023.1：`open_project -noprogress <xpr>` → `ERROR: [Common 17-170] Unknown option '-noprogress'`（`PITFALLS.md:82`）。新版手册里的写法**照抄即挂** |
| `2025.2+` | **未知（本档未实测）** | **文档/未实测**。已知的只有：**2026.1 基线的新版手册里写了该 flag**（这正是坑 #72 的来源），但「2025.2 本身是否已有」**没有实测**。上机探一次：`open_project -noprogress <xpr>`，看是正常打开还是 `[Common 17-170]`；**结果写进本节才算数** |

### 2.3 `report_*` 参数差异

| 档 | 值 | 标记与证据 |
|---|---|---|
| `2023.1` | 下列写法**实测可用**：`report_utilization -file <path>`（另有 `-pb <path>`，见综合 run 自动生成）、`report_timing_summary -file <path>`；`report_cdc -details -return_string` **在 2023.1 上未实测** | **实测**（前两条）·本机 2023.1：EIF 仓库 `docs/操作文档/阶段三_prj10_第一级内存插入集成执行单_2026-10-04.md:200`（`report_utilization -file $P/report_util_synth.rpt`）、同文件 `:209`（`report_timing_summary -file $P/report_timing.rpt`）；自动产物见 `prj/project_1/project_1.runs/synth_1/runme.log:351`（`report_utilization -file design_1_wrapper_utilization_synth.rpt -pb design_1_wrapper_utilization_synth.pb`）。<br>**文档/未实测**（`report_cdc`）：`vivado-mcp` 0.3.26 现场路径会执行 `report_cdc -details -return_string`（`<vivado-mcp>\site\vivado_mcp\tools\cdc_tools.py:53`），但该工具在本机**从未被触发**（作者本机的规范化取证记录（未随仓库发布）§5 第 4 项的未触达工具清单含 `get_cdc_report`） |
| `2025.2+` | **参数集按版本变，逐条待实测** | **文档/未实测**。**不要从任何手册/技能里抄 flag**；上机用 `report_<name> -help`（如 `report_timing_summary -help`）看该版本支持的参数，或 `info commands report_*` 列出该版本有哪些 `report_` 命令 |

> 经验规则（与档无关）：`report_*` 的**输出文件参数**在 2023.1 上是 `-file`；`-return_string` 也存在（vivado-mcp 的 `cdc_tools.py:53` 用法）。凡是「新手册里见过、本机没跑过」的参数，一律先 `-help`。

### 2.4 ILA `C_DATA_DEPTH` 最小合法值

| 档 | 值 | 标记与证据 |
|---|---|---|
| `2023.1` | **1024**（512 非法） | **实测**·本机 2023.1（prj11 R2 round3b）：`create_debug_core` 后设 `C_DATA_DEPTH=512` → `[Vivado 12-206] Invalid value '512' for 'C_DATA_DEPTH'. Valid values are 1024 2048 ...`，4 次重试全败；改 1024 即过（`PITFALLS.md:77`，坑 #67）。⇒ 降 ILA 面积只能 `2048 → 1024`，**不能再低**；再省只能裁 probe 或换更小核 |
| `2025.2+` | **未知** | **文档/未实测**。2023.1 的 1024 下限**不可外推**；上机探：开一个含 debug core 的设计，`set_property C_DATA_DEPTH 512 [get_debug_cores <name>]`，看是否仍报 `[Vivado 12-206]` 并在错误里读到该版本的合法值列表 |

### 2.5 part / 器件族

| 档 | 值 | 标记与证据 |
|---|---|---|
| `2023.1` | 板上器件 **`xcku060-ffva1156-2-i`** = **Kintex UltraScale XCKU060**（FFVA1156、速度 -2、工业级；**非 CIV 变体**、非 UltraScale+）；2023.1 器件库含它，综合/实现/上板均跑通 | **实测**·本机：工程文件 `<Option Name="Part" Val="xcku060-ffva1156-2-i"/>`（`<project_root>\prj\project_1\project_1.xpr:11`）；版本横幅 `****** Vivado v2023.1 (64-bit)` + `SW Build 3865809 ... 2023`（`prj/project_1/project_1.runs/synth_1/runme.log:7-8`）；板卡族与「非 CIV」结论见 `docs/里程碑_prj1_M1进度总结_2026-08-11.md:10`；`xcku060_CIV-ffva1156-2-i` 是**教学视频里的错 part**，用它会烧录失败（同文件 `:37`、`:42`） |
| `2025.2+` | **文档/未实测**：UltraScale 器件族在新版应仍在支持列表，但**本机没量过** | **文档/未实测**。上机探：`get_parts -filter {PART =~ "xcku060*"}`（或 `get_parts xcku060-ffva1156-2-i`，返回空即本档器件库不含）；同时核对 `.xpr` 的 `Part` 行与位流头部 part 字段 |

### 2.6 同族其它版本相关口径（顺带记下，避免重复踩）

| 事实 | 档 | 值 / 标记 |
|---|---|---|
| ILA 基本触发要 `CONTROL.TRIGGER_MODE BASIC_ONLY` + `CONTROL.TRIGGER_CONDITION AND`；`wait_on_hw_ila -timeout` 单位是**分钟**；`write_hw_ila_data -csv_file` 用**基名**（不带 `.csv`） | `2023.1` | **实测**（`PITFALLS.md:76`，坑 #66） |
| `C_USE_BSCAN` 语义（MDM v3.2）：`0=INTERNAL, 2=EXTERNAL, 3=NONE`；`1` 非法（`valid: 0,2`） | **历史记录（2026.1，不算实测）** | `docs/阶段一_prj1_Vivado2026.1交接_2026-08-09.md:113-119`。**2023.1 上是另有语义还是同名不同义未验证** —— 改 MDM 前先看本机 `component.xml` |
| `BITSTREAM.GENERAL.COMPRESS` 属性路径 | **历史记录（2026.1，不算实测）**：2026.1 在 project/run/design 上都找不到该属性（API 改了）；2023.1 老语法 `set_property BITSTREAM.GENERAL.COMPRESS true [current_project]` | `docs/阶段一_prj1_Vivado2026.1交接_2026-08-09.md:107-108`。2023.1 一行是 **实测**（同文件 `:108` 记录写法，交接时已用） |
| QSPI `Add Configuration Memory Device` 有无 `Auto Detect` 按钮 | **历史记录（2026.1 无，2023.1 有）** | `docs/阶段一_prj1_Vivado2026.1交接_2026-08-09.md:103`、`:177` |
| 工程 `.xpr` 跨大版本兼容 | **历史记录**：2023.1 **打不开** 2026.1 的 `.xpr` | `docs/阶段一_prj1_Vivado2026.1交接_2026-08-09.md:174` |
| JTAG 编程失败提示文本 | **历史记录**：2023.1 = `DONE PIN is not HIGH`；2026.1 = `End of startup status: LOW`（同根因：part 选错） | `docs/里程碑_prj1_M1进度总结_2026-08-11.md:37` |
| Python / stdout 编码：Windows 控制台 GBK 打印 `✓` 会崩 → 必须 `PYTHONUTF8=1` | 与 Vivado 版本无关 | **实测**（`PITFALLS.md:22`，坑 #12） |

## 3. `2025.2+` 档为什么几乎全是「未实测」

1. **本机没装 2025.2+**：现装只有 `D:\Xilinx\Vivado\2023.1\`（`bin\vivado.bat` 存在；该文件时间戳 2023-05-08，即 2023.1 安装包构建期）；工具链（Vitis 等）同为 2023.1。
2. 本机**曾经装过 2026.1**（2026-08-09 前后），但已卸载换 2023.1（`docs/阶段一_prj1_Vivado2026.1交接_2026-08-09.md:3`：环境 2026.1，「已决定卸载,换 2023.1」）。那时的结论只能作**历史记录**（§2.6 末几行），**不能当 2025.2 档的实测**，也不能当 2023.1 的实测。
3. 官方 AMD 技能/文档的基线是 **2026.1**（`<project_root>\docs\参考_cross_AI工具链_AMD官方skill与知识库_2026-10-18.md:70`：「官方基线 2026.1，版本差异必须说明」；同一文件 `:72` 禁止把 2026.1 行为直接当本工程结论）。本 kit 随包的 6 件 AMD 技能因此一律标 `baseline.status = unverified`（`skills/NOTICE-skills.md:77`）。
4. 所以 `2025.2plus` 片段（`templates/persona/2025.2plus.frag.yml`）只写「**重探，别假设**」，不写任何「该版本的行为」。

## 4. 新机器怎么重新探（checklist，照抄即可）

> 前置纪律：Vivado **全局串行** —— 探之前 `tasklist | grep -i vivado` 必须为空；cwd / TEMP / TMP 必须纯 ASCII（`PITFALLS.md:31`、`:72`）。下面每条都是**只读**探测，不综合、不烧板。

### 4.1 一次性脚本（Tcl，`-mode batch` 跑，输出落文件再读）

把下面存成 `probe_vivado.tcl`（ASCII 路径），用 **batch 模式**跑：`vivado -mode batch -notrace -source probe_vivado.tcl -log probe.log -journal probe.jou`。

```tcl
# ---- 1) Tcl 解释器版本（2023.1 实测应为 8.5.14）----
puts "PROBE tcl_patchlevel = [info patchlevel]"

# ---- 2) Vivado 版本（同 runme.log 横幅格式）----
puts "PROBE vivado_version = [version -short]"

# ---- 3) 该版本有哪些 report_ 命令 ----
puts "PROBE report_cmds = [lsort [info commands report_*]]"

# ---- 4) 器件库是否含本板 part（空 = 不含）----
if {[catch {set p [get_parts xcku060-ffva1156-2-i]} e]} {
    puts "PROBE part_lookup = ERROR: $e"
} else {
    puts "PROBE part_lookup = '$p'"
}
```

再各跑一条「help 型」探测（不同版本参数集不同，只信本版本输出）：

```tcl
report_timing_summary -help
report_utilization -help
report_cdc -help
```

### 4.2 `open_project -noprogress` 探针（最容易被文档带偏的一条）

```tcl
# 2023.1 实测：ERROR: [Common 17-170] Unknown option '-noprogress'
# 新版预期：正常打开且不刷进度；两种都记下来，别只记「能用/不能用」
if {[catch {open_project -noprogress D:/probe/probe.xpr} e]} {
    puts "PROBE noprogress = ERROR: $e"
} else {
    puts "PROBE noprogress = OK"
    close_project
}
```

判读：报 `[Common 17-170]` ⇒ 该档**没有**这个 flag（2023.1 就是这种）；正常返回 ⇒ 有。**不要**用「手册里写着」代替这一步。

### 4.3 ILA `C_DATA_DEPTH` 下限探针（需要一个已综合、含 debug 核的设计）

```tcl
# 在 open_run synth_1 之后（或 open_checkpoint 后）：
create_debug_core u_probe ila
# 故意给非法/边界值，让工具自己报出该版本的合法集合
if {[catch {set_property C_DATA_DEPTH 512 [get_debug_cores u_probe]} e]} {
    puts "PROBE c_data_depth_512 = ERROR: $e"   ;# 2023.1 实测：Valid values are 1024 2048 ...
} else {
    puts "PROBE c_data_depth_512 = ACCEPTED"
}
set_property C_DATA_DEPTH 1024 [get_debug_cores u_probe]
```

### 4.4 `vivado -version` 与安装版本一致性

```powershell
# 1) 直接问可执行文件（最轻；本轮未跑 Vivado 进程，故命令本身的输出标「待实测」）
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -version
# 2) 看真实批处理日志的版本横幅（已实测的证据形态）
Select-String -Path '<project_root>\prj\project_1\project_1.runs\synth_1\runme.log' -Pattern 'Vivado v20' | Select-Object -First 1
#   实测输出：****** Vivado v2023.1 (64-bit)   （runme.log:7）
```

判读：`-version` 的第一行应与安装目录名、`runme.log` 横幅三方一致；不一致时以 **`-version` 实测**为准，并同步改 `config.yml` 的 `vivado_version` / `vivado_path`（`doctor.ps1` 检查 #1/#2 就是抓这个）。

### 4.5 探完把结果落到哪里

1. `config.yml`：`vivado_version` / `vivado_path` / `part` 改成本机实测值；
2. 本文件：在 §2 对应格子里把「文档/未实测」改成「实测·本机 <版本>：<命令> → <原文>（证据）」，**没测过的不要改**；
3. 若升到 `>= 2025.2`：重跑 `tools\render_patch.ps1`（档位会自动切到 `2025.2plus`），并重跑 `doctor.ps1`。

## 5. 明确「我们没测」的清单（别替我们补脑）

| 未测项 | 原因 | 一旦测了要改哪里 |
|---|---|---|
| `2025.2+` 全部格（Tcl 版本 / `-noprogress` / `report_*` 参数 / `C_DATA_DEPTH` / 器件族） | 本机只有 2023.1 | 本文件 §2 全部 `2025.2+` 行 |
| `report_cdc -details -return_string` 在 2023.1 的实际行为 | 该 MCP 工具从未触发 | §2.3；`patches/vivado-mcp/README.md` §8 |
| 本 kit 的 4 个 MCP 补丁在**别人的**安装上重放 | 只在 scratch 树验证（pristine 副本→apply→逐字节相同） | `patches/vivado-mcp/README.md` §5 |
| `xdc_lint` 默认全量的**端到端**行为（25 引脚给 25 条） | 需安装后跑真会话 | 验收时补；§2.3 `report_*` 无关 |
| AMD 6 技能在 2023.1 的适用性（除 `vivado-rtl-elaboration-analysis`） | 无真实报告/无硬件链路 | `skills/MANIFEST.json`（生成器禁手写）+ `skills/NOTICE-skills.md` §3 |

## 6. 证据索引（一行一条，便于复核）

| 事实 | 位置 |
|---|---|
| 坑 #72：Tcl 8.5.14 + 无 `-noprogress`（2023.1 实测） | `PITFALLS.md:82` |
| 坑 #67：`C_DATA_DEPTH` 最小 1024、512 报 `[Vivado 12-206]` | `PITFALLS.md:77` |
| 坑 #66：ILA 触发/`wait_on_hw_ila` 分钟/`-csv_file` 基名 | `PITFALLS.md:76` |
| 坑 #74/#75/#76：大 stdout / safe_tcl 占位符 / 默认无损（2023.1 实测） | `PITFALLS.md:84`、`:85`、`:86` |
| 坑 #69/#70：`is_error=false` 但文本 `[ERROR]`；CLI 桥一进程一调用 | `PITFALLS.md:79`、`:80` |
| 坑 #12：GBK 控制台 + `PYTHONUTF8=1` | `PITFALLS.md:22` |
| Vivado 2023.1 版本横幅（实测） | `<project_root>\prj\project_1\project_1.runs\synth_1\runme.log:7-8` |
| 本板 part 与器件族（实测） | `<project_root>\prj\project_1\project_1.xpr:11`；`<project_root>\docs\里程碑_prj1_M1进度总结_2026-08-11.md:10` |
| 2023.1 `report_utilization -file` / `report_timing_summary -file`（实测） | `<project_root>\docs\操作文档\阶段三_prj10_第一级内存插入集成执行单_2026-10-04.md:200`、`:209`；`prj/project_1/project_1.runs/synth_1/runme.log:351` |
| 2026.1 历史记录（不算实测） | `<project_root>\docs\阶段一_prj1_Vivado2026.1交接_2026-08-09.md:3`、`:13`、`:96`、`:103`、`:107-108`、`:113-119`、`:174`、`:177`；`docs/里程碑_prj1_M1进度总结_2026-08-11.md:37`、`:42` |
| 官方文档基线 2026.1（本仓库规则） | `<project_root>\docs\参考_cross_AI工具链_AMD官方skill与知识库_2026-10-18.md:70`、`:72` |
| 档位规则实现 | `D:\dsh-vivado\tools\render_patch.ps1:76-87`；`KIT-SPEC.md:79` |
| MCP 侧 `report_cdc` 现场调用（代码证据，未实测行为） | `<vivado-mcp>\site\vivado_mcp\tools\cdc_tools.py:53` |
| 结论文档：`get_cdc_report` 属未触达工具 | 作者本机的规范化取证记录（未随仓库发布）§5 第 4 项 |
