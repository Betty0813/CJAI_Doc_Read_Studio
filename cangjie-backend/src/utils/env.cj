package ai_doc_read_studio.utils

import std.fs.*
import std.collection.*

// ????? .env???? std.os
var envMap: HashMap<String, String> = HashMap<String, String>()

public func fileExists(path: String): Bool {
    try {
        let _ = File.readFrom(path)
        return true
    } catch (_: Exception) {
        return false
    }
}

public func getEnvVar(name: String, defaultValue!: String = ""): String {
    match (envMap.get(name)) {
        case Some(v) =>
            if (v.size > 0) { return v }
        case None => ()
    }
    return defaultValue
}

public func loadDotEnv(path!: String = ".env"): Unit {
    if (!fileExists(path)) {
        return
    }
    try {
        let content = String.fromUtf8(File.readFrom(path))
        let lines = content.split("\n")
        for (line in lines) {
            let trimmed = line.trimAscii()
            if (trimmed.size == 0 || trimmed.startsWith("#")) {
                continue
            }
            match (trimmed.indexOf("=")) {
                case Some(eqIdx) =>
                    if (eqIdx <= 0) { continue }
                    let key = trimmed[0..eqIdx].trimAscii()
                    var value = trimmed[eqIdx + 1..].trimAscii()
                    if (value.startsWith("\"") && value.endsWith("\"") && value.size >= 2) {
                        value = value[1..value.size - 1]
                    }
                    envMap[key] = value
                case None => ()
            }
        }
    } catch (_: Exception) {}
}

public func toLowerAscii(s: String): String {
    let bytes = s.toArray()
    let sb = StringBuilder()
    var i: Int64 = 0
    let size = Int64(bytes.size)
    while (i < size) {
        let ch = bytes[i]
        if (ch >= 65 && ch <= 90) {
            // ASCII uppercase A-Z: convert to lowercase
            sb.append(String.fromUtf8([ch + 32]))
            i += 1
        } else if (ch <= 127) {
            // Other single-byte ASCII: pass through
            sb.append(String.fromUtf8([ch]))
            i += 1
        } else if (ch >= 194 && ch <= 223 && i + 1 < size) {
            // 2-byte UTF-8 sequence (e.g. Latin extended)
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1]])); i += 2 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (ch >= 224 && ch <= 239 && i + 2 < size) {
            // 3-byte UTF-8 sequence (e.g. CJK characters)
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1], bytes[i + 2]])); i += 3 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (ch >= 240 && ch <= 247 && i + 3 < size) {
            // 4-byte UTF-8 sequence (e.g. emoji)
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]])); i += 4 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else {
            sb.append("?")
            i += 1
        }
    }
    return sb.toString()
}

public func loadConfigJson(path: String): ?JsonValue {
    if (!fileExists(path)) {
        return None
    }
    try {
        let content = String.fromUtf8(File.readFrom(path))
        return parseJson(content)
    } catch (_: Exception) {
        return None
    }
}
