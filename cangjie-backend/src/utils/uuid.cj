package ai_doc_read_studio.utils

import std.random.*
import std.collection.*

let HEX_CHARS: Array<Rune> = [
    r'0', r'1', r'2', r'3', r'4', r'5', r'6', r'7',
    r'8', r'9', r'a', r'b', r'c', r'd', r'e', r'f'
]

public func generateUUID(): String {
    let rng = Random()
    let sb = StringBuilder()
    for (i in 0..32) {
        if (i == 8 || i == 12 || i == 16 || i == 20) {
            sb.append('-')
        }
        let idx = rng.nextInt64(16)
        if (i == 12) {
            sb.append('4')
        } else if (i == 16) {
            let v = (rng.nextInt64(4)) + 8
            sb.append(HEX_CHARS[v])
        } else {
            sb.append(HEX_CHARS[idx])
        }
    }
    return sb.toString()
}
