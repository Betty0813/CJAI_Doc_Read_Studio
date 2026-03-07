package ai_doc_read_studio

import std.collection.*
import std.fs.*
import std.io.*
import ai_doc_read_studio.utils.*

public func parseDocument(filePath: String): String {
    let ext = toLowerAscii(getFileExtension(filePath))

    match (ext) {
        case ".txt" => return parseTxt(filePath)
        case ".md" => return parseMarkdown(filePath)
        case ".docx" => return parseDocx(filePath)
        case ".pdf" => return parsePdf(filePath)
        case _ => throw Exception("Unsupported file extension: ${ext}")
    }
}

func parseTxt(filePath: String): String {
    let bytes = File.readFrom(filePath)
    return safeDecodeBytes(bytes)
}

func parseMarkdown(filePath: String): String {
    let bytes = File.readFrom(filePath)
    return safeDecodeBytes(bytes)
}

func parseDocx(filePath: String): String {
    // Not using std.os/Process. Only TXT/MD supported.
    throw Exception("DOCX parsing requires std.os/Process (not available in this build). Use TXT or MD, or run with Python backend for DOCX/PDF.")
}

func parsePdf(filePath: String): String {
    throw Exception("PDF parsing requires std.os/Process (not available in this build). Use TXT or MD, or run with Python backend for DOCX/PDF.")
}

func getFileExtension(path: String): String {
    match (path.lastIndexOf(".")) {
        case Some(idx) => return path[idx..]
        case None => return ""
    }
}

func escapePath(path: String): String {
    return path.replace("\\", "\\\\").replace("'", "\\'")
}

public func parseMultipleDocuments(documents: ArrayList<DocumentInfo>): String {
    let sb = StringBuilder()
    for (doc in documents) {
        try {
            let content = parseDocument(doc.path)
            sb.append("<document filename=\"${doc.filename}\">\n")
            sb.append(content)
            sb.append("\n</document>\n\n")
        } catch (e: Exception) {
            sb.append("<document filename=\"${doc.filename}\">\n")
            sb.append("ERROR: Could not parse document - ${e.toString()}\n")
            sb.append("</document>\n\n")
        }
    }
    return sb.toString().trimAscii()
}
