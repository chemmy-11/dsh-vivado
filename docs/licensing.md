# 许可与来源审查（dsh-vivado）

> 审查日期：**2026-10-24**；审查范围：本 kit 实际**随包分发**的内容（不含使用者自己安装的 Vivado / vivado-mcp / DSH）。
> 结论一句话：**三个上游（AMD 技能 MIT、DSH 配置数据 MIT、vivado-mcp Apache-2.0）都允许本 kit 这么分发**，
> 义务全部落在「保留版权与许可声明」这一类，已逐条履行（见各节的「履行方式」）。
> 本文件不是法律意见；它只把**能复核的事实**与**我们的履行动作**对齐，public 版发布前仍建议做一次正式 SPDX 审查。

## 0. 结论表

| # | 上游 | 版本/身份 | 许可 | 我们分发什么 | 允许？ | 义务 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | **AMD 官方技能**（6 件） | `vivado-ai-extension-2026.9.1.vsix :: extension/resources/plugin-bundled/skills/**` | **MIT**（© 2026 Advanced Micro Devices, Inc.） | `skills/<6 个目录>/**`（逐字节 + 我们改的 7 个文件） | ✅ | 保留版权+许可声明；标明改动 | ✅ `NOTICE` §1.2/§1.3 + 附录 A |
| 2 | **DeepSeek Harness**（DSH） | `@deepseek-ai/dsh-desktop` / `@deepseek-ai/dsh-web-app` 0.2.1-rc.2 | **MIT**（© 2026 DeepSeek） | 22 条 shipped 插件行（预设 patch 片段） | ✅ | 保留版权+许可声明 | ✅ `NOTICE` §3.1 + 附录 C |
| 3 | **vivado-mcp** | 0.3.26（`mapleleavessssssss-wq/vivado-mcp`，Apache-2.0，作者 NJ） | **Apache-2.0** | **只发 4 个 `.patch`**，不分发其源码 | ✅ | §4(a) 随附许可证全文；§4(b) 改动标记；§4(c) 保留声明；§4(d) 上游无 NOTICE；§6 无商标授权 | ✅ `patches/vivado-mcp/LICENSE-APACHE-2.0.txt` + README §3.5 |

**不随包分发**（因此不构成本 kit 的许可问题）：Vivado 本体与许可证、AMD entitlement、任何密钥/token、
`vivado-mcp` 的源码或其依赖、DSH 的运行时/CLI/UI 代码、AMD 的专有 MCP server。

---

## 1. AMD 官方技能（MIT）

### 1.1 事实

| 证据 | 命令/位置 | 结果 |
|---|---|---|
| 子树许可文件 | `vsix :: extension/resources/plugin-bundled/LICENSE` | `MIT License` / `Copyright (c) 2026 Advanced Micro Devices, Inc.`，标准 MIT 全文 1 085 B |
| 该子树里就是这些技能 | `vsix :: extension/resources/plugin-bundled/` 下 `skills/` **1149 文件** | 我们随包的 6 件技能即取自此处 |
| 上游仓库同源 | GitHub API `GET /repos/Xilinx/ross-ai-assistant` → `license.spdx_id = "MIT"` | 与 vsix 一致 |
| 逐技能 frontmatter | 6 个 `SKILL.md` 的 `license: MIT` | 一致 |

### 1.2 外层专有协议的边界（必须说清，不能只挑 MIT 看）

同一个 vsix 的外层是**专有协议** `extension/LICENSE.txt`（「XILINX MCP SERVER AND EXTENSION LICENSE AGREEMENT」，21 730 B），
`extension.vsixmanifest` 里写 `<License>extension/LICENSE.txt</License>`，`extension/package.json` 的 `license` 字段是 `SEE LICENSE IN LICENSE.txt`。
这份协议的 **§5.1 保密条款**确实限制「不得把 Licensed Materials 提供给第三方」（原文见附录 A 引文），看起来与再分发冲突。

**但同一协议的 §4.1 明确把这类文件排除在本协议之外**（原文）：

> "4.1 Third-Party / Open Source Licenses. Certain files, programs, or other materials distributed in
> connection with the Licensed Materials may originate from Xilinx or one or more third-party licensors
> ("Additional Materials"). **Such Additional Materials are licensed to Licensee not under the terms and
> conditions of this Agreement, but pursuant to the terms and conditions of the applicable licenses that are
> distributed or otherwise made available with the Licensed Materials** … Notwithstanding the foregoing, …
> all such Additional Materials shall be deemed covered under Sections 6 (Disclaimers), 7 (Limitation of
> Liability), and 9.3 (Governing Law) of this Agreement."

⇒ `plugin-bundled/**`（自带 MIT LICENSE）属于 §4.1 的 Additional Materials：**由 MIT 支配**，不受 §5.1 保密条款约束；
仅 §6（免责）/§7（责任限制）/§9.3（管辖法）被视为适用。本 kit 的处理：在 `NOTICE` §3.2 增加「无担保/无背书」声明，
与 §6/§7 的口径一致；`LICENSE` §4 也写了「按现状提供、不附担保」。

### 1.3 履行方式

- 版权+许可声明：`NOTICE` 附录 A 收录 AMD 的 MIT 全文，`NOTICE` §1.1/§1.2 记录来源与证据；
- 改动声明：`NOTICE` §1.3 逐文件列出我们对 7 个文件的修改（6 个 `SKILL.md` + `parse_elab_messages.py`）；
- 商标：`NOTICE` §3.2，无 logo/图标，仅为指称。

---

## 2. DeepSeek Harness 的 22 条插件行（MIT）

### 2.1 事实（直接读安装包，不看网页）

| 证据 | 位置 | 值 |
|---|---|---|
| 桌面外壳 | `app.asar :: package.json` | `"name": "@deepseek-ai/dsh-desktop"`, **`"license": "MIT"`**, version `0.2.1-rc.2` |
| 运行时包 | `app.asar :: dsh/package.json` | `@deepseek-ai/dsh-desktop-runtime`（**无** `license` 字段） |
| 运行时许可文件 | `app.asar :: dsh/node_modules/@deepseek-ai/dsh/LICENSE` | `MIT License` / `Copyright (c) 2026 DeepSeek` |
| **22 行的出处包** | `app.asar :: dsh/node_modules/@deepseek-ai/dsh-web-app/package.json` | **`"license": "MIT"`** |
| 该包的许可文件 | `app.asar :: dsh/node_modules/@deepseek-ai/dsh-web-app/LICENSE` | `MIT License` / `Copyright (c) 2026 DeepSeek` |
| 安装目录是否有专有 EULA | `D:\dsh\` 根目录 | **没有** DSH 自身 EULA；只有 `LICENSE.electron.txt` / `LICENSES.chromium.html` / `7zip-installer-*.txt`（第三方依赖的许可文本） |
| asar 内是否有 EULA | `asar.py ls "EULA"` | **0 hits** |

⇒ 22 条插件行是 **MIT 许可的配置数据**，再分发与修改都允许；唯一实质义务是保留 DeepSeek 的版权与许可通知。

### 2.2 履行方式

- `NOTICE` §3.1 记录来源、版本、证据与「不含 DSH 运行时/CLI/UI 代码」的边界；
- `NOTICE` 附录 C 收录 DeepSeek 的 MIT 全文（原文取自 `@deepseek-ai/dsh/LICENSE`）。

> 为什么不是「抄人家的代码」：这 22 行是**插件清单配置**（id/name/config），不是可执行代码；且 `templates/` 里保留了
> 逐字节审计件 `shipped-standard-22rows.yml` 与 sha256，任何人可以自己从**自己的** DSH 安装里重新抽取
> （`tools/make_template.py --source <bundle patch>`）。升级 DSH 后该清单若变化，重跑生成器即可。

---

## 3. vivado-mcp（Apache-2.0）

### 3.1 事实

| 证据 | 位置 | 值 |
|---|---|---|
| 身份/许可 | `vivado_mcp-0.3.26.dist-info/METADATA` | `Name: vivado-mcp`, `Version: 0.3.26`, **`License-Expression: Apache-2.0`**, `License-File: LICENSE`, `Author: NJ`, `Requires-Python: >=3.10` |
| 上游仓库 | 同上 `Project-URL: Repository` | `https://github.com/mapleleavessssssss-wq/vivado-mcp`（public） |
| 上游许可 | GitHub API `GET /repos/mapleleavessssssss-wq/vivado-mcp/license` | `Apache-2.0` |
| 上游是否有 NOTICE | GitHub Contents API 根目录列表 | **没有** `NOTICE`/`NOTICE.md`（只有 `LICENSE`）→ §4(d) 无内容需转发 |
| 许可证全文 | `vivado_mcp-0.3.26.dist-info/licenses/LICENSE` | 10 774 B，sha256 `77b29df2…459e9c`，随包放在 `patches/vivado-mcp/LICENSE-APACHE-2.0.txt` |

### 3.2 我们分发的是补丁，不是源码

`patches/vivado-mcp/0001..0004` 是我们写的 `-u` 差分，改的是上游 4 个文件（`tcl_tools.py` / `xdc_linter.py` /
`diagnostic_tools.py` / `cdc_tools.py`）。补丁里引用了上游代码的上下文行，因此**仍需履行 Apache-2.0 的声明义务**：

| 条款 | 履行 |
|---|---|
| §4(a) 随附许可证 | `patches/vivado-mcp/LICENSE-APACHE-2.0.txt` |
| §4(b) 修改标记 | 只发补丁 ⇒ 被改文件由使用者产生；`patches/vivado-mcp/README.md` §3.5 给了一行现成标记注释 |
| §4(c) 保留声明 | 差分上下文保留原文件头与版权声明，未剥离 |
| §4(d) NOTICE | 上游无 NOTICE（已核对） |
| §6 商标 | 不使用其商标/logo；`NOTICE` §3.2 |

---

## 4. 我们自己的内容

`LICENSE` 的定位：**纯 MIT 文本**（`Copyright (c) 2026 chemmy-11`），2026-10-24 随仓库公开一并切换——
保持纯文本是为了让 GitHub / 工具链能识别为 MIT。
「MIT 只覆盖我们原创的那部分」这条 carve-out 写在 `NOTICE` §3.0（含 AMD MIT / DeepSeek MIT / vivado-mcp Apache-2.0 的逐项映射），
两处不冲突：MIT 的义务照做，第三方条款按各自原文执行。
这与本文件 §0 的合规结论一致：三方许可互不冲突，MIT 内容的再分发不需要额外许可。

### 公开版发布（2026-10-24 已执行 / 剩余项）

| # | 事项 | 状态 |
|---|---|---|
| 1 | 三个上游许可查清并履行义务（本文件 §0） | ✅ 完成 |
| 2 | 我们自己内容切换为 **MIT**（`LICENSE` 的 MIT 正文 + 第三方 carve-out 适用范围表） | ✅ 完成 |
| 3 | `skills/**` 注记里的作者机器路径脱敏为 config 驱动占位符（`NOTICE` §1.3 记录） | ✅ 完成 |
| 4 | 仓库由 private 转 **public**（`github.com/chemmy-11/dsh-vivado`），README 加 powered-by-dsh 与 Vivado 2023.1 徽章 | ✅ 完成 |
| 5 | 4 个补丁按 `patches/vivado-mcp/README.md` §6 政策提上游 PR；上游接受后删补丁并登记「已上游化」 | ⬜ 待办（对外动作，需要人决定时机） |
| 6 | （可选）正式 SPDX 扫描（如 `reuse` / `scancode`）作为机器复核 | ⬜ 未做：本文件是人工取证版，不替代工具扫描 |

---

## 5. 残留风险与限制（如实写）

| # | 风险 | 现状/缓解 |
|---|---|---|
| 1 | 上游**改许可**或改 API | 版本已钉死（AMD vsix 2026.9.1、DSH 0.2.1-rc.2、vivado-mcp 0.3.26）；升级时按 §6 复核命令重跑，`doctor` 会报版本/补丁不符 |
| 2 | 外层 EULA §6/§7/§9.3 被 §4.1 视为适用 | 已在 `NOTICE` §3.2 与 `LICENSE` §4 写入无担保/责任限制口径 |
| 3 | 商标指称（AMD/Xilinx/Vivado/DeepSeek） | nominative use，无 logo，`NOTICE` §3.2 声明无隶属/背书 |
| 4 | 22 行插件行是否算「substantial portion」 | 即便按最保守解释也已保留 MIT 通知（附录 C）；且提供自抽取路径 |
| 5 | 本审查非法律意见 | 结论只覆盖「事实 + 我们的动作」；已尽量把义务落成可复核的文件（附录 A/C、Apache 全文、carve-out 表），但正式发布前仍建议做一次工具化 SPDX 扫描 |

---

## 6. 复核命令（全部实测过，复制即用）

```powershell
# ---------- 0) asar 读取器（本 kit 的 tools 里没有，用临时脚本或任意 asar 解包工具）----------
#   本项目里的探针：<repo>\ase.py 等价物见 结论_cross_*_2026-10-24.md §8

# ---------- 1) AMD：子树 MIT + 外层专有协议 + 上游仓库 ----------
py -c "import zipfile;z=zipfile.ZipFile(r'%USERPROFILE%\Downloads\vivado-ai-extension-2026.9.1.vsix');print(z.read('extension/resources/plugin-bundled/LICENSE').decode()[:80])"
py -c "import zipfile;z=zipfile.ZipFile(r'%USERPROFILE%\Downloads\vivado-ai-extension-2026.9.1.vsix');t=z.read('extension/LICENSE.txt').decode();i=t.find('4.1 Third-Party');print(t[i:i+520])"
node <github-account 技能目录>/scripts/gh.mjs api GET /repos/Xilinx/ross-ai-assistant

# ---------- 2) DSH：MIT（两条都要看）----------
#   app.asar 顶层 package.json -> license: MIT
#   app.asar :: dsh/node_modules/@deepseek-ai/dsh-web-app/package.json -> license: MIT
#   app.asar :: dsh/node_modules/@deepseek-ai/dsh/LICENSE         -> MIT / Copyright (c) 2026 DeepSeek
#   D:\dsh 根目录无 DSH 自身 EULA（只有 electron/chromium/7zip 的第三方许可文本）
Get-ChildItem D:\dsh -Filter *.txt | Select-Object Name
py -c "import pathlib;[print(p.name) for p in pathlib.Path(r'D:\dsh\resources').glob('*') if p.suffix in ('.asar','.txt')]"

# ---------- 3) vivado-mcp：Apache-2.0 + 上游无 NOTICE ----------
py -c "import pathlib;print([l for l in pathlib.Path(r'<vivado-mcp>\site\vivado_mcp-0.3.26.dist-info\METADATA').read_text(encoding='utf-8').splitlines() if l.startswith(('Name:','Version:','License-Expression:','Project-URL: Repository','Requires-Python:'))])"
node <github-account 技能目录>/scripts/gh.mjs api GET /repos/mapleleavessssssss-wq/vivado-mcp/license
node <github-account 技能目录>/scripts/gh.mjs api GET /repos/mapleleavessssssss-wq/vivado-mcp/contents   # 根目录无 NOTICE

# ---------- 4) 本 kit 的履行物是否在位 ----------
py -c "import hashlib,pathlib;b=pathlib.Path(r'<kit>\patches\vivado-mcp\LICENSE-APACHE-2.0.txt').read_bytes();print(len(b),hashlib.sha256(b).hexdigest())"
Select-String -Path <kit>\NOTICE -Pattern 'Copyright \(c\) 2026 (Advanced Micro Devices|DeepSeek)'
```

> 复核时注意：本机 `git`、`node`、`py` 都在 PATH；`gh.mjs` 走的通道是 SSH/直连，与许可无关。
> Windows 的 MSYS bash 会把 `/repos/...` 当路径改写，跑 `gh.mjs api` 前先 `export MSYS_NO_PATHCONV=1`。
