# AI Doc Read Studio

基于多 AI 角色的文档审阅与自动改进应用。上传文档后，多个"专家"角色（产品、技术、测试、设计等）进行多轮讨论与辩论，并由文档改进 Agent（ReAct 架构）根据讨论结果自动改进文档。

---

## 功能概览

- **文档上传**：支持 TXT、Markdown（.md）格式
- **多角色讨论**：配置不同 AI 角色，围绕文档内容逐条发言
- **辩论轮**：首轮讨论后，各角色可对他人观点进行挑战、补充，形成多轮对话
- **实时流式输出**：通过 WebSocket 逐条展示回复，支持"正在输入"状态
- **可执行摘要**：根据讨论生成 Markdown 行动清单
- **文档改进 Agent**：基于 ReAct + Function Calling + 反思 + 长期记忆，自动多轮改进文档并输出改进报告

---

## 技术栈

| 层级     | 技术说明 |
|----------|----------|
| 后端     | 仓颉（Cangjie），REST + WebSocket |
| AI 调用  | OpenAI 兼容 API（可配置 `OPENAI_BASE_URL` 使用其他网关） |
| 文档改进 | ReAct + Function Calling + 反思 + 长期记忆 |
| 前端     | 原生 JS，单页应用（由后端一并托管） |

---

## 快速开始

### 环境要求

| 依赖 | 说明 |
|------|------|
| 仓颉（Cangjie）SDK | 含 `cjpm`，建议安装到 `D:\Cangjie` 或 `C:\Cangjie` |
| Windows 10/11 | 当前仅支持 Windows（start.ps1） |
| OpenSSL 3 DLL | `libssl-3-x64.dll` / `libcrypto-3-x64.dll`（MySQL 8.0 安装目录自带） |
| OpenAI 兼容 API | 需有效的 API Key |

### 安装步骤

```powershell
# 1. 克隆项目
git clone https://github.com/<你的用户名>/ai-doc-read-studio.git
cd ai-doc-read-studio

# 2. 配置 API Key（复制示例后填入你的 Key 和 Base URL）
Copy-Item .env.example .env
notepad .env

# 3. （可选）修改 cjpm.toml 中的 stdx 路径（见下方说明）

# 4. 一键启动
.\start.ps1
```

启动后访问：**http://localhost:8000/**

### 配置 .env

```env
# 必填
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxx

# 可选，默认 https://api.openai.com/v1
OPENAI_BASE_URL=https://api.openai.com/v1
```

> `.env` 已被 `.gitignore` 忽略，不会上传到 GitHub。

### 配置 cjpm.toml（stdx 路径）

`cangjie-backend/cjpm.toml` 中的 `path-option` 指向仓颉扩展标准库（stdx）的本地路径，**克隆后需改成你自己的解压路径**：

```toml
[target.x86_64-w64-mingw32.bin-dependencies]
path-option = ["C:/你的路径/cangjie-stdx/windows_x86_64_llvm/dynamic/stdx"]
```

stdx 下载：https://cangjie-lang.cn/download → 选择 Windows x64 版本解压即可。

---

## 使用流程

1. **上传文档**：在左侧上传 TXT 或 Markdown 文件（最多 10 个）
2. **配置团队**：添加成员并设置姓名、角色、模型；可加载/保存团队模板
3. **开始讨论**：输入首条提示（如"请审阅并给出初步反馈"），各角色会逐条回复并实时展示
4. **辩论与追问**：首轮结束后自动进入辩论轮；也可继续提问
5. **导出**：导出对话为 Markdown；可生成可执行摘要（Action Plan）
6. **文档改进**（可选）：点击「运行文档改进」，系统从讨论中抽取建议，Agent 多轮调用工具改文档，输出改进报告与可下载的文档

---

## 项目结构

```
ai-doc-read-studio/
├── cangjie-backend/
│   ├── src/
│   │   ├── main.cj                  # 后端入口、会话、上传、WebSocket、导出 + 静态前端托管
│   │   ├── agents.cj                # 多角色讨论与辩论轮
│   │   ├── document_parser.cj       # 文档解析（支持 TXT/MD）
│   │   ├── agent_engine/
│   │   │   ├── agent_loop.cj        # 主循环：迭代 → ReAct → 验证 → 反思
│   │   │   ├── llm_agent.cj         # ReAct + Function Calling
│   │   │   ├── reflection.cj        # 改进效果评估
│   │   │   └── memory.cj            # 长期记忆
│   │   ├── tools/
│   │   │   ├── document_tools.cj    # 文档修改工具（词汇表、摘要、案例、图示）
│   │   │   └── validation_tools.cj  # 文档质量验证器（5个维度）
│   │   └── utils/
│   │       ├── http_client.cj       # HTTP/流式请求
│   │       ├── json_helper.cj
│   │       └── env.cj               # .env 读取
│   ├── cjpm.toml                    # 构建配置（注意修改 stdx 路径）
│   └── start.ps1                    # 编译 + 启动脚本（自动处理 OpenSSL DLL 和 PATH）
├── frontend/
│   ├── index.html
│   ├── app.js
│   └── config.js
├── config.json                      # 应用与模型配置（端口、可用模型等）
├── .env.example                     # 环境变量示例（复制为 .env 后填入 Key）
└── start.ps1                        # 根目录一键启动（调用 cangjie-backend/start.ps1）
```

---

## 常见问题

**Q：启动时提示 `cjpm` 找不到？**
A：`start.ps1` 会自动检测 `D:\Cangjie` 和 `C:\Cangjie`。若安装在其他路径，请在 `start.ps1` 开头手动指定 `$cangjieRoot`。

**Q：编译报 stdx 路径找不到？**
A：修改 `cangjie-backend/cjpm.toml` 中的 `path-option` 为你本机的 stdx 解压路径（见上方说明）。

**Q：启动后没有 AI 回复？**
A：检查 `.env` 中 `OPENAI_API_KEY` 和 `OPENAI_BASE_URL` 是否填写正确。

**Q：运行文档改进报错？**
A：需先完成至少一轮讨论，系统从对话记录中抽取改进建议后才能运行 Agent。

**Q：上传 DOCX/PDF 失败？**
A：当前仅支持 TXT 和 Markdown 格式解析。请将文档另存为 UTF-8 编码的 `.md` 或 `.txt` 再上传。

**Q：端口冲突？**
A：在 `config.json` 中修改端口号，默认后端 8000。

---

## 许可证

MIT，详见 [LICENSE](LICENSE)。
