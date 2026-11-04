# dev/ — 验收与验证工具（维护者用）

> 这一层是**维护者工具**，不是 bundle 的运行时内容：`package.json` 只声明 `cordis.patch.yml`
> 一条补丁，`dev/` 不被任何安装/渲染脚本 import，装不装它都不改变用户拿到的行为。
> 普通使用者只需要 `install.ps1` / `doctor.ps1`，见仓库根 [README](../README.md)。
>
> 占位符：`<kit>` = 本仓库根目录；`<work-dir>` = 临时工作目录（默认 `<TEMP>\dsh-vivado-dev`）；
> `<DSH_HOME>` = DSH 配置根（默认 `%USERPROFILE%\.dsh`）；`<DSH 安装根>` = 含 `DeepSeek Harness.exe`
> 的目录（其下有 `resources\runtime\cli\bin\dsh.cmd`）；`<profile>` = profile 名（默认 `desktop`）。

> **路径存在性（2026-10-24 起）**：`install.ps1` / `doctor.ps1` 会要求 `project_root` / `vivado_mcp_cwd` / `temp_dir` 指向真实存在的目录（缺 `temp_dir` 时安装器自动创建）。本套件的夹具已自建 `<work-dir>/project`，所以直接跑即可；你自己手写 config 时别用 `config.example.yml` 里的占位路径。

## 0. 为什么需要它

仓库里的 `--check` 门禁（`tools/make_template.py`、`tools/gen_skills_manifest.py`）只能证明
**源文件自洽**：模板与审计件逐字节一致、`skills/MANIFEST.json` 没漂移。它们不能证明
`install.ps1` 还能装、`uninstall.ps1` 还能卸干净、`doctor.ps1` 该报错时还会报错。

端到端验收的难点是**它必须真的去改一个 DSH profile**。所以这一层把三件事拆开：

| 脚本 | 作用 | 会不会写你的真实 profile |
|---|---|---|
| `validate_patch.py` | 结构校验一份**渲染后**的 `cordis.patch.yml`（独立于渲染器自己的自检） | 不写任何东西 |
| `validate_schema.py` | 用**当前 DSH 自己的** `--dump-config-schema` 校验渲染后 patch / 组合后 dump（2026-11-04 新增，见 §2.4） | 不写任何东西（只读 schema 与 YAML） |
| `make_probe_home.py` | 把现有 profile 完整复制成一个**隔离** `DSH_HOME` | 源 profile 只读 |
| `accept_all.py` | 6 组 54 条断言：`static` / `install` / `uninstall` / `manual` / `stranger` / `doctor` | 只写 `<work-dir>` |

所有机器相关的东西都走参数：没有写死的盘符、没有写死的用户目录。

## 1. 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| Python | **≥ 3.9** | 纯 stdlib；`validate_patch.py` 另需 PyYAML，`validate_schema.py` 另需 PyYAML + `jsonschema`（缺任一个都会 `exit 2`，不静默通过） |
| PyYAML | `validate_patch.py` / `validate_schema.py` | 缺失时会打印安装提示并 `exit 2`（不 vendor YAML 解析器） |
| jsonschema | 只有 `validate_schema.py` 需要 | 缺失时同样 `exit 2`；`accept_all.py` 会把它记成 `[SKIP]` 而不是 PASS |
| PowerShell | **5.1**（`powershell.exe`） | 脚本用 `-NoProfile -ExecutionPolicy Bypass -File` 调 `.ps1` |
| DeepSeek Harness | **桌面版真装过**，且至少有一个能用的 profile | `accept_all.py` 默认自动探测 `<DSH 安装根>`；探不到就传 `--dsh-install` |
| 磁盘 | `<work-dir>` 预留 **≈350 MB**（≈1.1 万文件） | 探针 home 是 `node_modules` 的完整拷贝，不是链接（联接点不跟随，见 §8） |
| 宿主 | **不需要关闭** | 本目录脚本只写隔离 `DSH_HOME`；但别在同一时间手工改真实 profile，`[GUARD]` 会点名 |

PyYAML 缺失时的安装方式（用**同一个解释器**）：

```powershell
py -m pip install pyyaml
```

`accept_all.py` 内部调用 `tools/*.py`、`dev/validate_patch.py` 用的是 `sys.executable`，
所以**跑它那个解释器里必须有 PyYAML**，否则 `static` 组的 `validate` 步骤会 `exit 2`。

## 2. 命令

### 2.1 渲染 + 结构校验（最便宜，先跑这一条）

```powershell
# 渲染两档各一份到 scratch（绝不写仓库：仓库里没有、也不该有 cordis.patch.yml）
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\render_patch.ps1 `
  -ConfigPath <kit>\config.example.yml `
  -OutFile <work-dir>\render\accept-2023.1.yml `
  -BundleDir <kit> -SkillsDir <kit>\skills

py <kit>\dev\validate_patch.py <work-dir>\render\accept-2023.1.yml `
  --tier 2023.1 --expect-skills-dir <kit>\skills
```

`--tier` 取 `2023.1` 或 `2025.2plus`；要验另一档就把 config 里的 `vivado_version` 改成
`2025.2`（或直接 `-ConfigPath <你自己的 config.yml>`）再渲染一次，`--tier 2025.2plus`。
退出码：`0` = PASS，`1` = FAIL（逐条打印原因），`2` = 环境问题（缺 PyYAML / 文件不存在）。

它校验的形态：一条 `- insert:`、预设行 `preset-vivado`（id/name/order）、22 条 shipped 插件行
**按原顺序** + 末尾 `mcp-vivado`、persona 块标量里的纪律短语与**该档**的实测事实、
`customSkillDirs` 单元素绝对 ASCII 且等于 `--expect-skills-dir`、`includeDefaultRoots` 保持缺省、
`mcp-vivado` 的 stdio/环境变量键/TEMP=TMP/超时、除 `{{model}}` 外无残留占位符。
另外还查：LF、无 BOM、无 `!include`、无**别人的**用户主目录路径（`X:\Users\<别人的账号>\`；
你自己账号下的路径是合法的，例如 venv 就装在自己家里）。

### 2.2 建一个隔离探针 home

```powershell
py <kit>\dev\make_probe_home.py --home <work-dir>\probe-accept --name probe --force
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--profile-source` | `%USERPROFILE%\.dsh\profiles\desktop` | 复制来源；**只读** |
| `--home` | `<TEMP>\dsh-vivado-dev\dshprobe-accept` | 要建的 `DSH_HOME` |
| `--name` | `probe` | home 里的 profile 名 |
| `--force` | 关 | 重建；顺带清掉 `<home>\bundles`（上一轮的 staging，否则会残留旧 `config.yml`） |
| `--keep-old-bundle` | 关 | 保留上一代预设包 `@local/dsh-vivado-preset`，用来复现「两个 bundle 抢同一个 `preset-vivado` 行」 |
| `--keep-kit` | 关 | 保留本包在 profile 里的依赖/`bundles`/`node_modules` 三处痕迹（只用于调试） |

默认会把**本包**的三处痕迹删掉，让探针 home 看起来像一台**从没装过本包**的机器——
否则「安装确实改动了 profile」这条断言等于没验。`--home` 落在源 profile 里、或源 profile 落在
`--home` 里时脚本直接拒绝运行。

### 2.3 端到端验收

```powershell
py <kit>\dev\accept_all.py                                     # 全量 6 组 54 条
py <kit>\dev\accept_all.py --only static                       # 只要 10 条，不需要 DSH 安装
py <kit>\dev\accept_all.py --only install,uninstall `
   --home <work-dir>\probe-accept                              # 真装+真卸 27 条
py <kit>\dev\accept_all.py --keep-home                         # 复用已建好的探针 home
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--kit` | 本脚本所在仓库根 | 被测仓库 |
| `--work-dir` | `<TEMP>\dsh-vivado-dev` | scratch 根：探针 home、渲染产物、config 夹具、日志都在这下面 |
| `--home` | `<work-dir>\dshprobe-accept` | 探针 `DSH_HOME` |
| `--profile` | `probe` | 探针 home 里的 profile 名 |
| `--dsh-install` | 自动探测 | `<DSH 安装根>` 或直接给 `...\cli\bin\dsh.cmd` |
| `--config` | `<kit>\config.example.yml` | 派生夹具用的机器配置；装真机时传 `<kit>\config.yml` 更贴近现实 |
| `--live-profile` | `desktop` | 只读指纹比对对象；传空串 `""` 关掉守卫 |
| `--only` | 全部 | 逗号分隔：`static,install,uninstall,manual,stranger,doctor` |
| `--keep-home` | 关 | 不重建探针 home |
| `--no-log` | 关 | 不写 `<work-dir>\logs\accept-<时间戳>.log` |

输出契约（照着读就行）：

```text
  [PASS] install.ps1 exit 0
  [FAIL] dump-config: customSkillDirs -> staged skills -- ...
  -- group install finished in 20.1s
=== ACCEPTANCE: 24/25 passed ===
  FAILED: <断言名> :: <细节>
[GUARD] live profile UNCHANGED: <DSH_HOME>\profiles\<profile> (package.json mtime+sha identical)
```

退出码：`0` = 全过且真实 profile 一字节没动；`1` = 有 `[FAIL]`（或 `[GUARD]` 报真实 profile 被改）；
`2` = 环境问题（缺入口文件、scratch 路径非 ASCII、探不到 DSH CLI、`--only` 写了不存在的组）。

`[GUARD]` 是**矩阵之外**的一条守卫，不占 53 条里的名额：跑之前给真实 profile 的
`package.json` / `pnpm-lock.yaml` / `compatibility.json` / `cordis.patch.yml` 记 `mtime+sha256`，
再给 `%USERPROFILE%\.dsh\skills` 记一份目录指纹，跑完比对，不一致就把它点名并把退出码打成 1。

### 2.4 适配新一代 DSH（改了哪一步、为什么）

DSH 升级会改**组合行为**而不改我们仓库里的任何一个文件（2026-11-04 实测：0.2.1-rc.3 → rc.5
的 shipped preset 行其实**一行没变**，但 `node_modules` 的解析次序变了，探针 home 里一份
"被 robocopy 解引用"的旧 bundle 副本压过了 profile 依赖，装完的组合检查直接失败）。固定动作：

```powershell
# 1) 先看运行时版本与本机豁免（doctor 第 12 项现在会 FAIL，不再只是 WARN）
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\doctor.ps1

# 2) 隔离 home + 安装：组合 + schema 两条门禁都在 install 组里
py <kit>\dev\accept_all.py --only install --home <work-dir>\probe-accept

# 3) 单独验 schema（给了 DSH 的 --dump-config-schema 才有意义）
py <kit>\dev\validate_schema.py --schema <home>\schema.json --patch <home>\bundles\dsh-vivado\cordis.patch.yml
py <kit>\dev\validate_schema.py --schema <home>\schema.json --entries <home>\dump-config.yml
```

- **`--dump-config` 仍然不校验 `compatibility.json`**（老结论没变），只有 doctor 第 12 项读文件判；
  rc.5 起第 12 项从 WARN 升成 **FAIL**：豁免缺失/过期 ⇒ 宿主静默丢掉 `mcp-vivado` 行 ⇒ 32 个工具全没了。
- **「shipped preset 行有没有变」怎么查**：在隔离 home 里 `dsh --profile probe --dump-config`，
  拿 `preset-standard` 的 `plugins` 与我们模板里的 22 行做结构 diff（2026-11-04 实测 rc.5：**0 处差异**）。
  这不是脚本门禁（没有稳定的机器可读入口），是升级时的**人工确认项**，结论写进 `docs/version-matrix.md`。

## 3. 安全边界

- **绝不写真实 profile。** 三道保险：所有子进程都带 `-DshHome <home>` 与 `DSH_HOME=<home>`；
  脚本自己拒绝 `--home` 落在 `<DSH_HOME>` 里；`[GUARD]` 事后比对真实 profile 指纹。
- **探针 home 是完整拷贝**（≈350 MB / ≈1.1 万文件）。用完删掉 `<work-dir>` 即可回收：
  `rmdir /S /Q <work-dir>`（或资源管理器里删）。
- **`make_probe_home.py` 要求源 profile 存在**（`<profile>\package.json`）。没装过桌面版就没有可复制的东西；
  默认源是 `%USERPROFILE%\.dsh\profiles\desktop`，用别的 profile 就传 `--profile-source`。
- **不打印凭据。** 脚本只跑 `--dump-config` / `install.ps1` / `uninstall.ps1` / `doctor.ps1`；
  `--dump-config` 的失败输出在打印前会把 `apiKey` / `token` / `secret` / `password` 之类替换成 `<redacted>`。
- **不读 license、不跑 Vivado、不需要管理员权限。** 验收不证明 Vivado 能用，只证明包能装能卸（见 §5）。
- **`--work-dir` / `--home` 必须纯 ASCII**，否则直接 `exit 2`：这是安装器自己的硬约束（Vivado 的 Tcl 层按 GBK 解码）。
- pnpm 的**全局 store**（`%LOCALAPPDATA%\pnpm\store`）不在隔离范围内，会被复用；这是 pnpm 的正常行为，不是泄漏。
- 每轮验收都会重建 `<work-dir>\probe-accept`，别把要留的东西放进去。

## 4. 54 条断言覆盖什么

| 组 | 条数 | 覆盖 | 代表断言 |
|---|---:|---|---|
| `static` | 10 | 生成器/渲染器/技能清单/**独立预设包**/卫生 | 两档各渲染+校验一次；`py tools\build_preset_package.py --check`（`packages/dsh-vivado-preset/` 的 patch 与 8 个技能副本必须与模板/`skills/` 逐字节一致）；仓库里没有 `__pycache__`/`.bak-*`/`config.yml`；3 个运行辅助脚本 + `templates/build-markers.tcl` 在场且纯 ASCII；仓库文本里没有作者主目录路径（`skills/` 与 `packages/*/skills` 是 vendored、`dev/` 是维护者工具，均豁免） |
| `install` | 20 | `-Mode auto` 真装 + 组合快照 + **schema 门禁** + 幂等 + `-WhatIf` + 红线 | 依赖写成 `link:<home>\bundles\...`；bundle 只追加一次；`--dump-config` 四条标记；**渲染后的 patch 与组合后的 dump 都过一遍当前 DSH 的 `--dump-config-schema`**（该 DSH 不暴露 schema 时记 `[SKIP]`，不冒充 PASS）；第二次装 `package.json` sha 不变；`-WhatIf` 前后字节不变；`%USERPROFILE%\.dsh\skills` 未被写 |
| `uninstall` | 7 | 干净移除 | 依赖行/`bundles` 行/staging/`node_modules` 联接全没了；`--dump-config` 仍能组合；第二次卸是 no-op |
| `manual` | 4 | `-Mode manual`（完全不用 pnpm） | 依赖与 bundle 行就位；组合出 `preset-vivado` + `mcp-vivado` |
| `stranger` | 7 | 换机器视角（另一个 part / project_root） | persona 带上新 part 与新工程根、旧 part 无残留；**回归守卫**：staging 已存在时再传另一个 `-Config` 必须重新渲染（`P0` 那次的 bug） |
| `doctor` | 6 | 体检自己会不会报错 | 健康机器 exit 0；注入 4 个故障（非 ASCII 路径 / 不存在的 Vivado / 错误的 MCP site / **删掉 `compatibility.json` 的豁免键**）分别被抓成 `[FAIL] <id>`；`-Json` 是合法 JSON 且字段恒为 5 个 |

合计 **10 + 20 + 7 + 4 + 7 + 6 = 54**。`--only install,uninstall` 那条快路径是 **20 + 7 = 27** 条。

## 5. 不覆盖什么（别把绿当全绿）

| 没覆盖 | 为什么 | 谁来兜 |
|---|---|---|
| 真实会话里的 **32 个 `mcp__vivado__*`** | 要重启 Electron 宿主 + 新建会话把预设切到 `Vivado`，脚本做不到 | 重启后按 README「一句话自检」手工确认 |
| 预设的 **UI 渲染**（插件卡片标题/图标/描述、预设下拉） | 那是宿主读 `locale/*.json` 与 `icon.png`，不在命令行输出里 | 打开宿主界面看一眼；显示元数据见 [docs/architecture.md](../docs/architecture.md) §8.5 |
| 真实 Vivado 行为（综合、`xdc_lint`、ILA） | 需要 Vivado + license + 器件 | `doctor.ps1` 只判静态条件，深水区靠真机 |
| `tools/vivado-probe.ps1` / `vivado-run.ps1` / `tcl-check.ps1` 的**真跑** | 会启动 Vivado（每次约 10-40 s），验收脚本刻意不碰 | 手工跑一次探针（`PROBE_RESULT=OK`）与 `tcl-check.ps1`（`TCLCHECK_RESULT=PASS`），见 [docs/architecture.md](../docs/architecture.md) §10 的门禁顺序 |
| `compatibility.json` 是否被宿主真正采用 | 实测 `--dump-config` **不校验**它（见 [docs/architecture.md](../docs/architecture.md) §6） | `doctor.ps1` 第 12 项（rc.5 起该判定缺失/过期直接 **FAIL**）+ 真会话 |
| `--dump-config-schema` 不存在的老版本 DSH | 不是每个 DSH 构建都暴露 schema | schema 两条断言记 `[SKIP]`（不是 PASS）；手工按 [docs/version-matrix.md](../docs/version-matrix.md) 登记 |
| **`packages/dsh-vivado-preset` 的 `dsh plugin add` 真装** | 验收只证明"包生成正确 + 组合出 `preset-vivado` + `!!js` 技能表达式能解析到安装目录"（见 `docs/architecture.md` §12）；它不启动宿主、不建会话 | 在隔离 home 里 `dsh plugin add <tgz|tree-url>` 后重启宿主，新会话选 `Vivado`，确认技能列表出现 |
| shipped preset 行与新版 DSH 的差异 | 没有稳定机器可读入口 | §2.4 的结构 diff 步骤 + `docs/version-matrix.md` 登记 |
| `2025.2+` 档的版本事实 | 本机未实测 | [docs/version-matrix.md](../docs/version-matrix.md) §5 |
| pnpm/CLI 路径本身是否走通 | `install` 组跑 `-Mode auto`：CLI 失败会自动降级 `manual`，仍然 PASS | 看输出里是 `official CLI install finished` 还是 `falling back to the manual` |
| 卸载后宿主是否真的「忘了」这一层 | 只有重启才知道 | 重启后 `doctor.ps1` + 预设列表 |

## 6. 改了哪里，跑哪一组

| 你改了什么 | 至少跑 | 为什么 |
|---|---|---|
| `install.ps1`、`lib/install-helpers.ps1` | `static` + `install` + `uninstall` + `manual` + `stranger` | 装、卸、不回退路径、`-Config` 重渲染都在这一组 |
| `uninstall.ps1` | 先 `install` 再 `uninstall`（`--only install,uninstall`） | 卸要卸得掉一个真装好的探针 home |
| `doctor.ps1` | `--only doctor`（会自己确保探针 home 已装） | 6 条里有 4 条是「该 FAIL 时必须 FAIL」（含删豁免键那条） |
| `dev/make_probe_home.py` | `--only install`（必须重建 home） | 探针 home 用 `/XJ` 不跟随联接点、且**一定**执行 strip，否则旧 bundle 副本会污染组合 |
| `dev/validate_schema.py` | `--only install` | schema 门禁的两条断言在这里；改它之后至少跑一次 install 组 |
| `tools/render_patch.ps1` | `static`（两档都会被渲染+校验） | 渲染器是两档共用 |
| `templates/preset.patch.yml.tmpl` | `static`，**两档都要过** | 模板一处漂移会同时影响两档 |
| `templates/persona/<tier>.frag.yml` | `static`，**两档都要过** | 只改一档 = 两档纪律开始分叉（[docs/architecture.md](../docs/architecture.md) §10） |
| `tools/vivado-*.ps1`、`lib/common.ps1` 的运行辅助段 | `--only static` + 手工真跑 `vivado-probe.ps1` / `tcl-check.ps1` | `static` 只验在场与 ASCII；真跑才会暴露 WinPS 5.1 的退出码/引号坑 |
| `tools/make_template.py`、shipped 22 行审计件 | `--only static` | 模板/审计件/生成器三者互相钉死 |
| `templates/preset.patch.yml.tmpl` 的 shipped 行、`skills/**` | `--only static`（含 `tools\build_preset_package.py`） | `packages/dsh-vivado-preset/` 是从这两处生成的，改一处不重生成 = 独立预设包漂移 |
| `packages/dsh-vivado-preset/` 的 `persona.txt` / `README.md` / `package.json` | `--only static` + 隔离 home 里 `dsh plugin add` 一次 | 手写件不参与生成，但 `package.json` 的 `dsh.bundle` / 版本一致性由 `--check` 把关 |
| `skills/**` | `--only static` + `doctor.ps1` 第 13 项 | `MANIFEST.json` 由生成器唯一产出，禁手写 |
| `config.example.yml` | `static` + `doctor` | `doctor` 组的 3 个注入点直接改这份配置里的键 |
| 只改文档 | `--only static`（`static` 也顺带查仓库卫生） | 5 秒，别省 |

`static` 组的 `validate` 步骤会对**两档**各跑一次渲染 + 校验，所以「模板/persona 升档」这类改动
只需要这一组就能证明两档没分叉。

## 7. 一次完整的维护者流程

```powershell
# 0) 便宜的门禁（与 docs/architecture.md §10 一致）
py <kit>\tools\make_template.py --check
py <kit>\tools\gen_skills_manifest.py --check

# 1) 静态组：10 条，几秒钟，不需要 DSH
py <kit>\dev\accept_all.py --only static

# 2) 真装 + 真卸：隔离 DSH_HOME，27 条
py <kit>\dev\accept_all.py --only install,uninstall --home <work-dir>\probe-accept

# 3) 全量：6 组 53 条（自动探测 DSH；探测不到就加 --dsh-install <DSH 安装根>）
py <kit>\dev\accept_all.py

# 4) 真机：重启宿主 → 新会话选 Vivado → 数工具/技能（脚本管不到这一步）

# 5) 收尾：删掉 scratch
rmdir /S /Q <work-dir>
```

## 8. 实现上的几个选择（免得下次又要重新想一遍）

- **探针 home 是拷贝，不是联接。** `install.ps1` 会跑 `dsh plugin add`（pnpm 会重写 `node_modules`），
  联接到真实 profile 等于直接往用户的环境里写。
- **robocopy 必须带 `/XJ`，且 strip 一定要跑到。** 真实 profile 的 `node_modules` 里有联接点
  （本包 bundle、以及 `link:` 依赖）。不 `/XJ` 时 robocopy 会把它**解引用成一份实目录副本**；
  如果源联接点的目标盘不存在，robocopy 还会以 `rc=9` 失败。2026-11-04 实测：旧实现在 `rc>=8`
  就直接 `return 1`，于是 strip 没执行、探针 home 里留下一份**为真实 home 渲染的旧 bundle 副本**，
  DSH 0.2.1-rc.5 的组合按 `node_modules` 解析时选中它 ⇒ 装完的组合检查报
  `customSkillDirs does not point at <probe>/bundles/.../skills`。现在：`/XJ` + `rc&8` 只 WARN +
  strip 永远执行；`install` 的 `New-KitDirectoryLink` 也会把「同一 package 的实目录副本」换成联接
  （只认 `package.json` name 相符的，别的一律拒绝）。
- **每组自建 home。** `install` / `manual` / `stranger` / `doctor` 各自 `--force` 重建，
  这样组之间不会互相污染；组内则故意复用（幂等、`-WhatIf`、第二次卸都得在同一个 home 上验）。
- **`install` 组在 `-Mode auto` 下跑**：它证明的是「用户跑 `install.ps1` 会成功」，
  不是「这台机器的 pnpm 一定可用」。
- **断言名字是契约。** PR/报告里靠名字对齐，改脚本时别顺手改名字。
- **`--dump-config` 的输出是 YAML 打印结果**，长路径会被折成 `>-` 块标量，
  所以「技能目录挂上了」这条按**去空白后包含**判定，不按行正则。
- **每个 `-Config` 夹具都写在 `<work-dir>\cfg\`**，安装器把探测值回写时只会改这些副本，
  仓库里的 `config.example.yml` 一个字节都不会变。
