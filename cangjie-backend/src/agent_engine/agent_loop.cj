package ai_doc_read_studio.agent_engine

import std.collection.*
import std.time.*
import std.sync.*
import ai_doc_read_studio.utils.*
import ai_doc_read_studio.tools.*

public enum AgentState {
    | IDLE
    | PLANNING
    | EXECUTING
    | OBSERVING
    | REFLECTING
    | COMPLETED
    | FAILED

    public func toString(): String {
        match (this) {
            case IDLE => "idle"
            case PLANNING => "planning"
            case EXECUTING => "executing"
            case OBSERVING => "observing"
            case REFLECTING => "reflecting"
            case COMPLETED => "completed"
            case FAILED => "failed"
        }
    }
}

public class AgentLoopManager {
    var apiKey: String
    var baseUrl: String
    var model: String
    public var maxIterations: Int64
    var memory: AgentMemory
    var client: ?OpenAIClient

    var documentTools: DocumentTools
    var documentValidator: DocumentValidator
    var reflectionEngine: ReflectionEngine

    public var currentState: AgentState
    var iterationResults: ArrayList<HashMap<String, JsonValue>>
    var currentDocument: ?String
    var originalFeedback: ?HashMap<String, JsonValue>
    var metricsBefore: HashMap<String, Float64>
    let mu = Mutex()

    public init(
        apiKey!: ?String = None,
        baseUrl!: ?String = None,
        model!: String = "gpt-4o-mini",
        maxIterations!: Int64 = 3,
        memory!: ?AgentMemory = None
    ) {
        this.apiKey = apiKey ?? getEnvVar("OPENAI_API_KEY")
        this.baseUrl = baseUrl ?? getEnvVar("OPENAI_BASE_URL", defaultValue: "https://api.openai.com/v1")
        this.model = model
        this.maxIterations = maxIterations
        this.memory = memory ?? agentMemory

        if (this.apiKey.size > 0) {
            this.client = OpenAIClient(this.apiKey, baseUrl: this.baseUrl)
        } else {
            this.client = None
        }

        this.documentTools = DocumentTools()
        this.documentValidator = DocumentValidator()
        this.reflectionEngine = ReflectionEngine(maxIterations: maxIterations)

        this.currentState = AgentState.IDLE
        this.iterationResults = ArrayList<HashMap<String, JsonValue>>()
        this.currentDocument = None
        this.originalFeedback = None
        this.metricsBefore = HashMap<String, Float64>()
    }

    public func runAgentLoop(
        documentContent: String,
        feedbackAnalysis: HashMap<String, JsonValue>,
        sessionId!: ?String = None
    ): JsonValue {
        logger.info("Starting agent loop (ReAct + FC)")
        currentDocument = documentContent
        originalFeedback = feedbackAnalysis
        metricsBefore = HashMap<String, Float64>()
        iterationResults = ArrayList<HashMap<String, JsonValue>>()
        reflectionEngine = ReflectionEngine(maxIterations: maxIterations)
        documentTools = DocumentTools()
        documentValidator = DocumentValidator()

        let recsJson = feedbackAnalysis.get("synthesized_recommendations")
        let recommendations = ArrayList<String>()
        match (recsJson) {
            case Some(JsonValue.JsonArray(arr)) =>
                for (item in arr) {
                    match (item.getString()) {
                        case Some(s) => recommendations.add(s)
                        case None => ()
                    }
                }
            case _ => ()
        }

        if (recommendations.size == 0) {
            return generateFinalReport()
        }

        let memoryContext = memory.getRelevantStrategies(safeTruncate(documentContent, 3000))
        let lessons = memory.getLessons(topK: 3)
        var fullMemoryContext = memoryContext
        if (lessons.size > 0) {
            fullMemoryContext += "\n\nLessons from past sessions:\n"
            for (l in lessons) { fullMemoryContext += "- ${l}\n" }
        }

        var iterationNumber: Int64 = 0
        while (iterationNumber < maxIterations) {
            iterationNumber += 1
            logger.info("Starting iteration ${iterationNumber}")

            try {
                currentState = AgentState.OBSERVING
                if (metricsBefore.size == 0) {
                    metricsBefore = validateDocument()
                }

                currentState = AgentState.EXECUTING
                let reactResult = runReactIteration(recommendations, fullMemoryContext)

                var actionsTaken = ArrayList<String>()
                var reactSteps = JsonValue.JsonArray(jsonArray())
                var finalReasoning = ""

                match (reactResult) {
                    case Some(r) =>
                        currentDocument = r.get("document").flatMap { v => v.getString() }
                        match (r.get("actions_taken")) {
                            case Some(JsonValue.JsonArray(arr)) =>
                                for (a in arr) {
                                    match (a.getString()) { case Some(s) => actionsTaken.add(s); case _ => () }
                                }
                            case _ => ()
                        }
                        reactSteps = r.get("steps") ?? JsonValue.JsonArray(jsonArray())
                        finalReasoning = r.get("final_reasoning").flatMap { v => v.getString() } ?? ""
                    case None =>
                        finalReasoning = "ReAct loop did not run (no LLM client)"
                }

                currentState = AgentState.OBSERVING
                let metricsAfter = validateDocument()

                currentState = AgentState.REFLECTING
                let reflection = reflect(
                    iterationNumber, actionsTaken, finalReasoning,
                    metricsBefore, metricsAfter
                )

                let iterResult = HashMap<String, JsonValue>()
                iterResult["iteration"] = JsonValue.JsonInt(iterationNumber)
                let actionsArr = jsonArray()
                for (a in actionsTaken) { actionsArr.add(JsonValue.JsonString(a)) }
                iterResult["actions"] = JsonValue.JsonArray(actionsArr)
                iterResult["react_steps"] = reactSteps
                let metricsObj = jsonObject()
                for ((k, v) in metricsAfter) { metricsObj[k] = JsonValue.JsonFloat(v) }
                iterResult["metrics"] = JsonValue.JsonObject(metricsObj)
                iterResult["reflection"] = JsonValue.JsonObject(reflection)
                iterResult["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
                iterationResults.add(iterResult)
                metricsBefore = metricsAfter

                // ??????
                if (actionsTaken.size > 0) {
                    memory.storeImprovementResult(
                        sessionId ?? "unknown", actionsTaken,
                        metricsBefore, metricsAfter, finalReasoning
                    )
                }
                let lesson = reflection.get("lesson_learned").flatMap { v => v.getString() } ?? ""
                if (lesson.size > 0) {
                    memory.storeLesson(lesson, sessionId: sessionId)
                }

                let shouldContinue = reflection.get("should_continue").flatMap { v => v.getBool() } ?? false
                if (!shouldContinue) {
                    logger.info("Agent loop stopping")
                    break
                }

                // Prepare next round
                match (reflection.get("next_steps")) {
                    case Some(JsonValue.JsonArray(arr)) =>
                        if (arr.size > 0) {
                            recommendations.clear()
                            for (item in arr) {
                                match (item.getString()) { case Some(s) => recommendations.add(s); case _ => () }
                            }
                        }
                    case _ => ()
                }

            } catch (e: Exception) {
                logger.error("Error in iteration ${iterationNumber}", fields: [("error", e.toString())])
                let errResult = HashMap<String, JsonValue>()
                errResult["iteration"] = JsonValue.JsonInt(iterationNumber)
                errResult["error"] = JsonValue.JsonString(e.toString())
                errResult["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
                iterationResults.add(errResult)
                break
            }
        }

        currentState = AgentState.COMPLETED
        return generateFinalReport()
    }

    func runReactIteration(
        recommendations: ArrayList<String>,
        memoryContext: String
    ): ?HashMap<String, JsonValue> {
        match (client) {
            case Some(c) =>
                try {
                    return reactLoop(
                        c, model, currentDocument ?? "",
                        recommendations, documentTools, documentValidator,
                        memoryContext: memoryContext
                    )
                } catch (e: Exception) {
                    logger.warning("ReAct loop failed, using fallback", fields: [("error", e.toString())])
                    return fallbackExecute(recommendations)
                }
            case None =>
                return fallbackExecute(recommendations)
        }
    }

    func fallbackExecute(recommendations: ArrayList<String>): ?HashMap<String, JsonValue> {
        var doc = currentDocument ?? ""
        let executed = ArrayList<String>()
        for (rec in recommendations) {
            if (rec.contains("glossary") || rec.contains("Glossary") || rec.contains("??")) {
                let items = ArrayList<HashMap<String, String>>()
                let item = HashMap<String, String>()
                item["term"] = "Term 1"; item["definition"] = "Definition 1"
                items.add(item)
                doc = documentTools.addGlossary(doc, items)
                executed.add("add_glossary")
            } else if (rec.contains("summary") || rec.contains("Summary") || rec.contains("??")) {
                doc = documentTools.addExecutiveSummary(doc, "Executive summary.")
                executed.add("add_summary")
            } else if (rec.contains("case") || rec.contains("Case") || rec.contains("??")) {
                let cases = ArrayList<HashMap<String, String>>()
                let c = HashMap<String, String>()
                c["title"] = "Example"; c["description"] = "Description"; c["results"] = "Results"
                cases.add(c)
                doc = documentTools.addCaseStudies(doc, cases)
                executed.add("add_case_studies")
            } else if (rec.contains("visual") || rec.contains("Visual") || rec.contains("figure")) {
                let enhancements = ArrayList<HashMap<String, String>>()
                let e = HashMap<String, String>()
                e["figure_ref"] = "Figure 1"; e["enhanced_caption"] = "Enhanced caption"
                enhancements.add(e)
                doc = documentTools.enhanceVisuals(doc, enhancements)
                executed.add("enhance_visuals")
            }
        }
        currentDocument = doc
        let result = HashMap<String, JsonValue>()
        result["document"] = JsonValue.JsonString(doc)
        let stepsArr = jsonArray()
        for (a in executed) {
            stepsArr.add(jsonObj([
                ("step", JsonValue.JsonInt(0)),
                ("thought", JsonValue.JsonString("Rule-based fallback")),
                ("action", JsonValue.JsonString(a)),
                ("observation", JsonValue.JsonString("ok"))
            ]))
        }
        result["steps"] = JsonValue.JsonArray(stepsArr)
        let actionsArr = jsonArray()
        for (a in executed) { actionsArr.add(JsonValue.JsonString(a)) }
        result["actions_taken"] = JsonValue.JsonArray(actionsArr)
        result["final_reasoning"] = JsonValue.JsonString("Executed via rule-based fallback (no LLM client)")
        return result
    }

    func validateDocument(): HashMap<String, Float64> {
        try {
            let doc = currentDocument ?? ""
            documentValidator.validateGlossaryCompleteness(doc)
            documentValidator.validateVisualConsistency(doc)
            documentValidator.validateStructureCompliance(doc)
            documentValidator.validateReadability(doc)
            documentValidator.validateEvidenceSupport(doc)
            return documentValidator.getMetricsScores()
        } catch (e: Exception) {
            logger.error("Validation failed", fields: [("error", e.toString())])
            return HashMap<String, Float64>()
        }
    }

    func reflect(
        iterationNumber: Int64,
        actionsTaken: ArrayList<String>,
        reactReasoning: String,
        mBefore: HashMap<String, Float64>,
        mAfter: HashMap<String, Float64>
    ): HashMap<String, JsonValue> {
        let ruleResult = reflectionEngine.evaluateImprovements(
            iterationNumber, originalFeedback ?? HashMap<String, JsonValue>(),
            mBefore, mAfter, actionsTaken
        )

        let improvementsArr = jsonArray()
        for (m in ruleResult.improvements) {
            improvementsArr.add(m.toJson())
        }

        let result = HashMap<String, JsonValue>()
        result["iteration"] = JsonValue.JsonInt(iterationNumber)
        result["improvements"] = JsonValue.JsonArray(improvementsArr)
        result["overall_improvement_score"] = JsonValue.JsonFloat(ruleResult.overallImprovementScore)
        result["converged"] = JsonValue.JsonBool(ruleResult.converged)
        result["should_continue"] = JsonValue.JsonBool(ruleResult.shouldContinue)
        result["reasoning"] = JsonValue.JsonString(ruleResult.reasoning)
        let stepsArr = jsonArray()
        for (s in ruleResult.nextSteps) { stepsArr.add(JsonValue.JsonString(s)) }
        result["next_steps"] = JsonValue.JsonArray(stepsArr)
        result["lesson_learned"] = JsonValue.JsonString("")

        match (client) {
            case Some(c) =>
                let llmRef = reflectWithLlm(
                    c, model, iterationNumber,
                    mBefore, mAfter, actionsTaken,
                    reactReasoning, maxIterations
                )
                match (llmRef.get("reasoning")) {
                    case Some(v) => result["reasoning"] = v
                    case None => ()
                }
                match (llmRef.get("should_continue")) {
                    case Some(v) =>
                        result["should_continue"] = v
                        result["converged"] = JsonValue.JsonBool(!(v.getBool() ?? false))
                    case None => ()
                }
                match (llmRef.get("next_steps")) {
                    case Some(v) => result["next_steps"] = v
                    case None => ()
                }
                match (llmRef.get("lesson_learned")) {
                    case Some(v) => result["lesson_learned"] = v
                    case None => ()
                }
            case None => ()
        }

        return result
    }

    func generateFinalReport(): JsonValue {
        let reflectionReport = reflectionEngine.generateFinalReport()
        let iterHistoryArr = jsonArray()
        for (r in iterationResults) {
            iterHistoryArr.add(JsonValue.JsonObject(r))
        }

        let doc = currentDocument ?? ""
        let preview = if (doc.size > 500) { safeTruncate(doc, 500) + "..." } else { doc }

        return jsonObj([
            ("status", JsonValue.JsonString("completed")),
            ("total_iterations", JsonValue.JsonInt(Int64(iterationResults.size))),
            ("final_state", JsonValue.JsonString(currentState.toString())),
            ("converged", reflectionReport["converged"] ?? JsonValue.JsonBool(false)),
            ("total_improvement_score", reflectionReport["total_improvement_score"] ?? JsonValue.JsonFloat(0.0)),
            ("improvements", reflectionReport),
            ("iteration_history", JsonValue.JsonArray(iterHistoryArr)),
            ("final_document_preview", JsonValue.JsonString(preview)),
            ("final_document", JsonValue.JsonString(doc)),
            ("memory_stats", memory.getStats()),
            ("timestamp", JsonValue.JsonString(DateTime.now().toString()))
        ])
    }

    public func getCurrentStatus(): JsonValue {
        return jsonObj([
            ("state", JsonValue.JsonString(currentState.toString())),
            ("iterations_completed", JsonValue.JsonInt(Int64(iterationResults.size))),
            ("max_iterations", JsonValue.JsonInt(maxIterations))
        ])
    }
}

// ????
public let agentLoopManager = AgentLoopManager()
