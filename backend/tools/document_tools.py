"""
Document Action Tools - Agent 执行层
用于修改和增强文档
"""

import os
import json
import re
from typing import List, Dict, Any
from datetime import datetime
from pathlib import Path
import structlog

logger = structlog.get_logger(__name__)


class DocumentModificationAction:
    """文档修改动作的基类"""

    def __init__(self, action_type: str, description: str):
        self.action_type = action_type
        self.description = description
        self.timestamp = datetime.now().isoformat()
        self.status = "pending"
        self.result = None

    def execute(self, document_content: str) -> str:
        """执行修改动作，返回修改后的内容"""
        raise NotImplementedError


class AddGlossaryAction(DocumentModificationAction):
    """添加术语表"""

    def __init__(self, glossary_items: List[Dict[str, str]]):
        super().__init__("add_glossary", "Add glossary of technical terms")
        self.glossary_items = glossary_items

    def execute(self, document_content: str) -> str:
        """在文档末尾添加术语表"""
        try:
            glossary_section = self._generate_glossary_markdown()

            # 检查是否已有术语表：只替换该节（到下一个 ## 或文档末尾），避免吃掉后续章节
            if re.search(r"^## (Glossary|术语表)\s*$", document_content, re.MULTILINE):
                logger.info("Glossary already exists, updating it")
                document_content = re.sub(
                    r"^## (Glossary|术语表)\s*\n.*?(?=\n##|\n#|\Z)",
                    glossary_section + "\n\n",
                    document_content,
                    flags=re.DOTALL | re.MULTILINE,
                    count=1,
                )
            else:
                # 在文档末尾添加
                document_content += "\n\n" + glossary_section

            self.status = "completed"
            self.result = f"Added {len(self.glossary_items)} glossary items"
            return document_content

        except Exception as e:
            self.status = "failed"
            self.result = str(e)
            logger.error("Failed to add glossary", error=str(e))
            return document_content

    def _generate_glossary_markdown(self) -> str:
        """生成 Markdown 格式的术语表"""
        markdown = "## Glossary\n\n"
        for item in self.glossary_items:
            term = item.get("term", "")
            definition = item.get("definition", "")
            markdown += f"**{term}**: {definition}\n\n"
        return markdown.strip()


class AddExecutiveSummaryAction(DocumentModificationAction):
    """添加执行摘要"""

    def __init__(self, summary_text: str):
        super().__init__("add_summary", "Add executive summary")
        self.summary_text = summary_text

    def execute(self, document_content: str) -> str:
        """在文档开头添加执行摘要；若已存在则替换该节，保证幂等。"""
        try:
            summary_section = f"## Executive Summary\n\n{self.summary_text}\n\n---\n\n"

            # 幂等：若已有 Executive Summary 节，只替换该节内容，不重复插入
            if re.search(r"^## Executive Summary\s*$", document_content, re.MULTILINE):
                document_content = re.sub(
                    r"^## Executive Summary\s*\n.*?(?=\n##|\n#|\Z)",
                    summary_section.strip() + "\n\n",
                    document_content,
                    flags=re.DOTALL | re.MULTILINE,
                    count=1,
                )
                self.status = "completed"
                self.result = "Executive summary updated"
                return document_content

            # 找到第一个主标题后插入（不硬编码跳过字符，避免吃掉内容）
            match = re.search(r"^(# .+)$", document_content, re.MULTILINE)
            if match:
                insert_pos = match.end()
                document_content = document_content[:insert_pos] + "\n\n" + summary_section + document_content[insert_pos:]
            else:
                document_content = summary_section + document_content

            self.status = "completed"
            self.result = "Executive summary added"
            return document_content

        except Exception as e:
            self.status = "failed"
            self.result = str(e)
            logger.error("Failed to add executive summary", error=str(e))
            return document_content


class AddSectionSummariesAction(DocumentModificationAction):
    """在关键章节后添加总结"""

    def __init__(self, sections_to_summarize: List[str], summaries: Dict[str, str]):
        super().__init__("add_section_summaries", "Add summaries to key sections")
        self.sections_to_summarize = sections_to_summarize
        self.summaries = summaries

    def execute(self, document_content: str) -> str:
        """在指定章节后添加总结"""
        try:
            modified_content = document_content

            for section_name, summary in self.summaries.items():
                # 查找章节标题
                pattern = rf"(### {re.escape(section_name)}.*?(?=\n###|\n##|$))"

                def replace_func(match):
                    return match.group(0) + f"\n\n**Summary:**\n{summary}\n"

                modified_content = re.sub(pattern, replace_func, modified_content, flags=re.DOTALL)

            self.status = "completed"
            self.result = f"Added summaries to {len(self.summaries)} sections"
            return modified_content

        except Exception as e:
            self.status = "failed"
            self.result = str(e)
            logger.error("Failed to add section summaries", error=str(e))
            return document_content


class EnhanceVisualsAction(DocumentModificationAction):
    """增强视觉元素（添加图表说明、改进格式等）"""

    def __init__(self, visual_enhancements: List[Dict[str, str]]):
        super().__init__("enhance_visuals", "Enhance visual elements")
        self.visual_enhancements = visual_enhancements

    def execute(self, document_content: str) -> str:
        """增强文档中的视觉元素"""
        try:
            modified_content = document_content

            # 为所有图表添加详细说明
            for enhancement in self.visual_enhancements:
                figure_ref = enhancement.get("figure_ref", "")
                enhanced_caption = enhancement.get("enhanced_caption", "")

                if figure_ref:
                    pattern = rf"(\[{re.escape(figure_ref)}.*?\])"
                    modified_content = re.sub(
                        pattern,
                        f"[{figure_ref}]\n\n*{enhanced_caption}*",
                        modified_content
                    )

            # 添加格式化指南
            formatting_guide = self._generate_formatting_guide()
            if "## Formatting Guide" not in modified_content:
                modified_content += "\n\n" + formatting_guide

            self.status = "completed"
            self.result = f"Enhanced {len(self.visual_enhancements)} visual elements"
            return modified_content

        except Exception as e:
            self.status = "failed"
            self.result = str(e)
            logger.error("Failed to enhance visuals", error=str(e))
            return document_content

    def _generate_formatting_guide(self) -> str:
        """生成格式化指南"""
        return """## Formatting Guide

### Visual Consistency Standards
- **Colors**: Use a consistent color palette throughout all figures
- **Fonts**: Use sans-serif fonts (Arial, Helvetica) for readability
- **Line Width**: Maintain consistent line weights across diagrams
- **Labels**: All axes and data elements should be clearly labeled
- **Legends**: Include comprehensive legends for all charts

### Best Practices
- Ensure sufficient contrast for accessibility
- Use color-blind friendly color schemes
- Include alt-text descriptions for all visuals
- Maintain aspect ratios for consistency
"""


class AddCaseStudiesAction(DocumentModificationAction):
    """添加真实案例研究"""

    def __init__(self, case_studies: List[Dict[str, str]]):
        super().__init__("add_case_studies", "Add real-world case studies")
        self.case_studies = case_studies

    def execute(self, document_content: str) -> str:
        """添加案例研究部分；若已存在则替换该节，保证幂等。"""
        try:
            case_studies_section = self._generate_case_studies_section()

            # 幂等：若已有该节，整节替换为新内容（含标题）
            if re.search(r"^## Real-World Case Studies\s*$", document_content, re.MULTILINE):
                document_content = re.sub(
                    r"^## Real-World Case Studies\s*\n.*?(?=\n##|\n#|\Z)",
                    case_studies_section.strip() + "\n\n",
                    document_content,
                    flags=re.DOTALL | re.MULTILINE,
                    count=1,
                )
                self.status = "completed"
                self.result = f"Updated {len(self.case_studies)} case studies"
                return document_content

            # 在结论之前插入案例研究
            if "## Conclusion" in document_content:
                document_content = document_content.replace(
                    "## Conclusion",
                    case_studies_section + "\n\n## Conclusion"
                )
            else:
                document_content += "\n\n" + case_studies_section

            self.status = "completed"
            self.result = f"Added {len(self.case_studies)} case studies"
            return document_content

        except Exception as e:
            self.status = "failed"
            self.result = str(e)
            logger.error("Failed to add case studies", error=str(e))
            return document_content

    def _generate_case_studies_section(self) -> str:
        """生成案例研究部分"""
        section = "## Real-World Case Studies\n\n"

        for i, case_study in enumerate(self.case_studies, 1):
            title = case_study.get("title", f"Case Study {i}")
            description = case_study.get("description", "")
            results = case_study.get("results", "")

            section += f"### {title}\n\n"
            section += f"{description}\n\n"
            if results:
                section += f"**Results**: {results}\n\n"

        return section.strip()


class DocumentTools:
    """文档修改工具集"""

    def __init__(self):
        self.actions_history: List[DocumentModificationAction] = []

    def create_glossary_action(self, glossary_items: List[Dict[str, str]]) -> AddGlossaryAction:
        """创建添加术语表的动作"""
        action = AddGlossaryAction(glossary_items)
        self.actions_history.append(action)
        return action

    def create_summary_action(self, summary_text: str) -> AddExecutiveSummaryAction:
        """创建添加摘要的动作"""
        action = AddExecutiveSummaryAction(summary_text)
        self.actions_history.append(action)
        return action

    def create_section_summaries_action(
        self,
        sections: List[str],
        summaries: Dict[str, str]
    ) -> AddSectionSummariesAction:
        """创建添加章节总结的动作"""
        action = AddSectionSummariesAction(sections, summaries)
        self.actions_history.append(action)
        return action

    def create_visual_enhancement_action(
        self,
        enhancements: List[Dict[str, str]]
    ) -> EnhanceVisualsAction:
        """创建增强视觉元素的动作"""
        action = EnhanceVisualsAction(enhancements)
        self.actions_history.append(action)
        return action

    def create_case_studies_action(
        self,
        case_studies: List[Dict[str, str]]
    ) -> AddCaseStudiesAction:
        """创建添加案例研究的动作"""
        action = AddCaseStudiesAction(case_studies)
        self.actions_history.append(action)
        return action

    def apply_modifications(
        self,
        document_content: str,
        actions: List[DocumentModificationAction]
    ) -> Dict[str, Any]:
        """按顺序应用所有修改动作（同步，无 I/O 阻塞）。"""

        modified_content = document_content
        execution_log = []

        for action in actions:
            logger.info(f"Executing action: {action.action_type}")

            try:
                modified_content = action.execute(modified_content)
                execution_log.append({
                    "action_type": action.action_type,
                    "status": action.status,
                    "result": action.result,
                    "timestamp": action.timestamp
                })
            except Exception as e:
                logger.error(f"Action failed: {action.action_type}", error=str(e))
                execution_log.append({
                    "action_type": action.action_type,
                    "status": "failed",
                    "error": str(e),
                    "timestamp": action.timestamp
                })

        return {
            "modified_content": modified_content,
            "execution_log": execution_log,
            "total_actions": len(actions),
            "successful_actions": sum(1 for log in execution_log if log.get("status") == "completed")
        }

    def get_history(self) -> List[Dict[str, Any]]:
        """获取所有执行历史"""
        return [
            {
                "action_type": action.action_type,
                "description": action.description,
                "status": action.status,
                "result": action.result,
                "timestamp": action.timestamp
            }
            for action in self.actions_history
        ]


# 不在模块级创建全局实例，避免多请求共享 actions_history。调用方按任务/会话创建实例，例如：
#   tools = DocumentTools()
