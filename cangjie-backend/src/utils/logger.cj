package ai_doc_read_studio.utils

import std.time.*
import std.fs.*
import std.sync.*
import std.collection.*

public enum LogLevel {
    | DEBUG
    | INFO
    | WARNING
    | ERROR

    public func toInt(): Int64 {
        match (this) {
            case DEBUG => 0
            case INFO => 1
            case WARNING => 2
            case ERROR => 3
        }
    }

    public func toString(): String {
        match (this) {
            case DEBUG => "DEBUG"
            case INFO => "INFO"
            case WARNING => "WARN"
            case ERROR => "ERROR"
        }
    }
}

public class Logger {
    var level: LogLevel = LogLevel.INFO
    var logFile: ?String = None
    let mu = Mutex()

    public init(level!: LogLevel = LogLevel.INFO, logFile!: ?String = None) {
        this.level = level
        this.logFile = logFile
    }

    public func setLevel(l: LogLevel): Unit {
        this.level = l
    }

    func shouldLog(msgLevel: LogLevel): Bool {
        return msgLevel.toInt() >= this.level.toInt()
    }

    func formatMessage(lvl: LogLevel, msg: String, fields: Array<(String, String)>): String {
        let now = DateTime.now().toString()
        let sb = StringBuilder()
        sb.append("${now} [${lvl.toString()}] ${msg}")
        for ((k, v) in fields) {
            sb.append(" ${k}=${v}")
        }
        return sb.toString()
    }

    public func log(lvl: LogLevel, msg: String, fields!: Array<(String, String)> = []): Unit {
        if (!shouldLog(lvl)) { return }
        let formatted = formatMessage(lvl, msg, fields)
        synchronized(mu) {
            println(formatted)
            match (logFile) {
                case Some(path) =>
                    try {
                        let line = (formatted + "\n").toArray()
                        var existing: Array<Byte> = []
                        try { existing = File.readFrom(path) } catch (_: Exception) { }
                        var out = ArrayList<Byte>()
                        for (b in existing) { out.add(b) }
                        for (b in line) { out.add(b) }
                        File.writeTo(path, collectArray(out))
                    } catch (_: Exception) {}
                case None => ()
            }
        }
    }

    public func debug(msg: String, fields!: Array<(String, String)> = []): Unit {
        log(LogLevel.DEBUG, msg, fields: fields)
    }

    public func info(msg: String, fields!: Array<(String, String)> = []): Unit {
        log(LogLevel.INFO, msg, fields: fields)
    }

    public func warning(msg: String, fields!: Array<(String, String)> = []): Unit {
        log(LogLevel.WARNING, msg, fields: fields)
    }

    public func error(msg: String, fields!: Array<(String, String)> = []): Unit {
        log(LogLevel.ERROR, msg, fields: fields)
    }
}

// 全局 logger 实例
public let logger = Logger()
