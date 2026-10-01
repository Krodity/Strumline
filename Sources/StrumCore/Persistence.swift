import Foundation

/// Loading saved settings across app versions.
public enum SavedState {
    /// Decodes JSON `data` on top of `defaults`. Keys the save doesn't have
    /// (fields added in a later version, nested structs included) keep their
    /// default values, and a key that no longer decodes (a renamed enum case,
    /// a changed type) falls back to its default instead of discarding the
    /// whole save. Returns nil only if `data` isn't a JSON object.
    public static func decode<T: Codable>(_ data: Data, over defaults: T) -> T? {
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              let def = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        var merged = merge(def, saved)
        // Each failing key is reset to its default and decoding retried.
        for _ in 0..<64 {
            guard let d = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
            do {
                return try JSONDecoder().decode(T.self, from: d)
            } catch let error as DecodingError {
                let path = codingPath(of: error).map(\.stringValue)
                guard !path.isEmpty, reset(&merged, path: path, from: def) else { return nil }
            } catch {
                return nil
            }
        }
        return nil
    }

    /// `saved` over `base`, recursing into nested objects.
    static func merge(_ base: [String: Any], _ saved: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in saved {
            if let b = base[k] as? [String: Any], let s = v as? [String: Any] { out[k] = merge(b, s) } else { out[k] = v }
        }
        return out
    }

    static func codingPath(of e: DecodingError) -> [CodingKey] {
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return c.codingPath
        case .keyNotFound(let k, let c): return c.codingPath + [k]
        @unknown default: return []
        }
    }

    /// Replaces the value at `path` with the default's (or removes it when
    /// there is none). False if nothing could be changed.
    static func reset(_ obj: inout [String: Any], path: [String], from def: [String: Any]?) -> Bool {
        guard let key = path.first else { return false }
        if path.count == 1 {
            // Defaults always decode, so the retry loop can't spin on this.
            if def?[key] == nil && obj[key] == nil { return false }
            obj[key] = def?[key]
            return true
        }
        guard var child = obj[key] as? [String: Any] else {
            // The path runs through something that isn't an object: reset it whole.
            guard obj[key] != nil || def?[key] != nil else { return false }
            obj[key] = def?[key]
            return true
        }
        let changed = reset(&child, path: Array(path.dropFirst()), from: def?[key] as? [String: Any])
        obj[key] = child
        if !changed, let d = def?[key] { obj[key] = d; return true }
        return changed
    }
}
