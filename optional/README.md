# optional/ — 可选插件集合

这个目录放**不在 Vivado 预设里**的可选插件。kit 本体（`install.ps1` / `cordis.patch.yml` /
预设行 / 8 个技能 / 11 个补丁）与它们互不依赖：装不装它们，kit 的安装结果与
`dsh-vivado` 预设都完全一致。

**默认不安装。** kit 的 `install.ps1` 不会注册这里任何东西；每个插件由自己的
`install.ps1` 单独注册到 profile。装过之后要重启宿主才生效（Electron 下 `dsh-hmr` 不生效）。

## 当前成员

| 目录 | 插件 | 作用 | 需要的服务 |
|---|---|---|---|
| [`team-link/`](team-link/README.md) | `dsh-vivado-team-link` | PC1↔PC2 协作层：A2A（7310）+ MCP（18790/stdio）+ 协作 issue 回退；PC2 是同等权限组员，靠口令+证据+审计约束 | Node ≥ 20、PowerShell ≥ 5.1、DSH ≥ 0.2.2-rc.1 |

> `team-link` 有 **GUI 配置面板**：装好后重启宿主，在 `设置 → 插件 → 已安装的插件 → dsh-vivado-team-link → 行 team-link → 配置`
> 里改角色 / 地址 / 端口 / 对端 / 回退 / 授权根。token **值**不在面板里（面板只显示引用名与文件路径），写入用宿主工具 `team_link_setup`。

## 装一个

从**本仓 clone 出来的目录**里直接跑（推荐，PC2 的正路）：

```powershell
cd .\optional\team-link
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile desktop -Role pc2
```

也可以从 kit 装好之后的 staging 目录跑（等价）：

```powershell
cd C:\Users\<你>\.dsh\bundles\dsh-vivado\optional\team-link
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile desktop -Role pc1
```

> **staging 会带走 `optional/`（已实测，不是推测）**：kit 的 `install.ps1` 用
> `robocopy /E /XD .git .tmp* node_modules dev /XF cordis.patch.yml config.yml KIT-SPEC.md …`
> 做 staging 拷贝，排除清单里**没有** `optional`，所以 `optional/team-link/lib/index.js`
> 这类必需文件会一起进 `<StageDir>\optional\team-link\`。
> 实测命令与判据：`install.ps1 -RenderOnly -StageDir <空目录>` 之后检查
> `<StageDir>\optional\team-link\lib\index.js` 是否存在（见 §验收）。
>
> 反过来说：**从仓重装 kit 会替换整个 staging 目录（含 `optional/`）**，
> 所以插件开发一律在仓里做（`D:\dsh-vivado\optional\team-link`），
> `~/.dsh/bundles/dsh-vivado/optional/team-link` 只当运行目标。

## 回滚

```powershell
cd .\optional\team-link
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Profile desktop
```

`uninstall.ps1` 会还原 profile 的 `package.json` 备份、摘除 `node_modules` 里的 junction、
删除 skill 副本、摘掉包内的 `schemastery` 解析 shim；加 `-Purge` 再清渲染产物与 token。
判据是**前后两次 kit 目录 SHA256 全量比对必须一致**（`install.ps1` 自己会打这个基线）。

## 纪律（往这里加插件也适用）

- **不放运行期产物**：`state/` 里的 token、`config.json`、`logs/`、`*.bak-*` 一律不进库；
  每个插件的 `.gitignore` 自己拦一遍，仓根 `.gitignore` 再兜一层。
- **不放作者的机器路径**：`D:/FPGA/...` 这类默认值不许出现在样板里（仓既有纪律）。
- **密钥不许进配置**：DSH 的 profile 插件配置是**明文持久化**的，`.volatile()` 也不是
  「不落盘」。密文只走 DSH 凭据存储（`~/.dsh/.credentials.yaml` 的 `refs` 段），
  由插件 `apply()` 在运行期读出来用。
- **不手改 kit 的生成物**：`cordis.patch.yml`、`packages/`、`patches/`、`skills/`、
  `templates/` 都由 `tools/render_patch.ps1` + `templates/` 生成。

## 验收

`optional/team-link` 有自己的一套离线验收（不需要重启宿主）：

```powershell
cd .\optional\team-link
node tools\apply-selftest.mjs                       # 宿主半边：config.json 物化 / 不 throw / 删后重建 / token 链路
node client\a2a-selfloop.mjs --config state\config.json
node client\mcp-selfloop.mjs --config state\config.json
powershell -NoProfile -File tools\collab_status.ps1
```

kit 一侧的 staging 判据（`optional/` 是否被带走）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RenderOnly -StageDir C:\temp\stage-probe
Test-Path C:\temp\stage-probe\optional\team-link\lib\index.js   # 期望 True
```
