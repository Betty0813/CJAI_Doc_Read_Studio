"""
Agent Loop Orchestrator - ReAct + Function Calling + Memory
每轮迭代 = ReAct 循环 (Think→Act→Observe→…) + 宏观反思 + 长期记忆
"""

import asyncio
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
import structlog
from openai import AsyncOpenAI

from ..tools.document_tools import DocumentTools
from ..tools.validation_tools import DocumentValidator
from .reflection import ReflectionEngine
from . import llm_agent
from .memory import AgentMemory, agent_memory

logger = structlog.get_logger(__name__)


class AgentState(Enum):
    IDLE = "idle"
    PLANNING = "planning"
    EXECUTING = "executing"         # ReAct 循环中
    OBSERVING = "observing"
    REFLECTING = "reflecting"
    COMPLETED = "completed"
    FAILED = "failed"


@dataclass
class AgentIterationResult:
    iteration_number: int
    state: AgentState
    plan: Optional[Dict[str, Any]]
    actions_taken: Optional[List[str]]
    react_steps: Optional[List[Dict]] = field(default_factory=list)
    validation_metrics: Optional[Dict[str, float]] = None
    reflection: Optional[Dict[str, Any]] = None
    timestamp: str = ""
    error: Optional[str] = None


class AgentLoopManager:
    """Agent 循环管理器 — ReAct + Function Calling + Memory"""

    def __init__(
        self,
        api_key: str = None,
        base_url: str = None,
        model: str = "gpt-4o-mini",
        max_iterations: int = 3,
        memory: AgentMemory = None,
    ):
        import os

        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        self.base_url = base_url or os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")
        self.model = model
        self.max_iterations = max_iterations
        self.memory = memory or agent_memory

        self._async_client: Optional[AsyncOpenAI] = (
            AsyncOpenAI(api_key=self.api_key, base_url=self.base_url) if self.api_key else None
        )
        self.document_tools = DocumentTools()
        self.document_validator = DocumentValidator()
        self.reflection_engine = ReflectionEngine(max_iterations=max_iterations)

        self.current_state = AgentState.IDLE
        self.iteration_results: List[AgentIterationResult] = []
        self.current_document: Optional[str] = None
        self.original_feedback: Optional[Dict[str, Any]] = None
        self._metrics_before: Dict[str, float] = {}

    # ------------------------------------------------------------------
    # 主循环
    # ------------------------------------------------------------------

    async def run_agent_loop(
        self,
        document_content: str,
        feedback_analysis: Dict[str, Any],
        session_id: str = None,
    ) -> Dict[str, Any]:
        logger.info("Starting agent loop (ReAct + FC)")
        self.current_document = document_content
        self.original_feedback = feedback_analysis
        self._metrics_before = {}
        self.iteration_results = []
        self.reflection_engine = ReflectionEngine(max_iterations=self.max_iterations)

        recommendations = feedback_analysis.get("synthesized_recommendations", [])
        if not recommendations:
            return self._generate_final_report()

        # 从长期记忆中检索相关策略
        memory_context = self.memory.get_relevant_strategies(document_content[:3000])
        lessons = self.memory.get_lessons(top_k=3)
        if lessons:
            memory_context += "\n\nLessons from past sessions:\n" + "\n".join(f"- {l}" for l in lessons)

        iteration_number = 0

        while iteration_number < self.max_iterations:
            iteration_number += 1
            logger.info(f"Starting iteration {iteration_number}")

            try:
                # Step 0: 验证当前文档（获取 before metrics）
                self.current_state = AgentState.OBSERVING
                if not self._metrics_before:
                    self._metrics_before = await self._validate_document()

                # Step 1+2: ReAct 循环 (Plan + Execute 合一)
                self.current_state = AgentState.EXECUTING
                react_result = await self._run_react_iteration(
                    recommendations, memory_context
                )

                if react_result:
                    self.current_document = react_result["document"]
                    actions_taken = react_result["actions_taken"]
                    react_steps = react_result["steps"]
                    final_reasoning = react_result["final_reasoning"]
                else:
                    actions_taken = []
                    react_steps = []
                    final_reasoning = "ReAct loop did not run (no LLM client)"

                # Step 3: 验证改进后的文档
                self.current_state = AgentState.OBSERVING
                metrics_after = await self._validate_document()

                # Step 4: 宏观反思
                self.current_state = AgentState.REFLECTING
                reflection = await self._reflect(
                    iteration_number, actions_taken, final_reasoning,
                    self._metrics_before, metrics_after
                )

                result = AgentIterationResult(
                    iteration_number=iteration_number,
                    state=self.current_state,
                    plan={"recommendations": recommendations},
                    actions_taken=actions_taken,
                    react_steps=react_steps,
                    validation_metrics=metrics_after,
                    reflection=reflection,
                    timestamp=datetime.now().isoformat(),
                )
                self.iteration_results.append(result)
                self._metrics_before = metrics_after

                # 存入长期记忆
                if actions_taken:
                    self.memory.store_improvement_result(
                        session_id=session_id or "unknown",
                        actions=actions_taken,
                        metrics_before=self._metrics_before,
                        metrics_after=metrics_after,
                        reasoning=final_reasoning,
                    )
                lesson = reflection.get("lesson_learned", "")
                if lesson:
                    self.memory.store_lesson(lesson, session_id=session_id)

                if not reflection.get("should_continue", False):
                    logger.info("Agent loop stopping", reason=reflection.get("reasoning", ""))
                    break

                # 准备下一轮的建议
                next_steps = reflection.get("next_steps", [])
                if next_steps:
                    recommendations = next_steps

            except Exception as e:
                logger.error(f"Error in iteration {iteration_number}", error=str(e))
                self.iteration_results.append(AgentIterationResult(
                    iteration_number=iteration_number,
                    state=self.current_state,
                    plan=None,
                    actions_taken=None,
                    timestamp=datetime.now().isoformat(),
                    error=str(e),
                ))
                break

        self.current_state = AgentState.COMPLETED
        report = self._generate_final_report()
        logger.info("Agent loop completed", iterations=iteration_number)
        return report

    # ------------------------------------------------------------------
    # ReAct 迭代
    # ------------------------------------------------------------------

    async def _run_react_iteration(
        self,
        recommendations: List[str],
        memory_context: str,
    ) -> Optional[Dict[str, Any]]:
        if not self._async_client:
            # 无 LLM → 退回规则执行
            return await self._fallback_execute(recommendations)

        try:
            return await llm_agent.react_loop(
                client=self._async_client,
                model=self.model,
                document_content=self.current_document or "",
                recommendations=recommendations,
                document_tools=self.document_tools,
                document_validator=self.document_validator,
                memory_context=memory_context,
            )
        except Exception as e:
            logger.warning("ReAct loop failed, using fallback", error=str(e))
            return await self._fallback_execute(recommendations)

    async def _fallback_execute(self, recommendations: List[str]) -> Dict[str, Any]:
        """无 LLM 时的规则回退"""
        actions = self._recommendations_to_actions(recommendations)
        executed = []
        for spec in actions:
            t = spec.get("type")
            if t == "add_glossary":
                a = self.document_tools.create_glossary_action(spec.get("items", []))
                self.current_document = a.execute(self.current_document)
                executed.append("add_glossary")
            elif t == "add_summary":
                a = self.document_tools.create_summary_action(spec.get("content", ""))
                self.current_document = a.execute(self.current_document)
                executed.append("add_summary")
            elif t == "add_case_studies":
                a = self.document_tools.create_case_studies_action(spec.get("cases", []))
                self.current_document = a.execute(self.current_document)
                executed.append("add_case_studies")
            elif t == "enhance_visuals":
                a = self.document_tools.create_visual_enhancement_action(spec.get("enhancements", []))
                self.current_document = a.execute(self.current_document)
                executed.append("enhance_visuals")
        return {
            "document": self.current_document,
            "steps": [{"step": 0, "thought": "Rule-based fallback", "action": a, "observation": "ok"} for a in executed],
            "actions_taken": executed,
            "final_reasoning": "Executed via rule-based fallback (no LLM client)",
        }

    # ------------------------------------------------------------------
    # 验证
    # ------------------------------------------------------------------

    async def _validate_document(self) -> Dict[str, float]:
        try:
            doc = self.current_document or ""
            self.document_validator.validate_glossary_completeness(doc)
            self.document_validator.validate_visual_consistency(doc)
            self.document_validator.validate_structure_compliance(doc)
            self.document_validator.validate_readability(doc)
            self.document_validator.validate_evidence_support(doc)
            return {name: m.score for name, m in self.document_validator.metrics.items()}
        except Exception as e:
            logger.error("Validation failed", error=str(e))
            return {}

    # ------------------------------------------------------------------
    # 宏观反思
    # ------------------------------------------------------------------

    async def _reflect(
        self,
        iteration_number: int,
        actions_taken: List[str],
        react_reasoning: str,
        metrics_before: Dict[str, float],
        metrics_after: Dict[str, float],
    ) -> Dict[str, Any]:
        # 规则反思（始终执行，作为 baseline）
        rule_result = self.reflection_engine.evaluate_improvements(
            iteration_number=iteration_number,
            original_feedback=self.original_feedback,
            validation_metrics_before=metrics_before,
            validation_metrics_after=metrics_after,
            actions_taken=actions_taken,
        )
        result = {
            "iteration": iteration_number,
            "improvements": [
                {"metric": m.metric_name, "before": m.before_score, "after": m.after_score,
                 "improvement": m.improvement, "status": m.status}
                for m in rule_result.improvements
            ],
            "overall_improvement_score": rule_result.overall_improvement_score,
            "converged": rule_result.converged,
            "should_continue": rule_result.should_continue,
            "reasoning": rule_result.reasoning,
            "next_steps": rule_result.next_steps,
            "lesson_learned": "",
        }

        # LLM 反思（覆盖推理和决策）
        if self._async_client:
            llm_ref = await llm_agent.reflect_with_llm(
                self._async_client, self.model,
                iteration_number, metrics_before, metrics_after,
                actions_taken, react_reasoning, self.max_iterations,
            )
            result["reasoning"] = llm_ref.get("reasoning") or result["reasoning"]
            result["should_continue"] = llm_ref.get("should_continue", result["should_continue"])
            result["next_steps"] = llm_ref.get("next_steps") or result["next_steps"]
            result["converged"] = not result["should_continue"]
            result["lesson_learned"] = llm_ref.get("lesson_learned", "")

        return result

    # ------------------------------------------------------------------
    # 辅助
    # ------------------------------------------------------------------

    def _recommendations_to_actions(self, recommendations: List[str]) -> List[Dict[str, Any]]:
        actions = []
        for rec in recommendations:
            rl = rec.lower()
            if "glossary" in rl or "术语" in rec:
                actions.append({"type": "add_glossary", "items": [
                    {"term": "Term 1", "definition": "Definition 1"},
                ]})
            elif "summary" in rl or "摘要" in rec:
                actions.append({"type": "add_summary", "content": "Executive summary."})
            elif "case" in rl or "案例" in rec:
                actions.append({"type": "add_case_studies", "cases": [
                    {"title": "Example", "description": "Description", "results": "Results"},
                ]})
            elif "visual" in rl or "图" in rec:
                actions.append({"type": "enhance_visuals", "enhancements": [
                    {"figure_ref": "Figure 1", "enhanced_caption": "Enhanced caption"},
                ]})
        return actions

    def _generate_final_report(self) -> Dict[str, Any]:
        reflection_report = self.reflection_engine.generate_final_report()
        return {
            "status": "completed",
            "total_iterations": len(self.iteration_results),
            "final_state": self.current_state.value,
            "converged": reflection_report.get("converged"),
            "total_improvement_score": reflection_report.get("total_improvement_score"),
            "improvements": reflection_report,
            "iteration_history": [
                {
                    "iteration": r.iteration_number,
                    "actions": r.actions_taken,
                    "react_steps": r.react_steps,
                    "metrics": r.validation_metrics,
                    "reflection": r.reflection,
                    "timestamp": r.timestamp,
                    "error": r.error,
                }
                for r in self.iteration_results
            ],
            "final_document_preview": (
                self.current_document[:500] + "..."
                if self.current_document and len(self.current_document) > 500
                else (self.current_document or "")
            ),
            "final_document": self.current_document or "",
            "memory_stats": self.memory.get_stats(),
            "timestamp": datetime.now().isoformat(),
        }

    def get_current_status(self) -> Dict[str, Any]:
        return {
            "state": self.current_state.value,
            "iterations_completed": len(self.iteration_results),
            "max_iterations": self.max_iterations,
            "last_iteration": (
                self.iteration_results[-1] if self.iteration_results else None
            ),
        }


agent_loop_manager = AgentLoopManager()
