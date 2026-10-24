---
name: amd-doc-search
description: 检索 AMD/Xilinx 官方文档（Vivado/Vitis/UG/PG/Answer Record 等 612K+ 页，可按器件系列与版本过滤）。当问题涉及 Vivado Tcl 命令、UG901/UG906/UG949、时序/CDC/AXI/Aurora/MIG 等需要官方文档依据时使用：运行 `py <本技能目录>\doc_search.py "<query>"`，并引用返回的 docs.amd.com 链接。
metadata:
  version: "1.0.0"
baseline:
  amd_doc: "unspecified"
  tested_on: null
  status: unverified
  evidence: "doc_search.py 实跑 PASS 2026-10-24（py doc_search.py 'report_timing_summary' --version 2023.1 --limit 2 → exit 0, 3.09s, server=AMD Doc Search 0.11.6, 命中 UG835）；技能不调用 Vivado，无 2023.1 适用项"
---

# AMD 官方文档检索（hosted amd-doc-search）

**是什么**：AMD 托管的远程 MCP 检索服务（HTTP，`https://ross.amd.com/mcp/doc-search`），只有 `vivado_doc_search` 一个工具。本技能用一个 stdlib Python 脚本直接调它——**不依赖 MCP 客户端、不启动 Vivado、不改工程**。

**本机映射（如实，勿写成"已挂"）**：`vivado_doc_search`（AMD 官方 MCP 工具名）→ 本机 `mcp__vivado__*` 里**没有**对应工具，实际调用 `doc_search.py`（等价检索，见下方用法）；等重启 `dsh web` 后才会出现 `mcp__amd_doc_search__vivado_doc_search`，届时优先用它。

**何时用**：
- 需要官方依据：Vivado Tcl 命令/属性、UG901 综合、UG906 时序分析、UG949 方法学、UG903 约束、AXI/Aurora/MIG/DDR4、ILA/硬件调试、Answer Record 已知问题。
- 与本项目资料冲突、或本机文档没有覆盖时，用官方文档做交叉验证（契合 AGENTS.md 的 L0–L4 依据等级：官方文档可作 L3/L4 溯源）。

**何时不用**：
- 查正点原子 KU060 板卡手册/例程、本项目调试记录/坑账本 → 直接读 `D:\FPGA\docs`、`D:\FPGA\AGENTS.md`（本服务只有 AMD 英文文档，不含第三方/中文资料）。
- 涉及未公开设计细节、需要保密时 → 不要用（query 会发到 AMD 服务）。

## 用法（PowerShell，工作目录任意）

```powershell
$py = "C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe"
$s  = "C:\Users\15266\Desktop\毕设\.dsh\skills\amd-doc-search\doc_search.py"

& $py $s "incremental implementation compile UG904" --limit 3
& $py $s "ILA trigger setup" --family "Kintex UltraScale+" --limit 5
& $py $s "report_methodology" --version 2023.1 --tool "Vivado Design Suite" --alpha 0.5
& $py $s "Aurora 64b66b" --json          # 需要结构化结果时
```

参数：`--limit`(默认 5，1–50) · `--alpha`(默认 0.8，0=关键词/1=语义；查精确命令时降到 0.3–0.5) · `--family`(可重复，如 `Kintex UltraScale+`) · `--version`(可重复，如 `2023.1`) · `--tool`(可重复，如 `Vivado Design Suite`) · `--json`。
退出码：0 成功 / 1 协议或网络错误 / 2 服务端 isError。

## 结果解读与引用纪律

- 每个结果块形如 `DOC #UG904 [User Guide] ... url: https://docs.amd.com/r/2023.1-English/...`。
- **必须引用 URL**；只写结果里有依据的内容，不臆造命令/参数/约束；多个结果冲突时列出冲突并说明。
- 结果为空/不相关：明确说"官方文档未检索到"，换关键词或缩小过滤条件（`family`/`version`/`tool`）重试一次，仍无则如实报告。
- 单次调用约 1 s（公网）；不要连续高频调用（服务无公开限流说明，保持礼貌间隔）。

## 环境与排障

- 需要联网；服务免 API key。若返回 `HTTP 4xx/5xx` 或超时，先重试一次；仍失败则改用 `web_fetch` 直读 `https://docs.amd.com` 对应 UG 页面。
- 索引仅英文、仅 AMD 已公开发布的文档；NDA/EA 受限文档不在其中。
- **升级路径**：DSH 已配置原生 MCP（`serverName=amd_doc_search`，`~/.dsh/profiles/web/cordis.patch.yml`），**下次重启 `dsh web` 后**模型侧会直接出现 `mcp__amd_doc_search__vivado_doc_search` 工具；届时优先用原生工具，本脚本保留为不支持 MCP 的 agent 或应急备用。
