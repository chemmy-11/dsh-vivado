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

### 2.11 热更新过 bundle 之后，新会话一个 `mcp__vivado__*` 都没有（但 doctor 第 7 项仍是 32）

- 现象：`Vivado` 预设还在、persona 与 8 个技能都正常，但工具数是 **0**（不是 32）；`doctor.ps1` 第 6/7/12 项却全 PASS；`py <vivado-mcp>\mcp_ctl.py list` 也正常给 32 行。
- 原因：MCP 客户端行在**宿主内热重载**（`install_bundle` / `remove_bundle` / `set_bundle` 开关 / 多次重写 staging）之后没有重新拉起 stdio 子进程。判据：`Get-Process python*` 里**看不到** `-m vivado_mcp` 进程（或只剩旧的、启动时间早于本次改动），而新会话工具数为 0。
- 修法：**重启宿主**。重启后再看两处：`doctor.ps1`（应 12 PASS / 1 WARN）+ 新 `Vivado` 会话问一句"列出你工具清单里所有 `mcp__vivado__*`"（应为 32）。
- 为什么文档一直强调"改 bundle 内容就重启"：静态行能热切，**子进程不行**；把它当铁律可以省掉一整类"装了半天没工具"的误判。

### 2.3 `start_session` 失败

- 原因：几乎都是非 ASCII 路径（工程根 / 会话 cwd / `TEMP` / `TMP` / `<vivado-mcp>`）；少数是 `PYTHONPATH` 指错，`import vivado_mcp` 导到了另一份副本——MCP 行上这两条硬约束的来历见 `templates/preset.patch.yml.tmpl:145-149`。
- 修法：doctor 第 5 项会点名是哪个键、哪个值含非 ASCII；第 6 项会指出 `__file__` 是否落在 `vivado_mcp_site` 之下。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 | Select-String 'ascii-paths|mcp-import'
```
把冒犯的路径换成同盘的纯 ASCII 目录（改 `config.yml` 后重跑 `install.ps1`），再重启。

### 2.4 工具"说成功"，但正文里全是 `[ERROR]`

- 原因：MCP 协议的 `is_error` 只反映传输层是否失败，Vivado 的业务失败仍会带着 `is_error: false` 返回。
- 修法：**判据看文本，不看 `is_error`**：正文出现 `[ERROR]` / `CRITICAL WARNING` 就是失败。这条已写进预设纪律（`templates/persona/2023.1.frag.yml:17`）。看到 `[ERROR]` 就把那一行连同错误码（`[Common 17-xxx]` / `[Vivado 12-xxx]`）贴回来，按码查，不要当成功继续。

### 2.5 会话里 `pwsh` 报 `unknown tool "pwsh"`

- 原因：本机实测 `pwsh` 会被异步摘除，工具列表里看着有、调用时没了。
- 修法：改用 `win_bash`，**不要重试 `pwsh`**（已写进预设纪律，`templates/persona/2023.1.frag.yml:20`）。

### 2.6 一次 `run_tcl` 吐掉几千 tokens（`open_run` / `open_project` 尤甚）

- 原因：`run_tcl` 原样返回 stdout，不裁剪；一次 `open_project` 的进度输出就能到约 8k tokens（`templates/persona/2023.1.frag.yml:21`）。
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
