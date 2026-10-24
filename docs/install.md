# dsh-vivado 安装 / 卸载 / 回退说明书

> 面向对象：**拿到本包的使用者（`git clone` 或下载 zip 后运行 `install.ps1`）**。
> 一句话：**一条命令装，然后重启 DeepSeek Harness**；不生效就照「故障排查」逐条看。
> 本文只讲 install.ps1 / uninstall.ps1 的行为与判据；环境体检见 `docs/doctor-checks.md`，包内容/来源见 `README.md` / `NOTICE`。

---

## 0. 先记住三条

1. **装完必须重启 DeepSeek Harness**（Electron 宿主，`dsh-hmr` 不生效）。重启后**新建会话**，在预设里选 `Vivado`。
2. 安装器**只改两处**：把 bundle 复制到 `<DSH_HOME>\bundles\dsh-vivado\`，再在 profile 的 `package.json` 里加**一行依赖 + 一个 bundle 名**。
   它**不会**写 `<DSH_HOME>\skills`，**不会**动你已有的任何 plugin 行，**不需要管理员权限**，**不改注册表 / 不改 PATH / 不 setx**。
3. 改 profile 之前先备份成 `*.bak-<yyyyMMdd>`；装完/卸载完都会把**逐行回退命令**打出来。

---

## 1. 安装

### 1.1 最短路径（本机已装 DSH、已有 profile）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

默认值：`-Profile desktop`、`-DshHome %USERPROFILE%\.dsh`（或 `$env:DSH_HOME`）、`-Mode auto`、`-Config` 取本包 `config.yml`（没有就用 `config.example.yml`）。
目标机是另一套环境时，把 `-Config <你的 config.yml>`、`-DshHome`、`-Profile` 传进去即可：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Config .\config.my.yml -DshHome D:\dsh-home -Profile work
```

### 1.2 参数表

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Config <路径>` | `config.yml`，没有则 `config.example.yml` | 环境配置（扁平 `key: value`，见 §2） |
| `-Profile <名字>` | `desktop` | 要装的 profile 名；**必须已存在**（`<DSH_HOME>\profiles\<名字>\package.json`） |
| `-DshHome <路径>` | `$env:DSH_HOME`，否则 `%USERPROFILE%\.dsh` | DSH 配置根 |
| `-InstallDir <路径>` | 自动发现 | DSH 安装根（含 `DeepSeek Harness.exe`）；一般不用传 |
| `-StageDir <路径>` | `<DSH_HOME>\bundles\dsh-vivado` | bundle 落地目录；**必须纯 ASCII** |
| `-Mode auto\|cli\|manual` | `auto` | `auto`=先官方 CLI、失败自动降级 `manual`；`cli`=只用官方 CLI（失败即报错）；`manual`=完全不用 pnpm |
| `-Part <器件>` | 取 config | 覆盖 `part`（例如 `xc7a35tftg256-1`） |
| `-SkipCompatibility` | 关 | 不动 `compatibility.json`（**代价见 §4**） |
| `-RenderOnly` | 关 | 只做「复制 + 渲染补丁」就停，不碰 profile（给排障/打包用） |
| `-WhatIf` | 关 | 只打印计划，**一个字节都不改** |
| `-NonInteractive` | 关 | 不交互：该问的值没给就直接失败并给一句修法 |

### 1.3 安装器做的 9 步（每步都有 `[STEP]` 行，改文件的地方会打印**实际执行的命令**）

1. **读配置**：定位 `-Config`；`-Part` 覆盖 `part`。
2. **自动探测**（只补「缺的/明显错的」，不覆盖你已经写对的值）：
   - `vivado_path`：在 `D:\Xilinx`、`C:\Xilinx`、`E:\Xilinx`、`%ProgramFiles%\Xilinx`（及各自的 `Vivado\` 子目录）里找 `<版本>\bin\vivado.bat`，**不做全盘扫描**；优先匹配 `vivado_version`。
   - `vivado_version`：取上面找到的版本目录名；没有就从 `vivado_path` 的父目录名推。
   - `python`：`py -3 -c "import sys;print(sys.executable)"`，再 `where python`。
   - `vivado_mcp_site`：从 python 路径推 `<venv>\..\..\site` / `<venv>\..\site`，再试 `<vivado-mcp>\site`、`C:\vivado-mcp\site`；命中要求目录存在。
   - `project_root` / `vivado_mcp_cwd` / `temp_dir` 为空才补（`project_root` 取当前目录，另两个从它派生）。
   - `part` 仍为空：`-NonInteractive` 直接失败并给一句修法；否则 `Read-Host`（默认值取 `config.example.yml` 的 part）。
   - **ASCII 守卫**：`-StageDir`、`skills`、`project_root`、`vivado_mcp_cwd`、`temp_dir` 只要含非 ASCII 字符就**立刻失败**并给修法（Vivado 的 Tcl 层会因此出错）。
3. **检查 profile 存在**（不存在 → 失败并列出 `<DSH_HOME>\profiles` 下现有的 profile）。
4. **复制到 staging**（`robocopy`）：排除 `cordis.patch.yml`、`config.yml`、`*.bak-*`、`.tmp*`、`KIT-SPEC.md`、`.git*`、`node_modules`。**可重复执行**（增量覆盖，不删已有文件）。
5. **落配置**：把「这次实际用的值」写成 `<StageDir>\config.yml`。**每次都重写**（staging 是派生物）——所以第二次换 `-Config` 不会再沿用上一轮的值（这曾是一个真 bug，见 §9）。
   若你显式传了 `-Config` 且探测改动了值，安装器会把探测值写回**你给的那个文件**，并先备份成 `<文件>.bak-<yyyyMMdd>`。
6. **渲染补丁**：在 staging 里跑 `tools\render_patch.ps1`，产出 `<StageDir>\cordis.patch.yml`（所有绝对路径都指向 staging）。
   打印的渲染命令原文形如：
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <StageDir>\tools\render_patch.ps1
       -ConfigPath <StageDir>\config.yml -OutFile <StageDir>\cordis.patch.yml -BundleDir <StageDir>
   ```
7. **备份 + 装 bundle**：
   - 备份 `<profile>\package.json`、`<profile>\pnpm-lock.yaml`（需要时还有 `compatibility.json`）为 `*.bak-<yyyyMMdd>`；**已存在就保留最早那份**（所以备份始终是「装之前」的原件）。
   - `-Mode cli`：`"<install>\resources\runtime\cli\bin\dsh.cmd" plugin --profile <p> add "link:<StageDir>"`（内部用 DSH 自带的 pnpm）。成功后 pnpm 在 `dependencies` 里写 `"dsh-vivado": "link:<StageDir>"`，CLI 的 reconcile 再把它追加到 `dsh.profile.bundles`。
   - `-Mode manual`：**不开 pnpm**，就地改 `package.json`（保留原有缩进/换行/键序，只插两行），然后用 `cmd /c mklink /J` 建 `node_modules\dsh-vivado` 目录联接（junction 不需要管理员；`mklink /D` 兜底，再不行才 `Copy-Item -Recurse`）。
     写文件前会**先用 `ConvertFrom-Json` 重新解析**并校验「两行都在、其余行一字未变」，不合格就一个字节都不写。
   - `-Mode auto`：CLI 失败（非 0 退出）→ 打印 CLI 的 stderr 尾巴（含它自己的 `Log file:` 路径）→ **回滚到备份** → 改走 `manual`。
8. **验证**：`dsh --profile <p> --dump-config`，断言 4 条标记（见 §5），逐条打印 PASS/FAIL 与**命中行号**。FAIL 时保留备份并打印回退命令，退出码 1。
9. **收尾大写字块**：重启要求、备份清单、逐行回退命令、以及「没有往 `~/.dsh/skills` 写任何文件」。

### 1.4 幂等

同一份 config 再跑一次：staging 增量刷新、补丁 hash 不变、profile 两行已指向 staging →
打印 `already installed (refreshed)`，**不备份、不调 CLI、不改 profile**（`package.json` 的 sha256 前后一致）。
连 `pnpm-lock.yaml` 也不会动。

---

## 2. `config.yml`（扁平 `key: value`，不需要 YAML 模块）

```yaml
part: xcku060-ffva1156-2-i          # 器件
project_root: D:/fpga_project               # 工程根（Vivado cwd，必须 ASCII）
vivado_version: 2023.1              # 决定 persona 版本分档（<2025.2 → 2023.1 档）
vivado_path: D:/Xilinx/Vivado/2023.1/bin   # 含 vivado.bat 的 bin 目录
python: <vivado-mcp>/venv/Scripts/python.exe
vivado_mcp_site: <vivado-mcp>/site        # PYTHONPATH
vivado_mcp_cwd: D:/fpga_project                    # MCP server 的 cwd（必须 ASCII）
temp_dir: D:/fpga_project/.tmp                     # TEMP/TMP（必须 ASCII）
```

规则：`#` 之后是注释；空行忽略；未知键原样保留；值里 `\` 或 `/` 都行（渲染时统一成 `/`）。
**所有路径必须是 ASCII**——这是硬约束，不是建议。

---

## 3. 安装到底改了什么（可核对的最小事实）

```text
<DSH_HOME>\bundles\dsh-vivado\           ← 新增（staging = bundle 本体，含 skills/、templates/、tools/、docs/）
<profile>\package.json                       ← dependencies 多一行 + dsh.profile.bundles 末尾多一项
<profile>\pnpm-lock.yaml                     ← 仅 -Mode cli 下由 pnpm 改写（-Mode manual 不动）
<profile>\compatibility.json                 ← 仅当需要版本豁免时合并一个键（见 §4）
<profile>\node_modules\dsh-vivado ← 指向 staging 的目录联接
<profile>\cordis.patch.yml                  ← **安装器不碰**（预设由 bundle 层自己提供）
<DSH_HOME>\skills\**                         ← **安装器不写**
```

卸载就是把这些**逐一撤掉**，别的什么都不动。

---

## 4. `compatibility.json`：mcp-vivado 行的版本豁免

`<profile>\compatibility.json` 是一张「版本豁免表」：`"<包>@<装的版本>": ["<允许的 dsh 版本>", ...]`。

当 profile 里 `node_modules\@deepseek-ai\dsh-mcp-client\package.json` 的版本 **≠** 运行时版本时（本机实测：`0.1.7-rc.2` vs `0.2.1-rc.2`），需要这条豁免，否则会话加载时 `mcp-vivado` 那行会被丢掉 —— 预设就没有那 32 个 MCP 工具了。

安装器会：

1. 读**运行时版本**：优先 `dsh.cmd --version` 的输出（正则取 `\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?`，本机 `0.2.1-rc.2`，约 0.35 s）；
   拿不到才退到 `DeepSeek Harness.exe` 的 `VersionInfo.FileVersion`；**优先不用 `ProductVersion`**（它是 `0.2.1.0`，把 `-rc.2` 后缀丢了，写成它会写坏这张表）——`FileVersion` 也拿不到时才作最后兜底，并在日志里 WARN 说明来源。
2. 读 profile 实际装的 mcp-client 版本。
3. 两者不同且表里没有该键 → **先备份** `compatibility.json.bak-<yyyyMMdd>`，再**只合并**这一个键（其余键、其余允许版本原样保留），写成 2 空格缩进的 JSON。

两种写法都对（安装器只加自己那一条）：

```json
{}
```

```json
{
  "@deepseek-ai/dsh-mcp-client@0.1.7-rc.2": ["0.2.1-rc.2"]
}
```

**`-SkipCompatibility` 的代价**：不改这张表。如果 profile 本来就缺这条豁免，`mcp-vivado` 行会在会话加载时被丢掉（工具面少 32 个），而**安装器的 4 条 dump-config 判据依然会全 PASS**——因为 `--dump-config` **不校验** `compatibility.json`（实测：把它清空成 `{}`、甚至写成非法 JSON，dump 输出逐字节相同、退出码 0）。所以：
> 不想要 MCP 工具 或 你自己的 profile 已有一条等效豁免 → 可以加 `-SkipCompatibility`；否则**别加**。
> 这条豁免是否就位，由 `doctor.ps1` 单独判定（它直接读 `compatibility.json`，不依赖 dump-config）。

---

## 5. 验证判据（`dsh --profile <p> --dump-config`）

装完（以及卸载完）安装器自己会跑一遍，判据是「**命中 + 段落归属**」，**不写死行号**：

| # | 判据 | 装好的样子（本机 2026-10-24 实测） | 卸载后 |
|---|---|---|---|
| 1 | bundle 层横幅，必须在行首 | `# == dsh-vivado` @ 1518 | 0 次 |
| 2 | 预设行 | `- id: preset-vivado` @ 1519 | 0 次 |
| 3 | 技能挂载：`customSkillDirs` 且路径必须是 **staging 的 `skills`** | `customSkillDirs:` @ 1648 → `- <StageDir>/skills` @ 1649（另有 1303 行是别的 bundle 自带的行，与本包无关） | 0 次 |
| 4 | MCP 行，**必须缩进**（=嵌套在预设的 plugin 列表里，不是漏到 profile 层） | `      - id: mcp-vivado` @ 1780 | 0 次 |

基线（未装）1517 行 → 装好 1800 行（+283 行），退出码 0、stderr 为空。

手工复核（cmd/PowerShell 都行）：

```powershell
$env:DSH_HOME = "$env:USERPROFILE\.dsh"
& "<install>\resources\runtime\cli\bin\dsh.cmd" --profile desktop --dump-config | Select-String 'preset-vivado|mcp-vivado|dsh-vivado|customSkillDirs'
```

> 提示：`--dump-config` 只是「组合快照」，它证明配置合成了；**真正能不能用**（Vivado 在不在、Python/MCP 能不能起、器件库有没有这个 part）由 `doctor.ps1` 判定，再由一个真实会话验证 `start_session` / `xdc_lint`。

---

## 6. 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

参数与安装器同签名（`-Config` / `-Part` / `-SkipCompatibility` 只接受不使用，保持命令可复制粘贴），去掉 `-RenderOnly`，多一个 `-KeepStage`（保留 staging 目录，只清 profile）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -DshHome D:\dsh-home -Profile work -KeepStage
```

顺序（有讲究）：

1. **先摘 profile 两行**：`-Mode cli`（默认）先跑
   `"<dsh.cmd>" plugin --profile <p> remove "dsh-vivado"`
   —— pnpm 会把依赖行清掉、CLI 的 reconcile 把 `dsh.profile.bundles` 里的名字摘掉（实测两者都干净）。
   若 pnpm 报 `ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS`（依赖已不在）→ **当成「已摘除」的幂等成功**，不是失败。
   pnpm 不可用 / 失败 / 有残留行 → 走下面的「还原规则」就地删。
2. **再删 `node_modules\dsh-vivado`**：**必须显式删**，因为 pnpm remove 之后这个 **junction 会残留**（目标目录还在时 pnpm 不删它）。
   删法只用 `[System.IO.Directory]::Delete($link, $false)`（只删重解析点），失败再退 `cmd /c rmdir "<link>"`；
   **不用 `Remove-Item -Recurse`**（PS 5.1 对 junction 递归可能穿透进 staging 把目标内容连带删坏）。
3. **再删 staging 目录**（`-KeepStage` 时跳过）。删除前会核对该目录的 `package.json.name` 是不是本包，或目录是否为空；不像本包就**只警告不删**。
4. **验证消失**：`--dump-config` 里 4 条标记都必须 **0 次**（含 `dsh-vivado`、`preset-vivado`、`mcp-vivado`、staging 路径）。
5. 打印重启要求 + 保留下来的备份清单。

**幂等**：第二次跑会直接 `nothing to remove: ...` 退出码 0。

### 6.1 还原规则（`package.json` / `pnpm-lock.yaml` 是同一套规则）

`<profile>\package.json.bak-<yyyyMMdd>` 是**第一次安装之前**的原件（后续重装不会覆盖它）。卸载时：

1. 若备份存在，且**当前文件「只差本包那两行」**（去掉本包的依赖行与 bundles 项后，与备份**按 JSON 语义完全相等**）→ **把备份逐字节复制回去**（连换行风格也还原 —— 实测 pnpm 会把 CRLF 改写成 LF，所以这一步是必要的）。
2. 否则（备份之后还有别的改动，例如你自己又装/删过别的插件）→ **只就地删本包那两行**，其余行**原样保留**，并提示「备份保留了但没还原」。
3. `pnpm-lock.yaml`：同样的「只差本包」判定，成立就从备份还原；不成立就**保持现状**（它因为别的原因变过，不能拿旧备份盖掉）。
4. `compatibility.json`：**不还原**。那条豁免是「包@版本 → 允许的 dsh 版本」级别的，与某个 bundle 无关；别的 MCP server 可能正需要它。卸载后它继续留着是无害的。

> 为什么不是「一律还原备份」：备份只代表第一次安装前的状态；如果用户后来自己动过 profile，一律还原等于**回滚别人的改动**。
> 为什么不是「一律就地删」：那样换行/格式会留下 pnpm 的改写痕迹，达不到「卸载后与装之前一致」。

---

## 7. 回退（逐行命令）

安装器失败/验证 FAIL 时会把下面几行按你机器上的真实路径打出来，直接抄：

```bat
REM 1) 用卸载器最省事（推荐）
powershell -NoProfile -ExecutionPolicy Bypass -File "<本包>\uninstall.ps1" -DshHome "<DSH_HOME>" -Profile <profile>

REM 2) 或者手工逐行：
copy /Y "<profile>\package.json.bak-20261024"    "<profile>\package.json"
copy /Y "<profile>\pnpm-lock.yaml.bak-20261024"  "<profile>\pnpm-lock.yaml"
REM    再从 "<profile>\package.json" 的 dsh.profile.bundles 里删掉 "dsh-vivado"
rmdir /S /Q "<DSH_HOME>\bundles\dsh-vivado"
REM 3) 重启 DeepSeek Harness
```

`-WhatIf` 只打印计划、**不改任何字节**（实测 5 个关键文件 hash 前后一致，且不产生新备份）。

---

## 8. 故障排查（按你看到的行找）

| 现象 | 原因 | 修法 |
|---|---|---|
| `part is empty: pass -Part ...` | config 里没 `part` 且 `-NonInteractive` | 加 `-Part xc7a35tftg256-1` 或写进 config.yml |
| `profile package.json not found` | `-Profile`/`-DshHome` 不对，或该 profile 还没初始化 | 用 `<DSH_HOME>\profiles` 下已有的名字；先在该 profile 里开过一次会话 |
| `... is not ASCII` | 路径含中文 | 把 `-StageDir` 指到 ASCII 目录；`project_root`/`temp_dir`/`vivado_mcp_cwd` 改 ASCII |
| `config is missing required values: python,...` | 自动探测也没找到 | 手写 `python:` / `vivado_mcp_site:` 到 config.yml |
| `official CLI install failed (exit N)` 后接 `falling back to the manual install path` | pnpm/网络/权限问题 | 看它打的 stderr 尾巴与 `Log file:`；结果已用 manual 装上，属正常降级。想强制复现 CLI 路径：`-Mode cli` |
| 安装最后 `verification failed: N of 4 markers missing` | bundle 没进组合 | 保留备份，先跑 `uninstall.ps1` 再装；仍失败把 dump 里的 `# == dsh-vivado` 附近贴出来 |
| 装完重启后**没有 `Vivado` 预设** | 没重启 / 重启的不是这个 `DSH_HOME` / profile 不是装的那个 | 确认宿主用的 `DSH_HOME`；重启；在新建会话的预设列表里找 `Vivado` |
| 预设里**工具少 32 个**（没有 `mcp__vivado__*`） | 缺 `compatibility.json` 豁免 或 `python`/`vivado_mcp_site` 不对 | 重跑 install.ps1（别加 `-SkipCompatibility`）；再跑 `doctor.ps1` 看 Python/import/MCP 三项 |
| `compatibility.json is not valid JSON, leaving it alone` | 该文件被手工改坏 | 改成 `{}` 后重跑安装器（它会合并正确的那一条），或删掉该文件再重跑 |

日志：安装/卸载**只往 stdout 打**（`[INFO]/[STEP]/[PASS]/[WARN]/[FAIL]`），不会在包里留 transcript。想留证据就自己重定向：`... > install.log 2>&1`。

---

## 9. 已知限制 / 设计取舍

1. **staging 是增量复制**（`robocopy /E`，不 `/PURGE`）：升级到新版本包时，上一版里有、新版里已删除的文件会残留在 staging 里（不会影响补丁，因为补丁每次重渲染）。要绝对干净：先 `uninstall.ps1` 再 `install.ps1`。
2. **`-Mode manual` 的 `Copy-Item` 兜底**：极端情况下（junction/symlink 都被策略禁掉）bundle 会被**复制**进 `node_modules`，此时后续重装不会刷新那份副本（日志会明确 WARN）。正常 Windows 上走 junction。
3. **`config.yml` 落点**：安装器把「实际使用的值」写到 `<StageDir>\config.yml`（staging 是派生物，每次都重写）；**不会**擅自改本包里的 `config.example.yml`。显式传 `-Config` 且探测改动了值时才回写你那个文件（先备份）。
4. **`--dump-config` 不校验 `compatibility.json`**（§4）：所以安装器的 4 条判据不能替代 doctor 的 MCP 检查。
5. **`-SkipCompatibility` 的取舍**（§4）。
6. **卸载不动 `compatibility.json`**（§6.1 第 4 条）。
7. 安装器**不打包 Vivado 本体/许可证**，不代签 AMD 协议，不改 `<vivado-mcp>\site` 的第三方源码。
8. 本机实测环境：Windows 10.0.26200 / `powershell.exe` **5.1.26100** / DSH **0.2.1-rc.2**（`D:\dsh`）/ 探针 `DSH_HOME=<tmp>\dshprobe-home`，profile `probe`。**所有命令都用 `powershell.exe`(5.1) 跑过，未使用 `pwsh`。**
