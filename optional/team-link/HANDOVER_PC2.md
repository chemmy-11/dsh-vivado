# 交付给 PC2 的转交说明（dsh-vivado-team-link · 宿主半边 + token schema v2）

这份说明对应 **PC1↔PC2 协作层的可选插件**。PC2 的正路是**从仓库 clone**，桌面 zip 只作离线备选。
对应 issue：**https://github.com/chemmy-11/EIF/issues/7**

仓库：`https://github.com/chemmy-11/dsh-vivado.git`（插件在仓内 `optional/team-link/`）

## 0. 包里有什么 / 没有什么

| | 内容 |
|---|---|
| **有** | 插件源码（`lib/` / `server/` / `client/` / `tools/`）、安装与卸载脚本、协作纪律技能、3 个模板、`state/config.example.json`、本说明 |
| **没有（有意排除）** | `*.token`（凭据）、`state/config.json`（机器专属配置）、`cordis.patch.yml`（渲染产物，装的时候重生成）、`logs/`、`state/tasks/`、`state/*.bak-*`、kit 哈希清单 |

Token 绝不随包分发；`config.json` 含 PC1 的绝对路径，带到 PC2 只会指向不存在的路径。

## 1. 获取与放置

### 正路：clone 仓库（推荐）

```powershell
git clone https://github.com/chemmy-11/dsh-vivado.git
cd dsh-vivado\optional\team-link
```

插件就在仓里，**不用**手工拷到 `%USERPROFILE%\.dsh\bundles\...`：`install.ps1` 会把**这个目录**按 link 注册进 profile。
以后 PC1 更新协作层，`git pull` 之后重跑 `install.ps1` 即可（`state/` 里的 token 与 `config.json` 不会被 git 动）。

### 离线备选：桌面 zip

拿到 zip 时，目录应落到 `%USERPROFILE%\.dsh\bundles\dsh-vivado\optional\team-link\`（`optional\` 不存在就新建）。
**不要**覆盖 dsh-vivado 自身的 `install.ps1` / `cordis.patch.yml` / `packages\` / `patches\` / `skills\` / `tools\` / `templates\`。

zip 里若有 `SHA256SUMS.txt`，先校验完整性：

```powershell
cd optional\team-link
Get-Content SHA256SUMS.txt -Encoding UTF8 | ForEach-Object {
  $h,$p = $_ -split '\s\s',2
  if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $h) { "MISMATCH $p" } else { "OK $p" }
}
```

## 2. Token 是双向分离的（v2，别再用"两端共用一个 token"）

| 方向 | 文件 | 里面放谁的 token |
|---|---|---|
| PC2 校验来客（入站） | `state\a2a.token`、`state\mcp.token` | **PC2 自己的**（install 自动生成） |
| PC2 调用 PC1（出站） | `state\peer-a2a.token`、`state\peer-mcp.token` | **PC1 的**（PC1 交给你） |

结论：**双方互交自己的 token，各自放进 `peer-*`**，不需要共享同一份。

### 交换方式 A（推荐）：用 `team_link_setup` 写进凭据存储

装完并重启宿主后，会话里会有宿主工具 **`team_link_setup`**（这是模型工具调用，不是 PowerShell 命令）。值只进 DSH 凭据存储（`~\.dsh\.credentials.yaml` 的 `refs:` 段），**工具永不返回值**：`status` 只报 `credential=configured|absent`、`file=present(NB)|MISSING` 这类存在性事实。

```
team_link_setup { action: "set-token", token: "peer-a2a", value: "<PC1 给你的 a2a token>" }
team_link_setup { action: "set-token", token: "peer-mcp", value: "<PC1 给你的 mcp token>" }
team_link_setup { action: "status" }          # 只报配了没配，不回显值
```

这条路径的好处：token 不落进 git、不进聊天记录、不进任何备份文件；换 token 时同样只动凭据存储。
`set-token` 会**当场**把值物化到 `state\*.token`（文件不用等重启），但 **A2A/MCP 服务是启动时读 token 的**，所以写完还要重启宿主，新 token 才在通道上生效。

### 交换方式 B（离线备选）：直接把 token 文件放到 `state\`

没有宿主工具、或通道还没通时，把 PC1 给你的两个 token 纯文本存成：

- `state\peer-a2a.token` ← PC1 的 `a2a.token`
- `state\peer-mcp.token` ← PC1 的 `mcp.token`

文件内容只要那一行 hex（行尾有无换行都行，服务端 `trim` 后使用）、**不要引号**。服务端是**启动时**读 token 的，所以放完要重启宿主。

> 注意：若同一条 token 你也用方式 A 配过凭据引用，则启动时**以凭据存储为准**（`apply()` 会把文件覆盖成凭据里的值）。两种方式选一种，别混着用。

## 3. 装（PC2 上，角色 = pc2）

在 `optional\team-link` 目录里执行（clone 路线就是 `dsh-vivado\optional\team-link`）：

```powershell
powershell -NoProfile -File install.ps1 -Profile desktop -Role pc2
```

然后按顺序打勾：

- [ ] **1. 前置**：Windows + PowerShell 5.1+、Node ≥ 20、`%USERPROFILE%\.dsh\profiles\desktop` 已存在、**PC1 没在烧板**（同一时刻只有一台上板）。
- [ ] **2. 取代码**：clone 仓库（§1 正路）；离线才用 zip。
- [ ] **3. 安装**：跑上面那条命令。末尾必须看到 `PASS kit 未改动：N 个文件 SHA256 全部一致`；install 会生成 PC2 自己的 `state\a2a.token` / `state\mcp.token`，**不覆盖**你已放的 `peer-*`。
- [ ] **4. 重启宿主**（Electron 下没有热更新）：新会话里应出现 `mcp__team_link__*` 工具与 `team_link_setup`。
- [ ] **5. 交换 token**：方式 A（`team_link_setup`，推荐）或方式 B（直接放 `state\peer-*.token`），见 §2。同时把 PC2 自己的 `state\a2a.token` / `state\mcp.token` 交回给 PC1（PC1 放成 `peer-*`），双向才通。
- [ ] **6. 再重启一次宿主**，让新 token 被 A2A/MCP 服务读到并生效。
- [ ] **7. 跑 §4 的四项自证**。
- [ ] **8. 按 `templates\PC2_上线清单.md` 走硬件与跨机互认**。

## 4. 装完必须自证的四项（缺一别上线）

```powershell
node client\a2a-selfloop.mjs --config state\config.json        # 期望 exit 0
node client\mcp-selfloop.mjs --config state\config.json        # 期望 exit 0
powershell -NoProfile -File tools\collab_status.ps1            # 无服务时期望 exit 2 + [FALLBACK]
powershell -NoProfile -File uninstall.ps1 -Profile desktop      # 期望 kit 未改动、无残留
```

第 4 项跑完如需继续用，再跑 `install.ps1 -Profile desktop -Role pc2` 装回（`state\` 里的配置与 token 会保留）。

## 5. 然后按清单走

`templates\PC2_上线清单.md`：硬件（GE2 直连、只接板 B、确认 PC1 没在烧板）→ 软件 → 安装 → 单机四项 → 跨机互认。

配置说明在插件 `README.md` §4：**现在没有 GUI 配置面板**，非密参数改 profile 的 `config:` 块，token 值用 `team_link_setup` 写。别去找"设置 → 插件 → 配置"那个面板，本轮不存在。

## 6. 三条最容易踩的坑
1. **PC↔PC 禁走 `192.168.1.0/24`**：两块板同为 `192.168.1.10`、MAC 固定 `00-11-22-33-44-55`，从 PC 侧连过去会命中错误的那块板 —— 症状是烧错板 / ILA 抓不到，**不会报错**。跨机走 WLAN / 第二网卡 / Tailscale，固定其中一条。
2. **两块板 JTAG 序列号同为 `210512180081`**：禁 `-Board Both`，一次只动一块板；先对端就绪再重烧本板；重烧板 B 之后板 A 也要重烧。
3. **通道只是加速器**：通道不通就回 issue 轮询（`collab_status.ps1` 会打 `[FALLBACK]` 并留 JSON 日志），争议一律落到 issue。

## 7. 回报

按 `skills/prj-team-collab/SKILL.md` 的口令：`TEAM-REPORT <id> | status | 一句话结论带数字`，证据带路径 + SHA256。进度与阻塞回 issue #7。
