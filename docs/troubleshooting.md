# 排错手册 — 出问题怎么查

> 读者：装完本包、准备用 `Vivado` 预设干活的用户。安装参数与文件落点见 [install 详解](install.md)，每项检查的判据与证据见 [doctor 详解](doctor-checks.md)，内部实现见 [架构说明](architecture.md)。
>
> **读法（公开版）**：`<kit>` = 本包根目录；`<DSH_HOME>` = DSH 配置根（默认 `%USERPROFILE%\.dsh`）；`<profile>` = 目标 profile 名（默认 `desktop`）；`<staging>` = `<DSH_HOME>\bundles\dsh-vivado`；`<install>` = DSH 安装根（含 `DeepSeek Harness.exe`）；`<vivado-mcp>` = vivado-mcp 安装目录（`<vivado-mcp>\site` 是它的 Python 包目录）；`<python>` = `config.yml` 里那个 ≥3.10 的解释器。命令里的尖括号要换成你的真实路径。

## 1. 三条铁律（先看，能省掉 90% 的"装了没用"）

1. **装完必须重启 DeepSeek Harness。** 配置只在宿主启动时读，Electron 宿主下 `dsh-hmr` 实测不生效。不遵守的症状：一切装好了，新会话的预设列表里**没有 `Vivado`**。
   > 补充（2026-10-24 实测）：用会话内 `plugin_manager` 热装/热卸/反复重载 bundle 时，**静态内容**（预设、persona、技能挂载）能即时生效，但 **MCP 子进程不一定重新拉起**——见 §2.11。
2. **所有 Vivado 相关路径必须纯 ASCII**（工程根、会话 cwd、`TEMP` / `TMP`、`<vivado-mcp>`、`<staging>`）。Vivado 的 Tcl 层按 GBK 解码路径（[doctor 详解](doctor-checks.md) §5）。不遵守的症状：`start_session` 起不来（常见报"Vivado GUI 进程提前退出"），或 Tcl 在 `open_project` / `write_*` 阶段报 `File not found` / 乱码。
3. **Vivado 全局串行**：同一时刻只允许一个 Vivado 进程。不遵守的症状：`start_session` 卡住或失败、`run_*` 排队到超时；先 `tasklist | grep -i vivado` 确认干净再动手。

## 2. 症状 → 原因 → 修法

### 2.1 重启后仍没有 `Vivado` 预设

- 原因：① 没重启；② profile 选错；③ bundle 没装进 profile；④ 宿主用的 `DSH_HOME` 不是你装的那个。
- 修法：先跑体检，第 9/10 项会直接点名是"没装"还是"渲染没做"。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Json
# 组合快照里找预设行；0 命中说明 bundle 没进组合
& "<install>\resources\runtime\cli\bin\dsh.cmd" --profile desktop --dump-config |
  Select-String 'preset-vivado|dsh-vivado|customSkillDirs'
```
再核对 profile 的两行（读法见 §4 第 3 条）：缺一 → 重跑 `install.ps1 -Profile <profile>`；两行都在但 dump 里 0 命中 → 确认宿主实际用的 `DSH_HOME`，然后重启。

### 2.2 预设出现了，但没有 `mcp__vivado__*` 工具（应为 32 个）

- 原因（最常见）：profile 的 `compatibility.json` 缺 `@deepseek-ai/dsh-mcp-client` 版本豁免，DSH 在会话加载时**静默丢掉** `mcp-vivado` 行——预设还在，工具没了。其次是 `<python>` / `vivado_mcp_site` 配错。
- 修法：重跑安装器（**不要**加 `-SkipCompatibility`，它正是负责合并这条豁免），然后重启；再跑 doctor 看第 6/7/12 项。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile <profile>
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
```
判据是"**+32**"，不是工具总数：总数随 DSH 版本变，别拿旧文档的绝对数当标准（doctor 第 7 项就是按 32 判的）。另外确认这个会话用的确实是 `Vivado` 预设——`standard` 会话**没有**这些工具，这是设计。

### 2.11 预设、技能都正常，但一个 `mcp__vivado__*` 工具都没有（`doctor` 第 7 项却是 32）

- 现象：`Vivado` 预设存在、persona 与 8 个技能都正常，工具数却是 **0**；`doctor.ps1` 第 6/7/12 项全 PASS；
  `py <vivado-mcp>\mcp_ctl.py list` 也正常给 32 行 —— 看起来"什么都好"，就是没有工具。
- 最常见原因（2026-10-24 亲历）：**MCP 行的 `cwd` / `TEMP` / `TMP` 指向一个不存在的目录**。
  这三项来自 `config.yml` 的 `project_root` / `vivado_mcp_cwd` / `temp_dir`；stdio 子进程在不存在的 `cwd`
  下根本起不来，而本行是 `failOnStartupError: false` ⇒ **失败静默**，会话就只剩"没有工具"这一个症状。
  典型触发：把 `config.example.yml` 里的示例路径（如 `D:/fpga_project`）原样拿去渲染。
- 判据：`doctor.ps1` 第 5 项（`ascii-paths`）会直接点名 `path does not exist: project_root=...`；
  `install.ps1` 现在也在渲染前拦下（`temp_dir` 缺失会自动创建，另两个直接 FAIL 并给修法）。
  手工复核：`Get-Content <staging>\cordis.patch.yml | Select-String "cwd:|TEMP:"`，再用 `Test-Path` 逐个验。
- 修法：把那三个键指到**真实存在**的纯 ASCII 目录（`temp_dir` 可以不存在，安装器会建）→ 重跑 `install.ps1`
  （它会重新渲染；重装时默认复用上一次写进 staging 的 `config.yml`，不会再退回示例值）→ 重启宿主。
- 次因：用会话内 `plugin_manager` 反复热装/热卸之后，MCP 行有时不会重新拉起子进程（判据：`Get-Process python*`
  里没有新的 `-m vivado_mcp`）——这种情况重启宿主即可，且**不影响**上面的路径判据。

### 2.3 `start_session` 失败

- 原因：几乎都是非 ASCII 路径（工程根 / 会话 cwd / `TEMP` / `TMP` / `<vivado-mcp>`）；少数是 `PYTHONPATH` 指错，`import vivado_mcp` 导到了另一份副本——MCP 行上这两条硬约束的来历见 `templates/preset.patch.yml.tmpl:145-149`。
- 修法：doctor 第 5 项会点名是哪个键、哪个值含非 ASCII；第 6 项会指出 `__file__` 是否落在 `vivado_mcp_site` 之下。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 | Select-String 'ascii-paths|mcp-import'
```
把冒犯的路径换成同盘的纯 ASCII 目录（改 `config.yml` 后重跑 `install.ps1`），再重启。

### 2.4 工具"说成功"，但正文里全是 `[ERROR]`

- 原因：MCP 协议的 `is_error` 只反映传输层是否失败，Vivado 的业务失败仍会带着 `is_error: false` 返回。
- 修法：**判据看文本，不看 `is_error`**：正文出现 `[ERROR]` / `CRITICAL WARNING` 就是失败。这条已写进预设纪律（persona 的 "Every conclusion must carry evidence" 那条）。看到 `[ERROR]` 就把那一行连同错误码（`[Common 17-xxx]` / `[Vivado 12-xxx]`）贴回来，按码查，不要当成功继续。

### 2.5 会话里 `pwsh` 报 `unknown tool "pwsh"`

- 原因（2026-10-25 更正）：这**不是** DSH 的缺陷，而是装了**第三方 shell 插件**之后的事（`dsh-win-bash` 一类，`replacePwsh: true` 会在会话中途把官方 `pwsh` 从工具面摘掉）。本包不依赖任何第三方 shell；出现这条错误说明是别的插件在改工具面。
- 修法：
  1. 报一次就别再重试同名工具，换会话里**仍然在**的 shell（官方 `pwsh` / `bash`），或直接走 `mcp__vivado__*`；
  2. 想根治：卸载或禁用那个第三方 shell 插件再重启宿主，官方 `pwsh` 会回来；保持它禁用也完全不影响本包（本包脚本都是 `powershell -NoProfile -File ...`）；
  3. 会话里一个 shell 都没有时，把要跑的命令写成脚本文件交给用户执行，不要凭空 exec。
- 本包的立场：**不被动适配别人开发的插件**。预设只保证「会话里有什么 shell 就用什么」；`win_bash` 之类的常驻 shell 是可选加速件，不是前提。

### 2.6 一次 `run_tcl` 吐掉几千 tokens（`open_run` / `open_project` 尤甚）

- 原因：`run_tcl` 原样返回 stdout，不裁剪；一次 `open_project` 的进度输出就能到约 8k tokens（persona 的 "`run_tcl` returns raw stdout" 那条）。
- 修法：优先用 `report_*` / `get_run_progress` 这类有界的工具；必须跑大段 Tcl 时，在 Tcl 里把输出重定向到文件，再只读文件尾部；打了 §2.7 的补丁后可显式传 `max_lines` / `save_full_to`。

### 2.7 `xdc_lint` / `get_cdc_report` 明细被截断

- 原因：上游默认裁剪——`xdc_lint` 默认 `max_items=20`、`get_cdc_report` 默认 `max_details=100`，大工程会静默少给你要修的那几条（`NOTICE` §2.1）。
- 修法二选一：显式传 `max_items=0` / `max_details=0`（0 = 全量）；或按 `patches/vivado-mcp/README.md` §4 打上 4 个补丁，之后默认就是全量。
```powershell
# 在 <vivado-mcp>\site 目录下执行；必须带 core.autocrlf=false
git -c core.autocrlf=false apply -p1 "<kit>\patches\vivado-mcp\0001-tcl-max-lines-and-safe-tcl-hint.patch"
git -c core.autocrlf=false apply -p1 "<kit>\patches\vivado-mcp\0002-xdc-lint-aggregate-and-default-full.patch"
git -c core.autocrlf=false apply -p1 "<kit>\patches\vivado-mcp\0003-xdc-lint-tool-default-full.patch"
git -c core.autocrlf=false apply -p1 "<kit>\patches\vivado-mcp\0004-get-cdc-report-default-full.patch"
```
打完用 doctor 第 11 项复核（它按源码内容探针判，不看 mtime）。

### 2.8 `dsh plugin add` 阶段报错（pnpm / store / 网络类）

- 原因：官方 CLI 走随包 pnpm，具体错误（网络、缓存、权限、profile 状态）以它的 stderr 与日志为准，本手册不替 pnpm 归类。
- 修法：安装器已经打了你需要的信息——先看 `official CLI install failed (exit N)` 后面那两行 `CLI stderr tail:` 与 `CLI log:`，日志文件就在那个路径（`install.ps1:506-509`）。`-Mode auto`（默认）失败时会自动回滚并改用 `manual`（不碰 pnpm），所以**装完能用**就不必深究；要强制复现或强制绕过：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile <profile> -Mode cli     # 只用 CLI，失败即致命
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile <profile> -Mode manual  # 完全不碰 pnpm
```
卸载时若看到 `ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS`，那是**已摘除**的幂等成功，不是失败（`docs/install.md:194`）。

### 2.9 profile 被改坏（或安装中断）怎么回滚

- 原因：手工改过 `package.json` / 安装中途失败 / 装完想退干净。
- 修法：优先用卸载器，它按"只差本包那两行"的规则决定「用备份还原」还是「就地删本包两行」，不会回滚你后来自己做的改动（`docs/install.md:205-215`）。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Profile <profile>
# 然后重启宿主
```
脚本不可用时走 §5 的四步手工回退。

### 2.10 卸载后 `node_modules\dsh-vivado` 还残留（junction）

- 原因：pnpm remove 只清依赖行，**不删 junction**（目标目录还在时它不删这个重解析点）。
- 修法：卸载器会显式删它；手工清理只能用删重解析点的方式，**不要**用递归删除——PS 5.1 对 junction 递归会穿透进 staging，把目标内容一起删坏（`docs/install.md:196-198`）。
```powershell
cmd /c rmdir "<profile>\node_modules\dsh-vivado"
```

### 2.12 `vivado.bat` 起不来，或"exit 1 且零输出"

- 现象（2026-10-24 实测）：`& vivado.bat -version`、bash 里的 `cmd //c "..."`、pwsh 里的 `cmd /c "<带引号整串>"` 全都返回 exit 1 且**零字节输出**；`Start-Process -ArgumentList '/c', <带引号整串>` 会让 cmd 收到二次套引号，报 `The filename, directory name, or volume label syntax is incorrect.`
- 判据：`exit != 0` 且输出 0 字节 = **启动失败**，不是"没问题"；`vivado.bat -version` **不是**探针（rdiArgs → prodversion → `exit /b 1`，重定向后什么都不打）。
- 唯一稳定配方（本包已封装，别手写）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\vivado-probe.ps1              # 探活：只认 PROBE_RESULT=OK
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\vivado-run.ps1 -Source .\x.tcl   # 跑 batch
```

- 参数：`-VivadoBat <path>` 指向别的安装；`-KeepFiles` 保留 tcl/log/journal/console 作证据。脚本打印的 `PROBE_*` / `RUN_*` 行就是证据，求助时贴这些行。
- 为什么不用 `Start-Process -PassThru` 判退出码：Windows PowerShell 5.1 下对 `.bat` 拿到的 Process 对象 `ExitCode` 是 `$null`（2026-10-25 实测：进程已正常 `Exiting Vivado`，`ExitCode` 仍为空）。所以本包脚本让 cmd 自己把 `%ERRORLEVEL%` 写进 `build_status.txt`，再读回来。

### 2.13 长构建跑到一半没了（回合结束被回收，或收到 `^C`）

- 现象 A：`run_in_background` 起的综合/实现，在下一条用户消息后消失（`job_output` 报 `unknown job`，`tasklist` 里也没有 Vivado）。原因：会话后台作业随回合中断被回收。
- 现象 B：已经脱离进程树的构建被外部 `^C` 打断（本机一次实现段跑 34 min 被作废，只能重跑）。
- 修法：
  1. 长构建一律脱离：`vivado-run.ps1 -Source <tcl> -Detach` → 返回 `RUN_PID`，进程不在会话进程树里；
  2. 构建 Tcl 顶部 `source <kit>\templates\build-markers.tcl`，关键节点 `kit_mark SYNTH_OK ...`；包装器自己会写 `BUILD_START` / `BUILD_EXIT=<rc>` / `BUILD_FAILED`；
  3. 判进度只认 `build_status.txt` 的标记行 + `-log` 尾部（脱离进程没有工具返回值，标记缺失 = 还在跑或已死，不是成功）；
  4. 分段：synth 后 `write_checkpoint`，实现段可单独重跑（本机 `^C` 后只重跑 34 min，没重做 synth）；
  5. 收尾杀进程：先 `tasklist` 定位 PID 再杀单个，`taskkill /T` 会波及无关子进程。

### 2.14 想先验 Tcl 语法，别再写"tclsh 不可用 → 跳过"

- 事实：Vivado 2023.1 自带 `bin\unwrapped\win64.o\tclsh85t.exe`（Tcl 8.5.14，与工具内的解释器同版本），但直接调会 `0xC0000135`（缺 DLL）——要先加 `<vivado>\lib\win64.o` 到 `PATH`，并设 `TCL_LIBRARY=<vivado>\tps\tcl\tcl8.5`。
- 用本包脚本一次搞定（不启动 Vivado、不动工程）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\tcl-check.ps1 <目录或 .tcl 文件...>
```

- 判据：`TCLCHECK_RESULT=PASS` 才算过；失败会打 `TCLCHECK_TAIL|` 明细行。`complete=1` 是 `info complete` 的结论，只保证"这份文件是完整命令序列"，不保证运行时语义正确。

## 3. `doctor.ps1` 13 项速查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1          # 人读版，13 项全跑
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Json    # 单行 JSON，字段 {id,title,status,detail,fix}
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Quick   # 跳过 3 个慢探针，<10s；被跳过项报 WARN
```

| # | `-Json` id | 检查什么 | 阈值（PASS / WARN / FAIL） | 一句修法 |
|---:|---|---|---|---|
| 1 | `vivado-install` | `<vivado_path>\vivado.bat` 存在且是文件 | 存在=PASS；缺失/不是文件=FAIL | 把 `vivado_path` 指到含 `vivado.bat` 的 bin 目录，重跑 `install.ps1` |
| 2 | `vivado-version` | config 版本能否被证明、且与磁盘一致 | 静态文件或 `-version` 与 config 相等=PASS；只有目录名 / `-Quick` 跳过 / 探针超时空输出=WARN；两个可比值不一致=FAIL | 按探测值改 `vivado_version`（persona 分档依赖它） |
| 3 | `python` | 可跑、≥3.10、UTF-8 探针、patch 里导出 `PYTHONUTF8` | 全过=PASS；仅 patch 缺 `PYTHONUTF8`=WARN；不可跑/低于 3.10/UTF-8 失败=FAIL | 指到 3.10+ 解释器（建议 vivado-mcp 的 venv） |
| 4 | `part` | `part` 在**本机**器件库里 | 索引命中且族目录在=PASS；完全没有 parts 树=WARN；树在但 device 不在=FAIL | 改 `part`（别用教学视频里的 CIV part） |
| 5 | `ascii-paths` | cwd / `TEMP` / `TMP` / `project_root` / `vivado_mcp_cwd` / `temp_dir` 纯 ASCII | 六个都纯 ASCII=PASS；只有 cwd 非 ASCII 或 config 键为空=WARN；`TEMP`/`TMP` 或 3 个 config 键非 ASCII=FAIL | `temp_dir` 指到同盘 ASCII 目录；`TEMP`/`TMP` 在跑 Vivado 前设好 |
| 6 | `mcp-import` | `PYTHONPATH=<site>` 下 `import vivado_mcp`，`__file__` 落在 site 内 | 导入成功且路径在 site 内=PASS；`-Quick` 跳过=WARN；不可导入或解析到 site 之外=FAIL | 改 `vivado_mcp_site`（含 `vivado_mcp\` 包的那层） |
| 7 | `mcp-tools` | `mcp_ctl.py list` 的工具数 | 恰好 **32**=PASS；≠32 但 >0 或 `-Quick` 跳过=WARN；命令失败/超时/0 个=FAIL | 重装 `vivado-mcp==0.3.26` 或修 `python` / `vivado_mcp_site` |
| 8 | `license` | 静态 license 线索（环境变量 / `*.lic`） | 命中线索=PASS；无线索或路径失效=WARN；**永不 FAIL** | 设 `XILINXD_LICENSE_FILE`；失败也照跑（可能来自服务器/评估模式） |
| 9 | `bundle-installed` | 依赖行 + `link:` 目录存在 + `dsh.profile.bundles` | 三者齐=PASS；裸 profile（零痕迹）=WARN；半装/坏装=FAIL | 跑 `install.ps1 -Profile <profile>` |
| 10 | `bundle-rendered` | `<staging>\cordis.patch.yml` 无残留占位符、`customSkillDirs` 目录存在 | 全过=PASS；staging 不存在=WARN；缺失/残留/目录不存在=FAIL | 重跑 `install.ps1`（会重新渲染） |
| 11 | `mcp-patches` | 5 组源码内容标记（4 个补丁是否在位） | 5/5=PASS；有缺失或 site 不可用=WARN；**永不 FAIL** | 按 `patches/vivado-mcp/README.md` §4 打补丁 |
| 12 | `compatibility` | `compatibility.json` 的 mcp-client 版本豁免 | 两版本相等，或键存在且含运行时版本=PASS；缺键/值不含/版本来源不可靠=WARN；**永不 FAIL** | 重跑 `install.ps1`（别加 `-SkipCompatibility`）后重启 |
| 13 | `skills` | 8 个技能目录在场，且 `SKILL.md` 的 `name:` 等于目录名 | 8/8=PASS；staging 不存在=WARN；缺目录/`name` 不符=FAIL | 重装 bundle，或把 `name:` 改成目录名 |

`-Quick` 只跳过 3 个慢探针（Vivado 版本 `-version`、`import vivado_mcp`、`mcp_ctl.py list`），退出码不受 WARN 影响：无 FAIL = `0`，任一 FAIL = `1`。每项的完整判据、证据形态与"为什么只 WARN"见 [doctor 详解](doctor-checks.md)（§14 有一页 WARN 清单）。

## 4. 求助前先把证据收齐

要贴的四样（**别贴 token、license 文件内容、任何密钥**）：

1. `doctor.ps1 -Json` 的整行输出（一行 JSON，13 项齐全，含 `id`/`status`/`detail`/`fix`）；
2. `--dump-config` 里与 kit 有关的那几段：
```powershell
$env:DSH_HOME = "<DSH_HOME>"
& "<install>\resources\runtime\cli\bin\dsh.cmd" --profile <profile> --dump-config |
  Select-String 'preset-vivado|mcp-vivado|dsh-vivado|customSkillDirs'
```
3. `<profile>\package.json` 里与本包有关的两行：`dependencies."dsh-vivado"` 的值，以及 `dsh.profile.bundles` 里有没有 `dsh-vivado`；
4. CLI 失败时的 `Log file:` 路径那一行（安装器会把 CLI 的 stderr 尾巴和日志路径打出来，`install.ps1:506-509`）。

安装日志不留档，需要就把整个过程的 stdout 重定向到文件：`.\install.ps1 ... > install.log 2>&1`（`docs/install.md:253`）。另外说明你的 Vivado 版本档位（`2023.1` 还是 `2025.2+`）——版本相关事实的实测/未实测界线见 [版本分档](version-matrix.md)。

## 5. 回滚四步（脚本不可用时的逐行做法）

```powershell
# ① 先按卸载器走（它会按备份还原或精确删本包两行，并删 staging；细则见 install 详解 §6.1/§7）
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -DshHome "<DSH_HOME>" -Profile <profile>

# ② 脚本不可用时就地还原：用安装前的备份覆盖被改文件（同目录、带日期后缀）
cd "<DSH_HOME>\profiles\<profile>"
Get-ChildItem package.json.bak-* | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Copy-Item .\package.json.bak-<YYYYMMDD> .\package.json -Force

# ③ 删 bundle 本体（staging）
Remove-Item -Recurse -Force "<DSH_HOME>\bundles\dsh-vivado"

# ④ 重启宿主；再确认 profile 的 cordis.patch.yml 不是本包改的（本包从不改它）
```
