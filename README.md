# AI Doc Read Studio

基于多 AI 角色的文档审阅与改进应用：上传文档后，多个“专家”角色（产品、技术、测试、设计等）参与讨论与辩论，并可根据讨论结果自动改进文档。

---

## 功能概览

- **文档上传**：支持 TXT、Markdown、Word（.docx）、PDF
- **多角色讨论**：配置不同 AI 角色（产品经理、技术负责人、QA、UX、主持人等），围绕文档逐条发言
- **辩论轮**：首轮讨论后，各角色可对他人观点进行挑战、补充或共识，形成多轮对话
- **实时流式输出**：通过 WebSocket 一条条展示回复，支持“正在输入”状态
- **可执行摘要**：根据讨论生成 Markdown 行动清单
- **文档改进 Agent**：根据讨论与辩论中的建议，用 ReAct + 工具（术语表、摘要、案例、图表说明等）自动改文档，多轮验证与反思后输出改进版

---

## 技术栈

| 层级     | 技术说明 |
|----------|----------|
| 后端     | 仓颉（Cangjie），REST + WebSocket |
| AI 调用  | OpenAI 兼容 API（可配置 `OPENAI_BASE_URL` 使用其他网关） |
| 文档改进 | ReAct + Function Calling + 反思 + 长期记忆 |
| 前端     | 原生 JS，单页应用 |

---

## 快速开始

### 环境要求

- 仓颉（Cangjie）SDK（含 `cjpm`）

### 安装与运行

```bash
cd ai-doc-read-studio

# 配置环境变量：复制示例后编辑 .env，填入 OPENAI_API_KEY
copy .env.example .env

# Windows：一键启动（仓颉后端会同时托管前端静态文件）
.\start.ps1
```

- **前端（Web UI）**：`http://localhost:8000/`
- **后端 API**：`http://localhost:8000/`

### 环境变量（.env）

```bash
# 必填：OpenAI 兼容 API 的 Key
OPENAI_API_KEY=your-api-key

# 可选：API 基地址，默认 https://api.openai.com/v1
OPENAI_BASE_URL=https://api.openai.com/v1
```

可将 `OPENAI_BASE_URL` 指向其他兼容 OpenAI 的网关（如各类中转或 Bedrock 代理）。

---

## 使用流程

1. **上传文档**：在左侧上传 TXT/MD/DOCX/PDF（最多 10 个）。
2. **配置团队**：添加成员并设置姓名、角色、模型；可加载/保存团队模板。
3. **开始讨论**：输入首条提示（如“请审阅并给出初步反馈”），各角色会**逐条**回复并实时展示。
4. **辩论与追问**：首轮结束后自动进入辩论轮；也可在输入框继续提问。
5. **导出**：导出对话为 Markdown/PDF；可生成可执行摘要（Action Plan）。
6. **文档改进**（可选）：点击「运行文档改进」，系统会从讨论+辩论中抽取建议，由文档改进 Agent 多轮调用工具改文档，并给出改进报告与可下载的文档。

---

## 项目结构

```
ai-doc-read-studio/
├── cangjie-backend/
│   ├── src/
│   │   ├── main.cj              # 后端入口、会话、上传、WebSocket、导出 + 静态前端托管
│   │   ├── agents.cj            # 多角色讨论与辩论轮
│   │   ├── document_parser.cj   # 文档解析（TXT/MD；DOCX/PDF 当前不支持）
│   │   ├── agent_engine/        # 文档改进 Agent
│   │   │   ├── agent_loop.cj    # 主循环：迭代 → ReAct → 验证 → 反思
│   │   │   ├── llm_agent.cj     # ReAct + Function Calling 工具定义与执行
│   │   │   ├── reflection.cj    # 改进效果评估与是否继续
│   │   │   └── memory.cj        # 长期记忆（策略与教训）
│   │   ├── tools/
│   │   │   ├── document_tools.cj
│   │   │   └── validation_tools.cj
│   │   └── utils/
│   │       ├── http_client.cj
│   │       ├── json_helper.cj
│   │       └── env.cj
│   └── start.ps1             # 编译 + 运行（处理 OpenSSL DLL）
├── frontend/
│   ├── index.html
│   ├── app.js
│   └── config.js
├── config.json              # 应用与模型配置
└── start.ps1                # 根目录一键启动（调用 cangjie-backend/start.ps1）
```

---

## 配置说明

- **config.json**：后端/前端端口、日志路径、可用模型列表与默认模型等。
- **.env**：`OPENAI_API_KEY`、`OPENAI_BASE_URL`，不要提交到 Git。

---

## 开发与测试

```bash
# 后端（仓颉）
cd cangjie-backend
cjpm build
cjpm run
```

---

## 常见问题

- **端口占用**：默认后端 8000、前端 3000，可在 `config.json` 中修改。
- **首次输入无回复**：确保 `.env` 中 `OPENAI_API_KEY` 和 `OPENAI_BASE_URL` 正确；回复会先通过 WebSocket 逐条展示，HTTP 返回后也会用完整会话渲染一次。
- **文档改进报错**：需先完成至少一轮讨论，以便从对话中抽取改进建议。
- **DOCX/PDF 上传失败**：仓颉版当前仅支持 TXT/MD 解析；请先将文档另存为 UTF-8 的 `.md` 或 `.txt` 再上传。

---

## 许可证

MIT，详见 [LICENSE](LICENSE)。
