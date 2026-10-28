# vivado-mcp 本地补丁归档（9 个 unified diff）

> 归档日期 2026-10-24（0001–0004）· 2026-10-28 追加（0005–0009）· 维护：`ps-docs` · 作用域：本目录只放 **补丁文件**，不放第三方源码。
> 一句话：`vivado-mcp` 是**第三方**资产（Apache-2.0，版本 0.3.26），本 kit 既不是它的作者，也不做它的私有分支；
> 我们只在它上面打了 9 个改动，以 `.patch` 形式随包，便于使用者复核、上游报 PR、或随时反向卸载。
>
> **叠加顺序（重要）**：0001–0004 打在 pip 原样（`RECORD`）上；**0005–0009 的基线是"0001–0004 已应用之后"的现文件**，
> 按 **0005 → 0006 → 0007 → 0008 → 0009** 顺序应用（0008 的 `report_tools.py` 段依赖 0007 先落）。全部 9 个应用后，
> `site` 下有 **9 个文件**与 pip `RECORD` 的 sha256 不一致（§2 的对账命令实测输出），这就是本目录全部本地改动。

---

> **读法（公开版）**：文中出现的 `<project_root>` = 你在 `config.yml` 里配置的工程根；`<vivado-mcp>` = 你的 vivado-mcp 安装目录；
> `PITFALLS.md` / `AGENTS.md` 指公开的工程笔记仓库 [`chemmy-11/EIF`](https://github.com/chemmy-11/EIF) 里的坑账本与规范文件
> （本仓库不复制它们，只引用编号）。所有绝对路径都是**示例**，权威值永远来自 `config.yml` + `doctor.ps1`。

## 1. 上游身份（可复核，不是猜的）

| 项 | 值 | 证据（文件:行 / 命令） |
|---|---|---|
| 包名 / 版本 | `vivado-mcp` **0.3.26** | `<vivado-mcp>\site\vivado_mcp-0.3.26.dist-info\METADATA:2-3`（`Name: vivado-mcp` / `Version: 0.3.26`） |
| 许可证 | **Apache-2.0**（`License-Expression: Apache-2.0`，附 `License-File: LICENSE`） | 同文件 `:10`、`:11`；许可证正文 `vivado_mcp-0.3.26.dist-info\licenses\LICENSE`（10 774 B，Apache 2.0 全文） |
| 上游仓库 | <https://github.com/mapleleavessssss-wq/vivado-mcp> | 同文件 `Project-URL: Homepage/Repository/Issues/Changelog`（`:5-8`） |
| 作者 | `Author: NJ` | 同文件 `:9` |
| Python 要求 | **≥3.10**（`Requires-Python: >=3.10`） | 同文件 `:23` |
| 安装形态（本机） | `pip install --target <vivado-mcp>\site`，安装器 `pip` | `vivado_mcp-0.3.26.dist-info\INSTALLER` 内容 = `pip`；`REQUESTED` 存在 |
| 安装位置红线 | 必须纯 ASCII（`<vivado-mcp>`）；中文路径会让 `start_session` 必失败 | `PITFALLS.md:31`（坑 #21） |

> 版本号的直接探针（不用启动 MCP）：
>
> ```powershell
> py -c "import importlib.metadata as m; print(m.version('vivado-mcp'))"   # → 0.3.26（PYTHONPATH 指向 site 时）
> py <vivado-mcp>\mcp_ctl.py list | wc -l                                 # → 32（工具数，见 §5.1）
> ```

## 2. 补丁基线是怎么证明的（关键：别拿错 `.bak`）

`<vivado-mcp>\site` 里有三种 `.bak-mcp-*` 文件，**含义不同、只有一种能当基线**：

| 文件名 | 真实含义 | 能否当补丁基线 |
|---|---|---|
| `*.bak-mcp-20261024` | **pip 安装时的原样**（与 `RECORD` 逐字节一致） | ✅ 能 |
| `*.bak-mcp-20261024b` | 第一轮改动之后的**中间态**（`xdc_linter.py` / `diagnostic_tools.py`） | ❌ 不能（会把第一轮改动漏掉） |
| `cdc_tools.py.bak-mcp-20261024b` | 该文件只被改过一次，这个 `b` 版**恰好就是上游原样**（时间戳仍是 2026-09-27 19:57） | ✅ 能（全站没有它的 `.bak-mcp-20261024`） |
| `tcl_tools.py.bak-mcp-20261024` | 上游原样（该文件没有 `b` 版） | ✅ 能 |

**证明方法（pip 的 RECORD 自带每个已安装文件的 sha256）**：

```powershell
# 全站对账：只有 4 个文件与 RECORD 不一致 ⇒ 本目录 4 个补丁就是本机全部本地改动
py -c "import base64,hashlib,os;root=r'<vivado-mcp>/site';mod=[];[mod.append(p.split(',')[0]) for p in open(os.path.join(root,'vivado_mcp-0.3.26.dist-info/RECORD'),encoding='utf-8') if p.split(',')[1].startswith('sha256=') and os.path.isfile(os.path.join(root,p.split(',')[0])) and base64.urlsafe_b64encode(hashlib.sha256(open(os.path.join(root,p.split(',')[0]),'rb').read()).digest()).decode().rstrip('=')!=p.split(',')[1][7:]];print(len(mod),mod)"
# 实测输出： 4 ['vivado_mcp/analysis/xdc_linter.py', 'vivado_mcp/tools/cdc_tools.py', 'vivado_mcp/tools/diagnostic_tools.py', 'vivado_mcp/tools/tcl_tools.py']

# 四个 `.bak` 基线的 sha256 与 RECORD 相等（实测 4/4 PRISTINE-MATCH）
```

| 补丁 | 目标文件 | 基线（pristine） | 上游大小 → 现大小 | 增/删行 |
|---|---|---|---:|---:|
| `0001-tcl-max-lines-and-safe-tcl-hint.patch` | `vivado_mcp/tools/tcl_tools.py` | `.bak-mcp-20261024` | 9 086 → 18 073 B | +202 / −3 |
| `0002-xdc-lint-aggregate-and-default-full.patch` | `vivado_mcp/analysis/xdc_linter.py` | `.bak-mcp-20261024` | 14 413 → 19 176 B | +129 / −8 |
| `0003-xdc-lint-tool-default-full.patch` | `vivado_mcp/tools/diagnostic_tools.py` | `.bak-mcp-20261024` | 30 505 → 31 786 B | +21 / −2 |
| `0004-get-cdc-report-default-full.patch` | `vivado_mcp/tools/cdc_tools.py` | `.bak-mcp-20261024b`（=上游原样） | 2 711 → 3 047 B | +6 / −3 |

> 补丁头用 `a/vivado_mcp/...` / `b/vivado_mcp/...`，**相对 `site` 根**，所以 `-p1` 正好剥掉一层。

### 2.1 2026-10-28 追加的 5 个补丁（基线 = 0001–0004 应用后的现文件）

| 补丁 | 目标文件 | 基线 | 大小变化 | 增/删行 | 解决什么（实测依据） |
|---|---|---|---:|---:|---|
| `0005-run-tcl-file-background.patch` | `tools/tcl_tools.py` | `.bak-p1-20261028`（= 0001 后） | 18 073 → 66 379 B | +1154 / −7 | `run_tcl` 加 `script_path`/`background`/`log_file`/`stdout_tail_bytes`/`job_id`：把 .tcl 文件当 batch 脚本**脱离进程树**跑，绕开 30 min 调用预算（实测实现段 34 min）与会话超时后"下一条命令被拒"。启动链四级：`popen → wmi-com → wmi-cim → schtasks`，按父进程 job 的 `KILL_ON_JOB_CLOSE` 判据选路 |
| `0006-xdc-lint-benign-families.patch` | `analysis/xdc_linter.py` + `tools/diagnostic_tools.py` | `.bak-p1-20261028`（= 0002/0003 后） | 19 176 → 26 847 B；31 786 → 33 181 B | +199 / −20 | GT refclk / MIG DDR4 的 `MISSING_IOSTANDARD` 归"已知良性"并给「阻断判定」，不再让 109 条误报淹没结论 |
| `0007-readiness-na-and-dcp.patch` | `tools/report_tools.py` + `tcl_scripts.py` + `analysis/timing_evidence.py` | `.bak-p1-20261028` | 26 546 → 29 483 B；32 110 → 32 983 B；18 893 → 21 318 B | +221 / −25 | `check_bitstream_readiness` 加 `dcp_path`/`run_name`；run 不存在时返回 **N/A（不适用）** 而不是 `[ERROR]/BLOCK`（checkpoint 式流程没有 impl_1 run） |
| `0008-timing-include-paths.patch` | `tools/report_tools.py` + `analysis/timing_parser.py` | `.bak-p1-20261028`（= 0007 后） | 29 483 → 30 517 B；20 989 → 21 752 B | +53 / −8 | `get_timing_report` 加 `include_paths`/`max_paths`：7.8 MB 时序报告默认回 204 664 B / 2 172 行，`include_paths=false` 后 555 B |
| `0009-xdc-autofix-skip-benign.patch` | `analysis/xdc_auto_fixer.py` | `.bak-p1-20261028`（pip 原样） | 14 505 → 18 312 B | +87 / −6 | `xdc_auto_fix` 跳过良性条目：改前对 prj12 真写 109 行 IOSTANDARD（首行给 `gt_refclk_p` 写 LVCMOS33 —— 坑 #20 反面），改后 0 补丁 / 0 写盘 |

**四条硬约束（都在本机实测过）**：

1. **叠加顺序固定**：`0005 → 0006 → 0007 → 0008 → 0009`；每个补丁的基线都是前一个应用后的现文件（`0008` 的 `report_tools.py` 段依赖 `0007`）。
2. **工具面不变**：9 个补丁应用后 `mcp_ctl.py list` 仍是 **32** 行；新能力都是往已有 4 个工具上加参数，不新增 `@mcp.tool`。
3. **默认值向后兼容**：不传新参数时输出与 0.3.26 逐字节相同（`get_timing_report` 默认输出 sha256 与改前相同；`xdc_lint` 默认条数 109 == 109）。
4. **反打自检**：9/9 在现树上 `git -c core.autocrlf=false apply -R --check -p1` 全部 rc=0；从各自基线正打后的文件与现文件 sha256 相等（含 0005 的 `ea0a8686…`）。


## 3. 每个补丁改了什么、为什么

### 3.1 `0001-tcl-max-lines-and-safe-tcl-hint.patch`（`tcl_tools.py`）

两件事，落在同一个文件同一轮里，但各自独立、可分别回退：

1. **`max_lines` / `save_full_to` 输出裁剪（默认 0 = 不裁剪）** —— 修 `PITFALLS.md:84`（坑 #74：`run_tcl` 原始 stdout 一次可烧 ~8k tokens）。
   - 新增纯函数 `truncate_output()`（`tcl_tools.py:65`）、`_count_key_lines()`（`:40`）、`_save_full_text()`（`:49`）与统一后处理 `_render_result()`（`:152`）。
   - `run_tcl`（`:197` 起）与 `safe_tcl`（`:350` 起）各加 `max_lines: int = 0`、`save_full_to: str = ""`；**默认不裁剪 ⇒ 默认行为逐字节不变**（`_render_result` 在 `max_lines<=0 且 save_full_to 为空` 时直接走原 `_safe_execute` 路径）。
   - 裁剪时红线段 `CRITICAL_LINE_RE = ^\s*(?:ERROR|CRITICAL WARNING|警告)`（`:34`）保证关键行即使落在窗口外也不丢（坑 #69 的延伸：裁剪不许吞错误）。
2. **`safe_tcl` 占位符陷阱提示** —— 修 `PITFALLS.md:85`（坑 #75：`tcl_quote` 把参数包成 `"..."`，模板 `puts X={0}` 会被 Tcl 拆成两个词）。
   - `_QUOTE_TRAP_MARKERS = ("close-quote", "can not find channel named")`、`_QUOTE_TRAP_HINT`（`:133`）、`_maybe_append_quote_hint()`（`:139`）：只在**执行确实失败**且命中特征时追加一行中文提示「占位符必须独占一个 Tcl 词」，不改变正常输出。

### 3.2 `0002-xdc-lint-aggregate-and-default-full.patch`（`xdc_linter.py`）

- **按规则聚合的摘要段**：新增 `_SEVERITY_ORDER`（`:328`）、`_rule_breakdown()`（`:345`，端口族归一 `c0_ddr4_dq[31] → c0_ddr4_dq`）。GT/DDR4 这类几百个引脚一次触发大量 `MISSING_IOSTANDARD` 时，先给端口族分布，避免被明细淹没（`PITFALLS.md:30` 坑 #20 的误报语境）。
- **`severity=` 过滤 + `max_items`**：`format_lint_report(report, severity="all", max_items=0)`（`:382`）；摘要段**永远全量**，过滤只影响明细。
- **默认值改为无损**：`max_items` 由 `20` → **`0`（默认全量）**，修 `PITFALLS.md:86`（坑 #76：默认截断会静默吞掉真要修的那几条；官方 273 引脚 `KU_IO.xdc` 反例）。

### 3.3 `0003-xdc-lint-tool-default-full.patch`（`diagnostic_tools.py`）

- `xdc_lint` 工具签名加 `severity: str = "all"` / `max_items: int = 0`（`:645-646`），非法 `severity` 直接 `[ERROR]` 返回；把两个参数透传给 `format_lint_report`（`:698`）。
- **默认 `max_items=0` = 全量**，同坑 #76。这是「工具层默认值」这一半；`0002` 是「格式化层默认值」那一半，两个文件都改了才算完整无损。

### 3.4 `0004-get-cdc-report-default-full.patch`（`cdc_tools.py`）
- `get_cdc_report(..., max_details: int = 0)`（`:23`）：由 `100` → **`0` = 全量**（工具自身界仍是 0..500），并在 docstring 写明理由（`:32-34`），修 `PITFALLS.md:86`（坑 #76 同族：CDC 违例同样是逐条可修的细节）。
- 现场路径仍是 `report_cdc -details -return_string`（`:53`）——**这一条在 2023.1 上尚未实测**（作者本机的规范化取证记录（未随仓库发布）§5 第 4 项把 `get_cdc_report` 列为未触达工具），见 `..\..\docs\version-matrix.md`。

### 3.4a `0005`–`0009`（2026-10-28 追加；逐条目的/基线/数字见 §2.1）

这 5 个补丁只做"覆盖度"和"判据"两件事，落地位置与不变式如下（全部本机实测，证据在 `结论_cross_dsh-vivado实战问题与改进_2026-10-25` 的后续轮次记录里）：

- **`0005` `run_tcl` 三种形态**：会话内联 `command=`（默认，行为不变）、`script_path=` 脱离式 batch 作业（无会话；返回 job_id/pid/日志/状态文件/启动方式）、`job_id=` 查询（running/finished/exit_code/日志尾部；sidecar 落盘 ⇒ server 重启后仍可查）。`stdout_tail_bytes` 只裁**返回正文**（UTF-8 边界安全、ERROR 行不丢），不裁日志文件。
  - 脱离实现按 **`QueryInformationJobObject(NULL)` 的 `LimitFlags & 0x2000`（KILL_ON_JOB_CLOSE）** 判定父进程是否会被连带杀；命中则不用 `DETACHED_PROCESS`（它只在"没被 job 管"时有效），改让 WmiPrvSE 代建进程：**优先老式 COM `[wmiclass]'Win32_Process'.Create()`，其次 `Invoke-CimMethod`，最后才是 `schtasks`**。
  - **为什么不是纯 WMI/CIM**：2026-10-28 本机 `Invoke-CimMethod Win32_Process Create` 对任何命令行恒 `RV=8`（`Get-CimInstance` 查询正常 ⇒ CIM 路由故障），而同日老式 **COM** 路由 `RV=0` 且实测子进程能在 kill-on-close job 关闭后 +30 s 存活（`COM_RESULT=ESCAPED`）。
  - **为什么 schtasks 只能垫底**：默认 schtasks 任务带 `IdleSettings{Duration=PT10M, StopOnIdleEnd=true}`、无 `ExecutionTimeLimit` 覆盖，实测 34 分钟实现段用它跑到 **9m20s 被静默中止**（无 rc、日志停在 `place_design Phase 3.2`、无 `Exiting Vivado`）。
  - **为什么不能只靠 DETACHED_PROCESS**：MCP 官方 Python SDK 的 `stdio_client` 给 server 建 `KILL_ON_JOB_CLOSE` 的 job，server 退出会连带杀光 job 树（实测客户端退出后 **1.8 s** 构建即死、日志连 banner 都没有）。
- **`0006` 良性族**：只对 `MISSING_IOSTANDARD` 生效；`LintIssue` 加 `benign`/`benign_reason`，头部给 `(N warnings: M known-benign)` 与「阻断判定」，明细给 `[known-benign]`；`benign_allowlist` 可加自定义族。**条数不吞**（默认 109 == 109）。
- **`0007` 就绪性 N/A**：`CHECK_PRE_BITSTREAM` 对不存在的 run 早退 `RUN_NOT_FOUND`（**不用 `return`**：`session.execute` 走 `catch {uplevel #0}`，顶层 `return` 会变 rc=2 被当错误）；`dcp_path` 只给文件事实（存在/字节数/修改时间）+ 边界声明，**绝不 `open_checkpoint`**（会把 8–34 分钟塞进这个工具）。
- **`0008` 时序摘要**：`format_timing_report(report, include_paths=True, max_paths=0)`；`include_paths=False` → 555 B（默认 204 664 B），JSON 模式同规矩（无 `paths`/`paths_truncated` 键）。
- **`0009` 自修复跳过良性**：`plan_fixes()` 在规则分派**前**判 `benign` → skip + 原因；非良性行为零回归（`{led[0]}` 真缺仍出 1 条补丁）。`_is_benign` 用 `getattr` 兜底，单独应用 0009（无 0006 的字段）也不抛。

## 3.5 许可合规（Apache-2.0，第一次用请读这 20 行）

`vivado-mcp` 是 **Apache-2.0**（`vivado_mcp-0.3.26.dist-info/METADATA` 的 `License-Expression: Apache-2.0`）。
本目录随包提供**许可证全文** `LICENSE-APACHE-2.0.txt`（10 774 B，取自
`vivado_mcp-0.3.26.dist-info/licenses/LICENSE`，sha256 `77b29df2…459e9c`）。

| Apache-2.0 条款 | 我们怎么履行 |
|---|---|
| §4(a) 给接收者一份许可证 | 就是同目录这份 `LICENSE-APACHE-2.0.txt`；`NOTICE` §2.1 也指向它 |
| §4(b) 被修改的文件要带「已修改」显著提示 | 本 kit 只发补丁、不发源码；**打了补丁的人**才是被改文件的产生者。建议在改过的 4 个文件头部加一行（任选，二选一即可）：<br>`# Modified by dsh-vivado patches (patches/vivado-mcp/0001..0004); see NOTICE §2.1.`<br>或保留本目录的 `README.md` 与之一起分发 |
| §4(c) 保留版权/专利/商标/归属声明 | 补丁是 `-u` 上下文差分，原文件的版权头与文件头都保留在上下文里，未做剥离 |
| §4(d) 若上游有 NOTICE 则转发 | 2026-10-24 核对上游仓库根目录：**没有** `NOTICE`/`NOTICE.md`（只有 `LICENSE`），故无内容需转发 |
| §6 无商标授权 | 本 kit 不使用上游商标/logo；`AMD`/`Xilinx`/`Vivado` 等仅为指称（见 `NOTICE` §3.2） |
| 不做私有分支 | 见 §6：优先上游 PR；上游合并或自行修掉后，本 kit 删除对应补丁并登记「已上游化」 |

> 一句话：**补丁本身是我们写的，但它改的是别人的代码**，所以许可证全文必须跟着补丁走；上面两条最容易漏（§4(b) 的修改标记、删除补丁后的登记）。

---

## 4. 怎么应用（在 `site` 目录下，`-p1`）

```powershell
# <kit> = 你解压 dsh-vivado 的目录（本机是 D:\dsh-vivado）
cd <vivado-mcp>\site
# 第一组（pip 原样基线，4 个不同文件，顺序无关）
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0001-tcl-max-lines-and-safe-tcl-hint.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0002-xdc-lint-aggregate-and-default-full.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0003-xdc-lint-tool-default-full.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0004-get-cdc-report-default-full.patch
# 第二组（基线 = 第一组应用后的现文件；必须按编号顺序）
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0005-run-tcl-file-background.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0006-xdc-lint-benign-families.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0007-readiness-na-and-dcp.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0008-timing-include-paths.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0009-xdc-autofix-skip-benign.patch
```

- **必须带 `-c core.autocrlf=false`**：本机 `core.autocrlf=true` 时 `git apply` 会把补丁里的 LF 写成 CRLF，结果文件与上游其余文件行尾不一致（实测踩到：应用后 3 047 B → 3 112 B）。补丁本身全是 LF（9/9 实测 `CRLF=0`）。
- **第二组不能乱序**：`0008` 的 `report_tools.py` 段基线是 `0007` 应用后的现文件；`0005` 又改了 `0001` 的上下文（先 `0001` 后 `0005` 才成立）。
- 没有 git 的环境用 `patch -p1 < 0001-....patch`（POSIX `patch` 同样只认相对路径，行尾不会被转换）。**本条未在本机验证**：本机 MSYS2/Git Bash 里没有 `patch` 命令（`patch: command not found`），验收用的是 `git apply`。
- `site` 目录不是 git 仓库也能打：实测在**裸目录**（无 `.git`）里 `git -c core.autocrlf=false apply --check -p1` 4/4 通过、应用后与现文件逐字节相同（`BARE_DIR_IDENTICAL=1`）；0005–0009 同样在裸 scratch 树上验证（从各自 `.bak-p1-20261028` 起 → 应用后 sha256 与现文件相等）。

## 5. 怎么验证「装好了」与「补丁打上了」

### 5.1 安装存在性（版本 + 工具面）

```powershell
py <vivado-mcp>\mcp_ctl.py list
```

- 期望：**32 行**工具、每行 `工具名<TAB>中文说明`（实测 `wc -l` = 32；首行 `check_bitstream_readiness`，末行 `xdc_lint`）。
- 少于 32：装的是别的版本或 `PYTHONPATH` 指错（`mcp_ctl.py` 走 `<vivado-mcp>\site`）；不是补丁问题，别先怀疑补丁。
- 版本核对：`METADATA` 里 `Version: 0.3.26`；本目录补丁**只对 0.3.26 的行文成立**。

### 5.2 补丁是否就位（最可靠：反向试打）

```powershell
cd <vivado-mcp>\site
foreach ($p in (Get-ChildItem <kit>\patches\vivado-mcp\*.patch)) {
  git -c core.autocrlf=false apply -R --check -p1 $p.FullName
  if ($LASTEXITCODE -eq 0) { "APPLIED  $($p.Name)" } else { "MISSING  $($p.Name)" }
}
```

已打过补丁的文件能**反向**干净还原 ⇒ 该补丁就位；文件被别的版本/别的改动动过则报 `patch does not apply`。
实测：**0001–0004 在 2026-10-24 的树上 4/4 REVERSE-OK；0005–0009 在 2026-10-28 的树上 9/9 REVERSE-OK**（含 0005；注意 0005 改了 0001 的上下文 —— 想验 0001 要先 reverse 0005，否则报 `does not apply` 属正常）。
另：0005–0009 的**正打**自检口径是「从各自 `.bak-p1-20261028` 基线起、按 0005→0009 顺序应用后与现文件 sha256 相等」，不是只 `--check`。

### 5.3 签名行（不想碰 git 时的快速 grep，PowerShell 原生写法，已实测）

```powershell
cd <vivado-mcp>\site
Select-String -SimpleMatch '_QUOTE_TRAP_HINT'      -Path vivado_mcp\tools\tcl_tools.py        # 0001
Select-String -SimpleMatch 'max_items: int = 0'    -Path vivado_mcp\analysis\xdc_linter.py     # 0002
Select-String -SimpleMatch 'max_items: int = 0'    -Path vivado_mcp\tools\diagnostic_tools.py  # 0003
Select-String -SimpleMatch 'max_details: int = 0'  -Path vivado_mcp\tools\cdc_tools.py         # 0004
Select-String -SimpleMatch '_launch_job'           -Path vivado_mcp\tools\tcl_tools.py        # 0005
Select-String -SimpleMatch '_BENIGN_FAMILIES'      -Path vivado_mcp\analysis\xdc_linter.py     # 0006
Select-String -SimpleMatch 'RUN_NOT_FOUND'         -Path vivado_mcp\tcl_scripts.py             # 0007
Select-String -SimpleMatch 'include_paths'         -Path vivado_mcp\analysis\timing_parser.py  # 0008
Select-String -SimpleMatch '_is_benign'           -Path vivado_mcp\analysis\xdc_auto_fixer.py  # 0009
```

实测输出（2026-10-24，本机现装）：

| 补丁 | 命中 |
|---|---|
| 0001 | `tcl_tools.py:133: _QUOTE_TRAP_HINT = (` |
| 0002 | `xdc_linter.py:385: max_items: int = 0,` |
| 0003 | `diagnostic_tools.py:646: max_items: int = 0,` |
| 0004 | `cdc_tools.py:23: report_file: str = "", max_details: int = 0,` |

无命中 = 该补丁没打（或打到了别的版本上）。

### 5.4 行为判据（补丁真正的目的）

- `xdc_lint` **默认全量**：对一份超过 20 条发现的 XDC 直接调用（不传 `max_items`）→ 明细条数 = 全量，且表头「按规则聚合（全量）」段与明细一致；25 引脚样例应给 25 条而不是 20 条。
- `get_cdc_report` 不传 `max_details` → `result_truncated` 不为真（≤500 条时）。（0004 的现场路径 `report_cdc -details` 在 2023.1 上仍未实测，见 §3.4。）
- `xdc_lint` **良性族**（0006）：prj12 顶层 XDC（GT refclk T6/T5 + DDR4 107 脚）→ 表头 `WARN (109 warnings: 109 known-benign)`、`阻断判定: 不阻断`；自建只含 `{led[0]}` 真缺的小 XDC → `阻断判定: 阻断（1 条非良性）`。**良性 ≠ 无问题**，条数必须一条不少。
- `xdc_auto_fix` **跳过良性**（0009）：同一 prj12 XDC `dry_run=True` → `补丁 0 条 / 跳过 109 条`（改前 109/0，且 `dry_run=False` 会真写 109 行含 `gt_refclk_p` 的 IOSTANDARD）；`{led[0]}` 仍出 1 条补丁。
- `check_bitstream_readiness` **N/A**（0007）：prj12（checkpoint 式构建，`impl_1` 从未跑）→ 首行 `=== 烧板前检查: N/A (不适用) ===`，正文写明"本工具只覆盖工程 run 式流程"并给 3 条替代路径；`impl_run=impl_1` 仍走原 BLOCK 路径（回归逐字节不变）。
- `get_timing_report`（0008）：prj12 的 7.8 MB 报告 → 默认 204 664 B/2 172 行（与改前 sha256 相同）；`include_paths=False` → 555 B/12 行且 WNS=+0.032/WHS=+0.004 不变；`max_paths=5` → 5 条 + "还有 535 条未显示"。
- `run_tcl`（0005）：不传新参数 → 输出与 0.3.26 一致；`max_lines=50` → 首行 `[截断] 原文 N 行 → 仅显示末 50 行`，且 `ERROR` / `CRITICAL WARNING` / `警告` 行出现在「关键行」小节；`stdout_tail_bytes=2000` → 只留末尾 2 000 字节且 ERROR 行不丢。`script_path=` + `background=false` → 等待并回报 `退出码 0`（实测短脚本 9.2 s）；`background=true` → 立即返回 job_id，`job_id=` 查询 running→finished（实测 2 分钟作业 +142 s 完成、exit 0）。

## 6. 上游政策：PR 优先，不做私有分支

- **不做私有 fork**：`<vivado-mcp>\site` 不是我们的仓库，我们**不重分发修改后的源码**，只随包给 `.patch`；本 kit 也不包含 `vivado-mcp` 本体（用 `pip install vivado-mcp==0.3.26` 自装）。
- **优先上游 PR**：按 Apache-2.0 §4(b)，被修改的文件必须带「已修改」提示；把改动留在我们自己的 patch 里、由使用者显式应用，比静默发一份改过的源码更符合该义务（也让上游可审）。`0001`–`0009` 每条都能独立成 PR；`docs/version-matrix.md` 与 `skills/` 里引用了坑号，PR 描述可直接抄 §3 / §3.4a。
- 上游若接受（或自己改了同名默认值），本目录对应补丁应删除并在 `NOTICE` §2 记录「已上游化」。

## 7. 上游升级到新版本后怎么重新生成

```powershell
# 1) 新环境先装到纯 ASCII 目录并留 pristine 副本
py -m pip install --target <vivado-mcp>\site vivado-mcp==<新版本>
cd <vivado-mcp>\site
#    用 dist-info\RECORD 的 sha256 逐个核对哪些文件被本 kit 改过（见 §2 命令）
# 2) 新版本上重放旧补丁：能干净应用 → 直接沿用；冲突 → 按 §3 的语义重新实现
#    注意两组基线不同：0001–0004 对 pip 原样；0005–0009 对"0001–0004 已应用"的副本
git -c core.autocrlf=false apply --check -p1 <旧补丁>
# 3) 重新生成（基线 = 上一组应用后的副本，目标 = 改好后的现文件）
diff -u --label a/vivado_mcp/tools/tcl_tools.py --label b/vivado_mcp/tools/tcl_tools.py `
     vivado_mcp/tools/tcl_tools.py.bak-<新日期> vivado_mcp/tools/tcl_tools.py > 0005-....patch
```

补丁内容只依赖 0.3.26 的行文（上下文 3 行），上游一旦改到同一段就会 `does not apply` —— 这是**故意的**：宁可拒绝，也不要打歪。

## 8. 已知边界 / 风险

1. **`get_cdc_report` 的现场路径（`report_cdc -details`）在 2023.1 上未实测**，本补丁只改了默认值，没有验证命令本身（`结论_…_2026-10-24.md` §5 第 4 项）。
2. `max_lines` / `save_full_to` 改变的是返回值，不改 Vivado 侧行为；`save_full_to` 写盘编码固定 UTF-8，路径由调用方负责（建议 ASCII）。
3. 上游 `METADATA` 声明 Python ≥3.10；低于此版本 `import vivado_mcp` 直接失败，与本目录补丁无关。
4. 本目录不提供「一键打补丁」脚本：应用动作必须由使用者显式执行（Apache-2.0 §4(b) 的「已修改」可见性）。

## 9. 本次归档的原始验证输出（2026-10-24，`ps-docs`）

```text
# 基线（4/4 与 pip RECORD 的 sha256 相等）
PRISTINE-MATCH vivado_mcp/analysis/xdc_linter.py.bak-mcp-20261024
PRISTINE-MATCH vivado_mcp/tools/diagnostic_tools.py.bak-mcp-20261024
PRISTINE-MATCH vivado_mcp/tools/tcl_tools.py.bak-mcp-20261024
PRISTINE-MATCH vivado_mcp/tools/cdc_tools.py.bak-mcp-20261024b

# 应用测试（scratch 树 <project_root>\.tmp\kit-recon-2026-10-24\applytest\site，文件由上面 4 个 pristine 副本重建）
0001-tcl-max-lines-and-safe-tcl-hint.patch           APPLIES CLEANLY
0002-xdc-lint-aggregate-and-default-full.patch       APPLIES CLEANLY
0003-xdc-lint-tool-default-full.patch                APPLIES CLEANLY
0004-get-cdc-report-default-full.patch               APPLIES CLEANLY
IDENTICAL  vivado_mcp/analysis/xdc_linter.py
IDENTICAL  vivado_mcp/tools/diagnostic_tools.py
IDENTICAL  vivado_mcp/tools/tcl_tools.py
IDENTICAL  vivado_mcp/tools/cdc_tools.py
RESULT_ALL_IDENTICAL=1

# 安装存在性
$ py mcp_ctl.py list | wc -l
32

# 裸目录（无 .git）应用测试：4/4 --check 通过，应用后与现文件逐字节相同
BARE_DIR_IDENTICAL=1

# 补丁就位判据（Select-String，实测输出）
tcl_tools.py:133: _QUOTE_TRAP_HINT = (
xdc_linter.py:385: max_items: int = 0,
diagnostic_tools.py:646: max_items: int = 0,
cdc_tools.py:23: report_file: str = "", max_details: int = 0,

# 反向试打（已应用 ⇒ 能干净还原）
0001-tcl-max-lines-and-safe-tcl-hint.patch           REVERSE-OK(=已应用)
0002-xdc-lint-aggregate-and-default-full.patch       REVERSE-OK(=已应用)
0003-xdc-lint-tool-default-full.patch                REVERSE-OK(=已应用)
0004-get-cdc-report-default-full.patch               REVERSE-OK(=已应用)
```

### 9.1 2026-10-28 追加批次的验证输出

```text
# 全站对账（RECORD 口径）：4 → 9 个文件与 pip 原样不一致
9
  vivado_mcp/analysis/timing_evidence.py      (0007)
  vivado_mcp/analysis/timing_parser.py        (0008)
  vivado_mcp/analysis/xdc_auto_fixer.py       (0009)
  vivado_mcp/analysis/xdc_linter.py           (0002 + 0006)
  vivado_mcp/tcl_scripts.py                   (0007)
  vivado_mcp/tools/cdc_tools.py               (0004)
  vivado_mcp/tools/diagnostic_tools.py        (0003 + 0006)
  vivado_mcp/tools/report_tools.py            (0007 + 0008)
  vivado_mcp/tools/tcl_tools.py               (0001 + 0005)

# 反向试打：9/9 REVERSE-OK（含 0005；0001 需先 reverse 0005 才能单独反打，属正常）
# 正打：从 .bak-p1-20261028 起 0005→0009 顺序应用，与现文件 sha256 相等
#   0005: 18 073 B → 66 379 B, +1154/−7, sha256 7371191d...
# 工具面：mcp_ctl.py list = 32；run_tcl input_schema 10 个参数（ctx 由框架注入）
#
# 行为（真机，全部实测）
#   xdc_lint(prj12 xdc)         : 109 warnings / 109 known-benign / 阻断判定: 不阻断
#   xdc_lint(neg_control.xdc)   : 2 warnings / 1 known-benign / 阻断判定: 阻断（1 条非良性）
#   xdc_auto_fix(prj12, dry_run): 补丁 109→0, 跳过 0→109（改前真写 109 行 IOSTANDARD，首行 gt_refclk_p）
#   get_timing_report(默认)      : 204 664 B / 2 172 行（与改前 sha256 相同）
#   get_timing_report(no paths)  : 555 B / 12 行，WNS +0.032 / WHS +0.004
#   check_bitstream_readiness    : prj12 默认 → N/A（不适用）；run 存在 → BLOCK 逐字节不变
#   run_tcl(script_path, bg)     : 返回 2.75 s；server 退出后 +60 s Vivado 仍存活；
#                                  job_id 查询 RUNNING → +142 s finished / exit 0 / SLOW_DONE
#   run_tcl(script_path, wait)   : 9.2 s / exit 0 / TCL_OK 8.5.14（无 start_session）
#   34 min 真实现段（prj12 pre_impl_debug.dcp，产物落 .tmp）:
#     job tcljob-20261028-180508-f7b470 / launcher=wmi-com / 启动返回 0.6 s
#     A 的 server 退出后 +20/+40 s 存活；每 2 min 用全新 server 查，跨 11/20.9/31 min 未死
#     +1861 s finished / exit 0；build 18:05:16 → 18:35:24 = 30m08s > 30 min 预算
#     log 227 243 B；IMPL_GATE WNS=0.032 WHS=0.004
#     对照：同一脚本用 schtasks 启动时 9m20s 被静默杀掉（IdleSettings PT10M）
#     证据：D:\FPGA\.tmp\dsh-vivado-20261028\p1-1-real\timeline.json
```
