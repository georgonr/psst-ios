// PSST (D99): every LoRa text exists in English and Slovak, and every key used in the code is defined.
import Foundation
@testable import PsstMesh
import Testing

@Suite struct L10nTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func table(_ lang: String) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Sources/PsstMesh/Resources/\(lang).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func englishAndSlovakHaveTheSameKeysAndPlaceholders() throws {
        let en = try table("en"), sk = try table("sk")
        #expect(Set(en.keys) == Set(sk.keys))
        let ph = try NSRegularExpression(pattern: #"%\d\$@|\{app\}"#)
        func placeholders(_ s: String) -> [String] { ph.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted() }
        for (k, v) in en { #expect(placeholders(v) == placeholders(sk[k] ?? ""), "placeholders differ: \(k)") }
    }

    @Test func allKeysUsedInCodeExist() throws {
        let en = try table("en")
        let dirs = ["Sources", "../../ElementX/Sources/Screens/RoomDetailsScreen/View", "../../ElementX/Sources/FlowCoordinators"]
        let re = try NSRegularExpression(pattern: #"psstTr\("([a-z0-9_]+)""#)
        var used = Set<String>()
        for d in dirs {
            let dir = Self.root.appendingPathComponent(d)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in e where f.pathExtension == "swift" {
                let s = try String(contentsOf: f, encoding: .utf8)
                for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { used.insert(String(s[Range(m.range(at: 1), in: s)!])) }
            }
        }
        #expect(used.count > 80)
        #expect(used.subtracting(en.keys).isEmpty, "missing: \(used.subtracting(en.keys).sorted())")
        // a format with arguments renders them
        #expect(psstTr("lora_sent_parts", 2, 3).contains("2/3"))
    }
}

@Suite struct NoHardcodedSlovakTests {
    /// UI and client code must not contain Slovak string literals — they would show in the English UI (D99).
    @Test func noSlovakLiteralsOutsideTheStringsFiles() throws {
        let root = L10nTests.root
        let dirs = ["Sources/PsstLabUI", "Sources/PsstMesh", "Sources/PsstMeshBLE", "../../ElementX/Sources/Screens/RoomDetailsScreen/View/PsstLabLoRaSection.swift"]
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        let slovak = try NSRegularExpression(pattern: "[áäčďéíĺľňóôŕšťúýžÁČĎÉÍĽŇÓŠŤÚÝŽ]")
        var hits: [String] = []
        for d in dirs {
            let url = root.appendingPathComponent(d)
            let files: [URL] = url.pathExtension == "swift" ? [url]
                : (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
            for f in files {
                for (i, line) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    for m in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        let lit = String(line[Range(m.range, in: line)!])
                        if slovak.firstMatch(in: lit, range: NSRange(lit.startIndex..., in: lit)) != nil { hits.append("\(f.lastPathComponent):\(i + 1) \(lit)") }
                    }
                }
            }
        }
        #expect(hits.isEmpty, "hardcoded Slovak: \(hits)")
    }

    /// Any word-bearing literal passed directly to a SwiftUI text API must go through psstTr (catches Slovak without
    /// diacritics like "Uzly" too). Allowed: units / numbers / interpolation only, "LoRa" and the app name.
    @Test func viewTextsAreLocalized() throws {
        let root = L10nTests.root
        let files = ["Sources/PsstLabUI/LoRaViews.swift", "Sources/PsstLabUI/QRScannerView.swift",
                     "../../ElementX/Sources/Screens/RoomDetailsScreen/View/PsstLabLoRaSection.swift"]
        let call = try NSRegularExpression(pattern: #"(?:Text|Label|Button|navigationTitle|LabeledContent|Section|TextField|accessibilityLabel)\(\s*"((?:[^"\\\n]|\\.)*)""#)
        var hits: [String] = []
        for f in files {
            for (i, line) in try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8).components(separatedBy: "\n").enumerated() {
                for m in call.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    var lit = String(line[Range(m.range(at: 1), in: line)!])
                    lit = lit.replacingOccurrences(of: #"\\\([^)]*\)+"#, with: "", options: .regularExpression)
                    for allowed in ["psstlab1", "LoRa", "dBm", "SNR", "%"] { lit = lit.replacingOccurrences(of: allowed, with: "") }
                    if lit.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil { hits.append("\(f.split(separator: "/").last!):\(i + 1) \(lit)") }
                }
            }
        }
        #expect(hits.isEmpty, "unlocalized view texts: \(hits)")
    }
}
