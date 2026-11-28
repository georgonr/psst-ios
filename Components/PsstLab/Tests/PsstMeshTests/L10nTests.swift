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
