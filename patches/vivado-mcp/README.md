# vivado-mcp 本地补丁归档（4 个 unified diff）

> 归档日期 2026-10-24 · 维护：`ps-docs` · 作用域：本目录只放 **补丁文件**，不放第三方源码。
> 一句话：`vivado-mcp` 是**第三方**资产（Apache-2.0，版本 0.3.26），本 kit 既不是它的作者，也不做它的私有分支；
> 我们只在它上面打了 4 个改动，以 `.patch` 形式随包，便于同门复核、上游报 PR、或随时反向卸载。

---

## 1. 上游身份（可复核，不是猜的）

| 项 | 值 | 证据（文件:行 / 命令） |
|---|---|---|
| 包名 / 版本 | `vivado-mcp` **0.3.26** | `D:\vivado-mcp\site\vivado_mcp-0.3.26.dist-info\METADATA:2-3`（`Name: vivado-mcp` / `Version: 0.3.26`） |
| 许可证 | **Apache-2.0**（`License-Expression: Apache-2.0`，附 `License-File: LICENSE`） | 同文件 `:10`、`:11`；许可证正文 `vivado_mcp-0.3.26.dist-info\licenses\LICENSE`（10 774 B，Apache 2.0 全文） |
| 上游仓库 | <https://github.com/mapleleavessssss-wq/vivado-mcp> | 同文件 `Project-URL: Homepage/Repository/Issues/Changelog`（`:5-8`） |
| 作者 | `Author: NJ` | 同文件 `:9` |
| Python 要求 | **≥3.10**（`Requires-Python: >=3.10`） | 同文件 `:23` |
| 安装形态（本机） | `pip install --target D:\vivado-mcp\site`，安装器 `pip` | `vivado_mcp-0.3.26.dist-info\INSTALLER` 内容 = `pip`；`REQUESTED` 存在 |
| 安装位置红线 | 必须纯 ASCII（`D:\vivado-mcp`）；中文路径会让 `start_session` 必失败 | `D:\FPGA\PITFALLS.md:31`（坑 #21） |

> 版本号的直接探针（不用启动 MCP）：
>
> ```powershell
> py -c "import importlib.metadata as m; print(m.version('vivado-mcp'))"   # → 0.3.26（PYTHONPATH 指向 site 时）
> py D:\vivado-mcp\mcp_ctl.py list | wc -l                                 # → 32（工具数，见 §5.1）
> ```

## 2. 补丁基线是怎么证明的（关键：别拿错 `.bak`）

`D:\vivado-mcp\site` 里有三种 `.bak-mcp-*` 文件，**含义不同、只有一种能当基线**：

| 文件名 | 真实含义 | 能否当补丁基线 |
|---|---|---|
| `*.bak-mcp-20261024` | **pip 安装时的原样**（与 `RECORD` 逐字节一致） | ✅ 能 |
| `*.bak-mcp-20261024b` | 第一轮改动之后的**中间态**（`xdc_linter.py` / `diagnostic_tools.py`） | ❌ 不能（会把第一轮改动漏掉） |
| `cdc_tools.py.bak-mcp-20261024b` | 该文件只被改过一次，这个 `b` 版**恰好就是上游原样**（时间戳仍是 2026-09-27 19:57） | ✅ 能（全站没有它的 `.bak-mcp-20261024`） |
| `tcl_tools.py.bak-mcp-20261024` | 上游原样（该文件没有 `b` 版） | ✅ 能 |

**证明方法（pip 的 RECORD 自带每个已安装文件的 sha256）**：

```powershell
# 全站对账：只有 4 个文件与 RECORD 不一致 ⇒ 本目录 4 个补丁就是本机全部本地改动
py -c "import base64,hashlib,os;root=r'D:/vivado-mcp/site';mod=[];[mod.append(p.split(',')[0]) for p in open(os.path.join(root,'vivado_mcp-0.3.26.dist-info/RECORD'),encoding='utf-8') if p.split(',')[1].startswith('sha256=') and os.path.isfile(os.path.join(root,p.split(',')[0])) and base64.urlsafe_b64encode(hashlib.sha256(open(os.path.join(root,p.split(',')[0]),'rb').read()).digest()).decode().rstrip('=')!=p.split(',')[1][7:]];print(len(mod),mod)"
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

## 3. 每个补丁改了什么、为什么

### 3.1 `0001-tcl-max-lines-and-safe-tcl-hint.patch`（`tcl_tools.py`）

两件事，落在同一个文件同一轮里，但各自独立、可分别回退：

1. **`max_lines` / `save_full_to` 输出裁剪（默认 0 = 不裁剪）** —— 修 `D:\FPGA\PITFALLS.md:84`（坑 #74：`run_tcl` 原始 stdout 一次可烧 ~8k tokens）。
   - 新增纯函数 `truncate_output()`（`tcl_tools.py:65`）、`_count_key_lines()`（`:40`）、`_save_full_text()`（`:49`）与统一后处理 `_render_result()`（`:152`）。
   - `run_tcl`（`:197` 起）与 `safe_tcl`（`:350` 起）各加 `max_lines: int = 0`、`save_full_to: str = ""`；**默认不裁剪 ⇒ 默认行为逐字节不变**（`_render_result` 在 `max_lines<=0 且 save_full_to 为空` 时直接走原 `_safe_execute` 路径）。
   - 裁剪时红线段 `CRITICAL_LINE_RE = ^\s*(?:ERROR|CRITICAL WARNING|警告)`（`:34`）保证关键行即使落在窗口外也不丢（坑 #69 的延伸：裁剪不许吞错误）。
2. **`safe_tcl` 占位符陷阱提示** —— 修 `D:\FPGA\PITFALLS.md:85`（坑 #75：`tcl_quote` 把参数包成 `"..."`，模板 `puts X={0}` 会被 Tcl 拆成两个词）。
   - `_QUOTE_TRAP_MARKERS = ("close-quote", "can not find channel named")`、`_QUOTE_TRAP_HINT`（`:133`）、`_maybe_append_quote_hint()`（`:139`）：只在**执行确实失败**且命中特征时追加一行中文提示「占位符必须独占一个 Tcl 词」，不改变正常输出。

### 3.2 `0002-xdc-lint-aggregate-and-default-full.patch`（`xdc_linter.py`）

- **按规则聚合的摘要段**：新增 `_SEVERITY_ORDER`（`:328`）、`_rule_breakdown()`（`:345`，端口族归一 `c0_ddr4_dq[31] → c0_ddr4_dq`）。GT/DDR4 这类几百个引脚一次触发大量 `MISSING_IOSTANDARD` 时，先给端口族分布，避免被明细淹没（`D:\FPGA\PITFALLS.md:30` 坑 #20 的误报语境）。
- **`severity=` 过滤 + `max_items`**：`format_lint_report(report, severity="all", max_items=0)`（`:382`）；摘要段**永远全量**，过滤只影响明细。
- **默认值改为无损**：`max_items` 由 `20` → **`0`（默认全量）**，修 `D:\FPGA\PITFALLS.md:86`（坑 #76：默认截断会静默吞掉真要修的那几条；官方 273 引脚 `KU_IO.xdc` 反例）。

### 3.3 `0003-xdc-lint-tool-default-full.patch`（`diagnostic_tools.py`）

- `xdc_lint` 工具签名加 `severity: str = "all"` / `max_items: int = 0`（`:645-646`），非法 `severity` 直接 `[ERROR]` 返回；把两个参数透传给 `format_lint_report`（`:698`）。
- **默认 `max_items=0` = 全量**，同坑 #76。这是「工具层默认值」这一半；`0002` 是「格式化层默认值」那一半，两个文件都改了才算完整无损。

### 3.4 `0004-get-cdc-report-default-full.patch`（`cdc_tools.py`）

- `get_cdc_report(..., max_details: int = 0)`（`:23`）：由 `100` → **`0` = 全量**（工具自身界仍是 0..500），并在 docstring 写明理由（`:32-34`），修 `D:\FPGA\PITFALLS.md:86`（坑 #76 同族：CDC 违例同样是逐条可修的细节）。
- 现场路径仍是 `report_cdc -details -return_string`（`:53`）——**这一条在 2023.1 上尚未实测**（`结论_cross_Vivado环境DSH规范化_2026-10-24.md` §5 第 4 项把 `get_cdc_report` 列为未触达工具），见 `..\..\docs\version-matrix.md`。

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
cd D:\vivado-mcp\site
# 一次性全打（顺序无关：4 个补丁改 4 个不同文件）
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0001-tcl-max-lines-and-safe-tcl-hint.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0002-xdc-lint-aggregate-and-default-full.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0003-xdc-lint-tool-default-full.patch
git -c core.autocrlf=false apply -p1 <kit>\patches\vivado-mcp\0004-get-cdc-report-default-full.patch
```

- **必须带 `-c core.autocrlf=false`**：本机 `core.autocrlf=true` 时 `git apply` 会把补丁里的 LF 写成 CRLF，结果文件与上游其余文件行尾不一致（实测踩到：应用后 3 047 B → 3 112 B）。补丁本身全是 LF。
- 没有 git 的环境用 `patch -p1 < 0001-....patch`（POSIX `patch` 同样只认相对路径，行尾不会被转换）。**本条未在本机验证**：本机 MSYS2/Git Bash 里没有 `patch` 命令（`patch: command not found`），验收用的是 `git apply`。
- `site` 目录不是 git 仓库也能打：实测在**裸目录**（无 `.git`）里 `git -c core.autocrlf=false apply --check -p1` 4/4 通过、应用后与现文件逐字节相同（`BARE_DIR_IDENTICAL=1`）。

## 5. 怎么验证「装好了」与「补丁打上了」

### 5.1 安装存在性（版本 + 工具面）

```powershell
py D:\vivado-mcp\mcp_ctl.py list
```

- 期望：**32 行**工具、每行 `工具名<TAB>中文说明`（实测 `wc -l` = 32；首行 `check_bitstream_readiness`，末行 `xdc_lint`）。
- 少于 32：装的是别的版本或 `PYTHONPATH` 指错（`mcp_ctl.py` 走 `D:\vivado-mcp\site`）；不是补丁问题，别先怀疑补丁。
- 版本核对：`METADATA` 里 `Version: 0.3.26`；本目录补丁**只对 0.3.26 的行文成立**。

### 5.2 补丁是否就位（最可靠：反向试打）

```powershell
cd D:\vivado-mcp\site
foreach ($p in (Get-ChildItem <kit>\patches\vivado-mcp\*.patch)) {
  git -c core.autocrlf=false apply -R --check -p1 $p.FullName
  if ($LASTEXITCODE -eq 0) { "APPLIED  $($p.Name)" } else { "MISSING  $($p.Name)" }
}
```

已打过补丁的文件能**反向**干净还原 ⇒ 该补丁就位；文件被别的版本/别的改动动过则报 `patch does not apply`。
实测（在已应用 4 个补丁的树上）：4/4 `REVERSE-OK`。

### 5.3 签名行（不想碰 git 时的快速 grep，PowerShell 原生写法，已实测）

```powershell
cd D:\vivado-mcp\site
Select-String -SimpleMatch '_QUOTE_TRAP_HINT'      -Path vivado_mcp\tools\tcl_tools.py        # 0001
Select-String -SimpleMatch 'max_items: int = 0'    -Path vivado_mcp\analysis\xdc_linter.py     # 0002
Select-String -SimpleMatch 'max_items: int = 0'    -Path vivado_mcp\tools\diagnostic_tools.py  # 0003
Select-String -SimpleMatch 'max_details: int = 0'  -Path vivado_mcp\tools\cdc_tools.py         # 0004
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
- `get_cdc_report` 不传 `max_details` → `result_truncated` 不为真（≤500 条时）。
- `run_tcl` 不传 `max_lines` → 输出与上游 0.3.26 完全一致（默认路径未改）；显式 `max_lines=50` → 首行 `[截断] 原文 N 行 → 仅显示末 50 行`，且 `ERROR` / `CRITICAL WARNING` / `警告` 行出现在「关键行」小节。

## 6. 上游政策：PR 优先，不做私有分支

- **不做私有 fork**：`D:\vivado-mcp\site` 不是我们的仓库，我们**不重分发修改后的源码**，只随包给 `.patch`；本 kit 也不包含 `vivado-mcp` 本体（同门用 `pip install vivado-mcp==0.3.26` 自装）。
- **优先上游 PR**：按 Apache-2.0 §4(b)，被修改的文件必须带「已修改」提示；把改动留在我们自己的 patch 里、由使用者显式应用，比静默发一份改过的源码更符合该义务（也让上游可审）。`0001`–`0004` 每条都能独立成 PR；`docs/version-matrix.md` 与 `skills/` 里引用了坑号，PR 描述可直接抄 §3。
- 上游若接受（或自己改了同名默认值），本目录对应补丁应删除并在 `NOTICE` §2 记录「已上游化」。

## 7. 上游升级到新版本后怎么重新生成

```powershell
# 1) 新环境先装到纯 ASCII 目录并留 pristine 副本
py -m pip install --target D:\vivado-mcp\site vivado-mcp==<新版本>
cd D:\vivado-mcp\site
#    用 dist-info\RECORD 的 sha256 逐个核对哪些文件被本 kit 改过（见 §2 命令）
# 2) 新版本上重放旧补丁：能干净应用 → 直接沿用；冲突 → 按 §3 的语义重新实现
git -c core.autocrlf=false apply --check -p1 <旧补丁>
# 3) 重新生成（基线 = RECORD 原样副本，目标 = 改好后的现文件）
diff -u --label a/vivado_mcp/tools/tcl_tools.py --label b/vivado_mcp/tools/tcl_tools.py `
     vivado_mcp/tools/tcl_tools.py.bak-<新日期> vivado_mcp/tools/tcl_tools.py > 0001-....patch
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

# 应用测试（scratch 树 D:\FPGA\.tmp\kit-recon-2026-10-24\applytest\site，文件由上面 4 个 pristine 副本重建）
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
