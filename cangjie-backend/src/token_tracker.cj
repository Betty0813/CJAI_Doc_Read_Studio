package ai_doc_read_studio

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import ai_doc_read_studio.utils.*

public class TokenTracker {
    var sessionTokens: HashMap<String, ArrayList<HashMap<String, JsonValue>>>
    var totalTokens: HashMap<String, HashMap<String, Int64>>
    let mu = Mutex()

    public init() {
        this.sessionTokens = HashMap<String, ArrayList<HashMap<String, JsonValue>>>()
        this.totalTokens = HashMap<String, HashMap<String, Int64>>()
    }

    public func estimateTokens(text: String): Int64 {
        let est = Int64(text.size) / 4
        return if (est > 0) { est } else { 1 }
    }

    public func trackAgentInvocation(
        sessionId: String,
        agentName: String,
        model: String,
        inputText: String,
        outputText: String,
        responseTime: Float64
    ): HashMap<String, JsonValue> {
        let inputTokens = estimateTokens(inputText)
        let outputTokens = estimateTokens(outputText)

        let record = HashMap<String, JsonValue>()
        record["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
        record["session_id"] = JsonValue.JsonString(sessionId)
        record["agent_name"] = JsonValue.JsonString(agentName)
        record["model"] = JsonValue.JsonString(model)
        record["input_tokens"] = JsonValue.JsonInt(inputTokens)
        record["output_tokens"] = JsonValue.JsonInt(outputTokens)
        record["total_tokens"] = JsonValue.JsonInt(inputTokens + outputTokens)
        record["response_time_seconds"] = JsonValue.JsonFloat(responseTime)

        synchronized(mu) {
            if (!sessionTokens.contains(sessionId)) {
                sessionTokens[sessionId] = ArrayList<HashMap<String, JsonValue>>()
            }
            match (sessionTokens.get(sessionId)) {
                case Some(list) => list.add(record)
                case None => ()
            }

            if (!totalTokens.contains(model)) {
                let m = HashMap<String, Int64>()
                m["input"] = 0
                m["output"] = 0
                totalTokens[model] = m
            }
            match (totalTokens.get(model)) {
                case Some(modelTokens) =>
                    modelTokens["input"] = (modelTokens.get("input") ?? 0) + inputTokens
                    modelTokens["output"] = (modelTokens.get("output") ?? 0) + outputTokens
                case None => ()
            }
        }

        logger.info("Tokens tracked", fields: [
            ("session_id", sessionId),
            ("agent", agentName),
            ("model", model),
            ("input_tokens", "${inputTokens}"),
            ("output_tokens", "${outputTokens}")
        ])

        return record
    }

    public func getSessionTokenSummary(sessionId: String): JsonValue {
        match (sessionTokens.get(sessionId)) {
            case None =>
                return jsonObj([
                    ("session_id", JsonValue.JsonString(sessionId)),
                    ("total_input_tokens", JsonValue.JsonInt(0)),
                    ("total_output_tokens", JsonValue.JsonInt(0)),
                    ("total_tokens", JsonValue.JsonInt(0)),
                    ("total_invocations", JsonValue.JsonInt(0)),
                    ("model_breakdown", jsonObj([])),
                    ("agent_breakdown", jsonObj([]))
                ])
            case Some(records) =>
                if (records.size == 0) {
                    return jsonObj([
                        ("session_id", JsonValue.JsonString(sessionId)),
                        ("total_input_tokens", JsonValue.JsonInt(0)),
                        ("total_output_tokens", JsonValue.JsonInt(0)),
                        ("total_tokens", JsonValue.JsonInt(0)),
                        ("total_invocations", JsonValue.JsonInt(0)),
                        ("model_breakdown", jsonObj([])),
                        ("agent_breakdown", jsonObj([]))
                    ])
                }

                var totalInput: Int64 = 0
                var totalOutput: Int64 = 0
                let modelBreakdown = HashMap<String, HashMap<String, Int64>>()
                let agentBreakdown = HashMap<String, HashMap<String, Int64>>()

                for (record in records) {
                    let inp = match (record.get("input_tokens")) {
                        case Some(v) => match (v.getInt()) { case Some(i) => i case None => 0 }
                        case None => 0
                    }
                    let outp = match (record.get("output_tokens")) {
                        case Some(v) => match (v.getInt()) { case Some(i) => i case None => 0 }
                        case None => 0
                    }
                    let mdl = match (record.get("model")) {
                        case Some(v) => match (v.getString()) { case Some(s) => s case None => "unknown" }
                        case None => "unknown"
                    }
                    let agent = match (record.get("agent_name")) {
                        case Some(v) => match (v.getString()) { case Some(s) => s case None => "unknown" }
                        case None => "unknown"
                    }

                    totalInput += inp
                    totalOutput += outp

                    updateBreakdown(modelBreakdown, mdl, inp, outp)
                    updateBreakdown(agentBreakdown, agent, inp, outp)
                }

                let recordsArr = jsonArray()
                for (r in records) {
                    recordsArr.add(JsonValue.JsonObject(r))
                }

                return jsonObj([
                    ("session_id", JsonValue.JsonString(sessionId)),
                    ("total_input_tokens", JsonValue.JsonInt(totalInput)),
                    ("total_output_tokens", JsonValue.JsonInt(totalOutput)),
                    ("total_tokens", JsonValue.JsonInt(totalInput + totalOutput)),
                    ("total_invocations", JsonValue.JsonInt(Int64(records.size))),
                    ("model_breakdown", breakdownToJson(modelBreakdown)),
                    ("agent_breakdown", breakdownToJson(agentBreakdown)),
                    ("records", JsonValue.JsonArray(recordsArr))
                ])
        }
    }

    public func getTotalTokenSummary(): JsonValue {
        var totalInput: Int64 = 0
        var totalOutput: Int64 = 0
        var totalSessions: Int64 = Int64(sessionTokens.size)
        var totalInvocations: Int64 = 0

        for ((_, records) in sessionTokens) {
            totalInvocations += Int64(records.size)
        }
        for ((_, tokens) in totalTokens) {
            totalInput += tokens.get("input") ?? 0
            totalOutput += tokens.get("output") ?? 0
        }

        let totalAll = totalInput + totalOutput
        let byModelObj = jsonObject()
        for ((model, tokens) in totalTokens) {
            let inp = tokens.get("input") ?? 0
            let outp = tokens.get("output") ?? 0
            byModelObj[model] = jsonObj([
                ("input_tokens", JsonValue.JsonInt(inp)),
                ("output_tokens", JsonValue.JsonInt(outp)),
                ("total_tokens", JsonValue.JsonInt(inp + outp))
            ])
        }

        return jsonObj([
            ("total_input_tokens", JsonValue.JsonInt(totalInput)),
            ("total_output_tokens", JsonValue.JsonInt(totalOutput)),
            ("total_tokens", JsonValue.JsonInt(totalAll)),
            ("total_sessions", JsonValue.JsonInt(totalSessions)),
            ("total_invocations", JsonValue.JsonInt(totalInvocations)),
            ("tokens_by_model", JsonValue.JsonObject(byModelObj)),
            ("average_tokens_per_session", JsonValue.JsonInt(if (totalSessions > 0) { totalAll / totalSessions } else { 0 })),
            ("average_tokens_per_invocation", JsonValue.JsonInt(if (totalInvocations > 0) { totalAll / totalInvocations } else { 0 }))
        ])
    }

    public func exportTokensToJson(filepath!: ?String = None): String {
        let now = DateTime.now()
        let path = filepath ?? "token_report_${now.toString()}.json"

        let exportData = jsonObj([
            ("export_timestamp", JsonValue.JsonString(now.toString())),
            ("summary", getTotalTokenSummary())
        ])

        let content = exportData.toJsonString()
        File.writeTo(path, content.toArray())
        logger.info("Token data exported", fields: [("filepath", path)])
        return path
    }
}

func updateBreakdown(breakdown: HashMap<String, HashMap<String, Int64>>, key: String, inp: Int64, outp: Int64): Unit {
    if (!breakdown.contains(key)) {
        let m = HashMap<String, Int64>()
        m["input_tokens"] = 0
        m["output_tokens"] = 0
        m["total_tokens"] = 0
        m["invocations"] = 0
        breakdown[key] = m
    }
    match (breakdown.get(key)) {
        case Some(m) =>
            m["input_tokens"] = (m.get("input_tokens") ?? 0) + inp
            m["output_tokens"] = (m.get("output_tokens") ?? 0) + outp
            m["total_tokens"] = (m.get("total_tokens") ?? 0) + inp + outp
            m["invocations"] = (m.get("invocations") ?? 0) + 1
        case None => ()
    }
}

func breakdownToJson(breakdown: HashMap<String, HashMap<String, Int64>>): JsonValue {
    let obj = jsonObject()
    for ((key, m) in breakdown) {
        obj[key] = jsonObj([
            ("input_tokens", JsonValue.JsonInt(m.get("input_tokens") ?? 0)),
            ("output_tokens", JsonValue.JsonInt(m.get("output_tokens") ?? 0)),
            ("total_tokens", JsonValue.JsonInt(m.get("total_tokens") ?? 0)),
            ("invocations", JsonValue.JsonInt(m.get("invocations") ?? 0))
        ])
    }
    return JsonValue.JsonObject(obj)
}

// Global instance
public let tokenTracker = TokenTracker()
