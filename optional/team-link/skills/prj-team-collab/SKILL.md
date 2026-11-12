---
name: prj-team-collab
description: PC1<->PC2 双板协作纪律（同等权限组员制）：发令/回报口令、证据目录与 SHA256 约定、上板与恢复阶梯硬约束、判据陷阱、通道不可用时退回 GitHub issue 审计。涉及跨机分工、双板上板窗口、证据搬运、协作通道排障时加载。
---

# prj-team-collab

## 0. 事实源（引用标签）
- `手册12` = `C:\Users\15266\Desktop\毕设\操作文档\prj12_双板上板操作手册_P1到M2_v1.0_2026-11-07.md`
- `手册13` = `...\操作文档\prj13_P2开工手册_2026-11-08.md`
- `RPT` = `D:\FPGA\prj\project_12\out\evidence_2026-11-06\REPORT_P1_2026-11-06.md`
- `DSR`/`VOB`/`CORR` = `...\evidence_2026-11-07_dma_stall\README.md` / `VERIFY_ON_BOARD.md` / `CORRECTION_for_REPORT_P1.md`
- `DELIV`/`IDX`/`RRAW` = `D:\GSnFPipe-FPGA-PP\README.md` / `fpga\bitstreams\INDEX.md` / `results\raw\20261106_a_p1_dual_board_bringup_v1\README.md`
- `P13`/`FM` = `D:\FPGA\prj\project_13\README.md` / `fork_manifest_13.json`
- 标注 **【推断】** 的条目是工程判断而非文档原文，落地前需实测确认。

## 1. 角色：同等权限，靠约定不靠降权
- **PC1 = lead**：优先级、共享仓提交、构建与烧录窗口分配、判据裁决。
- **PC2 = 板 B 侧实物负责人**：烧录 / 串口 / ILA / 抓包 / 证据，**在板侧范围内自主行动**，也可提方案。PC2 与 PC1 **同级 full access**，不设只读、不设审批。
- 因此约束只能来自**口令 + 证据 + 审计**这三样；任何"因为权限不够所以做不了"的回答都是错的，正确回答是"这属于谁的边界"。
- 边界冲突时的裁决顺序：① 安全（不烧错板/不抢 Vivado 会话）→ ② 判据（谁的判据被写进 issue）→ ③ 排期。裁决必须落到 issue，聊天里说的不算。

## 2. 发令 / 回报格式（跨机只交换决策与证据）
发令（PC1→PC2 或反向）首行固定：
```
TEAM-CMD <id> | <owner:pc1|pc2> | <priority:P0|P1|P2> | <deadline 或 "-">
目标：<一句话，可验收>
判据：<命令 + 期望值，不许写"正常/没问题">
证据落点：<results/raw/... 或 prj/out/evidence_...，含 SHA256 要求>
禁止：<本次不许碰的板/窗口/文件>
```
回报首行固定，**结论先行、数字在首句**（沿用 issue 评论风格，DELIV:47）：
```
TEAM-REPORT <id> | <status:done|blocked|rejected> | <一句话结论，带数字>
做了什么：<命令与关键输出，≤5 行>
证据：<路径> + SHA256=<hex>
偏差与风险：<没有就写 none>
下一步建议：<一句>
```
- 收到 `TEAM-CMD` 可以**拒绝**，但必须用 `TEAM-REPORT status:rejected` 并给出理由（越界、判据不可执行、会撞窗口）。
- 不确定就 `status:blocked` 并列"我需要谁给什么"，**不许猜着往下做**。
- 禁止 micromanage：PC1 不给 PC2 排"第几步点哪个按钮"，只给目标和判据；PC2 不反问"你希望我用哪个 COM 口"。

## 3. 通道
| 用途 | 通道 | 端口 | 认证 |
|---|---|---|---|
| 喊话、任务状态 | A2A | 7310 | AgentCard 公开；`POST /` Bearer |
| 证据读写 + SHA256 | MCP | 18790 | Bearer |
| 本机工具挂载 | MCP stdio | 无端口 | 进程内 |
- 只走 WLAN / 第二网卡 / Tailscale。**不走 `192.168.1.x`**。
  依据：板卡走 GE2 直连本机网口 + 静态 ARP Permanent（手册12:54-55、RRAW:17）；P1 现网两台 PC 同为 192.168.1.102、两块板同为 192.168.1.10、板卡 MAC 固定 00-11-22-33-44-55（手册12:34、手册12:53、RPT:40）。**【推断】** "板卡私有链路"是文档未写明的措辞，但"同一网段里存在同 IP/同 MAC 的第二块板"是可实证事实，PC↔PC 走该网段会命中错误对端。
- Token 的值只在 DSH 凭据存储（`~/.dsh/.credentials.yaml` 的 `refs:` 段，写入用宿主工具 `team_link_setup`）与运行时物化的 `state/*.token`，**不进 git / 不进 issue / 不进聊天**；任何一层都不打印值；AgentCard 是公开面，禁止放路径与凭据。

## 4. 证据目录约定
- 工程侧：`prj\out\evidence_<日期>_<主题>\`（手册13:122）；早期无主题后缀（手册12:122）。
- 交付仓：`results\raw\<YYYYMMDD>_<owner>_<experiment>_v1\`，**append-only**：不覆盖、不就地改，修订另开 `_fix`（手册12:123、手册13:123）。
- 子目录分工（取自 RRAW:103-113 的实测镜像）：`report/`（总报告+专项）、`ila/`（ILA CSV，`ila6_`/`ila3_` 前缀）、`judge/`（判据脚本输出与轮询日志）、`pcap/`（抓包日志；pcap 本体不入库）、`serial/`（串口 U 寄存器快照）、`pc2_issue/`（issue 内对端原文归档）、`sim/logs`（仿真结论日志，`work/` 可删，DSR:205-212）、`SHA256SUMS.txt`。
- `audit/`：**文档未定义**（仅见 dma_stall/audit/xsct_jtag_probe.tcl:1-8 一例）。本技能起统一为"只读探针脚本与其输出"，禁止放位流与大文件。
- 大文件（.bit/.ltx/.pcap）**不入 git**，一律"路径 + SHA256"引用（手册12:127、手册13:89、IDX:3-4）。
- 每条证据都必须能被 `tools\evidence_pull.ps1` 拉回并**本地重算 SHA256 复核**；不一致即视为未交付。

## 5. 硬件操作约定
标准序列（手册12:45-63、手册12:164）：`list_targets.tcl` 认板 → `twin_burn.ps1 -Board <A|B> -Mode BitElf -Run`（期望 BURN_OK / BURN_ELF_DONE）→ `serial_dma_mode.ps1 -Com COMx`（期望 `now=DMA`；`d` 是**翻转**命令）→ `Get-NetAdapter` Up/1Gbps 后 `static_arp.ps1 -IfIndex <n>`（期望 State=Permanent）→ `ila_capture.tcl`（任意核用 `ila_capture_any.tcl ... probes.ltx <marker>`）→ `twin_send.py --count 3 --len 100 --run-id 0x91`（期望 pk_frames +3）→ `ila_poll_stable.tcl ... 600 5`（秒数/间隔）→ `pcap_capture.py --seconds 180`（**不加 BPF**）。
硬约束（全部实证，违反即烧错板或留卡死态）：
1. **单机禁 `-Board Both`**：两块板 JTAG 序列号同为 `210512180081`（手册12:31、手册12:105、VOB:14）。**【推断】** "一次只动一块板"是文档未写的措辞，等价约束就是这一条 + 下面两条窗口纪律。
2. **先对端就绪、再本板重烧**（手册12:19、RPT:91）：对端 `ilas=4` 且 `ch_up=1` → 重烧本板 + `d` → 3 帧探针 pk+3 → 才开 180 s 抓包窗。反序留下卡死态。
3. **重烧板 B 之后板 A 也必须重烧**（手册12:115、RRAW:73、issue #15）。
4. **Vivado 会话互斥**：实验前 `Get-Process vivado` 必须为空（VOB:10）；两台机器不得同时跑同一板卡的 ILA 抓取。
5. **V3 类受控闪断实验必须用打补丁前的旧位流**（VOB:220）。

## 6. 恢复阶梯（写通路死锁，B1 结论）
- 根因：`frame_mem_if` 内 5 个 async_fifo 的 `wr_rst_n`/`rd_rst_n` 分接 user/ui 两域，Aurora 闪断只单边复位 → 指针永久错位成"永久满"（DSR:14-18、DSR:83-91）。
- 唯一出口是 `ui_rst_n`：发 `d` 实测**无效**，整板 BitElf 重烧有效，耗时 60–90 s（DSR:34-39、手册12:103）。
- 因此"每次上电 / 每次对端闪断都要重烧两板"是当前**已知代价**（3 分钟人工量级），排期与自动化判据都要按这个量级算（CORR:54-60）。
- 根治路径 = B1 补丁（5 个 FIFO 两侧复位成对，产物 E9BE2B14，WNS +0.029 / WHS +0.004、0 失败端点，IDX:16、手册13:24），**但未上板验证**。转正唯一判据：闪断后**不重烧**直接发 3 帧，pk_frames +3（IDX:18、P13:69）。在此之前禁止对外称"已验证"。

## 7. 判据陷阱（曾产生假 PASS / 假 FAIL）
1. 单次**连续**抓包 ≥180 s，禁止分块：块间 1–2 s 空档会整轮漏掉 0.4 s 的 20 帧突发（手册12:20、RPT:30）。
2. 稳定性看 **5 s 轮询的 drops/resets**；"两次抓取计数不增长"会假 PASS，因为同域复位会把计数清零（手册12:74、RPT:32）。
3. `ch_up=1` **不等于**健康：实际已死锁的板上也能看到 ch_up=1（RPT:91）。
4. 回声帧 `dst_mac = ff:ff:ff:ff:ff:ff`，判据**不看** dst_mac（手册12:79、RPT:29）。

## 8. 通道不可用 → 退回 issue
触发条件：A2A/MCP 任一不可用；对端身份与 AgentCard 不符；判据/IP/角色有争议，通道上讲不清；需要可被第三方复核的决策记录。
动作三步：① `tools\collab_status.ps1` 留证（它会打印 `[FALLBACK]` 并写 `logs\collab_status.log`）；② 在共享仓开/更 issue，格式见下；③ 通道恢复后用 `tools\evidence_pull.ps1` 补齐通道期间证据并复核 SHA256。
issue 格式（沿用 #6/#10/#15 的实际风格）：首行 `## <YYYY-MM-DD> <主题>更新：<一句话结论带数字>`，正文分「事实/已完成」「待办 checkbox」「阻塞与依赖」「排期建议/执行顺序」「证据路径（含 SHA256）」五块，跨 issue 用 `#N` 互引。一交付一 issue，PR 用 `Closes #N`（DELIV:40、DELIV:47）。
标签：`A组/B组/接口/环境/实验/验收/阻塞/P0/P1/文档` + 里程碑 M1–M4（DELIV:51）。日更模板见 `templates/daily-audit-issue.md`（**本插件新立约定，仓库此前无此模板**）。

## 9. 禁止事项
- 禁止在两块板之间"顺便都烧一下"（同 JTAG 序列号，必烧错）。
- 禁止把 `ch_up=1`、`BURN_OK`、或单次抓包当"通过"。
- 禁止改对端的判据、抢对端的烧录窗口、擅自替对方决定板侧细节。
- 禁止把 Token、位流、pcap 贴进 issue 或聊天。
- 禁止在 B1 未过 `VERIFY_ON_BOARD` 前宣称"免重烧"。
