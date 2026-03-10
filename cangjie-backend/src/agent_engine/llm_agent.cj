package ai_doc_read_studio.agent_engine

import std.collection.*
import ai_doc_read_studio.utils.*
import ai_doc_read_studio.tools.*

let MAX_DOC_CHARS: Int64 = 12000
let MAX_REACT_STEPS: Int64 = 8

func jsonStr(jv: ?JsonValue): String {
    match (jv) {
        case Some(v) => match (v.getString()) {
            case Some(s) => s
            case None => ""
        }
        case None => ""
    }
}

func truncate(s: String, maxLen: Int64): String {
    if (s.size <= maxLen) { return s }
    return safeTruncate(s, maxLen) + "\n\n...(truncated)"
}

// Tool definition: generate OpenAI function calling format JSON
public func getAgentToolsJson(): JsonValue {
    let tools = jsonArray()

    // add_glossary
    tools.add(makeToolDef(
        "add_glossary",
        "Add a glossary of technical terms extracted from the document.",
        jsonObj([
            ("type", JsonValue.JsonString("object")),
            ("properties", jsonObj([
                ("terms", jsonObj([
                    ("type", JsonValue.JsonString("array")),
                    ("description", JsonValue.JsonString("5-10 key terms with definitions")),
                    ("items", jsonObj([
                        ("type", JsonValue.JsonString("object")),
                        ("properties", jsonObj([
                            ("term", jsonObj([("type", JsonValue.JsonString("string"))])),
                            ("definition", jsonObj([("type", JsonValue.JsonString("string"))]))
                        ])),
                        ("required", jsonArr([JsonValue.JsonString("term"), JsonValue.JsonString("definition")]))
                    ]))
                ]))
            ])),
            ("required", jsonArr([JsonValue.JsonString("terms")]))
        ])
    ))

    // add_executive_summary
    tools.add(makeToolDef(
        "add_executive_summary",
        "Add an executive summary to the beginning of the document.",
        jsonObj([
            ("type", JsonValue.JsonString("object")),
            ("properties", jsonObj([
                ("summary", jsonObj([
                    ("type", JsonValue.JsonString("string")),
                    ("description", JsonValue.JsonString("2-4 paragraph executive summary"))
                ]))
            ])),
            ("required", jsonArr([JsonValue.JsonString("summary")]))
        ])
    ))

    // add_case_studies
    tools.add(makeToolDef(
        "add_case_studies",
        "Add real-world case studies to the document.",
        jsonObj([
            ("type", JsonValue.JsonString("object")),
            ("properties", jsonObj([
                ("cases", jsonObj([
                    ("type", JsonValue.JsonString("array")),
                    ("items", jsonObj([
                        ("type", JsonValue.JsonString("object")),
                        ("properties", jsonObj([
                            ("title", jsonObj([("type", JsonValue.JsonString("string"))])),
                            ("description", jsonObj([("type", JsonValue.JsonString("string"))])),
                            ("results", jsonObj([("type", JsonValue.JsonString("string"))]))
                        ])),
                        ("required", jsonArr([
                            JsonValue.JsonString("title"),
                            JsonValue.JsonString("description"),
                            JsonValue.JsonString("results")
                        ]))
                    ]))
                ]))
            ])),
            ("required", jsonArr([JsonValue.JsonString("cases")]))
        ])
    ))

    // enhance_visuals
    tools.add(makeToolDef(
        "enhance_visuals",
        "Enhance figure/chart captions and formatting.",
        jsonObj([
            ("type", JsonValue.JsonString("object")),
            ("properties", jsonObj([
                ("enhancements", jsonObj([
                    ("type", JsonValue.JsonString("array")),
                    ("items", jsonObj([
                        ("type", JsonValue.JsonString("object")),
                        ("properties", jsonObj([
                            ("figure_ref", jsonObj([("type", JsonValue.JsonString("string"))])),
                            ("enhanced_caption", jsonObj([("type", JsonValue.JsonString("string"))]))
                        ])),
                        ("required", jsonArr([
                            JsonValue.JsonString("figure_ref"),
                            JsonValue.JsonString("enhanced_caption")
                        ]))
                    ]))
                ]))
            ])),
            ("required", jsonArr([JsonValue.JsonString("enhancements")]))
        ])
    ))

    // validate_document
    tools.add(makeToolDef(
        "validate_document",
        "Run quality validation checks on the current document.",
        jsonObj([("type", JsonValue.JsonString("object")), ("properties", jsonObj([]))])
    ))

    // finish_improvement
    tools.add(makeToolDef(
        "finish_improvement",
        "Signal that document improvement is complete.",
        jsonObj([
            ("type", JsonValue.JsonString("object")),
            ("properties", jsonObj([
                ("reasoning", jsonObj([
                    ("type", JsonValue.JsonString("string")),
                    ("description", JsonValue.JsonString("Brief explanation of what was achieved"))
                ]))
            ])),
            ("required", jsonArr([JsonValue.JsonString("reasoning")]))
        ])
    ))

    return JsonValue.JsonArray(tools)
}

func makeToolDef(name: String, description: String, parameters: JsonValue): JsonValue {
    return jsonObj([
        ("type", JsonValue.JsonString("function")),
        ("function", jsonObj([
            ("name", JsonValue.JsonString(name)),
            ("description", JsonValue.JsonString(description)),
            ("parameters", parameters)
        ]))
    ])
}

// Tool execution
public func executeToolCall(
    functionName: String,
    arguments: JsonValue,
    documentTools: DocumentTools,
    documentValidator: DocumentValidator,
    currentDocument: String
): (String, String) {
    try {
        if (functionName == "add_glossary") {
                let items = ArrayList<HashMap<String, String>>()
                match (arguments["terms"]) {
                    case Some(termsJv) =>
                        match (termsJv.getArray()) {
                            case Some(termsArr) =>
                                for (t in termsArr) {
                                    let item = HashMap<String, String>()
                                    item["term"] = jsonStr(t["term"])
                                    item["definition"] = jsonStr(t["definition"])
                                    items.add(item)
                                }
                            case None => ()
                        }
                    case None => ()
                }
                let updated = documentTools.addGlossary(currentDocument, items)
                let termNamesSb = StringBuilder()
                for (i in items) {
                    if (termNamesSb.size > 0) { termNamesSb.append(", ") }
                    termNamesSb.append(i.get("term") ?? "")
                }
                return ("Added glossary with ${items.size} terms: ${termNamesSb.toString()}", updated)
        } else if (functionName == "add_executive_summary") {
                let summaryStr = jsonStr(arguments["summary"])
                let updated = documentTools.addExecutiveSummary(currentDocument, summaryStr)
                return ("Added executive summary (${summaryStr.size} chars)", updated)
        } else if (functionName == "add_case_studies") {
                let cases = ArrayList<HashMap<String, String>>()
                match (arguments["cases"]) {
                    case Some(casesJv) =>
                        match (casesJv.getArray()) {
                            case Some(casesArr) =>
                                for (c in casesArr) {
                                    let item = HashMap<String, String>()
                                    item["title"] = jsonStr(c["title"])
                                    item["description"] = jsonStr(c["description"])
                                    item["results"] = jsonStr(c["results"])
                                    cases.add(item)
                                }
                            case None => ()
                        }
                    case None => ()
                }
                let updated = documentTools.addCaseStudies(currentDocument, cases)
                return ("Added ${cases.size} case studies", updated)
        } else if (functionName == "enhance_visuals") {
                let enhancements = ArrayList<HashMap<String, String>>()
                match (arguments["enhancements"]) {
                    case Some(enhJv) =>
                        match (enhJv.getArray()) {
                            case Some(enhArr) =>
                                for (e in enhArr) {
                                    let item = HashMap<String, String>()
                                    item["figure_ref"] = jsonStr(e["figure_ref"])
                                    item["enhanced_caption"] = jsonStr(e["enhanced_caption"])
                                    enhancements.add(item)
                                }
                            case None => ()
                        }
                    case None => ()
                }
                let updated = documentTools.enhanceVisuals(currentDocument, enhancements)
                return ("Enhanced ${enhancements.size} visual elements", updated)
        } else if (functionName == "validate_document") {
                documentValidator.validateGlossaryCompleteness(currentDocument)
                documentValidator.validateVisualConsistency(currentDocument)
                documentValidator.validateStructureCompliance(currentDocument)
                documentValidator.validateReadability(currentDocument)
                documentValidator.validateEvidenceSupport(currentDocument)
                let scores = documentValidator.getMetricsScores()
                let sb = StringBuilder()
                sb.append("Validation metrics: {")
                var first = true
                for ((name, score) in scores) {
                    if (!first) { sb.append(", ") }
                    sb.append("\"${name}\": ${score}")
                    first = false
                }
                sb.append("}")
                return (sb.toString(), currentDocument)
        } else if (functionName == "finish_improvement") {
                var reasoning = jsonStr(arguments["reasoning"])
                if (reasoning.size == 0) { reasoning = "Completed" }
                return ("FINISHED: ${reasoning}", currentDocument)
        } else {
                return ("Unknown tool: ${functionName}", currentDocument)
        }
    } catch (e: Exception) {
        return ("Error executing ${functionName}: ${e.toString()}", currentDocument)
    }
}

let REACT_SYSTEM_PROMPT = """
You are a document improvement agent that uses the ReAct pattern (Reasoning + Acting).

You have access to tools for modifying and validating a document. Your job:
1. Read the document and reviewer recommendations
2. THINK about what improvements are needed
3. ACT by calling at least one document-modifying tool (add_glossary, add_executive_summary, add_case_studies, or enhance_visuals)
4. OBSERVE the result
5. Use validate_document to check the improvement
6. THINK again: did it work? What else is needed?
7. Repeat, then call finish_improvement ONLY after you have made at least one real change

MANDATORY RULES:
- You MUST call at least one of: add_glossary, add_executive_summary, add_case_studies, or enhance_visuals
- NEVER call finish_improvement as your first action — always improve the document first
- Use validate_document after making changes to confirm improvement
- Extract REAL terms/content from the actual document text
- Use the same language as the document (if document is in Chinese, use Chinese)
- After calling a modifying tool, always call validate_document to verify the changes

TOOL SELECTION GUIDE:
- If recommendations mention glossary/terms/definitions → call add_glossary first
- If recommendations mention summary/overview → call add_executive_summary first
- If recommendations mention examples/cases → call add_case_studies first
- If recommendations mention figures/charts/visuals → call enhance_visuals first
"""

// ReAct ??
public func reactLoop(
    client: OpenAIClient,
    model: String,
    documentContent: String,
    recommendations: ArrayList<String>,
    documentTools: DocumentTools,
    documentValidator: DocumentValidator,
    memoryContext!: String = ""
): HashMap<String, JsonValue> {
    var doc = documentContent
    let recsSb = StringBuilder()
    for (r in recommendations) {
        if (recsSb.size > 0) { recsSb.append("\n") }
        recsSb.append("- ${r}")
    }
    let recsText = recsSb.toString()

    let systemPrompt = REACT_SYSTEM_PROMPT + "\n" + memoryContext

    // 运行初始验证，获取当前指标分数以指导 LLM 优先处理低分项
    let glossaryMetric = documentValidator.validateGlossaryCompleteness(doc)
    let evidenceMetric = documentValidator.validateEvidenceSupport(doc)
    let visualMetric = documentValidator.validateVisualConsistency(doc)
    let glossaryScore = glossaryMetric.score
    let evidenceScore = evidenceMetric.score
    let visualScore = visualMetric.score

    let scoresSb = StringBuilder()
    scoresSb.append("Current document quality scores:\n")
    scoresSb.append("- glossary_completeness: ${glossaryScore}/100 -> use add_glossary to improve\n")
    scoresSb.append("- evidence_support: ${evidenceScore}/100 -> use add_case_studies to improve\n")
    scoresSb.append("- visual_consistency: ${visualScore}/100 -> use enhance_visuals to improve\n")
    scoresSb.append("PRIORITY RULE: Call add_glossary FIRST if glossary_completeness < 100.\n")
    let scoresHint = scoresSb.toString()

    let userContent = "Document (excerpt):\n${truncate(doc, MAX_DOC_CHARS)}\n\n${scoresHint}\nReviewer recommendations:\n${recsText}\n\nIMPORTANT: Call each tool at most ONCE per iteration. Prioritize the lowest-scoring metric. Call finish_improvement only after you have used at least one tool."

    let messages = ArrayList<HashMap<String, String>>()
    let sysMsg = HashMap<String, String>()
    sysMsg["role"] = "system"
    sysMsg["content"] = systemPrompt
    messages.add(sysMsg)

    let userMsg = HashMap<String, String>()
    userMsg["role"] = "user"
    userMsg["content"] = userContent
    messages.add(userMsg)

    let steps = jsonArray()
    let actionsTaken = ArrayList<String>()
    // 去重：每种文档修改工具在一轮中只执行一次
    let executedToolTypes = HashSet<String>()
    var finalReasoning = ""
    var hasDocModification = false

    let toolsJson = getAgentToolsJson()

    for (stepIdx in 0..MAX_REACT_STEPS) {
        // 构建本次 API 调用的临时消息列表（复制 messages，不修改原列表）
        let stepMessages = ArrayList<HashMap<String, String>>()
        for (m in messages) { stepMessages.add(m) }

        // 将"已用工具"状态注入到本次调用（临时，不持久化到 messages）
        if (executedToolTypes.size > 0) {
            let doneToolsSb = StringBuilder()
            for (t in executedToolTypes) {
                if (doneToolsSb.size > 0) { doneToolsSb.append(", ") }
                doneToolsSb.append(t)
            }
            let doneStr = doneToolsSb.toString()
            let hintMsg = HashMap<String, String>()
            hintMsg["role"] = "user"
            hintMsg["content"] = "Tools already used this iteration: [${doneStr}]. Do NOT call these again. Choose a different tool or call finish_improvement if all improvements are done."
            stepMessages.add(hintMsg)
        }

        let (responseText, fullResponse) = client.chatCompletion(
            model, stepMessages, tools: toolsJson
        )

        let thought = responseText

        // 提取 tool_calls
        let toolCalls = extractToolCalls(fullResponse)

        if (toolCalls.size == 0) {
            // LLM 没有调用工具，记录 thought 并提示
            steps.add(jsonObj([
                ("step", JsonValue.JsonInt(stepIdx)),
                ("thought", JsonValue.JsonString(thought)),
                ("action", JsonValue.JsonNull),
                ("observation", JsonValue.JsonNull)
            ]))
            finalReasoning = thought

            let assistMsg = HashMap<String, String>()
            assistMsg["role"] = "assistant"
            assistMsg["content"] = thought
            messages.add(assistMsg)

            let nextPrompt = if (hasDocModification) {
                "You have made some improvements. You may call finish_improvement to complete this iteration, or call a tool you have NOT yet used."
            } else {
                "You MUST call a document-modifying tool (add_glossary, add_executive_summary, add_case_studies, or enhance_visuals). Do NOT call finish_improvement without making at least one change."
            }
            let promptMsg = HashMap<String, String>()
            promptMsg["role"] = "user"
            promptMsg["content"] = nextPrompt
            messages.add(promptMsg)
            continue
        }

        for (tc in toolCalls) {
            let fnName = tc.get("name") ?? ""
            let fnArgsStr = tc.get("arguments") ?? "{}"
            let fnArgs = parseJson(fnArgsStr) ?? JsonValue.JsonObject(jsonObject())

            let isDocTool = fnName == "add_glossary" || fnName == "add_executive_summary" ||
                            fnName == "add_case_studies" || fnName == "enhance_visuals"

            // 文档修改工具去重：同类工具本轮只执行一次
            if (isDocTool && executedToolTypes.contains(fnName)) {
                steps.add(jsonObj([
                    ("step", JsonValue.JsonInt(stepIdx)),
                    ("thought", JsonValue.JsonString(thought)),
                    ("action", JsonValue.JsonString(fnName)),
                    ("observation", JsonValue.JsonString("Already used ${fnName} this iteration. Skipped."))
                ]))
                // 持久化到对话历史：告知 LLM 这个工具已跳过
                let skipAssist = HashMap<String, String>()
                skipAssist["role"] = "assistant"
                skipAssist["content"] = thought
                messages.add(skipAssist)
                let skipObs = HashMap<String, String>()
                skipObs["role"] = "user"
                skipObs["content"] = "${fnName} was already used. Please call a different tool or finish_improvement."
                messages.add(skipObs)
                continue
            }

            let (observation, updatedDoc) = executeToolCall(
                fnName, fnArgs, documentTools, documentValidator, doc
            )
            doc = updatedDoc

            steps.add(jsonObj([
                ("step", JsonValue.JsonInt(stepIdx)),
                ("thought", JsonValue.JsonString(thought)),
                ("action", JsonValue.JsonString(fnName)),
                ("observation", JsonValue.JsonString(observation))
            ]))
            actionsTaken.add(fnName)

            if (isDocTool) {
                executedToolTypes.add(fnName)
                hasDocModification = true
            }

            // 持久化工具调用结果到对话历史（使用干净格式，不含特殊前缀）
            let assistToolMsg = HashMap<String, String>()
            assistToolMsg["role"] = "assistant"
            assistToolMsg["content"] = thought
            messages.add(assistToolMsg)
            let obsMsg = HashMap<String, String>()
            obsMsg["role"] = "user"
            obsMsg["content"] = "Tool result for ${fnName}: ${observation}"
            messages.add(obsMsg)

            if (fnName == "finish_improvement") {
                var fnReason = jsonStr(fnArgs["reasoning"])
                if (fnReason.size == 0) { fnReason = thought }
                finalReasoning = fnReason
                let result = HashMap<String, JsonValue>()
                result["document"] = JsonValue.JsonString(doc)
                result["steps"] = JsonValue.JsonArray(steps)
                let actionsArr = jsonArray()
                for (a in actionsTaken) { actionsArr.add(JsonValue.JsonString(a)) }
                result["actions_taken"] = JsonValue.JsonArray(actionsArr)
                result["final_reasoning"] = JsonValue.JsonString(finalReasoning)
                return result
            }
        }
    }

    if (finalReasoning.size == 0) {
        finalReasoning = "Reached maximum ReAct steps"
    }

    let result = HashMap<String, JsonValue>()
    result["document"] = JsonValue.JsonString(doc)
    result["steps"] = JsonValue.JsonArray(steps)
    let actionsArr = jsonArray()
    for (a in actionsTaken) { actionsArr.add(JsonValue.JsonString(a)) }
    result["actions_taken"] = JsonValue.JsonArray(actionsArr)
    result["final_reasoning"] = JsonValue.JsonString(finalReasoning)
    return result
}

func extractToolCalls(response: JsonValue): ArrayList<HashMap<String, String>> {
    let result = ArrayList<HashMap<String, String>>()
    match (response["choices"]) {
        case Some(JsonValue.JsonArray(choices)) =>
            if (choices.size > 0) {
                match (choices[0]["message"]) {
                    case Some(msg) =>
                        match (msg["tool_calls"]) {
                            case Some(JsonValue.JsonArray(calls)) =>
                                for (call in calls) {
                                    match (call["function"]) {
                                        case Some(fn) =>
                                            let tc = HashMap<String, String>()
                                            let tcName = jsonStr(fn["name"])
                                            var tcArgs = jsonStr(fn["arguments"])
                                            if (tcArgs.size == 0) { tcArgs = "{}" }
                                            let tcId = jsonStr(call["id"])
                                            tc["name"] = tcName
                                            tc["arguments"] = tcArgs
                                            tc["id"] = tcId
                                            result.add(tc)
                                        case None => ()
                                    }
                                }
                            case _ => ()
                        }
                    case None => ()
                }
            }
        case _ => ()
    }
    return result
}

// LLM reflection
public func reflectWithLlm(
    client: OpenAIClient,
    model: String,
    iterationNumber: Int64,
    metricsBefore: HashMap<String, Float64>,
    metricsAfter: HashMap<String, Float64>,
    actionsTaken: ArrayList<String>,
    reactReasoning: String,
    maxIterations: Int64
): HashMap<String, JsonValue> {
    let system = """
You are a document quality agent performing reflection after an improvement iteration.
Based on metrics, actions taken, and the agent's reasoning, decide:
1. Was this iteration effective?
2. Should we do another iteration?
3. What should the next iteration focus on?

Output ONLY valid JSON:
{
  "reasoning": "2-3 sentences analyzing the iteration results.",
  "should_continue": true or false,
  "next_steps": ["specific action 1", "action 2"] or [],
  "lesson_learned": "One sentence about what worked or didn't work."
}"""

    let beforeStr = metricsMapToString(metricsBefore)
    let afterStr = metricsMapToString(metricsAfter)
    let actionsSb = StringBuilder()
    for (a in actionsTaken) {
        if (actionsSb.size > 0) { actionsSb.append(", ") }
        actionsSb.append(a)
    }
    let actionsStr = actionsSb.toString()
    let reasoningTrunc = if (reactReasoning.size > 500) { safeTruncate(reactReasoning, 500) } else { reactReasoning }

    let userPrompt = "Iteration: ${iterationNumber} / ${maxIterations}\nMetrics before: ${beforeStr}\nMetrics after: ${afterStr}\nActions taken: ${actionsStr}\nAgent reasoning: ${reasoningTrunc}\n\nOutput JSON only."

    try {
        let (responseText, _) = invokeWithRetry(client, system, userPrompt, model, maxAttempts: 2)
        var text = responseText.trimAscii()
        if (text.contains("```")) {
            let parts = text.split("```")
            if (parts.size >= 2) {
                text = parts[1]
                if (text.startsWith("json")) {
                    text = text[4..]
                }
            }
        }
        let parsed = parseJson(text)
        match (parsed) {
            case Some(json) =>
                let result = HashMap<String, JsonValue>()
                result["reasoning"] = json["reasoning"] ?? JsonValue.JsonString("")
                var shouldContinue = match (json["should_continue"]) {
                    case Some(bv) => match (bv.getBool()) { case Some(b) => b case None => false }
                    case None => false
                }
                if (iterationNumber >= maxIterations) { shouldContinue = false }
                result["should_continue"] = JsonValue.JsonBool(shouldContinue)
                result["next_steps"] = json["next_steps"] ?? JsonValue.JsonArray(jsonArray())
                result["lesson_learned"] = json["lesson_learned"] ?? JsonValue.JsonString("")
                return result
            case None => ()
        }
    } catch (_: Exception) {}

    let fallback = HashMap<String, JsonValue>()
    fallback["reasoning"] = JsonValue.JsonString(reactReasoning)
    fallback["should_continue"] = JsonValue.JsonBool(iterationNumber < maxIterations)
    fallback["next_steps"] = JsonValue.JsonArray(jsonArray())
    fallback["lesson_learned"] = JsonValue.JsonString("")
    return fallback
}

func metricsMapToString(m: HashMap<String, Float64>): String {
    let sb = StringBuilder()
    sb.append("{")
    var first = true
    for ((k, v) in m) {
        if (!first) { sb.append(", ") }
        sb.append("\"${k}\": ${v}")
        first = false
    }
    sb.append("}")
    return sb.toString()
}
