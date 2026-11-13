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
        Script.stamp.string(from: updatedAt)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

struct WorkItem: Identifiable, Hashable {
    let url: URL
    /// 体积和创建时间在扫目录时一次取好。
    ///
    /// 以前 `size` / `date` 是计算属性，每读一次就 stat 一次文件。作品页 6 个格子 ×
    /// 两个属性、设置页再遍历一遍算总用量 —— 一次渲染能打出几十次文件系统调用，
    /// 全发生在主线程上。列表一滑就掉帧，还平白耗电。
    let bytes: Int64
    let created: Date

    init(url: URL, bytes: Int64? = nil, created: Date? = nil) {
        self.url = url
        if let b = bytes, let c = created {
            self.bytes = b
            self.created = c
        } else {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            self.bytes = bytes ?? Int64(v?.fileSize ?? 0)
            self.created = created ?? v?.creationDate ?? Date()
        }
    }

    var id: URL { url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    var size: Int64 { bytes }

    var date: Date { created }

    var sizeText: String {
        let mb = Double(size) / 1048576.0
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }

    var dateText: String {
        WorkItem.stamp.string(from: date)
    }

    /// DateFormatter 初始化一次要几百微秒，列表里每格每帧新建一个就是纯浪费。
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
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
        // 作品动辄几百 MB 到几 GB。进 iCloud 备份没有意义，还会把用户的空间和
        // 新机恢复时间一起吃掉 —— 明确排除掉。
        var dir = worksDir
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
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
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let list = (try? fm.contentsOfDirectory(at: worksDir,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        let filtered = list.filter { $0.pathExtension.lowercased() == "mp4" || $0.pathExtension.lowercased() == "mov" }
        // 一次把元数据带上，后面列表怎么重绘都不再碰文件系统
        works = filtered.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return WorkItem(url: url,
                            bytes: Int64(v?.fileSize ?? 0),
                            created: v?.creationDate ?? Date())
        }.sorted { $0.date > $1.date }
    }

    func newWorkURL() -> URL {
        worksDir.appendingPathComponent("拍_\(Store.stamp.string(from: Date())).mp4")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

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
