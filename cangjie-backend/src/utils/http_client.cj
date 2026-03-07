package ai_doc_read_studio.utils

import stdx.net.http.*
import std.io.*
import std.time.*
import std.collection.*

public class OpenAIClient {
    let apiKey: String
    let baseUrl: String
    let client: Client

    public init(apiKey: String, baseUrl!: String = "https://api.openai.com/v1") {
        this.apiKey = apiKey
        this.baseUrl = baseUrl
        this.client = ClientBuilder().build()
    }

    public func chatCompletion(
        model: String,
        messages: ArrayList<HashMap<String, String>>,
        maxTokens!: Int64 = 2048,
        temperature!: Float64 = 0.7,
        tools!: ?JsonValue = None
    ): (String, JsonValue) {
        let url = "${baseUrl}/chat/completions"

        let messagesArr = jsonArray()
        for (msg in messages) {
            let msgObj = jsonObject()
            for ((k, v) in msg) {
                msgObj[k] = JsonValue.JsonString(v)
            }
            messagesArr.add(JsonValue.JsonObject(msgObj))
        }

        let bodyObj = jsonObject()
        bodyObj["model"] = JsonValue.JsonString(model)
        bodyObj["messages"] = JsonValue.JsonArray(messagesArr)
        bodyObj["max_tokens"] = JsonValue.JsonInt(maxTokens)
        bodyObj["temperature"] = JsonValue.JsonFloat(temperature)

        match (tools) {
            case Some(t) => bodyObj["tools"] = t
            case None => ()
        }

        match (tools) {
            case Some(_) => bodyObj["tool_choice"] = JsonValue.JsonString("auto")
            case None => ()
        }

        var bodyJson = ""
        try {
            bodyJson = JsonValue.JsonObject(bodyObj).toJsonString()
        } catch (e: Exception) {
            logger.warning("toJsonString() failed: ${e.toString()}")
            throw e
        }
        logger.info("Request body built OK, length=${bodyJson.size}")

        let request = HttpRequestBuilder()
            .method("POST")
            .url(url)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer ${apiKey}")
            .header("Accept-Encoding", "identity")
            .body(bodyJson)
            .build()

        logger.info("Sending API request to ${url} model=${model}")
        var response: HttpResponse
        try {
            response = client.send(request)
        } catch (e: Exception) {
            logger.warning("client.send failed: ${e.toString()}")
            throw e
        }
        logger.info("Got API response, reading body...")
        let respBody = readResponseBody(response)
        logger.info("Response body read OK, length=${respBody.size}")
        let parsed = parseJson(respBody)

        match (parsed) {
            case Some(json) =>
                let content = extractChatContent(json)
                return (content, json)
            case None =>
                return ("Error: Failed to parse API response", JsonValue.JsonNull)
        }
    }

    public func close(): Unit {
        client.close()
    }
}

func readResponseBody(response: HttpResponse): String {
    let chunks = ArrayList<Array<Byte>>()
    let buf = Array<Byte>(65536, repeat: 0)
    var totalSize: Int64 = 0
    while (true) {
        var n: Int64 = 0
        try {
            n = response.body.read(buf)
        } catch (e: Exception) {
            logger.warning("response.body.read() threw: ${e.toString()}, collected ${totalSize} bytes so far")
            break
        }
        if (n <= 0) { break }
        let chunk = Array<Byte>(n, repeat: 0)
        for (i in 0..n) { chunk[i] = buf[i] }
        chunks.add(chunk)
        totalSize += Int64(n)
    }
    let all = Array<Byte>(totalSize, repeat: 0)
    var offset: Int64 = 0
    for (chunk in chunks) {
        for (i in 0..chunk.size) {
            all[offset] = chunk[i]
            offset += 1
        }
    }
    // Debug: log first bytes to diagnose encoding issue
    if (totalSize > 0) {
        let previewLen = if (totalSize < 20) { totalSize } else { 20 }
        let sb = StringBuilder()
        for (i in 0..previewLen) {
            if (i > 0) { sb.append(" ") }
            sb.append("${Int64(all[i])}")
        }
        logger.info("Response body size=${totalSize} first_bytes=[${sb.toString()}]")
    }

    // Try safe decoding: skip/replace invalid bytes
    let sb2 = StringBuilder()
    var i: Int64 = 0
    while (i < totalSize) {
        let b = all[i]
        if (b <= 127) {
            sb2.append(String.fromUtf8([b]))
            i += 1
        } else if (b >= 194 && b <= 223 && i + 1 < totalSize) {
            try { sb2.append(String.fromUtf8([all[i], all[i + 1]])); i += 2 } catch (_: Exception) { sb2.append("?"); i += 1 }
        } else if (b >= 224 && b <= 239 && i + 2 < totalSize) {
            try { sb2.append(String.fromUtf8([all[i], all[i + 1], all[i + 2]])); i += 3 } catch (_: Exception) { sb2.append("?"); i += 1 }
        } else if (b >= 240 && b <= 247 && i + 3 < totalSize) {
            try { sb2.append(String.fromUtf8([all[i], all[i + 1], all[i + 2], all[i + 3]])); i += 4 } catch (_: Exception) { sb2.append("?"); i += 1 }
        } else {
            sb2.append("?")
            i += 1
        }
    }
    return sb2.toString()
}

func extractChatContent(json: JsonValue): String {
    match (json["choices"]) {
        case Some(JsonValue.JsonArray(choices)) =>
            if (choices.size > 0) {
                match (choices[0]["message"]) {
                    case Some(msg) =>
                        match (msg["content"]) {
                            case Some(JsonValue.JsonString(s)) => return s
                            case _ => ()
                        }
                    case None => ()
                }
            }
        case _ => ()
    }
    return ""
}

public func invokeWithRetry(
    client: OpenAIClient,
    systemPrompt: String,
    userPrompt: String,
    model: String,
    maxAttempts!: Int64 = 3
): (String, Float64) {
    var attempt: Int64 = 0
    var lastError = ""
    let startTime = DateTime.now()

    while (attempt < maxAttempts) {
        attempt += 1
        try {
            let messages = ArrayList<HashMap<String, String>>()
            let sysMsg = HashMap<String, String>()
            sysMsg["role"] = "system"
            sysMsg["content"] = systemPrompt
            messages.add(sysMsg)

            let userMsg = HashMap<String, String>()
            userMsg["role"] = "user"
            userMsg["content"] = userPrompt
            messages.add(userMsg)

            let (responseText, _) = client.chatCompletion(model, messages)
            let elapsedSec = 0.0
            return (responseText, elapsedSec)
        } catch (e: Exception) {
            lastError = e.toString()
            logger.warning("API call failed, attempt ${attempt}", fields: [("error", lastError)])
            if (attempt < maxAttempts) {
                let waitMs = Int64(1000) * attempt * attempt
                sleep(Duration.millisecond * waitMs)
            }
        }
    }
    throw Exception("All ${maxAttempts} attempts failed: ${lastError}")
}
