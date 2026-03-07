package ai_doc_read_studio

import std.collection.*
import std.time.*
import ai_doc_read_studio.utils.*

public class TeamMember {
    public var id: String
    public var name: String
    public var role: String
    public var model: String

    public init(id: String, name: String, role: String, model!: String = "gpt-4o-mini") {
        this.id = id
        this.name = name
        this.role = role
        this.model = model
    }

    public func toJson(): JsonValue {
        return jsonObj([
            ("id", JsonValue.JsonString(id)),
            ("name", JsonValue.JsonString(name)),
            ("role", JsonValue.JsonString(role)),
            ("model", JsonValue.JsonString(model))
        ])
    }

    public static func fromJson(json: JsonValue): ?TeamMember {
        let idVal = match (json["id"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        let nameVal = match (json["name"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        let roleVal = match (json["role"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        let modelVal = match (json["model"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "gpt-4o-mini" } case None => "gpt-4o-mini" }
        if (idVal.size == 0 || nameVal.size == 0 || roleVal.size == 0) {
            return None
        }
        return Some(TeamMember(idVal, nameVal, roleVal, model: modelVal))
    }
}

public class DocumentInfo {
    public var id: String
    public var filename: String
    public var path: String
    public var extension: String
    public var uploadedAt: String

    public init(id: String, filename: String, path: String, extension: String, uploadedAt: String) {
        this.id = id
        this.filename = filename
        this.path = path
        this.extension = extension
        this.uploadedAt = uploadedAt
    }

    public func toJson(): JsonValue {
        return jsonObj([
            ("id", JsonValue.JsonString(id)),
            ("filename", JsonValue.JsonString(filename)),
            ("path", JsonValue.JsonString(path)),
            ("extension", JsonValue.JsonString(extension)),
            ("uploaded_at", JsonValue.JsonString(uploadedAt))
        ])
    }
}

public class Session {
    public var sessionId: String
    public var documentIds: ArrayList<String>
    public var teamMembers: ArrayList<TeamMember>
    public var conversation: ArrayList<HashMap<String, JsonValue>>
    public var createdAt: String
    public var agentLoopReport: ?JsonValue

    public init(sessionId: String, documentIds: ArrayList<String>, teamMembers: ArrayList<TeamMember>) {
        this.sessionId = sessionId
        this.documentIds = documentIds
        this.teamMembers = teamMembers
        this.conversation = ArrayList<HashMap<String, JsonValue>>()
        this.createdAt = DateTime.now().toString()
        this.agentLoopReport = None
    }
}

public class CreateSessionRequest {
    public var documentIds: ArrayList<String>
    public var teamMembers: ArrayList<TeamMember>

    public init(documentIds: ArrayList<String>, teamMembers: ArrayList<TeamMember>) {
        this.documentIds = documentIds
        this.teamMembers = teamMembers
    }

    public static func fromJson(json: JsonValue): ?CreateSessionRequest {
        let docIdsArr: ?ArrayList<JsonValue> = match (json["document_ids"]) {
            case Some(jv) => jv.getArray()
            case None => None
        }
        let membersArr: ?ArrayList<JsonValue> = match (json["team_members"]) {
            case Some(jv) => jv.getArray()
            case None => None
        }

        let docIds = ArrayList<String>()
        match (docIdsArr) {
            case Some(arr) =>
                for (item in arr) {
                    match (item.getString()) {
                        case Some(s) => docIds.add(s)
                        case None => ()
                    }
                }
            case None => return None
        }

        let members = ArrayList<TeamMember>()
        match (membersArr) {
            case Some(arr) =>
                for (item in arr) {
                    match (TeamMember.fromJson(item)) {
                        case Some(m) => members.add(m)
                        case None => ()
                    }
                }
            case None => return None
        }

        if (docIds.size == 0 || members.size == 0) { return None }
        return Some(CreateSessionRequest(docIds, members))
    }
}

public class AddPromptRequest {
    public var prompt: String

    public init(prompt: String) {
        this.prompt = prompt
    }

    public static func fromJson(json: JsonValue): ?AddPromptRequest {
        let p = match (json["prompt"]) {
            case Some(jv) => match (jv.getString()) {
                case Some(s) => s
                case None => return None
            }
            case None => return None
        }
        if (p.size == 0 || p.size > 2000) { return None }
        return Some(AddPromptRequest(p))
    }
}

public class ActionableSummaryRequest {
    public var model: String

    public init(model!: String = "gpt-4o") {
        this.model = model
    }

    public static func fromJson(json: JsonValue): ActionableSummaryRequest {
        let m = match (json["model"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "gpt-4o" } case None => "gpt-4o" }
        return ActionableSummaryRequest(model: m)
    }
}

public class RunAgentLoopRequest {
    public var maxIterations: Int64

    public init(maxIterations!: Int64 = 3) {
        this.maxIterations = maxIterations
    }

    public static func fromJson(json: JsonValue): RunAgentLoopRequest {
        let m = match (json["max_iterations"]) { case Some(jv) => match (jv.getInt()) { case Some(i) => i case None => 3 } case None => 3 }
        return RunAgentLoopRequest(maxIterations: m)
    }
}

public class ExportRequest {
    public var format: String
    public var includeMetadata: Bool

    public init(format: String, includeMetadata!: Bool = true) {
        this.format = format
        this.includeMetadata = includeMetadata
    }

    public static func fromJson(json: JsonValue): ?ExportRequest {
        let fmt = match (json["format"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        if (fmt != "markdown" && fmt != "pdf") { return None }
        let meta = match (json["include_metadata"]) { case Some(jv) => match (jv.getBool()) { case Some(b) => b case None => true } case None => true }
        return Some(ExportRequest(fmt, includeMetadata: meta))
    }
}

public class ContentExportRequest {
    public var content: String
    public var format: String
    public var filename: String

    public init(content: String, format: String, filename: String) {
        this.content = content
        this.format = format
        this.filename = filename
    }

    public static func fromJson(json: JsonValue): ?ContentExportRequest {
        let c = match (json["content"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        let f = match (json["format"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        let n = match (json["filename"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
        if (c.size == 0 || (f != "markdown" && f != "pdf") || n.size == 0) { return None }
        return Some(ContentExportRequest(c, f, n))
    }
}

public class CreateTeamFromTemplateRequest {
    public var templateIds: ArrayList<String>
    public var documentIds: ArrayList<String>
    public var initialPrompt: String

    public init(templateIds: ArrayList<String>, documentIds: ArrayList<String>, initialPrompt: String) {
        this.templateIds = templateIds
        this.documentIds = documentIds
        this.initialPrompt = initialPrompt
    }

    public static func fromJson(json: JsonValue): ?CreateTeamFromTemplateRequest {
        let tIdsArr: ?ArrayList<JsonValue> = match (json["template_ids"]) {
            case Some(jv) => jv.getArray()
            case None => None
        }
        let dIdsArr: ?ArrayList<JsonValue> = match (json["document_ids"]) {
            case Some(jv) => jv.getArray()
            case None => None
        }
        let prompt: String = match (json["initial_prompt"]) {
            case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" }
            case None => ""
        }
        if (prompt.size == 0) { return None }

        let templateIds = ArrayList<String>()
        match (tIdsArr) {
            case Some(arr) =>
                for (item in arr) {
                    match (item.getString()) {
                        case Some(s) => templateIds.add(s)
                        case None => ()
                    }
                }
            case None => return None
        }
        let documentIds = ArrayList<String>()
        match (dIdsArr) {
            case Some(arr) =>
                for (item in arr) {
                    match (item.getString()) {
                        case Some(s) => documentIds.add(s)
                        case None => ()
                    }
                }
            case None => return None
        }
        if (templateIds.size == 0 || documentIds.size == 0) { return None }
        return Some(CreateTeamFromTemplateRequest(templateIds, documentIds, prompt))
    }
}

public class LogRequest {
    public var source: String
    public var logs: String

    public init(source: String, logs: String) {
        this.source = source
        this.logs = logs
    }

    public static func fromJson(json: JsonValue): ?LogRequest {
        let s = match (json["source"]) { case Some(jv) => match (jv.getString()) { case Some(ss) => ss case None => "" } case None => "" }
        let l = match (json["logs"]) { case Some(jv) => match (jv.getString()) { case Some(ss) => ss case None => "" } case None => "" }
        if (s.size == 0) { return None }
        return Some(LogRequest(s, l))
    }
}

// Helper to create messages
public func makeUserMessage(content: String): HashMap<String, JsonValue> {
    let msg = HashMap<String, JsonValue>()
    msg["type"] = JsonValue.JsonString("user")
    msg["content"] = JsonValue.JsonString(content)
    msg["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
    return msg
}

public func makeAgentMessage(
    agentId: String,
    agentName: String,
    role: String,
    model: String,
    content: String,
    responseTime!: Float64 = 0.0
): HashMap<String, JsonValue> {
    let msg = HashMap<String, JsonValue>()
    msg["type"] = JsonValue.JsonString("agent")
    msg["agent_id"] = JsonValue.JsonString(agentId)
    msg["agent_name"] = JsonValue.JsonString(agentName)
    msg["role"] = JsonValue.JsonString(role)
    msg["model"] = JsonValue.JsonString(model)
    msg["content"] = JsonValue.JsonString(content)
    msg["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
    msg["response_time_seconds"] = JsonValue.JsonFloat(responseTime)
    msg["response_length"] = JsonValue.JsonInt(Int64(content.size))
    return msg
}

public func conversationMessageToJson(msg: HashMap<String, JsonValue>): JsonValue {
    return JsonValue.JsonObject(msg)
}

public func conversationToJson(conv: ArrayList<HashMap<String, JsonValue>>): JsonValue {
    let arr = jsonArray()
    for (msg in conv) {
        arr.add(JsonValue.JsonObject(msg))
    }
    return JsonValue.JsonArray(arr)
}
