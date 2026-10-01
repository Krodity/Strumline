import Foundation

public enum TextDecoding {
    /// Chart and ini files show up as UTF-8 (with or without BOM), UTF-16
    /// (with BOM), or legacy Windows-1252. Decode whichever it is.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian).map { String($0.drop(while: { $0 == "\u{FEFF}" })) } ?? ""
            }
            if bytes[0] == 0xFE && bytes[1] == 0xFF {
                return String(data: data, encoding: .utf16BigEndian).map { String($0.drop(while: { $0 == "\u{FEFF}" })) } ?? ""
            }
        }
        var body = data
        if bytes.count == 3 && bytes == [0xEF, 0xBB, 0xBF] { body = data.dropFirst(3) }
        if let s = String(data: body, encoding: .utf8) { return s }
        return String(data: body, encoding: .windowsCP1252) ?? String(decoding: body, as: UTF8.self)
    }

    /// Removes Unity rich-text tags (`<color=#FF0000>`, `<b>` …) that charters
    /// put in song.ini names.
    public static func stripTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let tag = s[s.index(after: i)..<close].lowercased()
                let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(whereSeparator: { $0 == "=" || $0 == " " }).first.map(String.init) ?? ""
                if ["color", "b", "i", "u", "s", "size", "sup", "sub", "mark", "alpha", "br", "material", "quad", "font", "voffset", "cspace", "mspace", "line-height", "pos", "indent", "noparse", "lowercase", "uppercase", "smallcaps", "align", "margin", "rotate", "nobr", "space", "sprite", "strikethrough", "underline", "link", "style", "gradient", "width"].contains(name) {
                    if name == "br" { out.append(" ") }
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Minimal song.ini reader. Keys are lower-cased; only the first [song]
/// section (or everything, if there are no sections) is kept.
public struct IniFile: Sendable {
    public var values: [String: String] = [:]

    public init(values: [String: String] = [:]) { self.values = values }

    public init(data: Data) {
        let text = TextDecoding.decode(data)
        var section: String? = nil
        var sawSection = false
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                sawSection = true
                continue
            }
            if sawSection && section != "song" { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }
    }

    public subscript(_ key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }

    public func string(_ keys: String...) -> String? {
        for k in keys { if let v = self[k] { return TextDecoding.stripTags(v) } }
        return nil
    }

    public func int(_ keys: String...) -> Int? {
        for k in keys {
            if let v = self[k] {
                if let i = Int(v) { return i }
                if let d = Double(v) { return Int(d) }
            }
        }
        return nil
    }

    public func double(_ keys: String...) -> Double? {
        for k in keys { if let v = self[k], let d = Double(v) { return d } }
        return nil
    }

    public func bool(_ keys: String...) -> Bool? {
        for k in keys {
            if let v = self[k]?.lowercased() {
                if v == "true" || v == "1" || v == "yes" { return true }
                if v == "false" || v == "0" || v == "no" { return false }
            }
        }
        return nil
    }
}
