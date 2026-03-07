package ai_doc_read_studio.tools

import std.collection.*
import std.regex.*
import std.time.*
import ai_doc_read_studio.utils.*

public class DocumentTools {
    var actionsHistory: ArrayList<String>

    public init() {
        this.actionsHistory = ArrayList<String>()
    }

    public func addGlossary(documentContent: String, items: ArrayList<HashMap<String, String>>): String {
        let glossarySection = generateGlossaryMarkdown(items)

        let glossaryRegex = Regex("^## (Glossary|Glossary Section)\\s*\\n.*?(?=\\n##|\\n#|$)", RegexOption().multiLine())
        let matcher = glossaryRegex.matcher(documentContent)
        var result: String
        match (matcher.find()) { case Some(_) =>
            result = matcher.replaceAll(glossarySection + "\n\n")
        case None =>
            result = documentContent + "\n\n" + glossarySection
        }

        actionsHistory.add("add_glossary")
        return result
    }

    public func addExecutiveSummary(documentContent: String, summaryText: String): String {
        let summarySection = "## Executive Summary\n\n${summaryText}\n\n---\n\n"

        let existsRegex = Regex("^## Executive Summary\\s*$", RegexOption().multiLine())
        match (existsRegex.matcher(documentContent).find()) {
            case Some(_) =>
                let replaceRegex = Regex("^## Executive Summary\\s*\\n.*?(?=\\n##|\\n#|$)", RegexOption().multiLine())
                let result = replaceRegex.matcher(documentContent).replaceAll(summarySection.trimAscii() + "\n\n")
                actionsHistory.add("add_executive_summary")
                return result
            case None => ()
        }

        let titleRegex = Regex("^(# .+)$", RegexOption().multiLine())
        let titleMatcher = titleRegex.matcher(documentContent)
        match (titleMatcher.find()) {
            case Some(m) =>
                let endPos = m.matchPosition().end
                let result = documentContent[..endPos] + "\n\n" + summarySection + documentContent[endPos..]
                actionsHistory.add("add_executive_summary")
                return result
            case None =>
                actionsHistory.add("add_executive_summary")
                return summarySection + documentContent
        }
    }

    public func addCaseStudies(documentContent: String, cases: ArrayList<HashMap<String, String>>): String {
        let section = generateCaseStudiesSection(cases)

        let existsRegex = Regex("^## Real-World Case Studies\\s*$", RegexOption().multiLine())
        match (existsRegex.matcher(documentContent).find()) {
            case Some(_) =>
                let replaceRegex = Regex("^## Real-World Case Studies\\s*\\n.*?(?=\\n##|\\n#|$)", RegexOption().multiLine())
                let result = replaceRegex.matcher(documentContent).replaceAll(section.trimAscii() + "\n\n")
                actionsHistory.add("add_case_studies")
                return result
            case None => ()
        }

        var result: String
        if (documentContent.contains("## Conclusion")) {
            result = documentContent.replace("## Conclusion", section + "\n\n## Conclusion")
        } else {
            result = documentContent + "\n\n" + section
        }
        actionsHistory.add("add_case_studies")
        return result
    }

    public func enhanceVisuals(documentContent: String, enhancements: ArrayList<HashMap<String, String>>): String {
        var result = documentContent
        for (enhancement in enhancements) {
            let figureRef = enhancement.get("figure_ref") ?? ""
            let enhancedCaption = enhancement.get("enhanced_caption") ?? ""
            if (figureRef.size > 0) {
                let escaped = escapeRegexChars(figureRef)
                let pattern = Regex("\\[${escaped}.*?\\]")
                result = pattern.matcher(result).replaceAll("[${figureRef}]\n\n*${enhancedCaption}*")
            }
        }

        if (!result.contains("## Formatting Guide")) {
            result = result + "\n\n" + generateFormattingGuide()
        }

        actionsHistory.add("enhance_visuals")
        return result
    }

    public func getHistory(): ArrayList<String> {
        return actionsHistory
    }
}

func generateGlossaryMarkdown(items: ArrayList<HashMap<String, String>>): String {
    let sb = StringBuilder()
    sb.append("## Glossary\n\n")
    for (item in items) {
        let term = item.get("term") ?? ""
        let definition = item.get("definition") ?? ""
        sb.append("**${term}**: ${definition}\n\n")
    }
    return sb.toString().trimAscii()
}

func generateCaseStudiesSection(cases: ArrayList<HashMap<String, String>>): String {
    let sb = StringBuilder()
    sb.append("## Real-World Case Studies\n\n")
    var i: Int64 = 1
    for (caseStudy in cases) {
        let title = caseStudy.get("title") ?? "Case Study ${i}"
        let description = caseStudy.get("description") ?? ""
        let results = caseStudy.get("results") ?? ""
        sb.append("### ${title}\n\n")
        sb.append("${description}\n\n")
        if (results.size > 0) {
            sb.append("**Results**: ${results}\n\n")
        }
        i += 1
    }
    return sb.toString().trimAscii()
}

func generateFormattingGuide(): String {
    return """
## Formatting Guide

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
}

func escapeRegexChars(s: String): String {
    let specialChars = ["\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"]
    var result = s
    for (ch in specialChars) {
        result = result.replace(ch, "\\${ch}")
    }
    return result
}
