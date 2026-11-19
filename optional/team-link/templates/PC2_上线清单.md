# PC2 上线清单（dsh-vivado-team-link v0.1.0）

> 用途：把第二台工作站接成 **与 PC1 同等权限的组员**（不是受控端）。
> 状态：PC2 机器未上线、板 B 离线；本清单在 PC2 可上电后逐条勾。
> 打印用法：`powershell -NoProfile -File install.ps1 -Role pc2 -Profile desktop`（在 PC2 上跑）

## 0. 需要先由人决定/提供的信息（卡在这三条上）
- [ ] **PC2 的 WLAN IP**：`______`
- [ ] **PC2 的 Tailscale IP / MagicDNS 名**：`______`（与 WLAN 二选一，选定后写进两边 `state/config.json` 的 `peer`）
- [ ] **是否允许开 18790 / 7310**：`允许 / 不允许`（不允许则只用 stdio + issue 回退，跨机不做实时通道）
- [ ] **PC1 侧对应地址**：WLAN `______` / Tailscale `______`
- [ ] **Token 交换方式**：`线下拷贝 state/*.token / 人工粘贴 / 不交换只用 issue`（禁止走聊天与 git）

## 1. 硬件与现场
- [ ] 板 B 上电，GE2 直连 PC2 网口（GE1 一直 Disconnected，不许用 GE1）
- [ ] `Get-NetAdapter` 显示该网口 Up / 1 Gbps
- [ ] JTAG 只接板 B；**确认 PC1 此刻没有在烧任何一块板**（两板 JTAG 序列号同为 210512180081）
- [ ] `vivado -mode batch -source scripts\list_targets.tcl` 只列出一个 target
- [ ] 串口编号记录：`COM____`

## 2. 软件前置
- [ ] Node >= 20：`node --version`
- [ ] DSH 已安装，且 `dsh-vivado` 已在 profile 的 `dsh.profile.bundles` 里
- [ ] `C:\Users\<user>\.dsh\bundles\dsh-vivado\optional\team-link\` 已就位
- [ ] 所有路径为 ASCII（Vivado Tcl 走 GBK 解码，中文路径会坏）

## 3. 安装
- [ ] `install.ps1 -Role pc2 -Profile desktop` 跑完，末尾出现 `PASS kit 未改动：N 个文件 SHA256 全部一致`
- [ ] `state/install-manifest.json` 里 `role` = `pc2`、`registered` = `true`
- [ ] 重启宿主后新会话能看到 `mcp__team_link__*` 工具
- [ ] `skills/prj-team-collab` 已出现在用户 skills 目录并被加载

## 4. 单机验证（PC2 自己就能过，缺一不予上线）
- [ ] **A2A 自环**：`node client\a2a-selfloop.mjs` → 退出码 0，含 `PASS discover` / `PASS auth-reject` / `PASS message-send` / `PASS tasks-get`
- [ ] **MCP 自环**：`node client\mcp-selfloop.mjs` → 退出码 0，含 `PASS list_roots-only-authorized` / `PASS sha256` / `PASS path-escape-rejected`
- [ ] **回退**：停掉两个服务后 `tools\collab_status.ps1` → 退出码 2，打印 `[FALLBACK]` 行，且 `logs\collab_status.log` 新增一行 JSON
- [ ] **可装卸**：`uninstall.ps1` 后 `collab_status.ps1` 报配置缺失、skills 目录无残留；再装回仍全过

## 5. 跨机互认（PC1 与 PC2 一起做）
- [ ] 两边 `state/config.json` 的 `peer` 互填对方的 WLAN/Tailscale 地址
- [ ] `tools\pc1_pc2_ping.ps1` → 打印**对端机器身份**（name/skills），与预期一致（防连错机器）
- [ ] 互换 AgentCard 并互相比对：`role`、`machine`、`capabilities` 一致
- [ ] 反向 ping 也通（PC2 → PC1）
- [ ] `tools\evidence_pull.ps1` 从对端拉一个证据文件，**本地 SHA256 与服务端一致**
- [ ] 故意把目标写成 `192.168.1.10` → 必须被网段守卫拒绝（退出码 4）

## 6. 角色与边界确认（口头确认即可，但要记进 issue）
- [ ] PC2 明确：板 B 侧烧录/串口/ILA/抓包/证据**自主决策**，不需要逐条请示
- [ ] PC1 明确：共享仓提交、构建与烧录窗口、判据裁决归 PC1
- [ ] 双方确认"一次只动一块板"与"先对端就绪再重烧本板"是硬约束，违反会烧错板
- [ ] 确认协作层不是唯一真相源：争议一律落 issue

## 7. 首个协作任务建议（PC2 上线后的第一件事）
- [ ] 由 PC1 用 `TEAM-CMD` 下第一条令，内容建议=板 B 侧只读取证（不烧板）：
      抓 `ilas=4`、`ch_up`、`drops/resets` 各一次 5 s 轮询，落 `results/raw/<日期>_pc2_b_baseline_v1/`，附 SHA256SUMS.txt
- [ ] PC2 用 `TEAM-REPORT` 回，PC1 复核 SHA256 后关令

## 8. 回滚（任一验收失败）
- [ ] `uninstall.ps1 -Profile desktop`（保留源码与日志）
- [ ] `uninstall.ps1 -Profile desktop -Purge`（连生成物一起清）
- [ ] 复核 `PASS kit 未改动`
- [ ] 重启宿主确认 `mcp__team_link__*` 消失

## 9. PC2 禁止事项
- 不烧板 A、不碰 PC1 的 Vivado 会话、不在 PC1 抓包窗口内重烧
- 不改共享仓判据与 `results/raw` 历史目录（append-only）
- 不把 Token / 位流 / pcap 贴进 issue 或聊天
- 不因为"权限高"就动超出板侧边界的东西；跨边界先提方案
