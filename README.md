# dsh-vivado — 给 Vivado 工作流准备的 DeepSeek Harness 聚合包

**简体中文** | [English](README.en.md)

[![powered by dsh](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
![Vivado 2023.1](https://img.shields.io/badge/Vivado-2023.1%20tested-BE1E2D?style=flat-square&logo=amd&logoColor=white)
![Vivado 2025.2+](https://img.shields.io/badge/Vivado-2025.2%2B%20unverified-9e9e9e?style=flat-square)
![MCP tools](https://img.shields.io/badge/MCP%20tools-32-6E4AFF?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)

一条命令 + 一次重启，给 DeepSeek Harness 装上「Vivado 专用开发环境」：
一个带工程纪律的会话预设、32 个直接驱动 Vivado 的工具、8 个官方/自研技能。

装上之后，你可以直接对助手说人话：「打开 `my_proj.xpr`，看综合状态和资源」「用 `xdc_lint` 查约束」
「跑综合，起完别等我，轮询进度」——它会自己按顺序复用既有结果、只在必要时才真正启动综合/实现。

> 本仓库**不含** Vivado 本体与许可证、不含 AMD 账号/entitlement、不含任何密钥；也**不代签**任何 AMD 协议。
> 你需要自备合法的 Vivado 安装与许可，以及第三方项目 [`vivado-mcp`](https://github.com/mapleleavessssssss-wq/vivado-mcp)。

---

## 装完你会得到什么

| 你会得到 | 说明 |
|---|---|
| 一个叫 **`Vivado`** 的会话预设 | 新建会话时选它（默认仍是 `standard`）。它把「先读工程 → `xdc_lint` → 复用既有综合/实现结果 → 确实必要时才综合」这套顺序，以及「路径必须 ASCII、Vivado 全局串行、结论必须带证据」这类纪律写进了助手的行为准则 |
| **32 个** `mcp__vivado__*` 工具 | 综合/实现、时序、利用率、CDC、XDC 检查、ILA 波形、会话管理等，全部通过 stdio MCP 直连本机 Vivado（第三方 `vivado-mcp` 提供） |
| **8 个技能** | AMD 官方 6 件（RTL 综合日志分析、lint、仿真、版本管理、ILA、VIO，MIT）+ 2 件自研（AMD 文档检索、Vivado 工作流纪律）。**随包挂载，不往你的 `~/.dsh/skills` 写任何文件** |
| 体检与干净的卸载 | `doctor.ps1` 13 项逐条 PASS/WARN/FAIL 并给一句修法；`uninstall.ps1` 还原 profile 并清掉自己装的目录 |

**适合谁**：Windows 上做 Xilinx/AMD FPGA、已经在用 DeepSeek Harness 桌面版、希望助手能真正操作 Vivado 而不是只在对话里出主意的人。

**不适合谁**：不想装第三方 MCP、或工程处在必须断网/NDA 环境（文档检索技能会把查询发往 AMD 服务，默认可以不装它）。

## 前置条件

| 项 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| DeepSeek Harness | **桌面版 ≥ 0.2.1-rc.2**（Electron 宿主） |
| Vivado | 已安装、`vivado.bat` 可跑。**2023.1 已实测**；2025.2+ 未实测（见[版本档位](#版本档位)） |
| Python | **≥ 3.10**（`vivado-mcp` 0.3.26 要求；用你跑 `vivado-mcp` 的那个解释器即可） |
| vivado-mcp | 已 `pip install vivado-mcp==0.3.26` 到**纯 ASCII 目录**，且能 `import vivado_mcp` |
| 路径 | 工程根、`TEMP`、`TMP`、vivado-mcp 安装位置**全部纯 ASCII**（中文路径会让 Vivado 的 Tcl 层按 GBK 解码而失败） |
| 许可 | 你自己合法的 Vivado license |

## 安装

```powershell
git clone https://github.com/chemmy-11/dsh-vivado.git
cd dsh-vivado
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安装器会自己探测 Vivado / Python / vivado-mcp 的位置，只需要你确认一下 `part`（器件型号）。
想先看它要做什么而不改任何东西：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WhatIf
```

**装完必须重启 DeepSeek Harness。** 配置在宿主启动时读取，Electron 宿主下没有热更新——这不是建议，是前提。
重启后新建会话，把预设切到 **`Vivado`**。

> 装到别的 profile / 别的 `DSH_HOME`：`.\install.ps1 -Profile work -DshHome D:\dsh-home`。
> 全部参数（`-Config` / `-Mode cli|manual` / `-StageDir` / `-RenderOnly` / `-SkipCompatibility` …）与九步流程：
> [`docs/install.md`](docs/install.md)。

安装器只做三件它会明确告诉你的事：把自己复制到 `<DSH_HOME>\bundles\dsh-vivado`、用你的配置在那个目录里生成
bundle 补丁、把这一层注册进你的 profile（改之前备份 `*.bak-<日期>`）。它**不改**你的 `cordis.patch.yml`、
**不写** `~/.dsh/skills`、**不需要**管理员权限，任何一步失败会自动回滚。

## 装完怎么用

1. 新建会话 → 预设选 **`Vivado`**（`standard` 会话是没有 `mcp__vivado__*` 工具的，这是故意的）。
2. 一句话自检：
   - 「列出你工具清单里所有 `mcp__vivado__*`」→ 应该是 **32** 个；
   - 「列一下你能看到的技能」→ 应该是 **8** 个；
   - 「你的系统提示里有没有 `Vivado is GLOBALLY SERIAL` 这句」→ 应该是「有」。
3. 然后就像平时一样说人话，例如：
   - 「打开 `D:\work\prj\project_1.xpr`，看综合状态和资源利用率」
   - 「用 `xdc_lint` 检查 `constraints_1`，要全量明细」
   - 「跑综合，`wait=false` 起，然后每轮报一次进度」
4. 长任务不用干等：`run_synthesis` / `run_implementation` 用 `wait: false` 起，再用 `get_run_progress` 轮询。

## 出问题了

先跑体检，它会把「哪一项坏了、怎么修」直接打出来：

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

最常见的四类（完整清单见 [`docs/troubleshooting.md`](docs/troubleshooting.md)）：

| 症状 | 先做什么 |
|---|---|
| 重启后看不到 `Vivado` 预设 | 确认真的重启过；确认装到的是你打开的那个 profile（`-Profile`）；再跑 `doctor.ps1` 看第 9/10 项 |
| 预设有了，但一个 `mcp__vivado__*` 都没有 | 多半是 profile 缺 `compatibility.json` 版本豁免 → 重跑 `install.ps1`（**别带** `-SkipCompatibility`）后重启 |
| `start_session` 失败 / Tcl 报 `File not found` | 几乎都是**非 ASCII 路径**；`doctor.ps1` 第 5 项会点名是哪个配置键 |
| `xdc_lint` / `get_cdc_report` 明细被截断 | 没打 `patches/vivado-mcp` 的补丁（默认不自动打），见 [`patches/vivado-mcp/README.md`](patches/vivado-mcp/README.md) |

三条铁律值得先记住：**改配置必须重启**、**所有 Vivado 路径必须 ASCII**、**同一时刻只跑一个 Vivado**。

## 版本档位

`config.yml` 里的 `vivado_version` 决定注入哪一档「版本真值」：

| 档 | 你会得到的口径 |
|---|---|
| `2023.1`（`< 2025.2`） | 本档**实测**事实：Tcl 8.5.14、`open_project -noprogress` 不存在、ILA `C_DATA_DEPTH` 最小 1024、`report_*` 参数按 2023.1 查 |
| `2025.2+` | **一条实测都没有**：所有版本相关事实都要求助手先探测再用，并如实标注量到的值 |

每个格子的证据、命令与新机器重探清单：[`docs/version-matrix.md`](docs/version-matrix.md)。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
# 同样要重启宿主
```

它会解绑 profile 里的这一层（用安装时的备份，或做等价精确删除）、删掉自己复制到 `bundles\dsh-vivado` 的目录，
不碰你原有的插件行与技能目录。要手工核对每一步（含保留 staging、逐行回退的 PowerShell 片段）：
[`docs/install.md`](docs/install.md)。

## 仓库结构

```text
dsh-vivado/
  package.json              bundle 清单（一个配置型 DSH bundle）
  install.ps1  uninstall.ps1  doctor.ps1  lib/   安装、卸载、体检
  config.example.yml        配置样板（安装器会据此生成 config.yml）
  tools/                    渲染器、模板生成器、技能清单生成器
  templates/                preset 模板、shipped 22 行审计件、persona/ 两档片段
  skills/                   8 个技能 + MANIFEST.json + 来源说明
  patches/vivado-mcp/       4 个可选补丁 + 许可证全文 + 应用/验证说明
  docs/                     安装详解、体检详解、版本表、原理、排错、许可
  NOTICE  LICENSE  README.md  README.en.md
```

> 仓库里**没有** `cordis.patch.yml`：那是按你的机器渲染出来的产物，安装时才生成。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/install.md`](docs/install.md) | 安装器/卸载器的全部参数、九步流程、逐行回退 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 症状 → 原因 → 修法，体检 13 项速查，求助时该贴什么 |
| [`docs/doctor-checks.md`](docs/doctor-checks.md) | 13 项体检的判据与阈值（含为什么有的只 WARN） |
| [`docs/version-matrix.md`](docs/version-matrix.md) | Vivado 版本真值分档表（实测 / 未实测分列） |
| [`docs/architecture.md`](docs/architecture.md) | 它怎么工作的：bundle 组合、技能挂载、渲染、安装链路、后续怎么扩展 |
| [`docs/licensing.md`](docs/licensing.md) | 上游许可审查（AMD / DeepSeek / vivado-mcp）与我们的义务 |
| [`NOTICE`](NOTICE) · [`LICENSE`](LICENSE) | 来源与改动清单；MIT 授权与第三方 carve-out |

## 许可与致谢

本仓库**自己的代码与文档**是 **MIT**（© 2026 chemmy-11）。随包发布的第三方内容各自保留原许可：

- **AMD 官方 6 件技能**：MIT（© 2026 Advanced Micro Devices, Inc.），取自 Vivado AI Extension 的
  `plugin-bundled/skills/`，我们改动的文件已在 `NOTICE` §1.3 逐条列出；
- **取自 DeepSeek Harness 的 22 条预设插件行**：MIT（© 2026 DeepSeek）；
- **`vivado-mcp`**：第三方项目，Apache-2.0；本仓库**不含其源码**，只带 4 个 `.patch`（许可证全文随包）。

MIT 只覆盖我们原创的部分，第三方条款见 [`NOTICE` §3.0](NOTICE) 与 [`docs/licensing.md`](docs/licensing.md)。
与 AMD / Xilinx / DeepSeek 均无隶属或背书关系，产品名仅为指称。

## 反馈

遇到问题请开 [Issue](https://github.com/chemmy-11/dsh-vivado/issues)，附上 `doctor.ps1 -Json` 的输出
（**别贴 license 内容、密钥或 token**）。

---

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
