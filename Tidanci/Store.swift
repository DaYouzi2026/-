import Foundation
import Combine

struct Script: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var content: String
    var updatedAt = Date()

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未命名台本" : t
    }

    var preview: String {
        let s = content.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 44 ? String(s.prefix(44)) + "…" : s
    }

    var charCount: Int {
        content.filter { !$0.isWhitespace && !$0.isNewline }.count
    }

    var durationText: String { Estimate.text(charCount) }

    var updatedText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: updatedAt)
    }
}

struct WorkItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    var size: Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    var date: Date {
        let v = try? url.resourceValues(forKeys: [.creationDateKey])
        return v?.creationDate ?? Date()
    }

    var sizeText: String {
        let mb = Double(size) / 1048576.0
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

final class Store: ObservableObject {
    @Published var scripts: [Script] = []
    @Published var works: [WorkItem] = []

    private let fm = FileManager.default

    var docDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var worksDir: URL {
        docDir.appendingPathComponent("works", isDirectory: true)
    }

    private var scriptsFile: URL {
        docDir.appendingPathComponent("scripts.json")
    }

    init() {
        try? fm.createDirectory(at: worksDir, withIntermediateDirectories: true)
        loadScripts()
        refreshWorks()
    }

    // MARK: - 台本

    func loadScripts() {
        guard let data = try? Data(contentsOf: scriptsFile) else {
            scripts = Store.samples
            saveScripts()
            return
        }
        if let list = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = list
        } else {
            scripts = Store.samples
        }
    }

    func saveScripts() {
        do {
            let data = try JSONEncoder().encode(scripts)
            try data.write(to: scriptsFile, options: .atomic)
        } catch {
            print("保存台本失败：\(error)")
        }
    }

    func upsert(_ script: Script) {
        var s = script
        s.updatedAt = Date()
        if let i = scripts.firstIndex(where: { $0.id == s.id }) {
            scripts[i] = s
        } else {
            scripts.insert(s, at: 0)
        }
        saveScripts()
    }

    func delete(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        saveScripts()
    }

    // MARK: - 作品

    func refreshWorks() {
        let list = (try? fm.contentsOfDirectory(at: worksDir,
                                                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        let filtered = list.filter { $0.pathExtension.lowercased() == "mp4" || $0.pathExtension.lowercased() == "mov" }
        works = filtered.map { WorkItem(url: $0) }.sorted { $0.date > $1.date }
    }

    func newWorkURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return worksDir.appendingPathComponent("拍_\(f.string(from: Date())).mp4")
    }

    func deleteWork(_ item: WorkItem) {
        try? fm.removeItem(at: item.url)
        refreshWorks()
    }

    static let samples: [Script] = [
        Script(title: "欢迎词",
               content: """
               大家好，欢迎来到我的频道。今天我们来聊一个很多人都在问的问题：人工智能到底会不会取代人类的工作。

               我个人的观点是，它不会取代人，但是会取代那些只会重复劳动的人。所以与其担心被替代，不如先学会怎么用它。

               接下来我会用三个具体的例子，告诉你普通人应该从哪里开始。
               """)
    ]
}
