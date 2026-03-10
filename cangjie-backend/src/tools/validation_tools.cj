package ai_doc_read_studio.tools

import std.collection.*
import std.regex.*
import ai_doc_read_studio.utils.*

public class ValidationMetric {
    public var metricName: String
    public var score: Float64
    public var status: String
    public var details: String
    public var recommendations: ArrayList<String>

    public init(metricName: String, score: Float64, status: String, details: String, recommendations: ArrayList<String>) {
        this.metricName = metricName
        this.score = score
        this.status = status
        this.details = details
        this.recommendations = recommendations
    }

    public func toJson(): JsonValue {
        let recsArr = jsonArray()
        for (r in recommendations) {
            recsArr.add(JsonValue.JsonString(r))
        }
        return jsonObj([
            ("metric_name", JsonValue.JsonString(metricName)),
            ("score", JsonValue.JsonFloat(score)),
            ("status", JsonValue.JsonString(status)),
            ("details", JsonValue.JsonString(details)),
            ("recommendations", JsonValue.JsonArray(recsArr))
        ])
    }
}

public class DocumentValidator {
    public var metrics: HashMap<String, ValidationMetric>

    public init() {
        this.metrics = HashMap<String, ValidationMetric>()
    }

    public func validateGlossaryCompleteness(documentContent: String): ValidationMetric {
        let glossaryRegex = Regex("## (Glossary|Glossary Section)")
        let matcher = glossaryRegex.matcher(documentContent)
        let hasGlossary = match (matcher.find()) { case Some(_) => true case None => false }

        var metric: ValidationMetric
        if (!hasGlossary) {
            let recs = ArrayList<String>()
            recs.add("Add a glossary section with technical terms")
            metric = ValidationMetric(
                "Glossary Completeness", 0.0, "fail",
                "No glossary found in document", recs
            )
        } else {
            let termRegex = Regex("\\*\\*.+?\\*\\*:")
            let termMatcher = termRegex.matcher(documentContent)
            var termCount: Int64 = 0
            while (true) {
                match (termMatcher.find()) { case Some(_) => termCount += 1 case None => break }
            }

            var score: Float64
            var status: String
            var details: String
            if (termCount >= 10) {
                score = 100.0; status = "pass"
                details = "Glossary with ${termCount} terms found"
            } else if (termCount >= 5) {
                score = 70.0; status = "warning"
                details = "Glossary with only ${termCount} terms (should have at least 10)"
            } else {
                score = 40.0; status = "warning"
                details = "Minimal glossary with ${termCount} terms"
            }

            let recs = ArrayList<String>()
            if (termCount < 10) {
                recs.add("Add ${10 - termCount} more terms to reach recommended count")
            }
            metric = ValidationMetric("Glossary Completeness", score, status, details, recs)
        }

        metrics["glossary_completeness"] = metric
        return metric
    }

    public func validateVisualConsistency(documentContent: String): ValidationMetric {
        let figureRegex = Regex("\\[Figure.*?\\]|\\[.*?\\]")
        let figureMatcher = figureRegex.matcher(documentContent)
        var figureCount: Int64 = 0
        while (true) {
            match (figureMatcher.find()) { case Some(_) => figureCount += 1 case None => break }
        }

        var metric: ValidationMetric
        if (figureCount == 0) {
            let recs = ArrayList<String>()
            recs.add("Add visual elements to enhance understanding")
            metric = ValidationMetric(
                "Visual Consistency", 50.0, "warning",
                "No figures found in document", recs
            )
        } else {
            let captionRegex = Regex("\\[Figure.*?\\]\\n\\n\\*[^*]+\\*")
            let captionMatcher = captionRegex.matcher(documentContent)
            var captionCount: Int64 = 0
            while (true) {
                match (captionMatcher.find()) { case Some(_) => captionCount += 1 case None => break }
            }

            let captionRatio = Float64(captionCount) / Float64(figureCount)
            var score: Float64
            var status: String
            var details: String
            if (captionRatio >= 0.9) {
                score = 100.0; status = "pass"
                details = "All ${figureCount} figures have detailed captions"
            } else if (captionRatio >= 0.7) {
                score = 75.0; status = "warning"
                details = "${captionCount} of ${figureCount} figures have captions"
            } else {
                score = 50.0; status = "fail"
                details = "Only ${captionCount} of ${figureCount} figures have captions"
            }

            let recs = ArrayList<String>()
            if (captionRatio < 1.0) {
                recs.add("Add captions to ${figureCount - captionCount} figures")
            }
            metric = ValidationMetric("Visual Consistency", score, status, details, recs)
        }

        metrics["visual_consistency"] = metric
        return metric
    }

    public func validateStructureCompliance(documentContent: String): ValidationMetric {
        // 学术类关键区块
        let academicSections = ["Abstract", "Introduction", "Methodology", "Results", "Conclusion"]
        // 工具添加的标准区块
        let toolSections = ["Executive Summary", "Glossary", "Real-World Case Studies", "Formatting Guide"]
        // 中文/通用区块
        let generalSections = ["Summary", "Overview", "Background", "Discussion", "References"]

        var foundCount: Int64 = 0
        var totalChecked: Int64 = 0
        for (section in academicSections) {
            totalChecked += 1
            let regex = Regex("^#+\\s+${section}", RegexOption().multiLine())
            match (regex.matcher(documentContent).find()) { case Some(_) => foundCount += 1 case None => () }
        }
        for (section in toolSections) {
            totalChecked += 1
            let regex = Regex("^#+\\s+${section}", RegexOption().multiLine())
            match (regex.matcher(documentContent).find()) { case Some(_) => foundCount += 1 case None => () }
        }
        for (section in generalSections) {
            totalChecked += 1
            let regex = Regex("^#+\\s+${section}", RegexOption().multiLine())
            match (regex.matcher(documentContent).find()) { case Some(_) => foundCount += 1 case None => () }
        }

        // 也统计文档中所有的二级标题数量（作为结构完整性指标）
        let h2Regex = Regex("^##\\s+.+", RegexOption().multiLine())
        let h2Matcher = h2Regex.matcher(documentContent)
        var h2Count: Int64 = 0
        while (true) {
            match (h2Matcher.find()) { case Some(_) => h2Count += 1 case None => break }
        }

        var score: Float64
        var status: String
        var details: String
        if (foundCount >= 3 || h2Count >= 5) {
            score = 100.0; status = "pass"
            details = "Document has ${foundCount} recognized sections, ${h2Count} level-2 headings"
        } else if (foundCount >= 2 || h2Count >= 3) {
            score = 70.0; status = "warning"
            details = "Document has ${foundCount} recognized sections, ${h2Count} level-2 headings"
        } else if (h2Count >= 1) {
            score = 50.0; status = "warning"
            details = "Document has minimal structure: ${h2Count} level-2 headings"
        } else {
            score = 20.0; status = "fail"
            details = "Document lacks clear section structure"
        }

        let recs = ArrayList<String>()
        if (foundCount < 3) {
            recs.add("Add key sections: Executive Summary, Glossary, or Conclusion to improve structure")
        }

        let metric = ValidationMetric("Structure Compliance", score, status, details, recs)
        metrics["structure_compliance"] = metric
        return metric
    }

    public func validateReadability(documentContent: String): ValidationMetric {
        let headingRegex = Regex("^#+.*$", RegexOption().multiLine())
        let contentOnly = headingRegex.matcher(documentContent).replaceAll("")

        var paragraphs = ArrayList<String>()
        for (p in contentOnly.split("\n\n")) { if (p.trimAscii().size > 0) { paragraphs.add(p) } }
        var words = ArrayList<String>()
        for (w in contentOnly.split(" ")) { if (w.trimAscii().size > 0) { words.add(w) } }
        var sentences = ArrayList<String>()
        for (s in contentOnly.split(".")) { if (s.trimAscii().size > 0) { sentences.add(s) } }

        let paragraphCount = if (paragraphs.size > 0) { Int64(paragraphs.size) } else { 1 }
        let sentenceCount = if (sentences.size > 0) { Int64(sentences.size) } else { 1 }
        let wordCount = Int64(words.size)

        let avgParagraphLength = Float64(wordCount) / Float64(paragraphCount)
        let avgSentenceLength = Float64(wordCount) / Float64(sentenceCount)

        var score: Float64 = 100.0
        if (avgParagraphLength > 200.0) { score -= 15.0 }
        else if (avgParagraphLength < 30.0) { score -= 10.0 }

        if (avgSentenceLength > 30.0) { score -= 20.0 }
        else if (avgSentenceLength < 10.0) { score -= 5.0 }

        let listRegex = Regex("^[-*] |^\\d+\\.", RegexOption().multiLine())
        match (listRegex.matcher(contentOnly).find()) { case Some(_) => score += 10.0 case None => () }

        score = max(0.0, min(100.0, score))
        let status = if (score >= 75.0) { "pass" } else if (score >= 50.0) { "warning" } else { "fail" }

        let recs = ArrayList<String>()
        if (avgParagraphLength > 200.0) {
            recs.add("Break down long paragraphs into smaller chunks")
        }
        if (avgSentenceLength > 30.0) {
            recs.add("Simplify complex sentences")
        }

        let details = "Avg paragraph: ${avgParagraphLength} words, Avg sentence: ${avgSentenceLength} words"
        let metric = ValidationMetric("Readability Score", score, status, details, recs)
        metrics["readability"] = metric
        return metric
    }

    public func validateEvidenceSupport(documentContent: String): ValidationMetric {
        let evidenceRegex = Regex("Figure|Table|results|metrics|accuracy|precision", RegexOption().ignoreCase())
        let evidenceMatcher = evidenceRegex.matcher(documentContent)
        var claimsWithData: Int64 = 0
        while (true) { match (evidenceMatcher.find()) { case Some(_) => claimsWithData += 1 case None => break } }

        let refRegex = Regex("\\[.*?\\]|\\(.*?, \\d{4}\\)")
        let refMatcher = refRegex.matcher(documentContent)
        var referencesFound: Int64 = 0
        while (true) { match (refMatcher.find()) { case Some(_) => referencesFound += 1 case None => break } }

        let sentenceEndRegex = Regex("[.!?]")
        let sentenceMatcher = sentenceEndRegex.matcher(documentContent)
        var totalClaims: Int64 = 0
        while (true) { match (sentenceMatcher.find()) { case Some(_) => totalClaims += 1 case None => break } }

        var metric: ValidationMetric
        if (totalClaims == 0) {
            let recs = ArrayList<String>()
            recs.add("Add clear claims and support them with data or citations")
            metric = ValidationMetric(
                "Evidence Support", 50.0, "warning",
                "No sentence-ending punctuation found; cannot assess evidence ratio", recs
            )
        } else {
            let supportRatio = Float64(claimsWithData + referencesFound) / Float64(totalClaims)
            var score: Float64
            var status: String
            var details: String
            if (supportRatio >= 0.3) {
                score = 90.0; status = "pass"
                details = "Strong evidence and references found"
            } else if (supportRatio >= 0.15) {
                score = 70.0; status = "warning"
                details = "Some claims lack supporting evidence"
            } else {
                score = 40.0; status = "fail"
                details = "Most claims lack supporting evidence"
            }
            let recs = ArrayList<String>()
            if (supportRatio < 0.3) {
                recs.add("Add more data, figures, or citations to support claims")
            }
            metric = ValidationMetric("Evidence Support", score, status, details, recs)
        }

        metrics["evidence_support"] = metric
        return metric
    }

    public func getMetricsScores(): HashMap<String, Float64> {
        let scores = HashMap<String, Float64>()
        for ((name, metric) in metrics) {
            scores[name] = metric.score
        }
        return scores
    }
}
