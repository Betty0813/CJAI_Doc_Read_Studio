"""
LLM Agent - Function Calling + ReAct 推理链
让文档改进循环成为真正的 Agent：LLM 自主选择工具、逐步推理、观察反馈
"""

import json
import re
import os
from typing import Dict, List, Any, Optional
import structlog
from openai import AsyncOpenAI

logger = structlog.get_logger(__name__)

MAX_DOC_CHARS = 12000
MAX_REACT_STEPS = 8


def _truncate(s: str, max_len: int) -> str:
    if not s or len(s) <= max_len:
        return s or ""
    return s[:max_len] + "\n\n...(truncated)"


# ---------------------------------------------------------------------------
# 1) OpenAI Function Calling: Tool 定义
# ---------------------------------------------------------------------------

AGENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "add_glossary",
            "description": "Add a glossary of technical terms extracted from the document. Call this when reviewers ask for definitions, or the document has unexplained jargon / acronyms.",
            "parameters": {
                "type": "object",
                "properties": {
                    "terms": {
                        "type": "array",
                        "description": "5-10 key terms from the document with clear definitions",
                        "items": {
                            "type": "object",
                            "properties": {
                                "term": {"type": "string"},
                                "definition": {"type": "string"},
                            },
                            "required": ["term", "definition"],
                        },
                    }
                },
                "required": ["terms"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_executive_summary",
            "description": "Add an executive summary (2-4 paragraphs) to the beginning of the document. Call this when reviewers suggest adding an overview / summary.",
            "parameters": {
                "type": "object",
                "properties": {
                    "summary": {
                        "type": "string",
                        "description": "2-4 paragraph executive summary capturing main points, findings, and conclusions. Must be real content, not placeholder.",
                    }
                },
                "required": ["summary"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_case_studies",
            "description": "Add real-world case studies or practical examples to the document.",
            "parameters": {
                "type": "object",
                "properties": {
                    "cases": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "title": {"type": "string"},
                                "description": {"type": "string"},
                                "results": {"type": "string"},
                            },
                            "required": ["title", "description", "results"],
                        },
                    }
                },
                "required": ["cases"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "enhance_visuals",
            "description": "Enhance figure/chart captions and add formatting guidance.",
            "parameters": {
                "type": "object",
                "properties": {
                    "enhancements": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "figure_ref": {"type": "string"},
                                "enhanced_caption": {"type": "string"},
                            },
                            "required": ["figure_ref", "enhanced_caption"],
                        },
                    }
                },
                "required": ["enhancements"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "validate_document",
            "description": "Run quality validation checks on the current document and get scores for glossary, visuals, structure, readability, and evidence support. Use this to observe the effect of your changes.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "finish_improvement",
            "description": "Signal that document improvement is complete. Call this when you believe the document is sufficiently improved or further changes would not help.",
            "parameters": {
                "type": "object",
                "properties": {
                    "reasoning": {
                        "type": "string",
                        "description": "Brief explanation of what was achieved and why you are stopping",
                    }
                },
                "required": ["reasoning"],
            },
        },
    },
]


# ---------------------------------------------------------------------------
# 2) Tool 执行器：接收 function name + args，修改文档，返回 observation
# ---------------------------------------------------------------------------

def execute_tool_call(
    function_name: str,
    arguments: Dict[str, Any],
    document_tools,
    document_validator,
    current_document: str,
) -> tuple[str, str]:
    """
    执行一个 tool call。
    返回 (observation_text, updated_document)。
    """
    try:
        if function_name == "add_glossary":
            items = arguments.get("terms", [])
            action = document_tools.create_glossary_action(items)
            updated = action.execute(current_document)
            obs = f"Added glossary with {len(items)} terms: {', '.join(t.get('term','') for t in items[:5])}"
            return obs, updated

        elif function_name == "add_executive_summary":
            summary = arguments.get("summary", "")
            action = document_tools.create_summary_action(summary)
            updated = action.execute(current_document)
            obs = f"Added executive summary ({len(summary)} chars)"
            return obs, updated

        elif function_name == "add_case_studies":
            cases = arguments.get("cases", [])
            action = document_tools.create_case_studies_action(cases)
            updated = action.execute(current_document)
            obs = f"Added {len(cases)} case studies"
            return obs, updated

        elif function_name == "enhance_visuals":
            enhancements = arguments.get("enhancements", [])
            action = document_tools.create_visual_enhancement_action(enhancements)
            updated = action.execute(current_document)
            obs = f"Enhanced {len(enhancements)} visual elements"
            return obs, updated

        elif function_name == "validate_document":
            document_validator.validate_glossary_completeness(current_document)
            document_validator.validate_visual_consistency(current_document)
            document_validator.validate_structure_compliance(current_document)
            document_validator.validate_readability(current_document)
            document_validator.validate_evidence_support(current_document)
            metrics = {
                name: round(m.score, 1)
                for name, m in document_validator.metrics.items()
            }
            obs = f"Validation metrics: {json.dumps(metrics)}"
            return obs, current_document

        elif function_name == "finish_improvement":
            reasoning = arguments.get("reasoning", "Completed")
            obs = f"FINISHED: {reasoning}"
            return obs, current_document

        else:
            return f"Unknown tool: {function_name}", current_document

    except Exception as e:
        logger.warning("Tool execution error", tool=function_name, error=str(e))
        return f"Error executing {function_name}: {str(e)}", current_document


# ---------------------------------------------------------------------------
# 3) ReAct 循环：Think → Act (Function Call) → Observe → Think → …
# ---------------------------------------------------------------------------

REACT_SYSTEM_PROMPT = """You are a document improvement agent that uses the ReAct pattern (Reasoning + Acting).

You have access to tools for modifying and validating a document. Your job:
1. Read the document and reviewer recommendations
2. THINK about what improvements are needed (output your reasoning as text)
3. ACT by calling the appropriate tool
4. OBSERVE the result
5. THINK again: did it work? What else is needed?
6. Repeat until the document is sufficiently improved, then call finish_improvement

IMPORTANT RULES:
- Always THINK before acting — explain your reasoning in the message content
- Use validate_document after making changes to check the effect
- Extract REAL terms/content from the document — never use placeholder text
- Call finish_improvement when done — don't loop forever
- Use the same language as the document (Chinese or English)

{memory_context}"""


async def react_loop(
    client: AsyncOpenAI,
    model: str,
    document_content: str,
    recommendations: List[str],
    document_tools,
    document_validator,
    memory_context: str = "",
    max_steps: int = MAX_REACT_STEPS,
) -> Dict[str, Any]:
    """
    ReAct 推理循环：LLM 自主思考 → 选工具 → 观察 → 再思考。

    Returns:
        {
            "document": str,           # 改进后的文档
            "steps": List[Dict],       # 每步的 thought/action/observation
            "actions_taken": List[str], # 执行的工具名称列表
            "final_reasoning": str,     # 最终的推理/总结
        }
    """
    doc = document_content
    recs_text = "\n".join(f"- {r}" for r in recommendations[:20])

    system = REACT_SYSTEM_PROMPT.format(
        memory_context=memory_context if memory_context else ""
    )

    messages = [
        {"role": "system", "content": system},
        {
            "role": "user",
            "content": (
                f"Document (excerpt):\n{_truncate(doc, MAX_DOC_CHARS)}\n\n"
                f"Reviewer recommendations:\n{recs_text}\n\n"
                "Think step by step about what improvements to make, then use your tools. "
                "Start by explaining your plan, then act."
            ),
        },
    ]

    steps = []
    actions_taken = []
    final_reasoning = ""

    for step_idx in range(max_steps):
        try:
            resp = await client.chat.completions.create(
                model=model,
                messages=messages,
                tools=AGENT_TOOLS,
                tool_choice="auto",
                temperature=0.3,
            )
        except Exception as e:
            logger.warning("ReAct LLM call failed", step=step_idx, error=str(e))
            break

        msg = resp.choices[0].message
        thought = msg.content or ""

        # 记录思考
        if thought:
            logger.info("ReAct thought", step=step_idx, thought=thought[:120])

        # 无 tool call → agent 在纯思考或出错，追加后继续
        if not msg.tool_calls:
            steps.append({"step": step_idx, "thought": thought, "action": None, "observation": None})
            final_reasoning = thought
            # 如果 LLM 没调工具也没说 finish，再给一次机会
            messages.append({"role": "assistant", "content": thought})
            messages.append({
                "role": "user",
                "content": "Please use a tool to take action, or call finish_improvement if you're done.",
            })
            continue

        # 处理 tool calls
        messages.append(msg)  # 包含 tool_calls 的 assistant message

        for tc in msg.tool_calls:
            fn_name = tc.function.name
            try:
                fn_args = json.loads(tc.function.arguments)
            except json.JSONDecodeError:
                fn_args = {}

            logger.info("ReAct action", step=step_idx, tool=fn_name)

            observation, doc = execute_tool_call(
                fn_name, fn_args, document_tools, document_validator, doc
            )

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": observation,
            })

            steps.append({
                "step": step_idx,
                "thought": thought,
                "action": fn_name,
                "action_args": fn_args,
                "observation": observation,
            })
            actions_taken.append(fn_name)

            if fn_name == "finish_improvement":
                final_reasoning = fn_args.get("reasoning", thought)
                return {
                    "document": doc,
                    "steps": steps,
                    "actions_taken": actions_taken,
                    "final_reasoning": final_reasoning,
                }

    # 如果用完了步数但没 finish
    if not final_reasoning:
        final_reasoning = "Reached maximum ReAct steps"

    return {
        "document": doc,
        "steps": steps,
        "actions_taken": actions_taken,
        "final_reasoning": final_reasoning,
    }


# ---------------------------------------------------------------------------
# 4) LLM 反思（保留，用于 react_loop 之后的宏观反思）
# ---------------------------------------------------------------------------

async def reflect_with_llm(
    client: AsyncOpenAI,
    model: str,
    iteration_number: int,
    metrics_before: Dict[str, float],
    metrics_after: Dict[str, float],
    actions_taken: List[str],
    react_reasoning: str,
    max_iterations: int,
) -> Dict[str, Any]:
    """
    宏观反思：在一轮 ReAct 之后，评估效果并决定是否继续。
    """
    system = """You are a document quality agent performing reflection after an improvement iteration.
Based on metrics, actions taken, and the agent's reasoning, decide:
1. Was this iteration effective?
2. Should we do another iteration?
3. What should the next iteration focus on?

Output ONLY valid JSON:
{
  "reasoning": "2-3 sentences analyzing the iteration results.",
  "should_continue": true or false,
  "next_steps": ["specific action 1", "action 2"] or [],
  "lesson_learned": "One sentence about what worked or didn't work (for long-term memory)."
}

Rules:
- If improvement is very small and iteration >= 2, prefer should_continue: false.
- If iteration >= max_iterations, set should_continue: false.
- next_steps only when should_continue is true."""

    user = f"""Iteration: {iteration_number} / {max_iterations}
Metrics before: {json.dumps(metrics_before)}
Metrics after: {json.dumps(metrics_after)}
Actions taken: {actions_taken}
Agent reasoning: {react_reasoning[:500]}

Output JSON only."""

    try:
        resp = await client.chat.completions.create(
            model=model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            temperature=0.2,
        )
        text = (resp.choices[0].message.content or "").strip()
        if "```" in text:
            text = re.sub(r"^```(?:json)?\s*", "", text)
            text = re.sub(r"\s*```\s*$", "", text)
        data = json.loads(text)
        should_continue = bool(data.get("should_continue", False))
        if iteration_number >= max_iterations:
            should_continue = False
        return {
            "reasoning": str(data.get("reasoning", "")),
            "should_continue": should_continue,
            "next_steps": data.get("next_steps") if isinstance(data.get("next_steps"), list) else [],
            "lesson_learned": str(data.get("lesson_learned", "")),
        }
    except Exception as e:
        logger.warning("LLM reflect failed", error=str(e))
        return {
            "reasoning": react_reasoning,
            "should_continue": iteration_number < max_iterations,
            "next_steps": [],
            "lesson_learned": "",
        }
