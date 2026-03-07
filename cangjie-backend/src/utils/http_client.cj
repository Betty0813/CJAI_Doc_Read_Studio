package ai_doc_read_studio.utils

import stdx.net.http.*
import stdx.net.tls.*
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
        // TrustAll skips CA verification — acceptable for calling third-party HTTPS
        // APIs in development where the system CA store may not be configured with
        // the OpenSSL DLLs we bundle. Switch to Default or CustomCA for production.
        var tlsCfg = TlsClientConfig()
        tlsCfg.verifyMode = TrustAll
        this.client = ClientBuilder()
            .tlsConfig(tlsCfg)
            .build()
    }

    public func chatCompletion(
        model: String,
        messages: ArrayList<HashMap<String, String>>,
        maxTokens!: Int64 = 2048,
        temperature!: Float64 = 0.7,
        tools!: ?JsonValue = None
    ): (String, JsonValue) {
        let url = "${baseUrl}/chat/completions"

        // Build the messages JSON array manually using safeJsonString so that we
        // never call Cangjie's toJsonString() on user/document content (it crashes
        // on certain valid Unicode codepoints).
        let msgParts = ArrayList<String>()
        for (msg in messages) {
            let role = msg.get("role") ?? ""
            let content = msg.get("content") ?? ""
            msgParts.add("{\"role\":${safeJsonString(role)},\"content\":${safeJsonString(content)}}")
        }
        var messagesJson = "["
        var first = true
        for (part in msgParts) {
            if (!first) { messagesJson += "," }
            messagesJson += part
            first = false
        }
        messagesJson += "]"

        // tools part – toJsonString() is safe here since tools are structured JsonValues
        var toolsSuffix = ""
        match (tools) {
            case Some(t) =>
                try {
                    toolsSuffix = ",\"tools\":${t.toJsonString()},\"tool_choice\":\"auto\""
                } catch (_: Exception) { toolsSuffix = "" }
            case None => ()
        }

        let bodyJson = "{\"model\":${safeJsonString(model)},\"messages\":${messagesJson},\"max_tokens\":${maxTokens},\"temperature\":${temperature}${toolsSuffix}}"
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

// Decode a byte array to String safely, replacing any invalid UTF-8 sequences with '?'.
// Also strips control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F) that are legal in
// UTF-8 Strings but cause Cangjie's JSON serializer to throw.
public func safeDecodeBytes(all: Array<Byte>): String {
    let totalSize = Int64(all.size)
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < totalSize) {
        let b = all[i]
        if (b <= 127) {
            // Allow tab (9), newline (10), carriage return (13); skip other control chars
            if (b >= 32 || b == 9 || b == 10 || b == 13) {
                sb.append(String.fromUtf8([b]))
            }
            i += 1
        } else if (b >= 194 && b <= 223 && i + 1 < totalSize) {
            try { sb.append(String.fromUtf8([all[i], all[i + 1]])); i += 2 } catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (b >= 224 && b <= 239 && i + 2 < totalSize) {
            try { sb.append(String.fromUtf8([all[i], all[i + 1], all[i + 2]])); i += 3 } catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (b >= 240 && b <= 247 && i + 3 < totalSize) {
            try { sb.append(String.fromUtf8([all[i], all[i + 1], all[i + 2], all[i + 3]])); i += 4 } catch (_: Exception) { sb.append("?"); i += 1 }
        } else {
            sb.append("?")
            i += 1
        }
    }
    return sb.toString()
}

// Truncate a string at a safe UTF-8 character boundary so that the result is always
// valid UTF-8, even when the input contains multi-byte (e.g. CJK) characters.
// Using plain s[..n] in Cangjie slices by byte offset and can cut inside a multi-byte
// sequence, producing an invalid byte sequence that later throws IllegalArgumentException.
public func safeTruncate(s: String, maxBytes: Int64): String {
    if (s.size <= maxBytes) { return s }
    let bytes = s.toArray()
    let size = Int64(bytes.size)
    var pos = if (maxBytes < size) { maxBytes } else { size }
    // Walk backward over UTF-8 continuation bytes (0x80-0xBF)
    while (pos > 0 && bytes[pos - 1] >= 128 && bytes[pos - 1] < 192) {
        pos -= 1
    }
    // If we stopped at a multi-byte start byte (>= 0xC2), remove it too — its
    // continuation bytes were cut off so the sequence would be incomplete.
    if (pos > 0 && bytes[pos - 1] >= 192) {
        pos -= 1
    }
    if (pos <= 0) { return "" }
    let truncBytes = Array<Byte>(pos, repeat: 0)
    for (i in 0..pos) { truncBytes[i] = bytes[i] }
    return safeDecodeBytes(truncBytes)
}

// Produce a JSON string literal (with surrounding quotes) that is always safe to
// embed in a JSON body, regardless of what the Cangjie JSON serializer supports.
// Handles all control chars, backslash, quote, and multi-byte UTF-8.
func safeJsonString(s: String): String {
    let bytes = s.toArray()
    let size = Int64(bytes.size)
    let sb = StringBuilder()
    let hexChars = "0123456789abcdef".toArray()
    sb.append("\"")
    var i: Int64 = 0
    while (i < size) {
        let b = bytes[i]
        if (b == 34) { sb.append("\\\""); i += 1 }
        else if (b == 92) { sb.append("\\\\"); i += 1 }
        else if (b == 10) { sb.append("\\n"); i += 1 }
        else if (b == 13) { sb.append("\\r"); i += 1 }
        else if (b == 9) { sb.append("\\t"); i += 1 }
        else if (b < 32) {
            sb.append("\\u00")
            sb.append(String.fromUtf8([hexChars[Int64(b >> 4)]]))
            sb.append(String.fromUtf8([hexChars[Int64(b & 15)]]))
            i += 1
        } else if (b <= 127) {
            sb.append(String.fromUtf8([b]))
            i += 1
        } else if (b >= 194 && b <= 223 && i + 1 < size) {
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1]])); i += 2 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (b >= 224 && b <= 239 && i + 2 < size) {
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1], bytes[i + 2]])); i += 3 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (b >= 240 && b <= 247 && i + 3 < size) {
            // 4-byte sequences (emoji/supplementary) – replace to avoid serializer bugs
            sb.append("?"); i += 4
        } else {
            sb.append("?"); i += 1
        }
    }
    sb.append("\"")
    return sb.toString()
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
    if (totalSize > 0) {
        let previewLen = if (totalSize < 20) { totalSize } else { 20 }
        let sb = StringBuilder()
        for (i in 0..previewLen) {
            if (i > 0) { sb.append(" ") }
            sb.append("${Int64(all[i])}")
        }
        logger.info("Response body size=${totalSize} first_bytes=[${sb.toString()}]")
    }
    return safeDecodeBytes(all)
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
