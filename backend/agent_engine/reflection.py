"""
Reflection Engine - Agent 反思层
用于评估改进效果和决定是否继续迭代
"""

from typing import Dict, List, Any, Optional
from dataclasses import dataclass
from datetime import datetime
import json
import structlog

logger = structlog.get_logger(__name__)


@dataclass
class ImprovementMetrics:
    """改进指标"""
    metric_name: str
    before_score: float
    after_score: float
    improvement: float
    status: str  # "improved" / "same" / "degraded"


@dataclass
class ReflectionResult:
    """反思结果"""
    timestamp: str
    iteration_number: int
    improvements: List[ImprovementMetrics]
    overall_improvement_score: float
    converged: bool
    should_continue: bool
    reasoning: str
    next_steps: Optional[List[str]]


class ReflectionEngine:
    """反思引擎 - 评估改进并决定是否继续"""

    def __init__(self, convergence_threshold: float = 0.05, max_iterations: int = 3):
        """
        初始化反思引擎

        Args:
            convergence_threshold: 改进收敛阈值（低于此值认为收敛）
            max_iterations: 最大迭代次数
        """
        self.convergence_threshold = convergence_threshold
        self.max_iterations = max_iterations
        self.history: List[ReflectionResult] = []

    def evaluate_improvements(
        self,
        iteration_number: int,
        original_feedback: Dict[str, Any],
        validation_metrics_before: Dict[str, float],
        validation_metrics_after: Dict[str, float],
        actions_taken: List[str]
    ) -> ReflectionResult:
        """
        评估改进效果

        Args:
            iteration_number: 迭代编号
            original_feedback: 原始反馈
            validation_metrics_before: 修改前的验证指标
            validation_metrics_after: 修改后的验证指标
            actions_taken: 执行的动作列表

        Returns:
            反思结果
        """

        logger.info(
            "Evaluating improvements",
            iteration=iteration_number,
            metrics_before=validation_metrics_before,
            metrics_after=validation_metrics_after
        )

        # 计算每个指标的改进
        improvements = []
        total_improvement = 0

        for metric_name in validation_metrics_after.keys():
            before_score = validation_metrics_before.get(metric_name, 0)
            after_score = validation_metrics_after.get(metric_name, 0)
            improvement = after_score - before_score

            if improvement > 0:
                status = "improved"
            elif improvement < 0:
                status = "degraded"
            else:
                status = "same"

            improvements.append(ImprovementMetrics(
                metric_name=metric_name,
                before_score=before_score,
                after_score=after_score,
                improvement=improvement,
                status=status
            ))

            total_improvement += abs(improvement)

        # 计算平均改进分数
        avg_improvement = total_improvement / len(improvements) if improvements else 0

        # 判断是否收敛
        converged = avg_improvement < self.convergence_threshold
        should_continue = (
            not converged and
            iteration_number < self.max_iterations
        )

        # 生成推理
        reasoning = self._generate_reasoning(
            iteration_number,
            improvements,
            avg_improvement,
            converged,
            actions_taken
        )

        # 生成下一步建议
        next_steps = None
        if should_continue:
            next_steps = self._suggest_next_steps(
                original_feedback,
                improvements,
                actions_taken
            )

        result = ReflectionResult(
            timestamp=datetime.now().isoformat(),
            iteration_number=iteration_number,
            improvements=improvements,
            overall_improvement_score=round(avg_improvement, 2),
            converged=converged,
            should_continue=should_continue,
            reasoning=reasoning,
            next_steps=next_steps
        )

        self.history.append(result)
        logger.info(
            "Reflection completed",
            iteration=iteration_number,
            improvement_score=avg_improvement,
            should_continue=should_continue
        )

        return result

    def _generate_reasoning(
        self,
        iteration_number: int,
        improvements: List[ImprovementMetrics],
        avg_improvement: float,
        converged: bool,
        actions_taken: List[str]
    ) -> str:
        """生成反思推理"""

        reasoning = f"Iteration {iteration_number}: "

        # 统计改进情况
        improved_count = sum(1 for i in improvements if i.status == "improved")
        degraded_count = sum(1 for i in improvements if i.status == "degraded")
        same_count = sum(1 for i in improvements if i.status == "same")

        reasoning += f"Out of {len(improvements)} metrics, "
        reasoning += f"{improved_count} improved, {same_count} stayed same, {degraded_count} degraded. "

        # 改进程度
        if avg_improvement > 15:
            reasoning += "Significant improvements detected. "
        elif avg_improvement > 5:
            reasoning += "Moderate improvements detected. "
        elif avg_improvement > 0:
            reasoning += "Minor improvements detected. "
        else:
            reasoning += "No meaningful improvements. "

        # 收敛状态
        if converged:
            reasoning += "The document has converged - further iterations may not yield significant improvements. "
        else:
            reasoning += "The document can still be improved. "

        # 已执行的动作
        if actions_taken:
            reasoning += f"Actions taken: {', '.join(actions_taken)}. "

        # 迭代限制
        if iteration_number >= self.max_iterations:
            reasoning += f"Maximum iterations ({self.max_iterations}) reached."

        return reasoning.strip()

    def _suggest_next_steps(
        self,
        original_feedback: Dict[str, Any],
        improvements: List[ImprovementMetrics],
        actions_taken: List[str]
    ) -> List[str]:
        """建议下一步行动"""

        next_steps = []

        # 分析改进最少的指标
        least_improved = min(improvements, key=lambda x: x.improvement)

        if least_improved.status != "improved":
            next_steps.append(
                f"Focus on improving '{least_improved.metric_name}' "
                f"(current: {least_improved.after_score})"
            )

        # 分析原始反馈中未解决的问题
        feedback_areas = original_feedback.get("areas_for_improvement", [])
        if feedback_areas:
            next_steps.append(
                f"Address remaining feedback areas: {', '.join(feedback_areas[:2])}"
            )

        # 检查是否还有未采取的行动类型
        possible_actions = [
            "add_glossary",
            "add_case_studies",
            "enhance_visuals",
            "add_market_analysis"
        ]

        taken_actions_types = {action.split("(")[0].strip() for action in actions_taken}
        untaken_actions = [
            action for action in possible_actions
            if action not in taken_actions_types
        ]

        if untaken_actions:
            next_steps.append(
                f"Consider implementing additional improvements: "
                f"{', '.join(untaken_actions[:2])}"
            )

        return next_steps

    def generate_final_report(self) -> Dict[str, Any]:
        """生成最终反思报告"""

        if not self.history:
            return {
                "status": "no_history",
                "message": "No reflection history available"
            }

        total_iterations = len(self.history)
        final_result = self.history[-1]

        # 计算总体改进
        total_improvement = sum(
            sum(m.improvement for m in result.improvements)
            for result in self.history
        ) / total_iterations if total_iterations > 0 else 0

        # 最佳指标和最差指标
        all_improvements = []
        for result in self.history:
            all_improvements.extend(result.improvements)

        best_metric = max(all_improvements, key=lambda x: x.improvement) if all_improvements else None
        worst_metric = min(all_improvements, key=lambda x: x.improvement) if all_improvements else None

        report = {
            "total_iterations": total_iterations,
            "total_improvement_score": round(total_improvement, 2),
            "converged": final_result.converged,
            "final_status": "completed" if final_result.converged else "in_progress",
            "best_improved_metric": {
                "name": best_metric.metric_name,
                "improvement": round(best_metric.improvement, 2)
            } if best_metric else None,
            "worst_metric": {
                "name": worst_metric.metric_name,
                "improvement": round(worst_metric.improvement, 2)
            } if worst_metric else None,
            "iteration_history": [
                {
                    "iteration": result.iteration_number,
                    "improvement_score": result.overall_improvement_score,
                    "converged": result.converged,
                    "timestamp": result.timestamp
                }
                for result in self.history
            ],
            "reasoning": final_result.reasoning,
            "recommendations": final_result.next_steps or [
                "Document has reached optimal improvement level",
                "Consider manual review for final polish"
            ]
        }

        return report

    def get_iteration_summary(self, iteration_number: int) -> Optional[ReflectionResult]:
        """获取特定迭代的总结"""
        for result in self.history:
            if result.iteration_number == iteration_number:
                return result
        return None

    def export_history(self) -> str:
        """导出反思历史为 JSON"""
        history_data = []

        for result in self.history:
            history_data.append({
                "timestamp": result.timestamp,
                "iteration": result.iteration_number,
                "improvements": [
                    {
                        "metric": m.metric_name,
                        "before": round(m.before_score, 2),
                        "after": round(m.after_score, 2),
                        "improvement": round(m.improvement, 2),
                        "status": m.status
                    }
                    for m in result.improvements
                ],
                "overall_improvement": result.overall_improvement_score,
                "converged": result.converged,
                "reasoning": result.reasoning
            })

        return json.dumps(history_data, indent=2, ensure_ascii=False)


# 创建全局实例
reflection_engine = ReflectionEngine()
