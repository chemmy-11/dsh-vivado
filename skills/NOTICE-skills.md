# NOTICE-skills.md — `skills/` 的来源、许可与我们的改动清单

> 作用域：本文件只覆盖 `<kit>/skills/`。整包口径的 `NOTICE` / `LICENSE` 由 ps-docs 在 kit 根维护；
> 两者不冲突 —— 本文件是 skills/ 的**逐文件证据版**（每条结论都能按 §4 的命令复现）。
> 标记约定：`实测` = **本仓**有本机实测与其证据（本轮未复测，属转述；凡是本轮亲自跑的会另注日期）；`按文档` = 只有文档/他人说法，未在本机核对。
> 生成门禁：`py tools/gen_skills_manifest.py --check`（`skills/MANIFEST.json` 禁手写）。

## 1. 来源 A：AMD 官方技能（6 件，MIT）

| 项 | 值 |
|---|---|
| 上游容器 | `vivado-ai-extension-2026.9.1.vsix`（本机副本：`<vsix 所在目录>\vivado-ai-extension-2026.9.1.vsix`）`实测` |
| 容器内路径 | `extension/resources/plugin-bundled/skills/<name>/` `实测` |
| 上游仓库 | <https://github.com/Xilinx/ross-ai-assistant>（同源说法来自 `<vault>/.ross-recon/安装记录.md:5`；本机未联网核对仓库内容 ⇒ `按文档`） |
| 许可 | **MIT** —— 见下方两条证据 |
| 是否 pristine | **不是**。随包的是「vsix 原样 + 我们 7 个文件的改动」，见 §1.2 |

**许可证据（`实测`）**

1. `vivado-ai-extension-2026.9.1.vsix :: extension/resources/plugin-bundled/LICENSE` 原文首两行：
   `MIT License` / `Copyright (c) 2026 Advanced Micro Devices, Inc.`（完整 MIT 正文）。
2. 各 `SKILL.md` frontmatter `license: MIT`：6/6 命中。
   `SPDX-License-Identifier: MIT` HTML 注释：5/6 命中 —— **`vivado-rtl-elaboration-analysis/SKILL.md` 没有这段注释块**（该文件的许可依据只有 frontmatter 的 `license: MIT` + 上条容器 LICENSE），此处不作更强的声明。

### 1.1 随包目录（6 件 AMD + 2 件自研）

| 目录 | 文件数 | 来源 | 许可 |
|---|---:|---|---|
| `hw-ila-debug` | 2 | vsix | MIT |
| `hw-vio-debug` | 2 | vsix | MIT |
| `vivado-revision-control` | 13 | vsix | MIT |
| `vivado-rtl-elaboration-analysis` | 568 | vsix | MIT |
| `vivado-rtl-lint` | 28 | vsix | MIT |
| `vivado-simulate-rtl` | 27 | vsix | MIT |
| `amd-doc-search` | 2 | **本 kit 自研**（§2） | 未单独声明（见 §2） |
| `vivado-workflow-discipline` | 1 | **本 kit 自研**（§2） | MIT（frontmatter） |

### 1.2 我们对 AMD 技能的改动：7 个文件（其余 633 个文件与上游**逐字节相同**）

比对基准 = 上游原样副本 `<vault>/.ross-recon/official-skills/`，它自身与 vsix 内 640/640 文件逐字节一致（§4 命令 3）。
`diff -rq` 结果：6 个目录共 640 个文件，**只有下列 7 个不同**（§4 命令 4）。

| # | 文件 | 改法 | 为什么 |
|---|---|---|---|
| 1–6 | 6 个 `SKILL.md` | ① `description:` 由 YAML 折叠块（`>` / `>-`）改为**单行双引号标量**（内部 `"` 转义为 `\"`）；② frontmatter 之后插入 `> **本机适配注记（非 AMD 原文；2026-10-18 由 DSH 会话追加）**` 区块；③ frontmatter 增补 `baseline:`（`amd_doc` / `tested_on` / `status` / `evidence`）与 `artifacts:`（有则加） | ① DSH 技能目录对多行 description 的展示/检索不稳定；② 把官方工具名映射到本机工具与 CLI 桥、写明 Vivado 2023.1 与 ASCII/串行硬约束；③ 让「基线是否实测」变成可门禁的字段（结论 §3 D3） |
| 7 | `vivado-rtl-elaboration-analysis/parse_elab_messages.py` | 给 `os.path.relpath(filepath, output_dir)` 包 `try/except ValueError`，跨盘时保留绝对路径（+7/−1，净 +6 行，含中文注释） | Windows 下源日志在 D:、输出 CSV 在 C: 时 `relpath` 抛 `ValueError: path is on mount 'D:'`，整份报告中止（`实测`：修复前 3 行崩溃 / 修复后 452 条全量） |

**改动明细补充（`实测`，逐条核对过文件）**

- `description` 折叠为标量后**内容不变**：与上游折叠值逐字比较，6/6 相等（长度 578 / 547 / 665 / 300 / 250 / 728）。
- 其中 `hw-ila-debug`、`hw-vio-debug` **额外**在 description 末尾追加了 `本工作区注（2026-10-24 修订）：…`（讲 `mcp__vivado__*` 与 CLI 桥现状）；其余 4 件只做折叠，未加内容。
- `本机适配注记` 严格插在 frontmatter 闭合 `---` 之后、正文之前，共 6 处，均自带「非 AMD 原文」标识。
- **没有改**：`resolution/**`（560 个修复卡）、`references/**`、`examples/**`、`helper-procedures/helper_scripts.tcl`、`scripts/**`、各目录的 `README.md` / `report-format.md` 等全部附属文档 —— 这些与上游逐字节相同。

### 1.3 已知的「不通用」内容（诚实声明，未擅自清洗）

`本机适配注记` 原含**作者机器**的绝对路径与本地事实；**公开版（2026-10-24）已脱敏**为配置驱动占位符（`<python 解释器：见 config.yml 的 python>`、`<vivado-mcp>`、`<project_root>`、`<本技能目录>\doc_search.py`、`<vsix 所在目录>`），技术内容未删。改动文件仍在本节列的 7 个之内。
按任务书「AMD 技能逐字节复制、不改内容」的要求，本轮**保留原样**：

- 对本 kit 的使用者，权威配置是 `config.yml`（`part` / `project_root` / `vivado_version` / `vivado_path` / `temp_dir` / `python`）+ `doctor.ps1`；注记里的路径只作历史参考。
- 若要对外（public 版）分发，需要在 kit 之外再做一次脱敏（改注记里的机器路径）—— 那会破坏「与上游只差 7 个文件」这条可核对性，因此**不在本轮**做。

## 2. 来源 B：本 kit 自研技能（2 件）

| 技能 | 内容 | 第三方代码 | 许可 |
|---|---|---|---|
| `amd-doc-search` | `SKILL.md` + `doc_search.py`（stdlib 客户端，检索 AMD hosted 文档服务） | **无** | frontmatter 未声明 `license`（保持原样，MANIFEST 里如实记 `null`） |
| `vivado-workflow-discipline` | 单文件 `SKILL.md`：工作流顺序 + 判据纪律 + 版本分档 + 文档检索两条通路 | **无** | frontmatter `license: MIT` |

- 两者**均不在**上游 vsix 里：vsix 的 50 个技能目录清单、以及 `.ross-recon/official-skills/` 的 8 个目录清单都没有它们（§4 命令 1/3）⇒ 归属「自研」有据，不是把 AMD 内容改个名。
- `amd-doc-search` 的 `doc_search.py` 会把 **query 外发到 AMD hosted 服务**（`实测`：服务端自报 `AMD Doc Search`）；`SKILL.md` 与 `vivado-workflow-discipline` 都写明「NDA/未公开项目不许用，或改走本地知识库」。
- `vivado-workflow-discipline` 的纪律条目抽自本仓库 `PITFALLS.md` #69–#76（相关补充 #64/#67/#72/#73），是流程/判据文本，无第三方代码；文中标「实测」的版本事实属**转述**，故其 `baseline.status` 仍是 `unverified`。
- 许可口径：自研两件的许可最终由 kit 顶层 `LICENSE`（ps-docs）决定。若顶层不是 MIT，只需改 `vivado-workflow-discipline/SKILL.md` 的 `license:` 一行并重跑生成器（`amd-doc-search` 无该字段，不需要改）。

## 3. baseline 诚实声明（结论 §3 D3）

**6 件 AMD 技能的上游自述基线是 `2026.1`（`vivado-simulate-rtl` 自述 `2025.2, 2026.1`），而本 kit 的首个目标版本是 `2023.1`；因此除 `vivado-rtl-elaboration-analysis` 有本机 2023.1 实测证据外，它们的 `baseline.status` 一律为 `unverified`、`tested_on` 为 `null`。**

| 技能 | `amd_doc`（上游自述） | `tested_on` | `status` | 依据 |
|---|---|---|---|---|
| `amd-doc-search` | `unspecified` | `null` | `unverified` | 不调用 Vivado，无版本适用项 |
| `hw-ila-debug` | `2026.1` | `null` | `unverified` | 上游 `compatibility: Requires Vivado 2026.1+`；无 2023.1 硬件链路实测 |
| `hw-vio-debug` | `2026.1` | `null` | `unverified` | 同上 |
| `vivado-revision-control` | `2026.1` | `null` | `unverified` | frontmatter 无 compatibility；无 2023.1 实测 |
| **`vivado-rtl-elaboration-analysis`** | `2026.1` | **`2023.1`** | **`verified`** | 唯一真跑过的：`parse_elab_messages.py` 喂 2023.1 真实综合日志（日志头自证 `Vivado v2023.1 (64-bit)`）→ `Parsed 67 elaboration messages`，exit 0 |
| `vivado-rtl-lint` | `2026.1` | `null` | `unverified` | 全盘无真实 lint 报告，脚本只在构造样例上验过可执行 ⇒ 不计 verified |
| `vivado-simulate-rtl` | `2025.2, 2026.1` | `null` | `unverified` | 上游自述 validated on 2025.2/2026.1，非本机 |
| `vivado-workflow-discipline` | `unspecified` | `null` | `unverified` | 流程说明，自身无基线可测 |

- 上表不是手写的：`amd_doc` / `tested_on` / `status` / `evidence` 全部来自各 `SKILL.md` 的 frontmatter，由生成器原样搬进 `MANIFEST.json`（本 kit 的生成器**不注入、不美化**任何基线）。
- `--check` 会机械拒绝两类伪造：`status=verified` 但 `tested_on`/`evidence` 为空；`status=unverified` 却填了 `tested_on`（结论 §3 D3）。反例已实测被拒（见 `ps-skills.md` §验收）。

## 4. 可复跑的证据命令

```powershell
# 1) vsix 里的许可与技能清单
py -c "import zipfile;z=zipfile.ZipFile(r'<vsix 所在目录>\vivado-ai-extension-2026.9.1.vsix');print(z.read('extension/resources/plugin-bundled/LICENSE').decode()[:80])"

# 2) dist\skills 与安装副本逐字节一致（同时是「复制没走样」的证明）
py <vault>\.vivado-scratch\kit-2026-10-24\ps-skills\sync_skills.py

# 3) 上游副本 vs vsix：640/640 文件逐字节一致（证明比对基准真的是上游）
#    见 ps-skills.md §「vsix 对齐」；脚本片段用 zipfile + sha256 对比

# 4) 我们改动的文件就这 7 个（其余 633 个与上游相同）
cd <vault>; diff -rq .ross-recon\official-skills\hw-ila-debug .dsh\skills\hw-ila-debug
#    … 6 个目录逐一跑；输出里只应出现 6 个 SKILL.md 与
#    vivado-rtl-elaboration-analysis\parse_elab_messages.py（合计 7 个文件）

# 5) 清单门禁（唯一判据，exit 0 = PASS）
py D:\dsh-vivado\tools\gen_skills_manifest.py --check

# 6) 重新生成清单（改动任何 SKILL.md 后必须跑；禁手改 MANIFEST.json）
py D:\dsh-vivado\tools\gen_skills_manifest.py
```

> 本文件本身不是随包技能：它在 `skills/` 根，不是技能目录（无 `SKILL.md`），技能加载器不会把它当技能，生成器也不会把它当技能目录。
