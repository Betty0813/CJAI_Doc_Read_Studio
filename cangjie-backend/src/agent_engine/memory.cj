package ai_doc_read_studio.agent_engine

import std.collection.*
import std.fs.*
import std.math.*
import std.regex.*
import std.sync.*
import std.time.*
import ai_doc_read_studio.utils.*

let MEMORY_DIR = "sessions"
let MEMORY_FILE = "agent_memory.json"

func tokenize(text: String): ArrayList<String> {
    let lowerText = toLowerAscii(text)
    let wordRegex = Regex("\\w+")
    let matcher = wordRegex.matcher(lowerText)
    let tokens = ArrayList<String>()
    while (true) {
        match (matcher.find()) {
            case Some(m) =>
                let pos = m.matchPosition()
                tokens.add(lowerText[pos.start..pos.end])
            case None => break
        }
    }
    return tokens
}

func tfVector(tokens: ArrayList<String>): HashMap<String, Float64> {
    let counts = HashMap<String, Int64>()
    for (t in tokens) {
        counts[t] = (counts.get(t) ?? 0) + 1
    }
    let total = max(1, Int64(tokens.size))
    let vec = HashMap<String, Float64>()
    for ((w, c) in counts) {
        vec[w] = Float64(c) / Float64(total)
    }
    return vec
}

func cosineSimilarity(a: HashMap<String, Float64>, b: HashMap<String, Float64>): Float64 {
    var dot: Float64 = 0.0
    var magA: Float64 = 0.0
    var magB: Float64 = 0.0

    for ((k, v) in a) {
        magA += v * v
        match (b.get(k)) {
            case Some(bv) => dot += v * bv
            case None => ()
        }
    }
    for ((_, v) in b) {
        magB += v * v
    }

    magA = sqrt(magA)
    magB = sqrt(magB)
    if (magA == 0.0 || magB == 0.0) { return 0.0 }
    return dot / (magA * magB)
}

public class AgentMemory {
    var storagePath: String
    public var entries: ArrayList<HashMap<String, JsonValue>>
    let mu = Mutex()

    public init(storageDir!: String = MEMORY_DIR, filename!: String = MEMORY_FILE) {
        this.storagePath = "${storageDir}/${filename}"
        this.entries = ArrayList<HashMap<String, JsonValue>>()
        try {
            if (!fileExists(storageDir)) {
                Directory.create(storageDir, recursive: true)
            }
        } catch (_: Exception) {}
        this.entries = load()
    }

    func load(): ArrayList<HashMap<String, JsonValue>> {
        if (!fileExists(storagePath)) {
            return ArrayList<HashMap<String, JsonValue>>()
        }
        try {
            let content = String.fromUtf8(File.readFrom(storagePath))
            let parsed = parseJson(content)
            match (parsed) {
                case Some(JsonValue.JsonArray(arr)) =>
                    let result = ArrayList<HashMap<String, JsonValue>>()
                    for (item in arr) {
                        match (item.getObject()) {
                            case Some(obj) => result.add(obj)
                            case None => ()
                        }
                    }
                    return result
                case _ => return ArrayList<HashMap<String, JsonValue>>()
            }
        } catch (_: Exception) {
            return ArrayList<HashMap<String, JsonValue>>()
        }
    }

    func save(): Unit {
        try {
            let arr = jsonArray()
            for (entry in entries) {
                arr.add(JsonValue.JsonObject(entry))
            }
            let content = JsonValue.JsonArray(arr).toJsonString()
            File.writeTo(storagePath, content.toArray())
        } catch (_: Exception) {}
    }

    public func store(
        content: String,
        category!: String = "general",
        metadata!: ?HashMap<String, JsonValue> = None,
        sessionId!: ?String = None
    ): Unit {
        let entry = HashMap<String, JsonValue>()
        entry["id"] = JsonValue.JsonString(generateUUID())
        entry["content"] = JsonValue.JsonString(content)
        entry["category"] = JsonValue.JsonString(category)
        match (metadata) {
            case Some(m) => entry["metadata"] = JsonValue.JsonObject(m)
            case None => entry["metadata"] = jsonObj([])
        }
        match (sessionId) {
            case Some(s) => entry["session_id"] = JsonValue.JsonString(s)
            case None => entry["session_id"] = JsonValue.JsonNull
        }
        entry["timestamp"] = JsonValue.JsonString(DateTime.now().toString())

        synchronized(mu) {
            entries.add(entry)
            if (entries.size > 500) {
                let trimmed = ArrayList<HashMap<String, JsonValue>>()
                let start = entries.size - 500
                for (i in start..entries.size) {
                    trimmed.add(entries[i])
                }
                entries = trimmed
            }
            save()
        }
    }

    public func retrieve(
        query: String,
        topK!: Int64 = 5,
        category!: ?String = None,
        minScore!: Float64 = 0.05
    ): ArrayList<(Float64, HashMap<String, JsonValue>)> {
        let queryVec = tfVector(tokenize(query))
        var scored = ArrayList<(Float64, HashMap<String, JsonValue>)>()

        for (entry in entries) {
            match (category) {
                case Some(cat) =>
                    let entryCat = entry.get("category").flatMap { v => v.getString() } ?? ""
                    if (entryCat != cat) { continue }
                case None => ()
            }
            let entryContent = entry.get("content").flatMap { v => v.getString() } ?? ""
            let entryVec = tfVector(tokenize(entryContent))
            let score = cosineSimilarity(queryVec, entryVec)
            if (score >= minScore) {
                scored.add((score, entry))
            }
        }

        let result = ArrayList<(Float64, HashMap<String, JsonValue>)>()
        var remaining = ArrayList<(Float64, HashMap<String, JsonValue>)>()
        for (p in scored) { remaining.add(p) }
        for (_ in 0..min(topK, Int64(scored.size))) {
            if (remaining.size == 0) { break }
            var bestIdx: Int64 = 0
            for (i in 1..remaining.size) {
                let (si, ei) = remaining[i]
                let (sb, eb) = remaining[bestIdx]
                if (si > sb) { bestIdx = i }
            }
            result.add(remaining[bestIdx])
            var next = ArrayList<(Float64, HashMap<String, JsonValue>)>()
            for (i in 0..remaining.size) {
                if (i != bestIdx) { next.add(remaining[i]) }
            }
            remaining = next
        }
        return result
    }

    public func storeImprovementResult(
        sessionId: String,
        actions: ArrayList<String>,
        metricsBefore: HashMap<String, Float64>,
        metricsAfter: HashMap<String, Float64>,
        reasoning: String
    ): Unit {
        let asSb = StringBuilder()
        for (a in actions) {
            if (asSb.size > 0) { asSb.append(", ") }
            asSb.append(a)
        }
        let actionsStr = asSb.toString()
        let content = "Actions: ${actionsStr}. Reasoning: ${reasoning}"
        let meta = HashMap<String, JsonValue>()
        let actionsArr = jsonArray()
        for (a in actions) { actionsArr.add(JsonValue.JsonString(a)) }
        meta["actions"] = JsonValue.JsonArray(actionsArr)
        store(content, category: "improvement", metadata: meta, sessionId: sessionId)
    }

    public func storeLesson(lesson: String, sessionId!: ?String = None): Unit {
        store(lesson, category: "lesson", sessionId: sessionId)
    }

    public func getRelevantStrategies(documentExcerpt: String, topK!: Int64 = 3): String {
        let results = retrieve(documentExcerpt, topK: topK, category: "improvement")
        if (results.size == 0) { return "" }
        let sb = StringBuilder()
        sb.append("Past improvement strategies that worked:\n")
        for ((_, entry) in results) {
            let content = entry.get("content").flatMap { v => v.getString() } ?? ""
            let truncated = if (content.size > 200) { content[..200] } else { content }
            sb.append("- ${truncated}\n")
        }
        return sb.toString()
    }

    public func getLessons(topK!: Int64 = 5): ArrayList<String> {
        let lessons = ArrayList<String>()
        // 倒序取最近的 lesson
        var count: Int64 = 0
        var i = entries.size - 1
        while (i >= 0 && count < topK) {
            let cat = entries[i].get("category").flatMap { v => v.getString() } ?? ""
            if (cat == "lesson") {
                let content = entries[i].get("content").flatMap { v => v.getString() } ?? ""
                lessons.add(content)
                count += 1
            }
            i -= 1
        }
        return lessons
    }

    public func getStats(): JsonValue {
        let cats = HashMap<String, Int64>()
        for (entry in entries) {
            let cat = entry.get("category").flatMap { v => v.getString() } ?? "general"
            cats[cat] = (cats.get(cat) ?? 0) + 1
        }
        let catsObj = jsonObject()
        for ((k, v) in cats) {
            catsObj[k] = JsonValue.JsonInt(v)
        }
        return jsonObj([
            ("total_entries", JsonValue.JsonInt(Int64(entries.size))),
            ("categories", JsonValue.JsonObject(catsObj)),
            ("storage_path", JsonValue.JsonString(storagePath))
        ])
    }
}

// 全局实例
public let agentMemory = AgentMemory()
