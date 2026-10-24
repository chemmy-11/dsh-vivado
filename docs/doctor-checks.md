# doctor 检查项判据与修法（`docs\doctor-checks.md`）

> 对应实现：`doctor.ps1` + `lib\doctor-helpers.ps1`
> 读者：拿到本 kit 的同门 / 维护者 / 以后想加检查项的自己。
> 本文只写**判据与证据**；"本机实测"一律标出机器与日期（2026-10-24，Windows，Vivado 2023.1，python 3.14.6，vivado-mcp 0.3.26），不当成官方保证。

---

## 0. 用法、输出契约与退出码

```powershell
# 日常体检（config.yml 存在时优先用它，否则用 config.example.yml）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\dsh-vivado\doctor.ps1

# 装了探针家目录时（不碰在用的 desktop profile）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -DshHome <tmp>\dshprobe-home -Profile probe -NonInteractive

# 机器可读（单行 JSON 数组，PS 5.1 才能 `| ConvertFrom-Json`）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Json

# 只做静态检查（<10 s；跳过 Vivado 启动、python import、mcp_ctl 三个慢探针）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Quick
```

参数：`-Config <file>` / `-Profile <name>`（默认 `desktop`）/ `-DshHome <dir>`（默认 `$env:DSH_HOME`，否则 `%USERPROFILE%\.dsh`）/ `-InstallDir <DSH 安装根>` / `-Json` / `-Quick` / `-NonInteractive`（与 install.ps1 对齐，doctor 本身从不提问）。

人读输出格式（每行一条）：

```
[PASS] <id> <title> - <detail>
[WARN] <id> <title> - <detail>
       fix: <一句话可执行修法>
[FAIL] <id> <title> - <detail>
       fix: <一句话可执行修法>
```

* **退出码**：无 FAIL → `0`；任一 FAIL → `1`（CI 可据此拦截）。WARN **不**改变退出码。
* **`-Json`**：stdout **只有一行** JSON（`ConvertTo-Json -Compress`），数组元素恒为
  `{id,title,status,detail,fix}` 五个字段（PASS 的 `fix` 为空串）。诊断信息走 stderr，不污染 stdout。
  单行是刻意为之：PS 5.1 把子进程输出**按行**管道化，多行 JSON 会让 `doctor.ps1 -Json | ConvertFrom-Json` 逐行解析而报错。
* **编码**：所有 `*.ps1` 只含 ASCII（PS 5.1 按 ANSI 读脚本，非 ASCII 字面量会乱码）；中文说明只在本 `.md` 里。
* **只读**：doctor 不写 profile、不写 Vivado、不写 `D:\vivado-mcp`、不需要管理员权限；唯一的外部动作是启动子进程。

**超时纪律**：所有外部命令都走 `Invoke-DoctorNative`（`System.Diagnostics.Process` + `WaitForExit(ms)`），超时后 `taskkill /T /F` 杀掉**整棵进程树**（`vivado.bat` 只是 `cmd` 外壳，里面还有 `loader.bat` → `vivado.exe`）。所以 doctor 不可能挂死。

---

## 1. `vivado-install` — Vivado 安装存在

| 项 | 内容 |
|---|---|
| 测什么 | `<vivado_path>\vivado.bat` 存在且是文件 |
| 命令 | 等价于 `Test-Path <vivado_path>\vivado.bat -PathType Leaf`（无外部进程） |
| PASS | 文件存在；detail 给出绝对路径与字节数 |
| WARN | 无（该项只有 PASS/FAIL） |
| FAIL | `vivado_path` 为空、目录不存在、或目录里没有 `vivado.bat`（detail 会额外注明"目录也不存在"） |
| 修法 | `set \`vivado_path\` to the directory that contains vivado.bat (e.g. D:/Xilinx/Vivado/2025.2/bin) and re-run install.ps1` |

`vivado_path` 的语义是**含 `vivado.bat` 的 bin 目录**，不是安装根：`D:/Xilinx/Vivado/2023.1/bin`。
安装根（`<install>`）= 它的上一级，检查 2/4 都用这个推导值。

---

## 2. `vivado-version` — 配置版本与磁盘一致（**证据链 ①②③**）

| 项 | 内容 |
|---|---|
| 测什么 | config 的 `vivado_version` 能否被**证明**，以及是否与磁盘一致 |
| 证据链 ① | `<install>\data\parts\installed_devices.txt` 第 2 行 `'BuildNumber' => '2023.1'`（静态、最快、本机有效） |
| 证据链 ② | `"<vivado_path>\vivado.bat" -version`（`Invoke-DoctorNative`，**超时 120 s**，`-Quick` 跳过） |
| 证据链 ③ | 只用目录名（`.../Vivado/2023.1`）——**只能 WARN**，不算证明 |
| 静态备选 | ① 之外还试 `<install>\data\version.txt`、`<install>\version.txt`、`<install>\.xinstall\Vivado\xinst_version`（本机三者都不存在），detail 会写清用的是哪一级 |
| PASS | ①/② 拿到的值与 `vivado_version` **字符串相等**；detail 形如 `proved by level 1 (static file): data/parts/installed_devices.txt (BuildNumber)` |
| WARN | 只拿到 ③（目录名），或 ② 超时/无输出，或 `-Quick` 跳过了 ②：detail 以 `unverified (2023.1): ...` 开头并说明缺哪一级 |
| FAIL | **只有拿到两个可比值且不相等时**才 FAIL，修法直接给出该写的值 |
| 修法 | `set \`vivado_version: <探测值>\` in config.yml and re-run install.ps1 (the persona tier depends on it)` |

**本机实测（2026-10-24，必须记住的坑）**：Vivado 2023.1 的 `bin\vivado.bat` 把 `-version` 交给
`loader.bat`，后者命中 `if defined RDI_INVOKE_VERSION_ONLY ( call %PRODVERSION_EXE% %RDI_PROGNAME% -longversion & exit /b 1 )`
（`bin\loader.bat`），于是 **rc=1 且 stdout/stderr 全空**——这是 2023.1 自带的破行为，不是安装坏了。
`prodversion.exe vivado.exe -longversion` 直接跑同样是空输出；而 `prodversion.exe vivado.exe`（不带 `-longversion`，
且 `XILINX_VIVADO` / `RDI_DATADIR` / `PATH` 都设好时）能打印 `vivado.exe v2023.1 (64-bit)`。
所以：**不要**把"`vivado.bat -version` 空输出"当成版本错误的证据；这也是把证据链 ① 放在第一位的原因。

`vivado_version` 的 consumer 是 `tools\render_patch.ps1`：它据此选 persona 分档
（`>= 2025.2` → `2025.2plus`，否则 `2023.1`）。

---

## 3. `python` — 解释器可用 + ≥3.10 + UTF-8 模式

| 项 | 内容 |
|---|---|
| 测什么 | ① `<python>` 能跑并报版本；② 版本 **≥ 3.10**；③ `PYTHONUTF8=1` 下能打印 CJK 字面量；④ kit 渲染出来的 patch 给 MCP 进程导出了 `PYTHONUTF8: '1'` |
| 命令 ① | `<python> -c "import sys;print(\"%d.%d.%d\" % sys.version_info[:3])"`（超时 30 s） |
| 命令 ③ | `$env:PYTHONUTF8='1'; <python> -c "print('\u4e2d')"`，子进程 stdout 按 **UTF-8** 解码，判输出里是否含 `U+4E2D` |
| 命令 ④ | `Select-String` 读 `<stage>\cordis.patch.yml`（没有则退到 `<kit>\templates\preset.patch.yml.tmpl`）里的 `PYTHONUTF8: '1'` |
| PASS | ①②③④ 全过；detail 形如 `python 3.14.6 (>=3.10), CJK literal emitted as UTF-8, PYTHONUTF8=1 in the rendered patch` |
| WARN | ①②③ 过、但 patch/template 里找不到 `PYTHONUTF8=1` |
| FAIL | 路径为空 / 不存在 / 起不来 / `< 3.10` / UTF-8 探针失败（含超时） |
| 修法 | `point \`python\` at a 3.10+ interpreter (e.g. the vivado-mcp venv: D:/vivado-mcp/venv/Scripts/python.exe)` |

**为什么是 3.10**：vivado-mcp 0.3.26（`D:\vivado-mcp\site`，`Requires-Python: >=3.10`）自己就要 3.10+；
低版本能"起"也跑不了这个 MCP。KIT-SPEC §7 #3 已同步为 3.10。

**为什么单独验 UTF-8**：MCP 进程把 Vivado 的原始输出（含中文 WARNING/提示）原样回传；`PYTHONUTF8=1`
缺失时，非中文代码页（如 GBK）上的 `print` 可能直接抛 `UnicodeEncodeError`，表现为"工具调用莫名失败"。
`PYTHONUTF8=1` 由渲染后的 patch 的 `mcp-vivado.env` 固定导出（`PYTHONIOENCODING: utf-8` 同时在），
不依赖用户系统设置。

---

## 4. `part` — 器件在本机 Vivado 器件库里

| 项 | 内容 |
|---|---|
| 测什么 | config `part` 非空；器件属于**本机已安装**的器件族 |
| 主判据 | `<install>\data\parts\installed_devices.txt` 的 `DeviceListMapping`：`'kintexu' => ['xcku060', ...]` 一族一块；device = `part.Split('-')[0]`（`xcku060-ffva1156-2-i` → `xcku060`） |
| 器件族目录 | `data/parts/xilinx/<family>`（本机布局）或 `data/parts/<family>`（另一种常见布局），两种都接受 |
| 备用判据 | 没有 `installed_devices.txt` 时按命名约定推：`xcku060`→`xcku`、`xc7a35t`→`xc7a`、`xczu9eg`→`xczu`，再映射到目录名（`kintexu` / `artix7` / `zynquplus` …，`xcku` 会同时试 `kintexu` 与 `kintexuplus`） |
| PASS | 索引里能查到该 device，且对应的族目录存在；detail 写 `family kintexu (data/parts/xilinx/<family>, listed in installed_devices.txt)` |
| WARN | **找不到任何 parts 树**（`<install>\data\parts` 不存在，例如装了 Vivado 但没装 device data）：`cannot verify statically` |
| FAIL | parts 树在、但 device 不在索引里（或索引点到不存在的族目录） |
| 修法 | `set \`part\` to a device installed in this Vivado (families found: artix7, kintex7, ... , versal; device names are listed in data/parts/installed_devices.txt) and re-run install.ps1` |

本机实测：`xcku060` 在 `kintexu` 族（`installed_devices.txt` 里 `'kintexu' => [` 段内含 `'xcku060'`），
目录 `D:\Xilinx\Vivado\2023.1\data\parts\xilinx\kintexu\` 存在。速度等级 / 封装（`-ffva1156-2-i`）不在本检查范围。

---

## 5. `ascii-paths` — 路径纯 ASCII

| 项 | 内容 |
|---|---|
| 测什么 | 六个值逐字符 `< 0x80`：`cwd`、`TEMP`、`TMP`、`project_root`、`vivado_mcp_cwd`、`temp_dir` |
| 命令 | 无外部进程；`Test-AsciiPath`（`lib\common.ps1`） |
| PASS | 六个都非空且纯 ASCII |
| WARN | ① 只有 **`cwd`** 含非 ASCII（doctor 恰好被从中文目录启动——那是 shell 位置，不是 kit 配置）；② 无非 ASCII 但 config 键为空（`project_root`/`vivado_mcp_cwd`/`temp_dir`） |
| FAIL | `TEMP`/`TMP` 或三个 config 键（`project_root`/`vivado_mcp_cwd`/`temp_dir`）含非 ASCII；detail 点名**第一个**冒犯的键（其余并列列出） |
| 修法 | `point \`temp_dir\` at a pure-ASCII directory on the same drive (e.g. D:/FPGA/.tmp) and re-run install.ps1; for TEMP/TMP set $env:TEMP/$env:TMP before running Vivado` |

**为什么 config/TEMP/TMP 是 FAIL**：Vivado 的 Tcl 层按 GBK 解码路径，中文目录会在 `open_project` /
`write_*` 级别炸掉，而且报错信息本身经常是乱码；`temp_dir` 还直接进 MCP 进程的 `TEMP`/`TMP`（渲染进 patch），
`vivado_mcp_cwd` 是 MCP 进程的 cwd。这些是"装进去就带着走"的值，错了 kit 就是不能用。
建议值始终给"同盘的 ASCII 目录"（本机 `D:/FPGA/.tmp` 已存在时优先建议它）。

**为什么 `cwd` 只 WARN**：doctor 的当前目录只是"用户恰好在这里敲命令"，不是 kit 的配置。
实测反例：在 vault（`<vault>`）里跑 doctor，若按 FAIL 处理会整项变红、
退出码 1，但 kit 本身完全正常——这是假阳性。所以 cwd 非 ASCII 只 WARN，
修法是"cd 到 ASCII 目录再跑 install.ps1 / Vivado 活"，而不是去改 config。

---

## 6. `mcp-import` — `import vivado_mcp` 且解析到 site 内

| 项 | 内容 |
|---|---|
| 测什么 | 用 config 的 `python`，`PYTHONPATH=<vivado_mcp_site>` 能 `import vivado_mcp`，并打印 `__version__` / `__file__`；**`__file__` 必须落在 `vivado_mcp_site` 之下** |
| 命令 | `$env:PYTHONPATH='<site>'; <python> -c "import vivado_mcp;print(getattr(vivado_mcp,'__version__',''));print(vivado_mcp.__file__)"`（超时 60 s） |
| PASS | 退出码 0 且 `__file__` 以 `<site>\` 开头（大小写不敏感）；detail 形如 `version 0.3.26 from D:\vivado-mcp\site\vivado_mcp\__init__.py` |
| WARN | `-Quick` 跳过 |
| FAIL | site 为空/不存在、python 不可用、import 抛异常（detail 带 rc 与前两行错误）、或解析到 site **之外**（说明 sys.path 上有旧副本） |
| 修法 | `set \`vivado_mcp_site\` to the directory that contains the \`vivado_mcp\` package (it is the \`site\` dir of the vivado-mcp install)` |

`vivado_mcp_site` = 含 `vivado_mcp\` 包的那层目录（本机 `D:/vivado-mcp/site`），不是仓库根、不是 venv。
"解析到 site 之外"是特意加的：`pip install vivado_mcp` 过的解释器里，`import` 会成功但用的是另一份代码，
补丁自然不在——这种"看起来 PASS 实际跑错版本"最难查。

---

## 7. `mcp-tools` — `mcp_ctl.py list` 出 32 个工具

| 项 | 内容 |
|---|---|
| 测什么 | `<python> <vivado_mcp_site 的上级>\mcp_ctl.py list` 的**工具数** |
| 命令 | `<python> "<parent of vivado_mcp_site>\mcp_ctl.py" list`，working dir = `parent`，超时 120 s |
| 解析 | 按行取第一个空白分隔 token，`^[a-z][a-z0-9_]*$` 且去重计数（中文描述不参与判断，避免代码页噪声） |
| PASS | **恰好 32**；detail `32 tools listed by mcp_ctl.py list (all become mcp__vivado__*)` |
| WARN | `>0` 但不等于 32 —— **不同版本的 vivado-mcp**（工具名仍会变成 `mcp__vivado__*`，只是数量不同） |
| FAIL | 命令失败（rc≠0）、`mcp_ctl.py` 不存在、超时、或 rc=0 但一个工具名都没有 |
| 修法 | `fix \`python\` / \`vivado_mcp_site\`, or reinstall vivado-mcp` |

本机实测：32 个（`check_bitstream_readiness` … `xdc_lint`），耗时约 3.7 s，所以放进了 `-Quick` 的跳过名单。
`mcp_ctl.py` 必须在 site 的**上一级**（本机 `D:\vivado-mcp\mcp_ctl.py`）；找不到时 FAIL 的 detail 会指出这个布局约束。

---

## 8. `license` — Vivado 许可证静态可见（**永不 FAIL**）

| 项 | 内容 |
|---|---|
| 测什么 | 静态线索：`XILINXD_LICENSE_FILE` / `LM_LICENSE_FILE`（先进程、再用户级环境变量）指向存在的文件/目录，或 `2100@host` 形态的许可证服务器条目，或 `%USERPROFILE%\.Xilinx` 下存在 `*.lic` |
| 命令 | 无 Vivado 启动；`[Environment]::GetEnvironmentVariable(v,'Process'/'User')` + `Get-ChildItem -Recurse -Filter *.lic` |
| PASS | 任一线索命中；detail 写清来源（`[exists]` / `[license server, not probed]` / `*.lic under ...`） |
| WARN | 一条线索都没有（detail 注明"许可证也可能在别处：服务器、加密狗、评估模式"），或值存在但路径失效 |
| FAIL | **永远不 FAIL** |
| 修法 | `set $env:XILINXD_LICENSE_FILE (this session) or the user environment variable to your .lic file / 2100@server, e.g. D:/Xilinx/license.lic; doctor never installs licenses` |

**为什么只 WARN**：许可证可以来自浮动服务器、`XILINX_LICENSE` 注册表项、MAC 绑定的随机器文件、
甚至 WebPACK/评估模式；静态判不了"能不能跑"，而**真去启动 Vivado 验 license 太慢且可能弹 GUI**。
本检查只回答"有没有看得见的线索"，不回答"license 一定可用"。
本机实测：`%USERPROFILE%\.Xilinx` 下无 `*.lic` 且未设环境变量 → 稳定 WARN（这正是一个 WARN 的样例）。

---

## 9. `bundle-installed` — bundle 已装进 profile（**裸 profile 只 WARN**）

| 项 | 内容 |
|---|---|
| 测什么 | `<profile>\package.json` 的 `dependencies` 里有 `dsh-vivado`、其 `link:` 目标目录**存在**、且名字也在 `dsh.profile.bundles` 里 |
| 命令 | 读 JSON（`ConvertFrom-Json`）+ `Test-Path`；不启动任何进程 |
| PASS | 依赖存在、`link:` 目标存在、名字在 `dsh.profile.bundles`；detail 给出目标与 bundle 数（本机探针 profile：`14 bundles`） |
| WARN | profile 目录/`package.json` 不存在，**且** staging 也不存在——"这台机器上还没装 kit，没什么可验的" |
| FAIL（半装/坏装） | 依赖指向不存在的目录 / 依赖在但不在 `dsh.profile.bundles` / 在 `dsh.profile.bundles` 但无依赖 / staging 在但 profile 没接上 / profile 没有 `package.json` 但 staging 在 |
| 修法 | `run install.ps1 -Profile <p>`（坏装时加一句"重装会重建 staging 链接"） |

**为什么"裸 profile = WARN"**（Lead 2026-10-24 裁决）：doctor 会随包发给同门，他们很可能在**装之前**
先跑一次看看环境；把"还没装"判成 FAIL 会让 `doctor.ps1` 一上手就红。语义上：
WARN = "环境本身没坏，但这件事还没做"；FAIL 只留给**做了一半/坏掉**（那才是真的不能用）。
验收时同理：裸 profile 必须 `exit 0`，装了 kit 的探针 profile 才看 13 项的 PASS 数。

---

## 10. `bundle-rendered` — staging 里的 patch 已渲染且指向真实技能目录

| 项 | 内容 |
|---|---|
| 测什么 | `<stage>\cordis.patch.yml`（`<stage> = <DshHome>\bundles\dsh-vivado`）存在、非空、**无残留占位符**（`{{...}}` 里只允许 `{{model}}`）、`skill-filesystem` 的 `customSkillDirs` 指向**存在**的目录 |
| 命令 | 读文件 + 正则 + `Test-Path`；无外部进程 |
| PASS | detail 形如 `no leftover placeholders except {{model}}, customSkillDirs -> .../skills (exists), top-level - insert: present, mcp-vivado row present` |
| WARN | staging 目录不存在（还没装） |
| FAIL | patch 缺失/空、有残留 `{{PLACEHOLDER}}`、没有 `customSkillDirs`、或它指向的目录不存在 |
| 修法 | `re-run install.ps1 -Profile <p> (it re-renders cordis.patch.yml)` |

`{{model}}` 是 DSH 提示词占位符，渲染器**故意**不替换（`tools\render_patch.ps1` 自检里同样豁免它），
所以它不算残留。`customSkillDirs` 必须存在，否则技能挂载点空掉、`skill` 工具找不到 AMD 技能——
这是"装完了但技能不出现"最常见的原因（渲染时写的是绝对路径，移动过 staging 就会坏）。

---

## 11. `mcp-patches` — 四个本地 vivado-mcp 补丁在位（**按内容判定，缺了只 WARN**）

| 项 | 内容 |
|---|---|
| 测什么 | 五组**内容标记**（`Select-String -SimpleMatch`），对应 `patches\vivado-mcp\0001..0004`：<br>① `tools\tcl_tools.py` 有 `max_lines: int = 0` 或 `save_full_to`（`run_tcl`/`safe_tcl` 输出裁剪）<br>② 同文件有 `_QUOTE_TRAP_HINT` 或 `close-quote`（`safe_tcl` 占位符踩坑提示）<br>③ `analysis\xdc_linter.py` 有 `_rule_breakdown` 或 `max_items: int = 0`（按规则聚合）<br>④ `tools\diagnostic_tools.py` 有 `max_items: int = 0`（`xdc_lint` 默认全量）<br>⑤ `tools\cdc_tools.py` 有 `max_details: int = 0`（`get_cdc_report` 默认全量） |
| 为什么按内容 | 补丁重打后 mtime 毫无意义；`.bak-mcp-*` 备份文件反而会让"没打补丁"看起来像"打了"。只认源码里的实际代码/字符串 |
| PASS | 5/5 命中（本机 5/5） |
| WARN | 有缺失（detail 列出缺哪几个、present 有哪些），或 site 不可用 |
| FAIL | **永不 FAIL** |
| 修法 | `re-apply the 4 patch files in patches/vivado-mcp/ (Vivado still runs, but xdc_lint/get_cdc_report/run_tcl lose default-full or lossless output)` |

**为什么只 WARN**：缺补丁 = 少了"默认全量 / 无损输出 / 提示文本"，**Vivado 跑得动、工具也在**，
只是 `xdc_lint` / `get_cdc_report` 会按上游默认截断（坑 #76：默认截断会静默吞掉真要修的那几条）。
这是能力降级不是不可用，所以 WARN。

---

## 12. `compatibility` — mcp-client 版本豁免（`compatibility.json`）

| 项 | 内容 |
|---|---|
| 测什么 | profile 实际解析到的 `@deepseek-ai/dsh-mcp-client` 版本 ≠ DSH 运行时版本时，`<profile>\compatibility.json` 必须有键 `@deepseek-ai/dsh-mcp-client@<mcp 版本>`，且其值数组包含运行时版本 |
| 运行时版本来源 | **`<dsh.cmd> --version` → `0.2.1-rc.2`**（约 0.35 s，保留预发布后缀）；退而求其次 exe `VersionInfo.ProductVersion` = `0.2.1.0`（**丢了 `-rc.2`，不能当豁免值**） |
| mcp-client 版本来源 | `<profile>\node_modules\@deepseek-ai\dsh-mcp-client\package.json` 的 `version`（本机 `0.1.7-rc.2`） |
| 命令 | `dsh.cmd --version`（超时 30 s）+ 读两个 JSON |
| PASS | 两版本相等（不需要豁免），或键存在且值含运行时版本；detail 写 `exemption "@deepseek-ai/dsh-mcp-client@0.1.7-rc.2" -> [0.2.1-rc.2] (runtime 0.2.1-rc.2 read from dsh.cmd --version)` |
| WARN | `compatibility.json` 缺失/无该键/值里没有运行时版本/profile 没有 mcp-client/只能从 exe ProductVersion 拿到版本（那种值会写坏） |
| FAIL | 无（该项不判 FAIL：mcp 行被静默丢弃属于"能力降级"） |
| 修法 | `re-run install.ps1 -Profile <p> (it merges the exemption) or add "@deepseek-ai/dsh-mcp-client@<v>": ["<runtime>"] to <profile>\compatibility.json` |

**后果**：DSH 加载 profile 时，插件版本与宿主不一致又没有豁免 → **静默丢掉那一行**（`mcp-vivado` 整行消失，
工具面从 91 掉回 59），日志里不一定有明显报错。所以宁可 WARN 得啰嗦一点。
**实测坑**：`D:\dsh\DeepSeek Harness.exe` 的 `ProductVersion = 0.2.1.0`、`FileVersion = 0.2.1-rc.2`；
活 profile 里的值是 `["0.2.1-rc.2"]`。写豁免**必须**用 `dsh.cmd --version` 的结果。

---

## 13. `skills` — 随包 8 个技能齐、且 `SKILL.md` 的 `name:` 与目录名一致

| 项 | 内容 |
|---|---|
| 测什么 | `<stage>\skills\<name>\SKILL.md` 存在，且文件里 `^name: xxx$` 的 xxx **等于目录名** |
| 期望目录（8 个） | `amd-doc-search`、`hw-ila-debug`、`hw-vio-debug`、`vivado-revision-control`、`vivado-rtl-elaboration-analysis`、`vivado-rtl-lint`、`vivado-simulate-rtl`（AMD 官方 7 件）+ `vivado-workflow-discipline`（自研纪律） |
| 命令 | 读文件 + 正则；无外部进程 |
| PASS | 8/8 存在且 name 全对；detail `8/8 skills present ... every SKILL.md name: matches its directory` |
| WARN | staging 目录不存在（还没装） |
| FAIL | 缺目录 / 缺 `SKILL.md` / `name:` 缺失或与目录名不一致 |
| 修法 | `reinstall the kit with install.ps1 -Profile <p> (skills\ is copied by install.ps1)` |

`skill-filesystem` 用 rank 300 的 `customSkillDirs` 挂 staging 的 `skills\`（不是 `<DshHome>\skills`）。
`name:` 与目录名不一致时，技能列表里会出现"两个名字"或排序错乱，且 `skill` 工具按名字调用会失败——
这是纯文本即可判定的硬错误，所以判 FAIL。

---

## 14. 判为 WARN 而不是 FAIL 的清单（一页速查）

| # | id | 什么时候只 WARN | 依据 |
|---|---|---|---|
| 2 | `vivado-version` | 只拿到目录名（证据链③）、②探针超时/空输出、`-Quick` 跳过 | 目录名不是证明；2023.1 的 `-version` 本就空输出（见 §2） |
| 4 | `part` | 完全找不到 parts 树 | 无法静态判定 ≠ 器件错；可能只是没装 device data |
| 5 | `ascii-paths` | 只有 `cwd` 含非 ASCII，或有 config 键为空 | shell 位置不是 kit 配置（§5 有实测反例） |
| 6 | `mcp-import` | `-Quick` 跳过 | 慢探针被显式跳过 |
| 7 | `mcp-tools` | 工具数 ≠ 32 但 > 0；`-Quick` 跳过 | 版本不同，工具面照旧可用 |
| 8 | `license` | 永远 WARN（除非有静态线索则 PASS） | 许可证可能来自看不见的地方（§8） |
| 9 | `bundle-installed` | profile 与 staging 都完全没有 kit 痕迹 | "还没装"不是"坏了"（Lead 裁决） |
| 10 | `bundle-rendered` | staging 不存在 | 还没装，无可验证 |
| 11 | `mcp-patches` | 永远 WARN（缺补丁/无 site） | 只丢默认全量行为，Vivado 照跑（§11） |
| 12 | `compatibility` | 键缺失/值不含运行时版本/版本来源不可靠 | 后果是 mcp 行被静默丢弃 = 能力降级 |
| 13 | `skills` | staging 不存在 | 还没装，无可验证 |

---

## 15. 扩展检查项时的约定

1. 新检查 = `doctor.ps1` 里一个 `Test-Check<Name>` 函数 + `$checkList` 里一行 + 本文新章节（三处同步）。
2. 函数**返回** `New-Result <id> <title> <PASS|WARN|FAIL> <detail> <fix>`；`id` 用小写连字符，与 `$checkList` 一致。
3. 任何外部命令只能用 `Invoke-DoctorNative`（带 `-TimeoutSec`），否则会把 doctor 变成能挂死的脚本。
4. 检查函数内部抛异常时，runner 会兜底成一行 `check crashed: ...`（`Soft=$true` 的项兜成 WARN），
   不会中断整个体检——但那是 bug 兜底，不是正常路径。
5. 只读：新增检查**不要**写 profile / Vivado / 第三方源码目录；需要慢探针就同时加进 `-Quick` 的跳过名单。
