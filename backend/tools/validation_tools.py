"""
Document Validation Tools - Agent 观察层
用于验证和评估文档改进效果
"""

import re
from typing import Dict, List, Any
from dataclasses import dataclass
import structlog

logger = structlog.get_logger(__name__)


@dataclass
class ValidationMetric:
    """验证指标"""
    metric_name: str
    score: float  # 0-100
    status: str  # "pass" / "warning" / "fail"
    details: str
    recommendations: List[str]


class DocumentValidator:
    """文档验证工具"""

    def __init__(self):
        self.metrics: Dict[str, ValidationMetric] = {}

    def validate_glossary_completeness(self, document_content: str) -> ValidationMetric:
        """检查术语表完整度"""

        glossary_match = re.search(
            r"## (Glossary|术语表)(.*?)(?=\n##|$)",
            document_content,
            re.DOTALL
        )

        if not glossary_match:
            metric = ValidationMetric(
                metric_name="Glossary Completeness",
                score=0,
                status="fail",
                details="No glossary found in document",
                recommendations=["Add a glossary section with technical terms"]
            )
        else:
            glossary_text = glossary_match.group(2)
            # 计算术语数量
            term_count = len(re.findall(r"\*\*.+?\*\*:", glossary_text))

            if term_count >= 10:
                score = 100
                status = "pass"
                details = f"Glossary with {term_count} terms found"
            elif term_count >= 5:
                score = 70
                status = "warning"
                details = f"Glossary with only {term_count} terms (should have at least 10)"
            else:
                score = 40
                status = "warning"
                details = f"Minimal glossary with {term_count} terms"

            recommendations = []
            if term_count < 10:
                recommendations.append(f"Add {10 - term_count} more terms to reach recommended count")

            metric = ValidationMetric(
                metric_name="Glossary Completeness",
                score=score,
                status=status,
                details=details,
                recommendations=recommendations
            )

        self.metrics["glossary_completeness"] = metric
        return metric

    def validate_visual_consistency(self, document_content: str) -> ValidationMetric:
        """检查视觉一致性"""

        # 查找所有图表引用
        figures = re.findall(r"\[Figure.*?\]|\[图.*?\]", document_content)

        if not figures:
            metric = ValidationMetric(
                metric_name="Visual Consistency",
                score=50,
                status="warning",
                details="No figures found in document",
                recommendations=["Add visual elements to enhance understanding"]
            )
        else:
            # 检查图表是否有详细说明
            figure_descriptions = re.findall(
                r"\[Figure.*?\]\n\n\*[^*]+\*",
                document_content
            )

            caption_ratio = len(figure_descriptions) / len(figures)

            if caption_ratio >= 0.9:
                score = 100
                status = "pass"
                details = f"All {len(figures)} figures have detailed captions"
            elif caption_ratio >= 0.7:
                score = 75
                status = "warning"
                details = f"{len(figure_descriptions)} of {len(figures)} figures have captions"
            else:
                score = 50
                status = "fail"
                details = f"Only {len(figure_descriptions)} of {len(figures)} figures have captions"

            recommendations = []
            if caption_ratio < 1:
                recommendations.append(f"Add captions to {len(figures) - len(figure_descriptions)} figures")

            metric = ValidationMetric(
                metric_name="Visual Consistency",
                score=score,
                status=status,
                details=details,
                recommendations=recommendations
            )

        self.metrics["visual_consistency"] = metric
        return metric

    def validate_structure_compliance(self, document_content: str) -> ValidationMetric:
        """检查文档结构是否完善"""

        required_sections = [
            "Abstract",
            "Introduction",
            "Methodology",
            "Results",
            "Conclusion"
        ]

        # 或中文版本
        required_sections_cn = [
            "摘要",
            "介绍",
            "方法论",
            "结果",
            "结论"
        ]

        found_sections = []

        for section in required_sections:
            if re.search(rf"^#+\s+{section}", document_content, re.MULTILINE):
                found_sections.append(section)

        for section in required_sections_cn:
            if re.search(rf"^#+\s+{section}", document_content, re.MULTILINE):
                found_sections.append(section)

        found_count = len(set(found_sections))
        required_count = len(set(required_sections + required_sections_cn))

        compliance_ratio = found_count / 5  # 5 个基本部分

        if compliance_ratio >= 0.8:
            score = 100
            status = "pass"
            details = f"Document has {found_count} of 5 required sections"
        elif compliance_ratio >= 0.6:
            score = 70
            status = "warning"
            details = f"Document has only {found_count} of 5 required sections"
        else:
            score = 40
            status = "fail"
            details = f"Document missing key sections"

        missing_sections = 5 - found_count
        recommendations = []
        if missing_sections > 0:
            recommendations.append(f"Add {missing_sections} missing sections")

        metric = ValidationMetric(
            metric_name="Structure Compliance",
            score=score,
            status=status,
            details=details,
            recommendations=recommendations
        )

        self.metrics["structure_compliance"] = metric
        return metric

    def validate_readability(self, document_content: str) -> ValidationMetric:
        """评估可读性"""

        # 简单的可读性指标：
        # - 段落长度（平均行数）
        # - 句子长度（平均单词数）
        # - 空白使用率

        # 移除标题和代码块
        content_only = re.sub(r"^#+.*$", "", document_content, flags=re.MULTILINE)
        content_only = re.sub(r"```.*?```", "", content_only, flags=re.DOTALL)

        # 计算段落
        paragraphs = [p.strip() for p in content_only.split("\n\n") if p.strip()]
        sentences = re.split(r"[.!?]+", content_only)
        words = content_only.split()

        avg_paragraph_length = len(words) / len(paragraphs) if paragraphs else 0
        avg_sentence_length = len(words) / len(sentences) if sentences else 0

        # 评分逻辑
        score = 100

        # 检查段落长度（理想：50-150 字）
        if avg_paragraph_length > 200:
            score -= 15
        elif avg_paragraph_length < 30:
            score -= 10

        # 检查句子长度（理想：15-20 字）
        if avg_sentence_length > 30:
            score -= 20
        elif avg_sentence_length < 10:
            score -= 5

        # 检查代码块或列表使用
        if re.search(r"```|^[-*] |^\d+\.", content_only, re.MULTILINE):
            score += 10  # 使用代码或列表改进可读性

        score = max(0, min(100, score))  # 限制在 0-100

        status = "pass" if score >= 75 else "warning" if score >= 50 else "fail"

        recommendations = []
        if avg_paragraph_length > 200:
            recommendations.append("Break down long paragraphs into smaller chunks")
        if avg_sentence_length > 30:
            recommendations.append("Simplify complex sentences")
        if not re.search(r"^[-*] |^\d+\.", content_only, re.MULTILINE):
            recommendations.append("Use bullet points or numbered lists for better readability")

        metric = ValidationMetric(
            metric_name="Readability Score",
            score=score,
            status=status,
            details=f"Avg paragraph: {avg_paragraph_length:.0f} words, "
                   f"Avg sentence: {avg_sentence_length:.0f} words",
            recommendations=recommendations
        )

        self.metrics["readability"] = metric
        return metric

    def validate_evidence_support(self, document_content: str) -> ValidationMetric:
        """验证文档中声明是否有数据/图表/引用等支撑（Evidence Support），非严格技术准确性。"""

        claims_with_data = len(re.findall(r"Figure|Table|results|metrics|accuracy|precision", document_content, re.IGNORECASE))
        references_found = len(re.findall(r"\[.*?\]|\(.*?, \d{4}\)", document_content))
        total_claims = len(re.findall(r"[.!?]", document_content))

        if total_claims == 0:
            metric = ValidationMetric(
                metric_name="Evidence Support",
                score=50,
                status="warning",
                details="No sentence-ending punctuation found; cannot assess evidence ratio",
                recommendations=["Add clear claims and support them with data or citations"]
            )
        else:
            support_ratio = (claims_with_data + references_found) / total_claims
            if support_ratio >= 0.3:
                score, status = 90, "pass"
                details = "Strong evidence and references found"
            elif support_ratio >= 0.15:
                score, status = 70, "warning"
                details = "Some claims lack supporting evidence"
            else:
                score, status = 40, "fail"
                details = "Most claims lack supporting evidence"
            recommendations = [] if support_ratio >= 0.3 else ["Add more data, figures, or citations to support claims"]
            metric = ValidationMetric(
                metric_name="Evidence Support",
                score=score,
                status=status,
                details=details,
                recommendations=recommendations
            )

        self.metrics["evidence_support"] = metric
        return metric

    def generate_validation_report(self) -> Dict[str, Any]:
        """生成验证报告"""

        if not self.metrics:
            return {
                "status": "no_metrics",
                "message": "No metrics have been validated yet"
            }

        total_score = sum(m.score for m in self.metrics.values()) / len(self.metrics)

        overall_status = (
            "pass" if total_score >= 80
            else "warning" if total_score >= 60
            else "fail"
        )

        report = {
            "overall_score": round(total_score, 2),
            "overall_status": overall_status,
            "metrics": {
                name: {
                    "score": metric.score,
                    "status": metric.status,
                    "details": metric.details,
                    "recommendations": metric.recommendations
                }
                for name, metric in self.metrics.items()
            },
            "all_recommendations": []
        }

        # 汇总所有建议
        for metric in self.metrics.values():
            report["all_recommendations"].extend(metric.recommendations)

        # 去重
        report["all_recommendations"] = list(set(report["all_recommendations"]))

        return report

    def get_metric(self, metric_name: str) -> ValidationMetric:
        """获取特定指标"""
        return self.metrics.get(metric_name)


# 不在模块级创建全局实例，避免多请求共享状态。调用方按任务/会话创建实例，例如：
#   validator = DocumentValidator()
