"""
Agent Memory - 长期记忆模块
持久化存储 + 向量相似度检索，让 Agent 能从历史经验中学习
"""

import json
import os
import re
import math
import uuid
from collections import Counter
from typing import Dict, List, Any, Optional
from datetime import datetime
import structlog

logger = structlog.get_logger(__name__)

MEMORY_DIR = "sessions"
MEMORY_FILE = "agent_memory.json"


def _tokenize(text: str) -> List[str]:
    return re.findall(r"\w+", (text or "").lower())


def _tf_vector(tokens: List[str]) -> Dict[str, float]:
    counts = Counter(tokens)
    total = len(tokens) or 1
    return {w: c / total for w, c in counts.items()}


def _cosine_similarity(a: Dict[str, float], b: Dict[str, float]) -> float:
    common = set(a.keys()) & set(b.keys())
    if not common:
        return 0.0
    dot = sum(a[k] * b[k] for k in common)
    mag_a = math.sqrt(sum(v * v for v in a.values()))
    mag_b = math.sqrt(sum(v * v for v in b.values()))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)


class AgentMemory:
    """
    长期记忆：持久化到 JSON 文件，用 TF 向量 + 余弦相似度做检索。
    支持多种 category（improvement / feedback / strategy / lesson）。
    """

    def __init__(self, storage_dir: str = MEMORY_DIR, filename: str = MEMORY_FILE):
        self.storage_path = os.path.join(storage_dir, filename)
        os.makedirs(storage_dir, exist_ok=True)
        self.entries: List[Dict[str, Any]] = self._load()

    def _load(self) -> List[Dict[str, Any]]:
        if not os.path.exists(self.storage_path):
            return []
        try:
            with open(self.storage_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                return data
            return []
        except Exception as e:
            logger.warning("Failed to load memory", error=str(e))
            return []

    def _save(self):
        try:
            with open(self.storage_path, "w", encoding="utf-8") as f:
                json.dump(self.entries, f, ensure_ascii=False, indent=2)
        except Exception as e:
            logger.warning("Failed to save memory", error=str(e))

    def store(
        self,
        content: str,
        category: str = "general",
        metadata: Optional[Dict[str, Any]] = None,
        session_id: str = None,
    ):
        entry = {
            "id": str(uuid.uuid4()),
            "content": content,
            "category": category,
            "metadata": metadata or {},
            "session_id": session_id,
            "timestamp": datetime.now().isoformat(),
        }
        self.entries.append(entry)
        # 保持条目数量合理
        if len(self.entries) > 500:
            self.entries = self.entries[-500:]
        self._save()
        logger.info("Memory stored", category=category, total=len(self.entries))

    def retrieve(
        self,
        query: str,
        top_k: int = 5,
        category: Optional[str] = None,
        min_score: float = 0.05,
    ) -> List[Dict[str, Any]]:
        query_vec = _tf_vector(_tokenize(query))
        scored = []
        for entry in self.entries:
            if category and entry.get("category") != category:
                continue
            entry_vec = _tf_vector(_tokenize(entry["content"]))
            score = _cosine_similarity(query_vec, entry_vec)
            if score >= min_score:
                scored.append((score, entry))
        scored.sort(reverse=True, key=lambda x: x[0])
        return [
            {**entry, "relevance_score": round(score, 4)}
            for score, entry in scored[:top_k]
        ]

    def store_improvement_result(
        self,
        session_id: str,
        actions: List[str],
        metrics_before: Dict[str, float],
        metrics_after: Dict[str, float],
        reasoning: str,
    ):
        improved = {
            k: round(metrics_after.get(k, 0) - metrics_before.get(k, 0), 2)
            for k in metrics_after
        }
        content = (
            f"Actions: {', '.join(actions)}. "
            f"Improvements: {json.dumps(improved)}. "
            f"Reasoning: {reasoning}"
        )
        self.store(
            content=content,
            category="improvement",
            metadata={
                "actions": actions,
                "metrics_before": metrics_before,
                "metrics_after": metrics_after,
                "improvements": improved,
            },
            session_id=session_id,
        )

    def store_lesson(self, lesson: str, session_id: str = None):
        self.store(content=lesson, category="lesson", session_id=session_id)

    def get_relevant_strategies(self, document_excerpt: str, top_k: int = 3) -> str:
        results = self.retrieve(document_excerpt, top_k=top_k, category="improvement")
        if not results:
            return ""
        lines = ["Past improvement strategies that worked:"]
        for r in results:
            lines.append(f"- {r['content'][:200]}")
        return "\n".join(lines)

    def get_lessons(self, top_k: int = 5) -> List[str]:
        lessons = [e for e in self.entries if e.get("category") == "lesson"]
        lessons.sort(key=lambda x: x.get("timestamp", ""), reverse=True)
        return [e["content"] for e in lessons[:top_k]]

    def get_stats(self) -> Dict[str, Any]:
        cats = Counter(e.get("category", "general") for e in self.entries)
        return {
            "total_entries": len(self.entries),
            "categories": dict(cats),
            "storage_path": self.storage_path,
        }


# 全局实例
agent_memory = AgentMemory()
