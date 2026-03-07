package ai_doc_read_studio.agent_engine

import std.collection.*
import std.time.*
import ai_doc_read_studio.utils.*

public class ImprovementMetrics {
    public var metricName: String
    public var beforeScore: Float64
    public var afterScore: Float64
    public var improvement: Float64
    public var status: String

    public init(metricName: String, beforeScore: Float64, afterScore: Float64) {
        this.metricName = metricName
        this.beforeScore = beforeScore
        this.afterScore = afterScore
        this.improvement = afterScore - beforeScore
        if (improvement > 0.0) {
            this.status = "improved"
        } else if (improvement < 0.0) {
            this.status = "degraded"
        } else {
            this.status = "same"
        }
    }

    public func toJson(): JsonValue {
        return jsonObj([
            ("metric", JsonValue.JsonString(metricName)),
            ("before", JsonValue.JsonFloat(beforeScore)),
            ("after", JsonValue.JsonFloat(afterScore)),
            ("improvement", JsonValue.JsonFloat(improvement)),
            ("status", JsonValue.JsonString(status))
        ])
    }
}

public class ReflectionResult {
    public var timestamp: String
    public var iterationNumber: Int64
    public var improvements: ArrayList<ImprovementMetrics>
    public var overallImprovementScore: Float64
    public var converged: Bool
    public var shouldContinue: Bool
    public var reasoning: String
    public var nextSteps: ArrayList<String>

    public init(
        timestamp: String, iterationNumber: Int64,
        improvements: ArrayList<ImprovementMetrics>,
        overallImprovementScore: Float64, converged: Bool,
        shouldContinue: Bool, reasoning: String,
        nextSteps: ArrayList<String>
    ) {
        this.timestamp = timestamp
        this.iterationNumber = iterationNumber
        this.improvements = improvements
        this.overallImprovementScore = overallImprovementScore
        this.converged = converged
        this.shouldContinue = shouldContinue
        this.reasoning = reasoning
        this.nextSteps = nextSteps
    }
}

public class ReflectionEngine {
    var convergenceThreshold: Float64
    public var maxIterations: Int64
    public var history: ArrayList<ReflectionResult>

    public init(convergenceThreshold!: Float64 = 0.05, maxIterations!: Int64 = 3) {
        this.convergenceThreshold = convergenceThreshold
        this.maxIterations = maxIterations
        this.history = ArrayList<ReflectionResult>()
    }

    public func evaluateImprovements(
        iterationNumber: Int64,
        originalFeedback: HashMap<String, JsonValue>,
        metricsBefore: HashMap<String, Float64>,
        metricsAfter: HashMap<String, Float64>,
        actionsTaken: ArrayList<String>
    ): ReflectionResult {
        let improvements = ArrayList<ImprovementMetrics>()
        var totalImprovement: Float64 = 0.0

        for ((metricName, afterScore) in metricsAfter) {
            let beforeScore = metricsBefore.get(metricName) ?? 0.0
            let m = ImprovementMetrics(metricName, beforeScore, afterScore)
            improvements.add(m)
            let imp = m.improvement
            totalImprovement += if (imp >= 0.0) { imp } else { -imp }
        }

        let avgImprovement = if (improvements.size > 0) {
            totalImprovement / Float64(improvements.size)
        } else { 0.0 }

        let converged = avgImprovement < convergenceThreshold
        let shouldContinue = !converged && iterationNumber < maxIterations

        let reasoning = generateReasoning(iterationNumber, improvements, avgImprovement, converged, actionsTaken)

        var nextSteps = ArrayList<String>()
        if (shouldContinue) {
            nextSteps = suggestNextSteps(originalFeedback, improvements, actionsTaken)
        }

        let result = ReflectionResult(
            DateTime.now().toString(), iterationNumber,
            improvements, avgImprovement, converged,
            shouldContinue, reasoning, nextSteps
        )
        history.add(result)
        return result
    }

    func generateReasoning(
        iterationNumber: Int64,
        improvements: ArrayList<ImprovementMetrics>,
        avgImprovement: Float64,
        converged: Bool,
        actionsTaken: ArrayList<String>
    ): String {
        let sb = StringBuilder()
        sb.append("Iteration ${iterationNumber}: ")

        var improved: Int64 = 0
        var degraded: Int64 = 0
        var same: Int64 = 0
        for (m in improvements) {
            match (m.status) {
                case "improved" => improved += 1
                case "degraded" => degraded += 1
                case _ => same += 1
            }
        }

        sb.append("Out of ${improvements.size} metrics, ")
        sb.append("${improved} improved, ${same} stayed same, ${degraded} degraded. ")

        if (avgImprovement > 15.0) {
            sb.append("Significant improvements detected. ")
        } else if (avgImprovement > 5.0) {
            sb.append("Moderate improvements detected. ")
        } else if (avgImprovement > 0.0) {
            sb.append("Minor improvements detected. ")
        } else {
            sb.append("No meaningful improvements. ")
        }

        if (converged) {
            sb.append("The document has converged - further iterations may not yield significant improvements. ")
        } else {
            sb.append("The document can still be improved. ")
        }

        if (actionsTaken.size > 0) {
            let atSb = StringBuilder()
            for (a in actionsTaken) {
                if (atSb.size > 0) { atSb.append(", ") }
                atSb.append(a)
            }
            let actionsStr = atSb.toString()
            sb.append("Actions taken: ${actionsStr}. ")
        }

        if (iterationNumber >= maxIterations) {
            sb.append("Maximum iterations (${maxIterations}) reached.")
        }

        return sb.toString().trimAscii()
    }

    func suggestNextSteps(
        originalFeedback: HashMap<String, JsonValue>,
        improvements: ArrayList<ImprovementMetrics>,
        actionsTaken: ArrayList<String>
    ): ArrayList<String> {
        let steps = ArrayList<String>()

        // Find worst metric
        var leastImproved: ?ImprovementMetrics = None
        var minImprovement: Float64 = 999999.0
        for (m in improvements) {
            if (m.improvement < minImprovement) {
                minImprovement = m.improvement
                leastImproved = m
            }
        }
        match (leastImproved) {
            case Some(m) =>
                if (m.status != "improved") {
                    steps.add("Focus on improving '${m.metricName}' (current: ${m.afterScore})")
                }
            case None => ()
        }

        let possibleActions = ["add_glossary", "add_case_studies", "enhance_visuals"]
        let takenSet = HashSet<String>()
        for (a in actionsTaken) { takenSet.add(a) }
        for (action in possibleActions) {
            if (!takenSet.contains(action)) {
                steps.add("Consider implementing: ${action}")
                break
            }
        }

        return steps
    }

    public func generateFinalReport(): JsonValue {
        if (history.size == 0) {
            return jsonObj([
                ("status", JsonValue.JsonString("no_history")),
                ("message", JsonValue.JsonString("No reflection history available"))
            ])
        }

        let totalIterations = Int64(history.size)
        let finalResult = history[history.size - 1]

        var totalImprovement: Float64 = 0.0
        for (result in history) {
            totalImprovement += result.overallImprovementScore
        }
        totalImprovement /= Float64(totalIterations)

        let iterHistory = jsonArray()
        for (result in history) {
            iterHistory.add(jsonObj([
                ("iteration", JsonValue.JsonInt(result.iterationNumber)),
                ("improvement_score", JsonValue.JsonFloat(result.overallImprovementScore)),
                ("converged", JsonValue.JsonBool(result.converged)),
                ("timestamp", JsonValue.JsonString(result.timestamp))
            ]))
        }

        return jsonObj([
            ("total_iterations", JsonValue.JsonInt(totalIterations)),
            ("total_improvement_score", JsonValue.JsonFloat(totalImprovement)),
            ("converged", JsonValue.JsonBool(finalResult.converged)),
            ("final_status", JsonValue.JsonString(if (finalResult.converged) { "completed" } else { "in_progress" })),
            ("iteration_history", JsonValue.JsonArray(iterHistory)),
            ("reasoning", JsonValue.JsonString(finalResult.reasoning))
        ])
    }
}
