package ai_doc_read_studio.utils

import std.collection.*
import std.convert.*

public enum JsonValue {
    | JsonNull
    | JsonBool(Bool)
    | JsonInt(Int64)
    | JsonFloat(Float64)
    | JsonString(String)
    | JsonArray(ArrayList<JsonValue>)
    | JsonObject(HashMap<String, JsonValue>)

    public func toJsonString(): String {
        match (this) {
            case JsonNull => "null"
            case JsonBool(b) => if (b) { "true" } else { "false" }
            case JsonInt(n) => "${n}"
            case JsonFloat(f) => "${f}"
            case JsonString(s) => "\"${escapeJsonString(s)}\""
            case JsonArray(arr) =>
                let sb = StringBuilder()
                sb.append('[')
                var first = true
                for (item in arr) {
                    if (!first) { sb.append(',') }
                    sb.append(item.toJsonString())
                    first = false
                }
                sb.append(']')
                sb.toString()
            case JsonObject(map) =>
                let sb = StringBuilder()
                sb.append('{')
                var first = true
                for ((k, v) in map) {
                    if (!first) { sb.append(',') }
                    sb.append("\"${escapeJsonString(k)}\":${v.toJsonString()}")
                    first = false
                }
                sb.append('}')
                sb.toString()
        }
    }

    public func getString(): ?String {
        match (this) {
            case JsonString(s) => Some(s)
            case _ => None
        }
    }

    public func getInt(): ?Int64 {
        match (this) {
            case JsonInt(n) => Some(n)
            case _ => None
        }
    }

    public func getFloat(): ?Float64 {
        match (this) {
            case JsonFloat(f) => Some(f)
            case JsonInt(n) => Some(Float64(n))
            case _ => None
        }
    }

    public func getBool(): ?Bool {
        match (this) {
            case JsonBool(b) => Some(b)
            case _ => None
        }
    }

    public func getArray(): ?ArrayList<JsonValue> {
        match (this) {
            case JsonArray(arr) => Some(arr)
            case _ => None
        }
    }

    public func getObject(): ?HashMap<String, JsonValue> {
        match (this) {
            case JsonObject(map) => Some(map)
            case _ => None
        }
    }

    public operator func [](key: String): ?JsonValue {
        match (this) {
            case JsonObject(map) => map.get(key)
            case _ => None
        }
    }

    public operator func [](index: Int64): ?JsonValue {
        match (this) {
            case JsonArray(arr) =>
                if (index >= 0 && index < arr.size) {
                    Some(arr[index])
                } else {
                    None
                }
            case _ => None
        }
    }
}

func escapeJsonString(s: String): String {
    let sb = StringBuilder()
    let bytes = s.toArray()
    let size = Int64(bytes.size)
    let hexChars = "0123456789abcdef".toArray()
    var i: Int64 = 0
    while (i < size) {
        let ch = bytes[i]
        if (ch == 34) { sb.append("\\\""); i += 1 }
        else if (ch == 92) { sb.append("\\\\"); i += 1 }
        else if (ch == 10) { sb.append("\\n"); i += 1 }
        else if (ch == 13) { sb.append("\\r"); i += 1 }
        else if (ch == 9) { sb.append("\\t"); i += 1 }
        else if (ch < 32) {
            sb.append("\\u00")
            sb.append(String.fromUtf8([hexChars[Int64(ch >> 4)]]))
            sb.append(String.fromUtf8([hexChars[Int64(ch & 15)]]))
            i += 1
        } else if (ch <= 127) {
            sb.append(String.fromUtf8([ch]))
            i += 1
        } else if (ch >= 194 && ch <= 223 && i + 1 < size) {
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1]])); i += 2 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (ch >= 224 && ch <= 239 && i + 2 < size) {
            try { sb.append(String.fromUtf8([bytes[i], bytes[i + 1], bytes[i + 2]])); i += 3 }
            catch (_: Exception) { sb.append("?"); i += 1 }
        } else if (ch >= 240 && ch <= 247 && i + 3 < size) {
            sb.append("?"); i += 4
        } else {
            sb.append("?"); i += 1
        }
    }
    return sb.toString()
}

public func jsonObject(): HashMap<String, JsonValue> {
    return HashMap<String, JsonValue>()
}

public func jsonArray(): ArrayList<JsonValue> {
    return ArrayList<JsonValue>()
}

public func jsonObj(pairs: Array<(String, JsonValue)>): JsonValue {
    let map = HashMap<String, JsonValue>()
    for ((k, v) in pairs) {
        map[k] = v
    }
    return JsonValue.JsonObject(map)
}

public func jsonArr(items: Array<JsonValue>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (item in items) {
        arr.add(item)
    }
    return JsonValue.JsonArray(arr)
}

// ---- Minimal JSON Parser ----

public func parseJson(input: String): ?JsonValue {
    let parser = JsonParser(input)
    return parser.parseValue()
}

class JsonParser {
    var source: String
    var pos: Int64 = 0

    init(source: String) {
        this.source = source
    }

    func parseValue(): ?JsonValue {
        skipWhitespace()
        if (pos >= source.size) { return None }
        let ch = source[pos]
        if (ch == 34) { return parseString() }
        if (ch == 123) { return parseObject() }
        if (ch == 91) { return parseArray() }
        if (ch == 116 || ch == 102) { return parseBool() }
        if (ch == 110) { return parseNull() }
        if (ch == 45 || (ch >= 48 && ch <= 57)) { return parseNumber() }
        return None
    }

    func skipWhitespace(): Unit {
        while (pos < source.size) {
            let ch = source[pos]
            if (ch == 32 || ch == 10 || ch == 13 || ch == 9) {
                pos += 1
            } else {
                break
            }
        }
    }

    func parseString(): ?JsonValue {
        if (source[pos] != 34) { return None }
        pos += 1
        let sb = StringBuilder()
        while (pos < source.size && source[pos] != 34) {
            let b = source[pos]
            if (b == 92) {
                // escape sequence
                pos += 1
                if (pos >= source.size) { return None }
                let c = source[pos]
                if (c == 34) { sb.append("\""); pos += 1 }
                else if (c == 92) { sb.append("\\"); pos += 1 }
                else if (c == 110) { sb.append("\n"); pos += 1 }
                else if (c == 114) { sb.append("\r"); pos += 1 }
                else if (c == 116) { sb.append("\t"); pos += 1 }
                else if (c == 47) { sb.append("/"); pos += 1 }
                else if (c == 117 && pos + 4 < source.size) {
                    // \uXXXX — decode the 4 hex digits to a code point
                    let h1 = hexVal(source[pos + 1])
                    let h2 = hexVal(source[pos + 2])
                    let h3 = hexVal(source[pos + 3])
                    let h4 = hexVal(source[pos + 4])
                    if (h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0) {
                        let cp = Int64(h1) * 4096 + Int64(h2) * 256 + Int64(h3) * 16 + Int64(h4)
                        sb.append(cpToUtf8(cp))
                        pos += 5
                    } else {
                        sb.append("?"); pos += 1
                    }
                } else {
                    sb.append(String.fromUtf8([c])); pos += 1
                }
            } else if (b <= 127) {
                sb.append(String.fromUtf8([b]))
                pos += 1
            } else if (b >= 194 && b <= 223 && pos + 1 < source.size) {
                try { sb.append(String.fromUtf8([source[pos], source[pos + 1]])); pos += 2 }
                catch (_: Exception) { sb.append("?"); pos += 1 }
            } else if (b >= 224 && b <= 239 && pos + 2 < source.size) {
                try { sb.append(String.fromUtf8([source[pos], source[pos + 1], source[pos + 2]])); pos += 3 }
                catch (_: Exception) { sb.append("?"); pos += 1 }
            } else if (b >= 240 && b <= 247 && pos + 3 < source.size) {
                sb.append("?"); pos += 4
            } else {
                sb.append("?"); pos += 1
            }
        }
        if (pos < source.size) { pos += 1 } // skip closing "
        return Some(JsonValue.JsonString(sb.toString()))
    }

    func hexVal(b: Byte): Int64 {
        if (b >= 48 && b <= 57) { return Int64(b - 48) }
        if (b >= 65 && b <= 70) { return Int64(b - 55) }
        if (b >= 97 && b <= 102) { return Int64(b - 87) }
        return -1
    }

    func cpToUtf8(cp: Int64): String {
        if (cp <= 0x7F) {
            return String.fromUtf8([UInt8(cp)])
        } else if (cp <= 0x7FF) {
            return String.fromUtf8([UInt8(0xC0 | (cp >> 6)), UInt8(0x80 | (cp & 0x3F))])
        } else if (cp <= 0xFFFF) {
            return String.fromUtf8([
                UInt8(0xE0 | (cp >> 12)),
                UInt8(0x80 | ((cp >> 6) & 0x3F)),
                UInt8(0x80 | (cp & 0x3F))
            ])
        } else {
            return "?"
        }
    }

    func parseNumber(): ?JsonValue {
        let start = pos
        var isFloat = false
        if (pos < source.size && source[pos] == 45) { pos += 1 }
        while (pos < source.size && source[pos] >= 48 && source[pos] <= 57) {
            pos += 1
        }
        if (pos < source.size && source[pos] == 46) {
            isFloat = true
            pos += 1
            while (pos < source.size && source[pos] >= 48 && source[pos] <= 57) {
                pos += 1
            }
        }
        if (pos < source.size && (source[pos] == 101 || source[pos] == 69)) {
            isFloat = true
            pos += 1
            if (pos < source.size && (source[pos] == 43 || source[pos] == 45)) { pos += 1 }
            while (pos < source.size && source[pos] >= 48 && source[pos] <= 57) {
                pos += 1
            }
        }
        let numStr = source[start..pos]
        if (isFloat) {
            try {
                let f = Float64.parse(numStr)
                return Some(JsonValue.JsonFloat(f))
            } catch (_: Exception) {
                return None
            }
        } else {
            try {
                let n = Int64.parse(numStr)
                return Some(JsonValue.JsonInt(n))
            } catch (_: Exception) {
                return None
            }
        }
    }

    func parseBool(): ?JsonValue {
        if (source.size - pos >= 4 && source[pos..pos + 4] == "true") {
            pos += 4
            return Some(JsonValue.JsonBool(true))
        }
        if (source.size - pos >= 5 && source[pos..pos + 5] == "false") {
            pos += 5
            return Some(JsonValue.JsonBool(false))
        }
        return None
    }

    func parseNull(): ?JsonValue {
        if (source.size - pos >= 4 && source[pos..pos + 4] == "null") {
            pos += 4
            return Some(JsonValue.JsonNull)
        }
        return None
    }

    func parseObject(): ?JsonValue {
        pos += 1 // skip '{'
        skipWhitespace()
        let map = HashMap<String, JsonValue>()
        if (pos < source.size && source[pos] == 125) {
            pos += 1
            return Some(JsonValue.JsonObject(map))
        }
        while (pos < source.size) {
            skipWhitespace()
            let keyVal = parseString()
            let key = match (keyVal) {
                case Some(JsonValue.JsonString(s)) => s
                case _ => return None
            }
            skipWhitespace()
            if (pos >= source.size || source[pos] != 58) { return None }
            pos += 1
            skipWhitespace()
            let val = parseValue()
            match (val) {
                case Some(v) => map[key] = v
                case None => return None
            }
            skipWhitespace()
            if (pos < source.size && source[pos] == 44) {
                pos += 1
            } else if (pos < source.size && source[pos] == 125) {
                pos += 1
                return Some(JsonValue.JsonObject(map))
            } else {
                return None
            }
        }
        return None
    }

    func parseArray(): ?JsonValue {
        pos += 1 // skip '['
        skipWhitespace()
        let arr = ArrayList<JsonValue>()
        if (pos < source.size && source[pos] == 93) {
            pos += 1
            return Some(JsonValue.JsonArray(arr))
        }
        while (pos < source.size) {
            skipWhitespace()
            let val = parseValue()
            match (val) {
                case Some(v) => arr.add(v)
                case None => return None
            }
            skipWhitespace()
            if (pos < source.size && source[pos] == 44) {
                pos += 1
            } else if (pos < source.size && source[pos] == 93) {
                pos += 1
                return Some(JsonValue.JsonArray(arr))
            } else {
                return None
            }
        }
        return None
    }
}
