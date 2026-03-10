package ai_doc_read_studio

import stdx.net.http.*
import std.time.*
import std.sync.*
import std.fs.*
import std.io.*
import std.collection.*
import std.convert.*
import std.regex.*
import ai_doc_read_studio.utils.*
import ai_doc_read_studio.tools.*
import ai_doc_read_studio.agent_engine.*

// ========== global state ==========
let sessions = HashMap<String, Session>()
let documents = HashMap<String, DocumentInfo>()
var currentAgentLoopSessionId: ?String = None
let globalMu = Mutex()
let APP_START_TIME = DateTime.now().toString()
let MAX_FILE_SIZE: Int64 = 10 * 1024 * 1024
let UPLOAD_DIR = "uploads"
let SESSIONS_DIR = "sessions"
let FRONTEND_DIR = "../frontend"

// ========== WebSocket Types ==========
class ConnectionManager {
    var globalConnections: ArrayList<WebSocket>
    var sessionConnections: HashMap<String, ArrayList<WebSocket>>
    let mu = Mutex()

    init() {
        this.globalConnections = ArrayList<WebSocket>()
        this.sessionConnections = HashMap<String, ArrayList<WebSocket>>()
    }

    func addConnection(ws: WebSocket, sessionId!: ?String = None): Unit {
        synchronized(mu) {
            globalConnections.add(ws)
            match (sessionId) {
                case Some(sid) =>
                    if (!sessionConnections.contains(sid)) {
                        sessionConnections[sid] = ArrayList<WebSocket>()
                    }
                    sessionConnections[sid].add(ws)
                case None => ()
            }
        }
    }

    func removeConnection(ws: WebSocket, sessionId!: ?String = None): Unit {
        synchronized(mu) {
            let filtered = ArrayList<WebSocket>()
            for (c in globalConnections) { if (!refEq(c, ws)) { filtered.add(c) } }
            globalConnections = filtered
            match (sessionId) {
                case Some(sid) =>
                    match (sessionConnections.get(sid)) {
                        case Some(conns) =>
                            let filt = ArrayList<WebSocket>()
                            for (c in conns) { if (!refEq(c, ws)) { filt.add(c) } }
                            sessionConnections[sid] = filt
                        case None => ()
                    }
                case None => ()
            }
        }
    }

    func broadcastToSession(message: String, sessionId: String): Unit {
        synchronized(mu) {
            match (sessionConnections.get(sessionId)) {
                case Some(conns) =>
                    for (ws in conns) {
                        let data = message.toArray()
                        try { ws.write(TextWebFrame, message.toArray()) } catch (_: Exception) {}
                    }
                case None => ()
            }
        }
    }

    func sendPersonal(message: String, ws: WebSocket): Unit {
        try { ws.write(TextWebFrame, message.toArray()) } catch (_: Exception) {}
    }
}

let wsManager = ConnectionManager()

// ========== CORS ?? ==========
func addCorsHeaders(ctx: HttpContext): Unit {
    ctx.responseBuilder
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type, Authorization, Cache-Control, Pragma, X-Requested-With")
        .header("Access-Control-Allow-Credentials", "true")
        .header("Cache-Control", "no-cache, no-store, must-revalidate")
        .header("Pragma", "no-cache")
        .header("Expires", "0")
}

func handleCorsOptions(ctx: HttpContext): Unit {
    addCorsHeaders(ctx)
    ctx.responseBuilder.status(204)
}

func readRequestBody(ctx: HttpContext): String {
    let bytes = readRequestBodyBytes(ctx)
    return safeDecodeBytes(bytes)
}

func readRequestBodyBytes(ctx: HttpContext): Array<Byte> {
    let chunks = ArrayList<Array<Byte>>()
    let buf = Array<Byte>(65536, repeat: 0)
    var totalSize: Int64 = 0
    while (true) {
        let n = ctx.request.body.read(buf)
        if (n <= 0) { break }
        let chunk = Array<Byte>(n, repeat: 0)
        for (i in 0..n) { chunk[i] = buf[i] }
        chunks.add(chunk)
        totalSize += Int64(n)
    }
    let result = Array<Byte>(Int64(totalSize), repeat: 0)
    var offset: Int64 = 0
    for (chunk in chunks) {
        for (i in 0..chunk.size) {
            result[offset] = chunk[i]
            offset += 1
        }
    }
    return result
}

func parseMultipartFormData(contentType: String, body: Array<Byte>): (String, Array<Byte>) {
    // Parse Content-Type for boundary
    var boundary = ""
    let parts = contentType.split("boundary=")
    if (parts.size >= 2) {
        boundary = parts[1].trimAscii()
        if (boundary.startsWith("\"") && boundary.endsWith("\"")) {
            boundary = boundary[1..boundary.size - 1]
        }
    }
    if (boundary.size == 0) {
        return ("upload.txt", body)
    }

    let bodyStr = safeDecodeBytes(body)
    let delimiter = "--${boundary}"
    let sections = bodyStr.split(delimiter)

    var filename = "upload.txt"
    var fileStartOffset: Int64 = -1
    var fileEndOffset: Int64 = -1

    for (section in sections) {
        if (section.contains("Content-Disposition") && section.contains("filename=")) {
            // Parse filename
            match (section.indexOf("filename=\"")) {
                case Some(fnIdx) =>
                    let start = fnIdx + 10
                    match (section.indexOf("\"", start)) {
                        case Some(endIdx) =>
                            if (endIdx > start) {
                                filename = section[start..endIdx]
                            }
                        case None => ()
                    }
                case None => ()
            }

            match (section.indexOf("\r\n\r\n")) {
                case Some(headerEnd) =>
                    let contentStart = headerEnd + 4
                var content = section[contentStart..]
                // Trim trailing newline
                if (content.endsWith("\r\n")) {
                    content = content[..content.size - 2]
                }
                return (filename, content.toArray())
                case None => ()
            }

            match (section.indexOf("\n\n")) {
                case Some(headerEnd2) =>
                    let contentStart = headerEnd2 + 2
                var content = section[contentStart..]
                if (content.endsWith("\n")) {
                    content = content[..content.size - 1]
                }
                return (filename, content.toArray())
                case None => ()
            }
        }
    }

    return (filename, body)
}

func jsonResponse(ctx: HttpContext, json: JsonValue, status!: UInt16 = 200): Unit {
    addCorsHeaders(ctx)
    ctx.responseBuilder
        .status(status)
        .header("Content-Type", "application/json")
        .body(json.toJsonString())
}

func errorResponse(ctx: HttpContext, detail: String, status!: UInt16 = 400): Unit {
    let err = jsonObj([("detail", JsonValue.JsonString(detail))])
    jsonResponse(ctx, err, status: status)
}

func serveStaticTextFile(ctx: HttpContext, filePath: String, contentType: String): Unit {
    addCorsHeaders(ctx)
    try {
        let bytes = File.readFrom(filePath)
        let body = safeDecodeBytes(bytes)
        ctx.responseBuilder
            .status(200)
            .header("Content-Type", contentType)
            .header("Cache-Control", "no-cache, no-store, must-revalidate")
            .header("Pragma", "no-cache")
            .header("Expires", "0")
            .body(body)
    } catch (_: Exception) {
        addCorsHeaders(ctx)
        ctx.responseBuilder
            .status(404)
            .header("Content-Type", "text/plain; charset=utf-8")
            .body("Not Found")
    }
}

func getFirstHeaderValue(ctx: HttpContext, name: String): String {
    let values = ctx.request.headers.get(name)
    for (v in values) { return v }
    return ""
}

func wantsHtml(ctx: HttpContext): Bool {
    let accept = getFirstHeaderValue(ctx, "Accept")
    return accept.contains("text/html")
}

func jStr(m: HashMap<String, JsonValue>, key: String): String {
    match (m.get(key)) {
        case Some(v) => v.getString() ?? ""
        case None => ""
    }
}

func jBool(m: HashMap<String, JsonValue>, key: String): Bool {
    match (m.get(key)) {
        case Some(v) => v.getBool() ?? false
        case None => false
    }
}

// Send a single streaming chunk (used when LLM streams in real time).
func sendAgentChunk(
    ws: ConnectionManager, sessionId: String,
    agentName: String, role: String, model: String, ts: String, delta: String,
    isDebate: Bool
): Unit {
    if (delta.size == 0) { return }
    let msg = jsonObj([
        ("type", JsonValue.JsonString("agent_response_chunk")),
        ("data", jsonObj([
            ("agent_name", JsonValue.JsonString(agentName)),
            ("role", JsonValue.JsonString(role)),
            ("model", JsonValue.JsonString(model)),
            ("timestamp", JsonValue.JsonString(ts)),
            ("delta", JsonValue.JsonString(delta)),
            ("is_debate", JsonValue.JsonBool(isDebate))
        ]))
    ])
    ws.broadcastToSession(msg.toJsonString(), sessionId)
}

// Send done + finished only (after real-time streaming; no content re-send).
func finishAgentResponse(ws: ConnectionManager, sessionId: String, response: HashMap<String, JsonValue>): Unit {
    let agentName = jStr(response, "agent_name")
    let ts = jStr(response, "timestamp")
    let isDebate = jBool(response, "is_debate")
    let doneMsg = jsonObj([
        ("type", JsonValue.JsonString("agent_response_done")),
        ("data", jsonObj([
            ("agent_name", JsonValue.JsonString(agentName)),
            ("timestamp", JsonValue.JsonString(ts)),
            ("is_debate", JsonValue.JsonBool(isDebate))
        ]))
    ])
    ws.broadcastToSession(doneMsg.toJsonString(), sessionId)
    let finished = jsonObj([
        ("type", JsonValue.JsonString("agent_finished")),
        ("data", jsonObj([("agent_name", JsonValue.JsonString(agentName))]))
    ])
    ws.broadcastToSession(finished.toJsonString(), sessionId)
}

func streamAgentResponse(ws: ConnectionManager, sessionId: String, response: HashMap<String, JsonValue>): Unit {
    let agentName = jStr(response, "agent_name")
    let role = jStr(response, "role")
    let model = jStr(response, "model")
    let ts = jStr(response, "timestamp")
    let content = jStr(response, "content")
    let isDebate = jBool(response, "is_debate")

    // Fallback: when not using LLM stream, send content line-by-line for progressive display
    let text = content.replace("\r\n", "\n")
    let lines = text.split("\n")
    for (line in lines) {
        let delta = line + "\n"
        if (delta.trimAscii().size == 0) { continue }
        sendAgentChunk(ws, sessionId, agentName, role, model, ts, delta, isDebate)
        sleep(Duration.millisecond * 30)
    }
    finishAgentResponse(ws, sessionId, response)
}

// ========== Route Handlers ==========
// (see code)

// ========== Markdown Helpers ==========
func generateMarkdownExport(session: Session, includeMetadata: Bool): String {
    let sb = StringBuilder()
    sb.append("# AI Document Review Session\n\n")

    if (includeMetadata) {
        sb.append("## Session Information\n\n")
        sb.append("**Session ID:** ${session.sessionId}\n")
        sb.append("**Created:** ${session.createdAt}\n")
        sb.append("**Documents:** ${session.documentIds.size}\n")
        sb.append("**Team Members:** ${session.teamMembers.size}\n\n")

        sb.append("### Documents\n\n")
        var i: Int64 = 1
        for (docId in session.documentIds) {
            let doc = documents.get(docId)
            let filename = match (doc) { case Some(d) => d.filename; case None => "Unknown" }
            sb.append("${i}. ${filename}\n")
            i += 1
        }
        sb.append("\n")

        sb.append("### Team Members\n\n")
        i = 1
        for (member in session.teamMembers) {
            sb.append("${i}. **${member.name}** - ${member.role} (Model: ${member.model})\n")
            i += 1
        }
        sb.append("\n---\n\n")
    }

    sb.append("## Conversation\n\n")
    for (msg in session.conversation) {
        let msgType = msg.get("type").flatMap { v => v.getString() } ?? ""
        let content = msg.get("content").flatMap { v => v.getString() } ?? ""
        let timestamp = msg.get("timestamp").flatMap { v => v.getString() } ?? ""

        if (msgType == "user") {
            sb.append("### User (${timestamp})\n\n${content}\n\n")
        } else if (msgType == "agent") {
            let agentName = msg.get("agent_name").flatMap { v => v.getString() } ?? "Agent"
            let role = msg.get("role").flatMap { v => v.getString() } ?? ""
            let model = msg.get("model").flatMap { v => v.getString() } ?? ""
            sb.append("### ${agentName} - ${role} (${model}) (${timestamp})\n\n${content}\n\n")
            if (includeMetadata) {
                let respTime = msg.get("response_time_seconds").flatMap { v => v.getFloat() }
                match (respTime) {
                    case Some(t) => sb.append("*Response time: ${t}s*\n\n")
                    case None => ()
                }
            }
        }
    }

    if (includeMetadata) {
        sb.append("---\n\n*Exported on ${DateTime.now().toString()}*\n")
    }

    return sb.toString()
}

func buildFeedbackFromConversation(conversation: ArrayList<HashMap<String, JsonValue>>): HashMap<String, JsonValue> {
    let recommendations = ArrayList<String>()
    let recRegex = Regex("^\\s*(?:\\d+[.)\\s]*|\\*+\\s*|-+\\s*)\\s*(.+)", RegexOption().multiLine())

    for (msg in conversation) {
        let msgType = match (msg.get("type")) { case Some(v) => match (v.getString()) { case Some(s) => s case None => "" } case None => "" }
        if (msgType != "agent") { continue }
        let content = match (msg.get("content")) { case Some(v) => match (v.getString()) { case Some(s) => s case None => "" } case None => "" }
        let matcher = recRegex.matcher(content)
        while (true) {
            match (matcher.find()) {
                case Some(m) =>
                    let pos = m.matchPosition()
                    let rec = content[pos.start..pos.end].trimAscii()
                    if (rec.size > 10 && !recommendations.contains(rec)) {
                        recommendations.add(rec)
                    }
                case None => break
            }
        }
    }

    if (recommendations.size == 0) {
        var count: Int64 = 0
        var i = conversation.size - 1
        while (i >= 0 && count < 5) {
            let msgType = conversation[i].get("type").flatMap { v => v.getString() } ?? ""
            if (msgType == "agent") {
                let content = conversation[i].get("content").flatMap { v => v.getString() } ?? ""
                let firstLine = content.split("\n")[0].trimAscii()
                if (firstLine.size > 15 && !recommendations.contains(firstLine)) {
                    recommendations.add(firstLine)
                    count += 1
                }
            }
            i -= 1
        }
    }

    let limited = ArrayList<String>()
    for (i in 0..min(25, recommendations.size)) {
        limited.add(recommendations[i])
    }

    let result = HashMap<String, JsonValue>()
    let recsArr = jsonArray()
    for (r in limited) { recsArr.add(JsonValue.JsonString(r)) }
    result["synthesized_recommendations"] = JsonValue.JsonArray(recsArr)
    result["source"] = JsonValue.JsonString("conversation")
    return result
}

// ========== Custom distributor: prefix match for /sessions so /sessions/xxx/prompt is handled ==========
class SessionsPrefixDistributor <: HttpRequestDistributor {
    let map = HashMap<String, HttpRequestHandler>()
    public func register(path: String, handler: HttpRequestHandler): Unit {
        map[path] = handler
    }
    public func distribute(path: String): HttpRequestHandler {
        if (path == "/sessions" || (path.size >= 10 && path[0..10] == "/sessions/")) {
            match (map.get("/sessions")) {
                case Some(h) => return h
                case None => ()
            }
        }
        match (map.get(path)) {
            case Some(h) => return h
            case None => return NotFoundCorsHandler()
        }
    }
}

class NotFoundCorsHandler <: HttpRequestHandler {
    public func handle(ctx: HttpContext): Unit {
        addCorsHeaders(ctx)
        ctx.responseBuilder.status(404).header("Content-Type", "application/json").body("{\"detail\":\"Not Found\"}")
    }
}

// ========== main entry ==========
main() {
    // Read config: try cwd .env then project root ../.env
    loadDotEnv(path: ".env")
    loadDotEnv(path: "../.env")
    // 重新初始化 LLM 客户端（全局 agentLoopManager 在 .env 加载前已构造，须重新读取 API Key）
    agentLoopManager.reinitClient()

    // Load templates
    try {
        if (!fileExists(UPLOAD_DIR)) { Directory.create(UPLOAD_DIR, recursive: true) }
        if (!fileExists(SESSIONS_DIR)) { Directory.create(SESSIONS_DIR, recursive: true) }
    } catch (_: Exception) {}

    let config = loadConfigJson("config.json")
    var host = "0.0.0.0"
    var port: Int64 = 8000
    match (config) {
        case Some(cfg) => match (cfg["backend"]) {
            case Some(backend) =>
                match (backend["host"]) { case Some(h) => match (h.getString()) { case Some(s) => host = s case None => () } case None => () }
                match (backend["port"]) { case Some(p) => match (p.getInt()) { case Some(i) => port = i case None => () } case None => () }
            case None => ()
        }
        case None => ()
    }

    logger.info("Starting AI Doc Read Studio Backend (Cangjie)", fields: [
        ("host", host), ("port", "${port}")
    ])

    let dist = SessionsPrefixDistributor()
    let server = ServerBuilder()
        .addr(host)
        .port(UInt16(port))
        .distributor(dist)
        .build()

    // ========== Routes ==========

    // GET /
    server.distributor.register("/", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        if (ctx.request.method == "GET" && wantsHtml(ctx)) {
            serveStaticTextFile(ctx, "${FRONTEND_DIR}/index.html", "text/html; charset=utf-8")
        } else {
            jsonResponse(ctx, jsonObj([("message", JsonValue.JsonString("AI Doc Read Studio API"))]))
        }
    })

    // Frontend static assets (served by backend so no separate frontend server is required)
    server.distributor.register("/app.js", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        serveStaticTextFile(ctx, "${FRONTEND_DIR}/app.js", "application/javascript; charset=utf-8")
    })
    server.distributor.register("/config.js", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        serveStaticTextFile(ctx, "${FRONTEND_DIR}/config.js", "application/javascript; charset=utf-8")
    })
    server.distributor.register("/index.html", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        serveStaticTextFile(ctx, "${FRONTEND_DIR}/index.html", "text/html; charset=utf-8")
    })

    // GET /version
    server.distributor.register("/version", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        jsonResponse(ctx, jsonObj([
            ("version", JsonValue.JsonString("1.0.0")),
            ("timestamp", JsonValue.JsonString(DateTime.now().toString())),
            ("cache_buster", JsonValue.JsonString("v${APP_START_TIME}"))
        ]))
    })

    // POST /upload (multipart/form-data)
    server.distributor.register("/upload", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        try {
            let rawBody = readRequestBodyBytes(ctx)
            let fileSize = Int64(rawBody.size)

            if (fileSize > MAX_FILE_SIZE) {
                errorResponse(ctx, "File too large. Maximum size is 10MB", status: 413)
                return
            }
            if (fileSize == 0) {
                errorResponse(ctx, "File is empty", status: 400)
                return
            }

            var contentType = ""
            let ctValues = ctx.request.headers.get("Content-Type")
            for (v in ctValues) { contentType = v; break }
            if (contentType.size == 0) {
                let ctValues2 = ctx.request.headers.get("content-type")
                for (v in ctValues2) { contentType = v; break }
            }
            var filename = "upload.txt"
            var fileContent = rawBody

            if (contentType.contains("multipart/form-data")) {
                let (parsedName, parsedContent) = parseMultipartFormData(contentType, rawBody)
                filename = parsedName
                fileContent = parsedContent
            } else {
                let xfnValues = ctx.request.headers.get("X-Filename")
                for (v in xfnValues) { if (v.size > 0) { filename = v }; break }
            }

            let ext = toLowerAscii(getFileExtension(filename))
            if (ext != ".txt" && ext != ".md" && ext != ".docx" && ext != ".pdf") {
                errorResponse(ctx, "Unsupported file type", status: 400)
                return
            }

            if (Int64(fileContent.size) == 0) {
                errorResponse(ctx, "File is empty", status: 400)
                return
            }

            let documentId = generateUUID()
            let filePath = "${UPLOAD_DIR}/${documentId}${ext}"
            File.writeTo(filePath, fileContent)

            let docInfo = DocumentInfo(documentId, filename, filePath, ext, DateTime.now().toString())
            synchronized(globalMu) { documents[documentId] = docInfo }

            logger.info("Document uploaded", fields: [("filename", filename), ("id", documentId)])
            jsonResponse(ctx, jsonObj([
                ("document_id", JsonValue.JsonString(documentId)),
                ("filename", JsonValue.JsonString(filename))
            ]))
        } catch (e: Exception) {
            errorResponse(ctx, e.toString(), status: 500)
        }
    })

    // POST /sessions handler
    // (see code)
    // (see code)
    // (see code)

    server.distributor.register("/sessions", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        let path = ctx.request.url.path
        let rawParts = path.split("/")
        let parts = ArrayList<String>()
        for (p in rawParts) { if (p.size > 0) { parts.add(p) } }

        if (parts.size == 1) {
             // POST /sessions handler
            handleCreateSession(ctx)
            return
        }

        if (parts.size >= 2 && parts[1] == "from-template") {
            handleCreateFromTemplate(ctx)
            return
        }

        let sessionId = parts[1]

        if (parts.size == 2) {
            handleGetSession(ctx, sessionId)
        } else if (parts.size == 3) {
            match (parts[2]) {
                case "prompt" => handlePrompt(ctx, sessionId)
                case "regenerate" => handleRegenerate(ctx, sessionId)
                case "revert" => handleRevert(ctx, sessionId)
                case "actionable-summary" => handleActionableSummary(ctx, sessionId)
                case "run-agent-loop" => handleRunAgentLoop(ctx, sessionId)
                case "agent-status" => handleAgentStatus(ctx, sessionId)
                case "improved-document" => handleImprovedDocument(ctx, sessionId)
                case "export" => handleExport(ctx, sessionId)
                case "tokens" => handleSessionTokens(ctx, sessionId)
                case "stream" => handleStream(ctx, sessionId)
                case _ => errorResponse(ctx, "Unknown endpoint", status: 404)
            }
        } else {
            errorResponse(ctx, "Unknown endpoint", status: 404)
        }
    })
    // Agent templates API
    server.distributor.register("/agent-templates", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        handleAgentTemplates(ctx)
    })

    server.distributor.register("/agent-memory", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        handleAgentMemoryStats(ctx)
    })

    server.distributor.register("/agent-memory/search", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        handleAgentMemorySearch(ctx)
    })

    server.distributor.register("/tokens/summary", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        jsonResponse(ctx, tokenTracker.getTotalTokenSummary())
    })

    server.distributor.register("/tokens/export", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        try {
            let filepath = tokenTracker.exportTokensToJson()
            jsonResponse(ctx, jsonObj([
                ("message", JsonValue.JsonString("Token data exported successfully")),
                ("filepath", JsonValue.JsonString(filepath)),
                ("timestamp", JsonValue.JsonString(DateTime.now().toString()))
            ]))
        } catch (e: Exception) {
            errorResponse(ctx, e.toString(), status: 500)
        }
    })

    server.distributor.register("/logs", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        try {
            let body = readRequestBody(ctx)
            let json = parseJson(body)
            match (json) {
                case Some(j) =>
                    match (LogRequest.fromJson(j)) {
                        case Some(req) =>
                            let logFile = "logs/${req.source}.log"
                            try {
                                if (!fileExists("logs")) { Directory.create("logs", recursive: true) }
                            } catch (_: Exception) {}
                            try {
                                let lineBytes = req.logs.toArray()
                                var existing: Array<Byte> = []
                                try { existing = File.readFrom(logFile) } catch (_: Exception) { }
                                var out = ArrayList<Byte>()
                                for (b in existing) { out.add(b) }
                                for (b in lineBytes) { out.add(b) }
                                File.writeTo(logFile, collectArray(out))
                            } catch (_: Exception) {}
                            jsonResponse(ctx, jsonObj([("status", JsonValue.JsonString("success"))]))
                        case None => errorResponse(ctx, "Invalid request")
                    }
                case None => errorResponse(ctx, "Invalid JSON")
            }
        } catch (e: Exception) {
            jsonResponse(ctx, jsonObj([
                ("status", JsonValue.JsonString("error")),
                ("message", JsonValue.JsonString(e.toString()))
            ]))
        }
    })

    server.distributor.register("/export/content", { ctx =>
        if (ctx.request.method == "OPTIONS") { handleCorsOptions(ctx); return }
        handleContentExport(ctx)
    })

    // WebSocket handler
    server.distributor.register("/ws", { ctx =>
        let path = ctx.request.url.path
        let wsParts = ArrayList<String>()
        for (p in path.split("/")) { if (p.size > 0) { wsParts.add(p) } }
        if (wsParts.size >= 2) {
            handleWebSocket(ctx, Some(wsParts[1]))
        } else {
            handleWebSocket(ctx, None)
        }
    })

    logger.info("Server starting on ${host}:${port}")
    server.serve()
}

// ========== Helper Functions ==========

func handleCreateSession(ctx: HttpContext): Unit {
    try {
        let body = readRequestBody(ctx)
        let json = parseJson(body)
        match (json) {
            case Some(j) =>
                match (CreateSessionRequest.fromJson(j)) {
                    case Some(req) =>
                        for (docId in req.documentIds) {
                            if (!documents.contains(docId)) {
                                errorResponse(ctx, "Document not found: ${docId}", status: 404)
                                return
                            }
                        }

                        let sessionId = generateUUID()
                        let session = Session(sessionId, req.documentIds, req.teamMembers)
                        synchronized(globalMu) { sessions[sessionId] = session }

                        let filenames = jsonArray()
                        for (docId in req.documentIds) {
                            match (documents.get(docId)) {
                                case Some(d) => filenames.add(JsonValue.JsonString(d.filename))
                                case None => ()
                            }
                        }

                        jsonResponse(ctx, jsonObj([
                            ("session_id", JsonValue.JsonString(sessionId)),
                            ("document_filenames", JsonValue.JsonArray(filenames)),
                            ("conversation", JsonValue.JsonArray(jsonArray()))
                        ]))
                    case None =>
                        errorResponse(ctx, "Invalid request body")
                }
            case None => errorResponse(ctx, "Invalid JSON")
        }
    } catch (e: Exception) {
        errorResponse(ctx, e.toString(), status: 500)
    }
}

func handleGetSession(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            let filenames = jsonArray()
            for (docId in session.documentIds) {
                match (documents.get(docId)) {
                    case Some(d) => filenames.add(JsonValue.JsonString(d.filename))
                    case None => filenames.add(JsonValue.JsonString("Unknown"))
                }
            }
            let membersArr = jsonArray()
            for (m in session.teamMembers) { membersArr.add(m.toJson()) }

            jsonResponse(ctx, jsonObj([
                ("session_id", JsonValue.JsonString(session.sessionId)),
                ("document_ids", jsonArr(session.documentIds.toArray().map { d => JsonValue.JsonString(d) })),
                ("document_filenames", JsonValue.JsonArray(filenames)),
                ("team_members", JsonValue.JsonArray(membersArr)),
                ("conversation", conversationToJson(session.conversation)),
                ("created_at", JsonValue.JsonString(session.createdAt)),
                ("has_agent_loop_report", JsonValue.JsonBool(match (session.agentLoopReport) { case Some(_) => true case None => false }))
            ]))
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handlePrompt(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            let body = readRequestBody(ctx)
            let json = parseJson(body)
            match (json.flatMap { j => AddPromptRequest.fromJson(j) }) {
                case Some(req) =>
                    session.conversation.add(makeUserMessage(req.prompt))

                    let sessionDocs = ArrayList<DocumentInfo>()
                    for (docId in session.documentIds) {
                        match (documents.get(docId)) {
                            case Some(d) => sessionDocs.add(d)
                            case None => ()
                        }
                    }

                    let onStart = { agentName: String =>
                        let msg = jsonObj([
                            ("type", JsonValue.JsonString("agent_thinking")),
                            ("data", jsonObj([("agent_name", JsonValue.JsonString(agentName))]))
                        ])
                        wsManager.broadcastToSession(msg.toJsonString(), sessionId)
                    }

                    let onChunk = { agentName: String, role: String, model: String, ts: String, delta: String =>
                        sendAgentChunk(wsManager, sessionId, agentName, role, model, ts, delta, false)
                    }

                    let onResponse = { response: HashMap<String, JsonValue> =>
                        session.conversation.add(response)
                        finishAgentResponse(wsManager, sessionId, response)
                    }

                    let responses = runDiscussionRound(
                        session, sessionDocs, req.prompt,
                        onAgentStart: onStart, onAgentResponse: onResponse, onChunk: onChunk
                    )

                    jsonResponse(ctx, jsonObj([("conversation", conversationToJson(session.conversation))]))
                case None =>
                    errorResponse(ctx, "Invalid prompt request")
            }
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleRegenerate(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            var lastUserIndex: Int64 = -1
            var i = session.conversation.size - 1
            while (i >= 0) {
                let msgType = session.conversation[i].get("type").flatMap { v => v.getString() } ?? ""
                if (msgType == "user") { lastUserIndex = i; break }
                i -= 1
            }

            if (lastUserIndex == -1) {
                errorResponse(ctx, "No user messages found", status: 400)
                return
            }

            let lastPrompt = session.conversation[lastUserIndex].get("content").flatMap { v => v.getString() } ?? ""
            let trimmed = ArrayList<HashMap<String, JsonValue>>()
            for (j in 0..lastUserIndex + 1) {
                trimmed.add(session.conversation[j])
            }
            session.conversation = trimmed

            let sessionDocs = ArrayList<DocumentInfo>()
            for (docId in session.documentIds) {
                match (documents.get(docId)) {
                    case Some(d) => sessionDocs.add(d)
                    case None => ()
                }
            }

            let responses = runDiscussionRound(session, sessionDocs, lastPrompt)
            for (r in responses) { session.conversation.add(r) }

            jsonResponse(ctx, jsonObj([("conversation", conversationToJson(session.conversation))]))
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleRevert(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            if (session.conversation.size <= 1) {
                errorResponse(ctx, "Cannot revert - conversation is too short", status: 400)
                return
            }

            var lastUserIndex: Int64 = -1
            var i = session.conversation.size - 1
            while (i >= 0) {
                let msgType = session.conversation[i].get("type").flatMap { v => v.getString() } ?? ""
                if (msgType == "user") { lastUserIndex = i; break }
                i -= 1
            }

            if (lastUserIndex == -1) {
                errorResponse(ctx, "No user messages found", status: 400)
                return
            }

            let trimmed = ArrayList<HashMap<String, JsonValue>>()
            for (j in 0..lastUserIndex) {
                trimmed.add(session.conversation[j])
            }
            session.conversation = trimmed

            jsonResponse(ctx, jsonObj([("conversation", conversationToJson(session.conversation))]))
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleActionableSummary(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            let body = readRequestBody(ctx)
            let json = parseJson(body)
            let req = match (json) {
                case Some(j) => ActionableSummaryRequest.fromJson(j)
                case None => ActionableSummaryRequest()
            }

            let sessionDocs = ArrayList<DocumentInfo>()
            for (docId in session.documentIds) {
                match (documents.get(docId)) {
                    case Some(d) => sessionDocs.add(d)
                    case None => ()
                }
            }

            let summaryMarkdown = generateActionableSummary(session, sessionDocs, req.model)

            jsonResponse(ctx, jsonObj([
                ("summary", JsonValue.JsonString(summaryMarkdown)),
                ("filename", JsonValue.JsonString("actionable_summary_${sessionId[..8]}.md"))
            ]))
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleRunAgentLoop(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            let body = readRequestBody(ctx)
            let json = parseJson(body)
            let req = match (json) {
                case Some(j) => RunAgentLoopRequest.fromJson(j)
                case None => RunAgentLoopRequest()
            }

            let agentMessages = ArrayList<HashMap<String, JsonValue>>()
            for (msg in session.conversation) {
                match (msg.get("type")) {
                    case Some(v) => match (v.getString()) {
                        case Some(t) => if (t == "agent") { agentMessages.add(msg) }
                        case None => ()
                    }
                    case None => ()
                }
            }
            if (agentMessages.size == 0) {
                errorResponse(ctx, "No agent messages found", status: 400)
                return
            }

            let feedbackAnalysis = buildFeedbackFromConversation(session.conversation)
            let recsArr: ?ArrayList<JsonValue> = match (feedbackAnalysis.get("synthesized_recommendations")) {
                case Some(jv) => jv.getArray()
                case None => None
            }
            match (recsArr) {
                case None =>
                    errorResponse(ctx, "No recommendations found", status: 400)
                    return
                case Some(arr) =>
                    if (arr.size == 0) {
                        errorResponse(ctx, "No recommendations found", status: 400)
                        return
                    }
            }

            var documentContent = ""
            for (docId in session.documentIds) {
                match (documents.get(docId)) {
                    case Some(doc) =>
                        if (fileExists(doc.path)) {
                            try {
                                let content = parseDocument(doc.path)
                                if (documentContent.size > 0) { documentContent += "\n\n---\n\n" }
                                documentContent += content
                            } catch (_: Exception) {}
                        }
                    case None => ()
                }
            }

            if (documentContent.size == 0) {
                errorResponse(ctx, "????????????", status: 400)
                return
            }

            try {
                agentLoopManager.maxIterations = req.maxIterations
                synchronized(globalMu) { currentAgentLoopSessionId = sessionId }
                let report = agentLoopManager.runAgentLoop(
                    documentContent, feedbackAnalysis, sessionId: sessionId
                )
                session.agentLoopReport = report
                synchronized(globalMu) { currentAgentLoopSessionId = None }
                jsonResponse(ctx, report)
            } catch (e: Exception) {
                synchronized(globalMu) { currentAgentLoopSessionId = None }
                errorResponse(ctx, "Agent ??????: ${e.toString()}", status: 500)
            }
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleAgentStatus(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            if (currentAgentLoopSessionId == Some(sessionId)) {
                let status = agentLoopManager.getCurrentStatus()
                jsonResponse(ctx, jsonObj([("state", JsonValue.JsonString("running")), ("status", status)]))
            } else if (match (session.agentLoopReport) { case Some(_) => true case None => false }) {
                jsonResponse(ctx, jsonObj([
                    ("state", JsonValue.JsonString("completed")),
                    ("report", match (session.agentLoopReport) { case Some(r) => r case None => JsonValue.JsonString("") })
                ]))
            } else {
                jsonResponse(ctx, jsonObj([("state", JsonValue.JsonString("idle"))]))
            }
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleImprovedDocument(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            match (session.agentLoopReport) {
                case Some(report) =>
                    var doc = match (report["final_document"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
                    if (doc.size == 0) {
                        doc = match (report["final_document_preview"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
                    }
                    jsonResponse(ctx, jsonObj([
                        ("content", JsonValue.JsonString(doc)),
                        ("session_id", JsonValue.JsonString(sessionId))
                    ]))
                case None =>
                    errorResponse(ctx, "Session not found", status: 404)
            }
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleExport(ctx: HttpContext, sessionId: String): Unit {
    match (sessions.get(sessionId)) {
        case Some(session) =>
            let body = readRequestBody(ctx)
            let json = parseJson(body)
            match (json.flatMap { j => ExportRequest.fromJson(j) }) {
                case Some(req) =>
                    let content = generateMarkdownExport(session, req.includeMetadata)
                    let filename = if (req.format == "markdown") {
                        "conversation_${sessionId[..8]}.md"
                    } else {
                        "conversation_${sessionId[..8]}.md"
                    }
                    addCorsHeaders(ctx)
                    ctx.responseBuilder
                        .status(200)
                        .header("Content-Type", "text/markdown")
                        .header("Content-Disposition", "attachment; filename=${filename}")
                        .body(content)
                case None =>
                    errorResponse(ctx, "Invalid export request")
            }
        case None =>
            errorResponse(ctx, "Session not found", status: 404)
    }
}

func handleSessionTokens(ctx: HttpContext, sessionId: String): Unit {
    jsonResponse(ctx, tokenTracker.getSessionTokenSummary(sessionId))
}

func handleStream(ctx: HttpContext, sessionId: String): Unit {
    // (see code)
}

func handleCreateFromTemplate(ctx: HttpContext): Unit {
    try {
        let body = readRequestBody(ctx)
        let json = parseJson(body)
        match (json.flatMap { j => CreateTeamFromTemplateRequest.fromJson(j) }) {
            case Some(req) =>
                let templatesJson = loadConfigJson("agent_templates.json")
                let templateLookup = HashMap<String, JsonValue>()
                match (templatesJson) {
                    case None =>
                        errorResponse(ctx, "Agent templates not found", status: 404)
                        return
                    case Some(templates) =>
                        match (templates["categories"]) {
                            case Some(JsonValue.JsonObject(categories)) =>
                                for ((_, category) in categories) {
                                    match (category["templates"]) {
                                        case Some(JsonValue.JsonArray(tmpls)) =>
                                            for (t in tmpls) {
                                                let tid = match (t["id"]) {
                                                    case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" }
                                                    case None => ""
                                                }
                                                if (tid.size > 0) { templateLookup[tid] = t }
                                            }
                                        case _ => ()
                                    }
                                }
                            case _ => ()
                        }
                }

                for (docId in req.documentIds) {
                    if (!documents.contains(docId)) {
                        errorResponse(ctx, "Document not found: ${docId}", status: 404)
                        return
                    }
                }

                let teamMembers = ArrayList<TeamMember>()
                let templatePrompts = HashMap<String, String>()
                var i: Int64 = 0
                for (templateId in req.templateIds) {
                    match (templateLookup.get(templateId)) {
                        case Some(tmpl) =>
                            let memberId = "template_${templateId}_${i}"
                            let tmplName = match (tmpl["name"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => templateId } case None => templateId }
                            let tmplRole = match (tmpl["role"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
                            let tmplModel = match (tmpl["model"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "gpt-4o-mini" } case None => "gpt-4o-mini" }
                            let member = TeamMember(memberId, tmplName, tmplRole, model: tmplModel)
                            teamMembers.add(member)
                            match (tmpl["system_prompt"]) {
                                case Some(jv) => match (jv.getString()) {
                                    case Some(sp) => templatePrompts[memberId] = sp
                                    case None => ()
                                }
                                case None => ()
                            }
                        case None =>
                            errorResponse(ctx, "Template not found: ${templateId}", status: 400)
                            return
                    }
                    i += 1
                }

                let sessionId = generateUUID()
                let session = Session(sessionId, req.documentIds, teamMembers)
                synchronized(globalMu) { sessions[sessionId] = session }

                let sessionDocs = ArrayList<DocumentInfo>()
                for (docId in req.documentIds) {
                    match (documents.get(docId)) {
                        case Some(d) => sessionDocs.add(d)
                        case None => ()
                    }
                }

                let responses = runDiscussionRoundWithTemplates(
                    session, sessionDocs, req.initialPrompt, templatePrompts
                )

                session.conversation.add(makeUserMessage(req.initialPrompt))
                for (r in responses) { session.conversation.add(r) }

                let filenames = jsonArray()
                for (docId in req.documentIds) {
                    match (documents.get(docId)) {
                        case Some(d) => filenames.add(JsonValue.JsonString(d.filename))
                        case None => ()
                    }
                }

                jsonResponse(ctx, jsonObj([
                    ("session_id", JsonValue.JsonString(sessionId)),
                    ("document_filenames", JsonValue.JsonArray(filenames)),
                    ("conversation", conversationToJson(session.conversation))
                ]))
            case None =>
                errorResponse(ctx, "Invalid request body")
        }
    } catch (e: Exception) {
        errorResponse(ctx, e.toString(), status: 500)
    }
}

func handleAgentTemplates(ctx: HttpContext): Unit {
    let templates = loadConfigJson("agent_templates.json")
    match (templates) {
        case Some(t) => jsonResponse(ctx, t)
        case None => errorResponse(ctx, "Agent templates not found", status: 404)
    }
}

func handleAgentMemoryStats(ctx: HttpContext): Unit {
    let stats = agentMemory.getStats()
    let recentArr = jsonArray()
    let entries = agentMemory.entries
    let start = max(0, Int64(entries.size) - 10)
    for (i in start..entries.size) {
        recentArr.add(JsonValue.JsonObject(entries[i]))
    }
    jsonResponse(ctx, jsonObj([
        ("stats", stats),
        ("recent_entries", JsonValue.JsonArray(recentArr))
    ]))
}

func handleAgentMemorySearch(ctx: HttpContext): Unit {
    var query = ""
    var topKStr = "5"
    let urlStr = ctx.request.url.toString()
    match (urlStr.indexOf("?")) {
        case Some(qIdx) =>
            let qs = urlStr[qIdx + 1..]
            let qParts = qs.split("&")
            for (p in qParts) {
                match (p.indexOf("=")) {
                    case Some(eqIdx) =>
                        let k = p[..eqIdx]
                        let v = p[eqIdx + 1..]
                        if (k == "q") { query = v }
                        if (k == "top_k") { topKStr = v }
                    case None => ()
                }
            }
        case None => ()
    }
    let topK = try { Int64.parse(topKStr) } catch (_: Exception) { 5 }

    let results = agentMemory.retrieve(query, topK: topK)
    let resultsArr = jsonArray()
    for ((score, entry) in results) {
        let entryWithScore = HashMap<String, JsonValue>()
        for ((k, v) in entry) { entryWithScore[k] = v }
        entryWithScore["relevance_score"] = JsonValue.JsonFloat(score)
        resultsArr.add(JsonValue.JsonObject(entryWithScore))
    }
    jsonResponse(ctx, jsonObj([
        ("query", JsonValue.JsonString(query)),
        ("results", JsonValue.JsonArray(resultsArr))
    ]))
}

func handleContentExport(ctx: HttpContext): Unit {
    let body = readRequestBody(ctx)
    let json = parseJson(body)
    match (json.flatMap { j => ContentExportRequest.fromJson(j) }) {
        case Some(req) =>
            let contentBytes = req.content.toArray()
            let filename = if (req.filename.endsWith(".md")) { req.filename } else { "${req.filename}.md" }
            addCorsHeaders(ctx)
            ctx.responseBuilder
                .status(200)
                .header("Content-Type", "text/markdown")
                .header("Content-Disposition", "attachment; filename=\"${filename}\"")
                .body(req.content)
        case None =>
            errorResponse(ctx, "Invalid content export request")
    }
}

func handleWebSocket(ctx: HttpContext, sessionId: ?String): Unit {
    try {
        let ws = WebSocket.upgradeFromServer(ctx)
        wsManager.addConnection(ws, sessionId: sessionId)

        match (sessionId) {
            case Some(sid) =>
                match (sessions.get(sid)) {
                    case Some(session) =>
                        let info = jsonObj([
                            ("type", JsonValue.JsonString("session_info")),
                            ("session_id", JsonValue.JsonString(sid)),
                            ("team_size", JsonValue.JsonInt(Int64(session.teamMembers.size))),
                            ("document_count", JsonValue.JsonInt(Int64(session.documentIds.size))),
                            ("conversation_length", JsonValue.JsonInt(Int64(session.conversation.size)))
                        ])
                        wsManager.sendPersonal(info.toJsonString(), ws)
                    case None => ()
                }
            case None => ()
        }

        while (true) {
            let frame = ws.read()
            if (frame.frameType == TextWebFrame) {
                let text = String.fromUtf8(frame.payload)
                let parsed = parseJson(text)
                match (parsed) {
                    case Some(msg) =>
                        let msgType = match (msg["type"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
                        if (msgType == "ping") {
                            let pong = jsonObj([("type", JsonValue.JsonString("pong"))])
                            wsManager.sendPersonal(pong.toJsonString(), ws)
                        }
                    case None => ()
                }
            } else if (frame.frameType == CloseWebFrame) {
                break
            }
        }

        wsManager.removeConnection(ws, sessionId: sessionId)
        ws.write(CloseWebFrame, Array<UInt8>())
    } catch (_: Exception) {
         // Cleanup
    }
}

// getFileExtension defined in document_parser.cj
