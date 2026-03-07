package ai_doc_read_studio

import std.collection.*
import std.random.*
import std.time.*
import ai_doc_read_studio.utils.*

func loadConfig(): ?JsonValue {
    return loadConfigJson("config.json")
}

public func getBedrockModelId(modelName: String): String {
    let config = loadConfig()
    match (config) {
        case Some(cfg) =>
            match (cfg["models"]) {
                case Some(models) =>
                    match (models["available"]) {
                        case Some(JsonValue.JsonArray(available)) =>
                            for (m in available) {
                                let mValue = match (m["value"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => "" } case None => "" }
                                if (mValue == modelName) {
                                    let mId = match (m["model_id"]) { case Some(jv) => match (jv.getString()) { case Some(s) => s case None => modelName } case None => modelName }
                                    return mId
                                }
                            }
                        case _ => ()
                    }
                case _ => ()
            }
        case None => ()
    }
    return modelName
}

func buildConversationHistory(session: Session, currentPrompt: String): String {
    let sb = StringBuilder()
    sb.append("<conversation_history>\n")
    for (msg in session.conversation) {
        let msgType = msg.get("type").flatMap { v => v.getString() } ?? ""
        let content = msg.get("content").flatMap { v => v.getString() } ?? ""
        if (msgType == "user") {
            sb.append("<user_message>${content}</user_message>\n")
        } else {
            let agentName = msg.get("agent_name").flatMap { v => v.getString() } ?? "Agent"
            let role = msg.get("role").flatMap { v => v.getString() } ?? "Team Member"
            sb.append("<agent_message agent='${agentName}' role='${role}'>${content}</agent_message>\n")
        }
    }
    sb.append("<current_user_prompt>${currentPrompt}</current_user_prompt>\n")
    sb.append("</conversation_history>")
    return sb.toString()
}

func createSystemPrompt(member: TeamMember, documentsContent: String, conversationHistory: String, customSystemPrompt!: ?String = None): String {
    if (member.name == "Team Moderator") {
        return """
You are the Team Moderator, responsible for analyzing and synthesizing feedback from all team members.

YOUR CORE RESPONSIBILITIES:
1. CONFLICT ANALYSIS: Identify conflicting recommendations between team members
2. SYNERGY IDENTIFICATION: Highlight areas where feedback reinforces each other
3. ACTIONABLE SYNTHESIS: Provide a consolidated summary
4. QUESTION CONSOLIDATION: Collect and organize clarification questions

DOCUMENTS TO REVIEW:
${documentsContent}

CONVERSATION CONTEXT:
${conversationHistory}

RESPONSE STRUCTURE:
## Cross-Team Analysis
### Conflicts Identified
### Synergies Found
### Consolidated Questions for Clarification
### Synthesized Recommendations"""
    }

    match (customSystemPrompt) {
        case Some(custom) =>
            return """
${custom}

DOCUMENTS TO REVIEW:
${documentsContent}

CONVERSATION CONTEXT:
${conversationHistory}

ADDITIONAL INSTRUCTIONS:
- ALWAYS mention the specific filename when referencing content
- Review the full conversation history
- Use markdown formatting
- Keep responses focused and actionable"""
        case None =>
            return """
You are ${member.name}, a team member participating in a collaborative document review.

Your role: ${member.role}

DOCUMENTS TO REVIEW:
${documentsContent}

CONVERSATION CONTEXT:
${conversationHistory}

INSTRUCTIONS:
1. Carefully analyze ALL documents from your role's perspective
2. Provide constructive feedback focused on improvements
3. ALWAYS mention the specific filename when referencing content
4. Review conversation history and build on previous points
5. Evaluate other team members' suggestions
6. Avoid repeating what others have covered
7. Be specific about changes and why they benefit the document
8. Keep responses focused and concise (2-3 paragraphs)
9. Use markdown formatting for readability
10. Ask clarification questions when needed using ### Clarification Questions"""
    }
}

public func runDiscussionRound(
    session: Session,
    documents: ArrayList<DocumentInfo>,
    prompt: String,
    onAgentStart!: ?(String) -> Unit = None,
    onAgentResponse!: ?(HashMap<String, JsonValue>) -> Unit = None
): ArrayList<HashMap<String, JsonValue>> {
    try {
        let documentsContent = parseMultipleDocuments(documents)
        let conversationHistory = buildConversationHistory(session, prompt)

        let apiKey = getEnvVar("OPENAI_API_KEY")
        if (apiKey.size == 0) {
            let errResp = ArrayList<HashMap<String, JsonValue>>()
            let msg = HashMap<String, JsonValue>()
            msg["type"] = JsonValue.JsonString("system")
            msg["content"] = JsonValue.JsonString("Error: OPENAI_API_KEY not set")
            msg["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
            errResp.add(msg)
            return errResp
        }

        let client = OpenAIClient(apiKey, baseUrl: getEnvVar("OPENAI_BASE_URL", defaultValue: "https://api.openai.com/v1"))

        var regularAgents = ArrayList<(TeamMember, String)>()
        var moderatorMember: ?TeamMember = None
        var moderatorPrompt: ?String = None

        for (member in session.teamMembers) {
            let systemPrompt = createSystemPrompt(member, documentsContent, conversationHistory)
            if (member.name == "Team Moderator") {
                moderatorMember = member
                moderatorPrompt = systemPrompt
            } else {
                regularAgents.add((member, systemPrompt))
            }
        }

        // Shuffle regular agents
        let rng = Random()
        for (i in 0..regularAgents.size) {
            let j = Int64(rng.nextInt64(Int64(regularAgents.size)))
            let temp = regularAgents[i]
            regularAgents[i] = regularAgents[j]
            regularAgents[j] = temp
        }

        let regularResponses = ArrayList<HashMap<String, JsonValue>>()
        for ((member, systemPrompt) in regularAgents) {
            match (onAgentStart) {
                case Some(cb) => cb(member.name)
                case None => ()
            }

            let response = getAgentResponse(client, member, systemPrompt, prompt, session.sessionId)
            regularResponses.add(response)

            match (onAgentResponse) {
                case Some(cb) => cb(response)
                case None => ()
            }
        }

        // ?? Team Moderator
        var moderatorResponse: ?HashMap<String, JsonValue> = None
        match (moderatorMember) {
            case Some(modMember) =>
                match (onAgentStart) {
                    case Some(cb) => cb(modMember.name)
                    case None => ()
                }
                var updatedHistory = conversationHistory
                for (resp in regularResponses) {
                    let name = resp.get("agent_name").flatMap { v => v.getString() } ?? ""
                    let role = resp.get("role").flatMap { v => v.getString() } ?? ""
                    let content = resp.get("content").flatMap { v => v.getString() } ?? ""
                    updatedHistory += "\n<agent_message agent='${name}' role='${role}'>${content}</agent_message>"
                }
                let modSystemPrompt = createSystemPrompt(modMember, documentsContent, updatedHistory)
                let modResp = getAgentResponse(client, modMember, modSystemPrompt, prompt, session.sessionId)
                moderatorResponse = modResp
                match (onAgentResponse) {
                    case Some(cb) => cb(modResp)
                    case None => ()
                }
            case None => ()
        }

        let allResponses = ArrayList<HashMap<String, JsonValue>>()
        for (r in regularResponses) { allResponses.add(r) }
        match (moderatorResponse) {
            case Some(r) => allResponses.add(r)
            case None => ()
        }

        // Run debate
        try {
            let debateResponses = runDebateRound(
                session, documents, allResponses, prompt, client,
                onAgentStart: onAgentStart, onAgentResponse: onAgentResponse
            )
            for (r in debateResponses) { allResponses.add(r) }
        } catch (_: Exception) {
            logger.warning("Debate round failed (non-critical)")
        }

        client.close()
        return allResponses

    } catch (e: Exception) {
        logger.error("Error in discussion round", fields: [("error", e.toString())])
        let errResp = ArrayList<HashMap<String, JsonValue>>()
        let msg = HashMap<String, JsonValue>()
        msg["type"] = JsonValue.JsonString("system")
        msg["content"] = JsonValue.JsonString("Error running discussion round: ${e.toString()}")
        msg["timestamp"] = JsonValue.JsonString(DateTime.now().toString())
        errResp.add(msg)
        return errResp
    }
}

func getAgentResponse(
    client: OpenAIClient,
    member: TeamMember,
    systemPrompt: String,
    prompt: String,
    sessionId: String
): HashMap<String, JsonValue> {
    let agentPrompt = "Current discussion prompt: ${prompt}\n\nPlease provide your perspective from your role as ${member.role}. Focus on actionable feedback."
    let modelId = getBedrockModelId(member.model)

    try {
        let (responseText, responseTime) = invokeWithRetry(
            client, systemPrompt, agentPrompt, modelId
        )

        tokenTracker.trackAgentInvocation(
            sessionId, member.name, member.model,
            agentPrompt, responseText, responseTime
        )

        return makeAgentMessage(
            member.id, member.name, member.role, member.model,
            responseText, responseTime: responseTime
        )
    } catch (e: Exception) {
        return makeAgentMessage(
            member.id, member.name, member.role, member.model,
            "I apologize, but I'm having trouble responding right now. Error: ${e.toString()}"
        )
    }
}

func runDebateRound(
    session: Session,
    documents: ArrayList<DocumentInfo>,
    initialResponses: ArrayList<HashMap<String, JsonValue>>,
    originalPrompt: String,
    client: OpenAIClient,
    onAgentStart!: ?(String) -> Unit = None,
    onAgentResponse!: ?(HashMap<String, JsonValue>) -> Unit = None
): ArrayList<HashMap<String, JsonValue>> {
    let documentsContent = parseMultipleDocuments(documents)

    let sb = StringBuilder()
    for (resp in initialResponses) {
        let msgType = resp.get("type").flatMap { v => v.getString() } ?? ""
        if (msgType != "agent") { continue }
        let name = resp.get("agent_name").flatMap { v => v.getString() } ?? ""
        let role = resp.get("role").flatMap { v => v.getString() } ?? ""
        let content = resp.get("content").flatMap { v => v.getString() } ?? ""
        sb.append("\n--- ${name} (${role}) ---\n${content}\n")
    }
    let othersText = sb.toString()
    if (othersText.trimAscii().size == 0) { return ArrayList<HashMap<String, JsonValue>>() }

    let debateMembers = ArrayList<TeamMember>()
    for (m in session.teamMembers) {
        if (m.name != "Team Moderator") { debateMembers.add(m) }
    }
    if (debateMembers.size == 0) { return ArrayList<HashMap<String, JsonValue>>() }

    let debateSystemTemplate = """
You are {name}, participating in a multi-agent debate about document review.

Your role: {role}

OTHER AGENTS' INITIAL FEEDBACK:
{others}

DOCUMENTS:
{docs}

YOUR TASK - DEBATE ROUND:
1. CHALLENGE points you disagree with
2. SUPPORT points you strongly agree with
3. REFINE suggestions by other agents
4. Raise any NEW insights

RULES:
- Address other agents BY NAME
- Be constructive
- Keep it concise (1-2 paragraphs)
- Start with "## Debate Response"
- Format as: ### Agreements, ### Challenges, ### New Insights"""

    let results = ArrayList<HashMap<String, JsonValue>>()
    for (member in debateMembers) {
        match (onAgentStart) {
            case Some(cb) => cb("${member.name} (debate)")
            case None => ()
        }

        let othersLimited = if (othersText.size > 6000) { othersText[..6000] } else { othersText }
        let docsLimited = if (documentsContent.size > 4000) { documentsContent[..4000] } else { documentsContent }

        let system = debateSystemTemplate
            .replace("{name}", member.name)
            .replace("{role}", member.role)
            .replace("{others}", othersLimited)
            .replace("{docs}", docsLimited)

        let modelId = getBedrockModelId(member.model)
        try {
            let (text, respTime) = invokeWithRetry(
                client, system,
                "Original discussion prompt: ${originalPrompt}\n\nProvide your debate response.",
                modelId
            )
            let resp = makeAgentMessage(
                member.id, "${member.name} (Debate)", member.role, member.model,
                text, responseTime: respTime
            )
            resp["is_debate"] = JsonValue.JsonBool(true)
            results.add(resp)

            match (onAgentResponse) {
                case Some(cb) => cb(resp)
                case None => ()
            }
        } catch (_: Exception) {
            logger.warning("Debate response failed for ${member.name}")
        }
    }

    return results
}

public func generateActionableSummary(
    session: Session,
    documents: ArrayList<DocumentInfo>,
    model: String
): String {
    let documentsContent = parseMultipleDocuments(documents)

    let suggestionsText = StringBuilder()
    suggestionsText.append("<all_suggestions>\n")
    var i: Int64 = 1
    for (msg in session.conversation) {
        let msgType = msg.get("type").flatMap { v => v.getString() } ?? ""
        if (msgType != "agent") { continue }
        let agentName = msg.get("agent_name").flatMap { v => v.getString() } ?? ""
        let role = msg.get("role").flatMap { v => v.getString() } ?? ""
        let content = msg.get("content").flatMap { v => v.getString() } ?? ""
        suggestionsText.append("<suggestion_${i} from='${agentName}' role='${role}'>\n${content}\n</suggestion_${i}>\n\n")
        i += 1
    }
    suggestionsText.append("</all_suggestions>")

    let systemPrompt = """
You are an expert project manager creating an actionable summary.

DOCUMENTS REVIEWED:
${documentsContent}

ALL TEAM SUGGESTIONS:
${suggestionsText.toString()}

TASK: Create a comprehensive, prioritized actionable summary in markdown format.

FORMAT:
1. Brief overview of documents reviewed
2. Numbered actionable items (10-25)
3. Priority levels: Critical, Important, Nice to Have
4. Stakeholder attribution
5. Implementation timeline suggestion

Use proper markdown formatting."""

    let apiKey = getEnvVar("OPENAI_API_KEY")
    if (apiKey.size == 0) {
        return "# Actionable Summary\n\nError: OPENAI_API_KEY not set"
    }
    let client = OpenAIClient(apiKey, baseUrl: getEnvVar("OPENAI_BASE_URL", defaultValue: "https://api.openai.com/v1"))
    let modelId = getBedrockModelId(model)

    try {
        let (summaryMarkdown, _) = invokeWithRetry(
            client, systemPrompt,
            "Please generate the actionable summary in markdown format.",
            modelId
        )
        client.close()
        return summaryMarkdown
    } catch (e: Exception) {
        client.close()
        return "# Actionable Summary\n\nError generating summary: ${e.toString()}"
    }
}

public func runDiscussionRoundWithTemplates(
    session: Session,
    documents: ArrayList<DocumentInfo>,
    prompt: String,
    templatePrompts: HashMap<String, String>
): ArrayList<HashMap<String, JsonValue>> {
    let documentsContent = parseMultipleDocuments(documents)
    let conversationHistory = buildConversationHistory(session, prompt)

    let apiKey = getEnvVar("OPENAI_API_KEY")
    if (apiKey.size == 0) {
        return ArrayList<HashMap<String, JsonValue>>()
    }
    let client = OpenAIClient(apiKey, baseUrl: getEnvVar("OPENAI_BASE_URL", defaultValue: "https://api.openai.com/v1"))

    let responses = ArrayList<HashMap<String, JsonValue>>()
    for (member in session.teamMembers) {
        let customPrompt = templatePrompts.get(member.id)
        let systemPrompt = createSystemPrompt(
            member, documentsContent, conversationHistory,
            customSystemPrompt: customPrompt
        )
        let response = getAgentResponse(client, member, systemPrompt, prompt, session.sessionId)
        responses.add(response)
    }

    // Shuffle results
    let rng = Random()
    for (i in 0..responses.size) {
        let j = Int64(rng.nextInt64(Int64(responses.size)))
        let temp = responses[i]
        responses[i] = responses[j]
        responses[j] = temp
    }

    client.close()
    return responses
}
