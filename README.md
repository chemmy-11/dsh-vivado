# dsh-vivado — Vivado 工作环境的 DSH 聚合包（preset + MCP 工具 + 技能）

[![powered by dsh](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
![Vivado 2023.1](https://img.shields.io/badge/Vivado-2023.1%20tested-BE1E2D?style=flat-square&logo=amd&logoColor=white)
![Vivado 2025.2+](https://img.shields.io/badge/Vivado-2025.2%2B%20unverified-9e9e9e?style=flat-square)
![MCP tools](https://img.shields.io/badge/MCP%20tools-32-6E4AFF?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)

一句话：**一条命令 + 一次重启**，把「Vivado 专用会话预设 + AMD 官方 6 个技能 + 自研工作流纪律 + 已打补丁的 `vivado-mcp`（32 工具）」装进你自己的 DeepSeek Harness。

它**不包含**：Vivado 本体、Vivado 许可证、AMD 账号/entitlement、任何密钥或 token；也**不代签**任何 AMD 协议。

| 你会得到 | 细节 |
|---|---|
| 一个名为 **`Vivado`** 的会话预设 | 创建会话时手动选它（默认仍是 `standard`）；它带版本分档的工程纪律，并按你的 Vivado 版本注入「已实测」与「待实测」的区分 |
| **32** 个 `mcp__vivado__*` 工具 | 由第三方 `vivado-mcp` 0.3.26 提供（stdio MCP，需你本机自装） |
| **8** 个技能 | AMD 官方 6 件（MIT）+ 自研 2 件（`amd-doc-search` 文档检索、`vivado-workflow-discipline` 工作流纪律）；随包经 rank 300 `customSkillDirs` 挂载，**不写你的 `~/.dsh/skills`** |
| 体检与卸载 | `doctor.ps1` 逐项 PASS/WARN/FAIL；`uninstall.ps1` + 逐行回退命令 |

---

## 0. 三条铁律（先读，能省掉 90% 的「装了没用」）

1. **装完必须重启 DeepSeek Harness。** 配置在宿主启动时读取；Electron 宿主下 `dsh-hmr` **实测不生效**（这是本 kit 的前提，不是建议）。本 kit 的任何改动（含换版本档位、改 `config.yml`）**都要重启**才生效。
2. **所有 Vivado 相关路径必须是纯 ASCII**（工程根、cwd、`TEMP`、`TMP`、`vivado-mcp` 安装位置）。中文路径会让 Vivado 的 Tcl 层按 GBK 解码 → `start_session` 必失败（`PITFALLS.md:31`，坑 #21）。
3. **Vivado 全局串行**：同一时刻只允许一个 Vivado 进程。动手前 `tasklist | grep -i vivado` 必须为空。

## 1. 前置条件

| 项 | 要求 | 检查方式 |
|---|---|---|
| 操作系统 | Windows 10 / 11 | — |
| DeepSeek Harness | **桌面版 ≥ 0.2.1-rc.2**（Electron） | 宿主「关于」；`<安装目录>\resources\runtime\cli\bin\dsh.cmd --version` |
| Vivado | 已安装且 `vivado.bat` 可执行；**2023.1 已实测**，`2025.2+` 未实测（见 §6） | `vivado -version`；目录里存在 `<安装>\Vivado\<版本>\bin\vivado.bat` |
| Python | **≥ 3.10**（`vivado-mcp` 0.3.26 声明 `Requires-Python: >=3.10`；kit 自身脚本只需标准库） | `py -c "import sys;print(sys.version)"` |
| vivado-mcp | 已 `pip install vivado-mcp==0.3.26` 到**纯 ASCII 目录**（如 `<vivado-mcp>\site`），且能 `import vivado_mcp` | `py -c "import vivado_mcp"`（需先设 `PYTHONPATH`） |
| 器件/工程 | 你的 part 与工程根路径（ASCII） | 见 `config.yml` |
| 许可 | 你自己合法的 Vivado license（本 kit 不分发、不破解） | `XILINXD_LICENSE_FILE` 或 license 文件 |

> 本机参考值（仅作示例，别照抄）：Windows 11、DSH 0.2.1-rc.2、Vivado 2023.1、Python 3.14（venv）、`vivado-mcp` 0.3.26 装在 `<vivado-mcp>`、part `xcku060-ffva1156-2-i`、工程根 `<project_root>`。

## 2. 一键安装

```powershell
git clone https://github.com/chemmy-11/dsh-vivado.git   # 或下载 GitHub 的 zip
cd dsh-vivado
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> 仓库里**没有** `cordis.patch.yml`，这是有意的：它是**按你的机器渲染出来的产物**（器件、Vivado 路径、
> MCP 解释器、TEMP 都要写进 patch，不能预置）。`install.ps1` 会把本目录拷到 staging 再渲染，
> 所以别手工 `plugin_manager install_bundle` 本仓库目录——要么跑安装器，要么先
> `powershell -File .\tools\render_patch.ps1 -ConfigPath .\config.yml -OutFile .\cordis.patch.yml`。

可选参数（下表是**交付版本 `install.ps1` 的实际参数**；以 `install.ps1 -?` 输出为准）：

| 参数 | 作用 |
|---|---|
| `-Config <path>` | 用指定的 `config.yml`（默认 `.\config.yml`，没有则用 `config.example.yml` 并回写实际值） |
| `-Profile <name>` | 目标 DSH profile（默认 `desktop`；你的 profile 名不同时必须显式传） |
| `-DshHome <path>` | DSH 配置根（默认 `$env:DSH_HOME`，否则 `%USERPROFILE%\.dsh`）；隔离试装/多环境用 |
| `-WhatIf` | 只打印完整计划（含将执行的 CLI 命令、备份文件名、`compatibility.json` 判断）后退出，**不改任何文件** |
| `-Mode auto\|cli\|manual` | `auto`（默认：优先官方 CLI，失败回退手改）/ `cli`（只用官方 CLI，失败即致命）/ `manual`（完全不碰 pnpm，手改 `package.json` + 建 junction） |
| `-InstallDir <path>` | DSH 安装根（含 `DeepSeek Harness.exe` 的目录）；默认自动发现 |
| `-StageDir <path>` | staging 目录；默认 `<DshHome>\bundles\dsh-vivado` |
| `-Part <part>` | 覆盖 `config.yml` 的 `part`（只改这一项时用） |
| `-RenderOnly` | 只 staging + 渲染，不改 profile、不备份、不调 CLI |
| `-SkipCompatibility` | 不写 profile 的 `compatibility.json` 版本豁免。**一般不要用**：缺豁免时 DSH 会静默丢掉 `mcp-vivado` 行（见 §9） |
| `-NonInteractive` | 不交互提问；缺东西时直接给一句修法后失败 |

**它会做什么（交付版 `install.ps1` 的 9 步）**：

1. **解析 `config.yml`**（没有就 `config.example.yml`），并**只对缺失/明显错误的值**做探测补齐：Vivado 安装、Vivado 版本、Python、`vivado-mcp` site；探测不到就用配置值；
2. **ASCII 守卫**：staging / `skills` / `temp_dir` / `vivado_mcp_cwd` / `project_root` 任一含非 ASCII → 立刻 FAIL 并给修法（Vivado 的 Tcl 层按 GBK 解码，非 ASCII 必炸）；
3. 检查 profile 存在、`package.json` 是合法 JSON；
4. **复制 kit 到 staging** `<DshHome>\bundles\dsh-vivado`（**不复制** `config.yml`、备份、临时/协作笔记这类不该进包的东西）；
5. 把**实际生效的**配置写进 staging 的 `config.yml`（留证据：以后 `doctor.ps1` 读的就是它）；
6. 在 staging 里用 `tools\render_patch.ps1` 渲染 `cordis.patch.yml`（所有绝对路径指向 staging；渲染后不应再有未替换占位符）；
7. **装 bundle**：调**安装包自带**的 CLI
   `<DSH 安装目录>\resources\runtime\cli\bin\dsh.cmd plugin --profile <profile> add "link:<staging>"`
   （官方 CLI 跑随包 pnpm，往 `dsh.profile.bundles` 追加一项）；CLI 不可用时按 `-Mode` 回退为「手改 profile `package.json` + 建 `node_modules\dsh-vivado` 链接」；
   同时**确保 profile 有 `compatibility.json` 的 `@deepseek-ai/dsh-mcp-client` 版本豁免**（缺失时 DSH 会静默丢掉 `mcp-vivado` 行）；
8. **用合成树验证**：`dsh --profile <p> --dump-config` 里断言 4 个 kit 标记（预设行 / persona / skill-filesystem / mcp-vivado）；
9. 打印结果、**备份清单**、**必须重启**、以及**逐行回滚命令**。任何一步失败会**自动回滚**本 run 改过的 profile 文件。

- 它**从不**写 `<DshHome>\skills`（技能只从 staging 的 `skills/` 经 rank 300 挂载）、**不改**不属于自己的 plugin 行、**不需要**管理员权限。
- 改动前把被改的 profile 文件备份为 `*.bak-<YYYYMMDD>`（`package.json` / `pnpm-lock.yaml` / `compatibility.json` 各自备份）。
- 安装是**幂等**的：连跑两次结果一致；装完再跑 `-WhatIf` 应显示「已是目标状态」。

> ⚠️ **别用 PATH 上的 `dsh`**：本机实测 PATH 上的 CLI 可能是旧版（0.1.7-rc.2），读到的树和运行中的宿主版本不一致。永远用 `<安装目录>\resources\runtime\cli\bin\dsh.cmd`（安装器内部就是这么定位的）。

**装完：重启 DeepSeek Harness**（见 §3）。

## 3. 必须重启（没有热更新）

| 事实 | 说明 |
|---|---|
| 重启才生效 | profile 与 bundle patch 在宿主**启动时**读取；新会话才会出现 `Vivado` 预设 |
| `dsh-hmr` 在 Electron 下不生效 | 多次重启实证（`结论_cross_Vivado环境DSH规范化_2026-10-24.md` §0）；**不要**相信「保存即生效」的说法 |
| 重启后仍未出现预设 | 跑 `doctor.ps1`（§5）：检查 #9/#10 会直接点名是「bundle 没装」还是「渲染没做」 |

## 4. 怎么用

1. **新建会话时把预设切到 `Vivado`**（默认是 `standard`；`standard` 会话**没有** `mcp__vivado__*` 工具，这是有意的）。
2. 自检（在会话里直接问 agent）：
   - 「列出你工具清单里所有 `mcp__vivado__*`」→ 应为 **32** 个；
   - 工具总数取决于 DSH 版本：本机 0.2.1-rc.2 的 Vivado 预设会话实测 **97**（65 非 MCP + 32 MCP）。旧资料里的 `91 = 59 + 32` 是旧 profile 口径，**增量 32 才是稳定判据**。
   - 「列一下你能看到的技能」→ 8 个（AMD 6 + 自研 2）。
3. 典型任务照旧说人话即可，例如：
   - 「打开 `<project_root>\prj\project_1\project_1.xpr`，看综合状态和资源」；
   - 「用 `xdc_lint` 检查 `constraints_1` 下的 XDC（默认要全量明细）」；
   - 「跑综合，用 `wait=false` 起，然后轮询进度」。
4. 长任务的正确姿势（写进 persona 的纪律）：`run_synthesis` / `run_implementation` 用 `wait: false` → `get_run_progress` 轮询；不要一个 turn 干等 40 分钟。

## 5. `doctor.ps1`（装完先体检，出问题再装一遍前也先跑它）

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1          # 人读版（13 项全跑）
powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -Json    # 机器可读（每项带 id，可 ConvertFrom-Json）
powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -Quick   # 跳过 3 个慢探针，10 秒内出结果
```

- **退出码：`0` = 没有 FAIL（允许 WARN）；`1` = 至少一项 FAIL**（可直接进 CI / 批处理）。
- 每项都给 **PASS / WARN / FAIL + 一句可执行修法**；检查顺序 = 输出顺序 = `-Json` 里的 `id` 顺序。
- `-Quick` 会跳过三个慢探针（`vivado.bat -version`、Python `import vivado_mcp`、`mcp_ctl.py list`），被跳过的项报 **WARN `skipped by -Quick`**（不是 PASS）。
- 其它参数：`-Config <path>` / `-Profile <name>` / `-DshHome <path>` / `-InstallDir <path>` / `-NonInteractive`（与安装器同名同义）。

| # | `-Json` id | 检查 | 判定与修法 |
|---:|---|---|---|
| 1 | `vivado-install` | Vivado 安装 | **FAIL** = `vivado.bat` 缺失 → 改 `config.yml` 的 `vivado_path` 或装 Vivado |
| 2 | `vivado-version` | Vivado 版本 | **FAIL** = 两个可比值不一致；**WARN** = 只能靠目录名（探针没输出）。按 `vivado -version` 改 `vivado_version` |
| 3 | `python` | Python + UTF-8 | **FAIL** = 不可跑或低于 **3.10**（`vivado-mcp` 声明 `Requires-Python>=3.10`）。换解释器；UTF-8 不生效则 `setx PYTHONUTF8 1` |
| 4 | `part` | 器件 part | **FAIL** = 器件族目录不存在；**WARN** = 无法静态核实。改 `part`（别用教学视频里的 CIV part） |
| 5 | `ascii-paths` | ASCII 路径 | **FAIL** = `TEMP`/`TMP` 或任一配置路径含非 ASCII（会点名是哪个键/值）；**WARN** = 仅 cwd 非 ASCII（例如从中文 vault 目录里跑 doctor）。把 cwd / `TEMP` / `TMP` / 工程根指到 ASCII 目录 |
| 6 | `mcp-import` | `import vivado_mcp` | **FAIL** = 不可导入，或路径不在 `vivado_mcp_site` 内。修 `config.yml` 的 `vivado_mcp_site` / `python` |
| 7 | `mcp-tools` | MCP 工具数 | **FAIL** = `mcp_ctl.py list` 命令失败；**WARN** = 数量 ≠ **32** 但 >0（版本不符）。重装/换 `vivado-mcp==0.3.26` |
| 8 | `license` | Vivado license | **只 WARN，永不 FAIL**（静态判定；license 也可能在服务器/加密狗/评估模式）。配 `XILINXD_LICENSE_FILE` 或 license 文件 |
| 9 | `bundle-installed` | bundle 已装 | **FAIL** = 半装/坏装；**WARN** = 裸 profile（零痕迹，说明还没装）。跑 `install.ps1`，然后重启 |
| 10 | `bundle-rendered` | bundle patch 已渲染 | **FAIL** = 缺失 / 占位符残留 / `customSkillDirs` 目录不存在。重跑 `install.ps1`（或手动 `tools\render_patch.ps1`） |
| 11 | `mcp-patches` | vivado-mcp 补丁 | **只 WARN**：缺补丁仍能跑，只是 `xdc_lint`/`get_cdc_report` 默认非全量（见 §7）。按 `patches\vivado-mcp\README.md` 应用 |
| 12 | `compatibility` | `mcp-client` 版本豁免 | **WARN** = 缺豁免（`mcp-vivado` 行会被 DSH **静默禁用**）。重跑 `install.ps1`（**不要** `-SkipCompatibility`）后重启 |
| 13 | `skills` | 随包技能 | **FAIL** = `skills` 目录缺失 / 某 `SKILL.md` 的 `name` 与目录名不符。重装 bundle 或修 `SKILL.md` 的 `name` |

## 6. 卸载与逐行回退

```powershell
# 默认 profile；装到别的 profile / DSH_HOME 时把同样的两个参数传进去（安装器最后打印的就是这行）
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -DshHome D:\dsh-home -Profile work
# 改完同样必须重启宿主
```

`uninstall.ps1` 只做两件事：把 profile 的 bundle 依赖/清单项去掉（用安装时的备份或等价的精确删除）、删除 staging 目录；它**不碰**你自己原有的 plugin 行、不碰 `~/.dsh/skills`。

> 其它参数（与安装器同名同义）：`-WhatIf`（只打印计划不落盘）、`-KeepStage`（保留 staging，只解绑 profile）、`-Mode`、`-InstallDir`、`-StageDir`、`-NonInteractive`。

**逐行回退（脚本不可用/要人工核对时）**：

```powershell
# ① 找到安装时留下的备份（同目录、带日期后缀）
cd $env:USERPROFILE\.dsh\profiles\desktop
Get-ChildItem package.json.bak-* | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# ② 用备份覆盖 profile 清单（这就是逐行回退：把 dependencies 里 dsh-vivado 那行、
#    dsh.profile.bundles 末尾那项一起还原）
Copy-Item .\package.json.bak-<YYYYMMDD> .\package.json -Force

# ③ 删 staging（bundle 本体）
Remove-Item -Recurse -Force $env:USERPROFILE\.dsh\bundles\dsh-vivado

# ④ 重启宿主；再确认 profile 的 cordis.patch.yml 未被本 kit 改过（本 kit 从不改它）
```

> 安装器**只动** bundle 与 profile 的 bundle 列表；动手前备份 `*.bak-<日期>`；`cordis.patch.yml` 由 bundle 提供，安装器不写它 —— 这是「不影响你原有配置」的保证方式。

## 7. `vivado-mcp` 的 4 个本地补丁（**默认不自动打**）

本 kit 的安装器**不修改** `<vivado-mcp>\site` 里的第三方源码（红线：不改第三方源码、不做私有分支），所以补丁需要你**显式**应用：

- 不打补丁：32 工具照常可用；但 `xdc_lint` / `get_cdc_report` 保持上游默认裁剪（`max_items=20` / `max_details=100`），大工程会**静默少给你明细**（`PITFALLS.md:86`，坑 #76）。
- 打补丁：检查类工具默认**全量**，并且 `run_tcl` / `safe_tcl` 可选用 `max_lines` / `save_full_to`（默认不裁剪，关键 `ERROR` 行不丢）。
- 应用与验证（含「是否已打」的反向检查）：见 **`patches\vivado-mcp\README.md`**。一条命令记住：`git -c core.autocrlf=false apply -p1 <补丁>`（从 `site` 目录；必须带 `core.autocrlf=false`）。

## 8. 版本分档：`2023.1` vs `2025.2+`

`config.yml` 的 `vivado_version` 决定档位（`>=2025.2` → `2025.2plus`，否则 `2023.1`），安装/渲染时自动选对应的 persona 片段：

| 档 | persona 会告诉你什么 |
|---|---|
| `2023.1` | 本档「实测」事实：Tcl **8.5.14**、`open_project -noprogress` **不存在**（`[Common 17-170]`）、ILA `C_DATA_DEPTH` 最小 **1024**、`report_*` 参数按 2023.1 查 |
| `2025.2+` | **没有一条实测**：所有版本相关事实都要 `Re-probe` 后再用（Tcl 版本 / `-noprogress` / `C_DATA_DEPTH` / `report_*` 参数 / 器件库），并把量到的值标成「实测」 |

每个格子的证据、命令与「新机器重探 checklist」：**`docs\version-matrix.md`**。

## 8.5 许可与来源（谁的东西、什么许可、我们履行的义务）

| 内容 | 许可 | 我们要做的 | 细节 |
|---|---|---|---|
| AMD 官方 6 件技能（`skills/` 里那 6 个目录） | **MIT**（© 2026 AMD） | 保留版权+许可声明、标明我们的改动 | `NOTICE` §1 + 附录 A；`docs/licensing.md` §1 |
| 取自 DeepSeek Harness 的 22 条预设插件行 | **MIT**（© 2026 DeepSeek） | 保留版权+许可声明 | `NOTICE` §3.1 + 附录 C；`docs/licensing.md` §2 |
| vivado-mcp 的 4 个补丁 | 改的是 **Apache-2.0** 代码 | 随附许可证全文、标明「已修改」 | `patches/vivado-mcp/LICENSE-APACHE-2.0.txt`、README §3.5 |
| 本仓库自己的代码/文档 | **MIT**（© 2026 chemmy-11） | 保留版权+许可声明 | `LICENSE`（MIT 正文 + 「适用范围」carve-out 表） |

- **不随包分发**：Vivado 本体与许可证、AMD entitlement、任何密钥、`vivado-mcp` 源码、DSH 运行时/CLI/UI 代码。
- 与 AMD / Xilinx / DeepSeek **无隶属或背书关系**；名称仅为指称（`NOTICE` §3.2）。
- 完整审查（含外层专有协议 §4.1 的边界引文、复核命令）：[`docs/licensing.md`](docs/licensing.md)。

## 9. 排错（按坑号索引，全部是本仓库踩过的真事）

| 症状 | 根因 / 修法 | 坑号 |
|---|---|---|
| 工具返回「成功」，但正文里有 `[ERROR] ...`，agent 却当成功继续 | MCP 协议层 `is_error` 只反映传输失败；**判据必须扫文本**（`[ERROR]` / `CRITICAL WARNING`）。persona 已写死这条 | #69（`PITFALLS.md:79`） |
| 用 `mcp_ctl.py` CLI 桥连跑多条命令，第二条就报「会话 'default' 不存在」 | 桥是**一进程一调用**，会话不跨进程。多步操作要么写成单进程脚本，要么用本预设的 MCP 长连接工具 | #70（`:80`） |
| 照官方文档写 `open_project -noprogress` 直接报错；Tcl 语法/命令行为怪 | 本机 2023.1 是 Tcl **8.5.14** 且**没有** `-noprogress`（`[Common 17-170]`）。**先探再用**，别把 2026.1 文档当本机事实 | #72（`:82`） |
| 一个 `run_tcl` 就把上下文烧掉几千 tokens（`open_run` / `open_project` 尤甚） | 原始 stdout 不裁剪。优先 `report_*` / `get_run_progress`；必须跑大 Tcl 时把 stdout 重定向到文件再读 tail；打了补丁可显式 `max_lines` | #74（`:84`） |
| `safe_tcl` 报 `can not find channel named "X=..."` 或 `extra characters after close-quote`，像工具坏了 | 占位符**必须独占一个 Tcl 词**：写 `puts {0}`，不要写 `puts X={0}`。打了补丁会附中文提示 | #75（`:85`） |
| `xdc_lint` 只给我 20 条、`get_cdc_report` 只给 100 条明细，真正的违例被吞 | 检查类工具默认必须无损（**调用方显式**才可裁剪）。打 §7 的补丁，或显式传 `max_items=0` / `max_details=0` | #76（`:86`） |
| 重启后仍看不到 `Vivado` 预设 / 工具清单里没有 `mcp__vivado__*` | ①没重启；②profile 选错（`-Profile`）；③bundle 没装（doctor #9）；④MCP 的 python/PYTHONPATH 错（doctor #6）。逐项用 `doctor.ps1` 抓 | 安装类 |
| 预设出现了，但 32 个 `mcp__vivado__*` 一个都没有 | 最常见：**`dsh-mcp-client` 版本与宿主要求不符，且 profile 的 `compatibility.json` 缺版本豁免 ⇒ DSH 静默丢掉 `mcp-vivado` 行**。`install.ps1` 会自动补这条豁免（`-SkipCompatibility` 会跳过它）；重跑安装器（不要带 `-SkipCompatibility`）后重启 | 安装类 |
| 装完提示 verification FAIL（4 个 kit 标记没齐） | 安装器已写入但合成树没看到：先看它打印的 `dsh --dump-config` 行号/退出码；再跑 `doctor.ps1` 的 #9/#10 | 安装类 |
| `start_session` 报「Vivado GUI 进程提前退出」 | 几乎都是**非 ASCII 路径**（工程根/cwd/TEMP/安装位置）。doctor #5 会点名 | #21（`:31`） |
| 中文/非 ASCII 路径下 Tcl 报 `File not found`，或 `✓` 打印崩溃 | 同上 + Windows 控制台 GBK：设 `PYTHONUTF8=1`；文件操作先拷到 ASCII 路径 | #1/#12（`:11`/`:22`） |
| 预设会话里 `pwsh` 突然报 `unknown tool "pwsh"` | 本机实测：`pwsh` 会被异步摘除。**改用 `win_bash`，不要重试**（persona 已写明） | #71（`:81`） |

## 10. 目录结构（安装后在 staging 里看到的就是这些）

```text
dsh-vivado\
  package.json              bundle 清单（dsh-vivado）
  cordis.patch.yml          安装时渲染产物（勿手改；含预设 + 技能根 + MCP 行）
  config.example.yml        配置样板（install.ps1 会生成/改写 config.yml）
  install.ps1 / uninstall.ps1 / doctor.ps1 / lib\common.ps1 / lib\install-helpers.ps1
  tools\                    渲染器、模板生成器、技能清单生成器
  templates\                preset 模板、shipped 22 行快照、persona\<tier>.frag.yml
  skills\                   8 个技能（AMD 6 + 自研 2）+ MANIFEST.json + NOTICE-skills.md
  patches\vivado-mcp\       4 个第三方补丁 + 应用/验证说明
  docs\version-matrix.md    版本真值分档表（T4）
  NOTICE / LICENSE / README.md
```

## 11. 来源与许可（务必读一眼）

- **AMD 官方 6 件技能**：来自 `vivado-ai-extension-2026.9.1.vsix :: extension/resources/plugin-bundled/skills/`，**MIT**（© 2026 Advanced Micro Devices, Inc.），我们改了其中 7 个文件（记录在案）；
- **`vivado-mcp`**：第三方项目（Apache-2.0，版本 0.3.26），**不是我们的资产**；本 kit 不含其源码，只带 4 个 `.patch`；不公开 PR 优先、不做私有 fork；
- **DSH 自带的 22 行插件配置**：抽取自你安装的 DSH 自身 shipped 预设，属宿主应用数据；
- **本 kit 自研内容**：内部/同门使用授权，**public 版 SPDX 审查未完成**（详见 `LICENSE`）。

→ 完整来源/许可/改动清单：**`NOTICE`**；授权条款：**`LICENSE`**。

## 12. English quick start

```powershell
# Prerequisites: Windows 10/11, DeepSeek Harness desktop >= 0.2.1-rc.2, a licensed Vivado install,
# Python >= 3.10, and vivado-mcp 0.3.26 installed under an ASCII-only path.
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Profile desktop
# then RESTART the DeepSeek Harness app (hot reload does NOT work in the Electron host),
# create a new session with the "Vivado" preset, and verify 32 `mcp__vivado__*` tools.
powershell -ExecutionPolicy Bypass -File .\doctor.ps1     # health check; exit 1 = FAIL
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1  # rollback (restart afterwards)
```

Notes: no Vivado binaries, licenses or tokens are bundled; the third-party `vivado-mcp` is Apache-2.0 and only patched via `patches\vivado-mcp\*.patch` (apply explicitly, `git -c core.autocrlf=false apply -p1`); the AMD skills are MIT (see `NOTICE`); everything else is internal-use only pending a public license review (`LICENSE`).
