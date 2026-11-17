import Foundation
import Combine

struct Script: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// 正文一变就重算字数（见下面的 `chars`）
    var content: String {
        didSet {
            if content != oldValue { chars = Script.countChars(content) }
        }
    }
    var updatedAt = Date()

    /// 非空白字数，建对象时算一次、之后随 `content` 走。
    ///
    /// 原来 `charCount` 是计算属性：首页每张卡片渲染要扫全文三遍（标签一次、
    /// 估时一次、搜索过滤再一次），长稿子几千字，滚动时全压在主线程上。
    private(set) var chars: Int

    init(id: UUID = UUID(), title: String, content: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.updatedAt = updatedAt
        self.chars = Script.countChars(content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        // 老存档里没有字数，现算一遍，不信磁盘上的值
        chars = Script.countChars(content)
    }

    static func countChars(_ s: String) -> Int {
        s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未命名台本" : t
    }

    var preview: String {
        // 只要开头 44 个字，没必要把整篇稿子替换一遍换行再截断
        let head = String(content.prefix(160))
        let s = head.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 44 ? String(s.prefix(44)) + "…" : s
    }

    var charCount: Int { chars }

    var durationText: String { Estimate.text(chars) }

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

    /// 示例库的种子版本。用户升级后把新增的示例补进来（按标题去重，不覆盖用户已改过的）。
    private static let samplesSeedKey = "tidanci.samples.seed"
    private static let samplesSeedVersion = 2

    func loadScripts() {
        guard let data = try? Data(contentsOf: scriptsFile),
              let list = try? JSONDecoder().decode([Script].self, from: data) else {
            scripts = Store.samples
            UserDefaults.standard.set(Store.samplesSeedVersion, forKey: Store.samplesSeedKey)
            saveScripts()
            return
        }
        scripts = list
        seedNewSamplesIfNeeded()
    }

    /// 老用户升级 App 后本地已有 scripts.json，不会重新走 samples。
    /// 这里按版本把新示例追加进去，同名（用户可能已改过）一律跳过。
    private func seedNewSamplesIfNeeded() {
        let ud = UserDefaults.standard
        guard ud.integer(forKey: Store.samplesSeedKey) < Store.samplesSeedVersion else { return }
        let existing = Set(scripts.map { $0.displayTitle })
        var added = false
        for s in Store.samples where !existing.contains(s.displayTitle) {
            scripts.append(s)
            added = true
        }
        ud.set(Store.samplesSeedVersion, forKey: Store.samplesSeedKey)
        if added { saveScripts() }
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

    /// 内置示例台本库。新用户首次打开即可看到；老用户升级后由 seedNewSamplesIfNeeded 补齐。
    /// 每条都是可直接念的口播稿，覆盖常见拍摄场景，标题前的序号方便按顺序找。
    static let samples: [Script] = [
        Script(title: "欢迎词",
               content: """
               大家好，欢迎来到我的频道。今天是第一期，先说清楚这个号是干什么的——我不讲大道理，只分享我真正在用、真的觉得有用的东西。

               如果你也喜欢这种不绕弯子的内容，点个关注，我们慢慢聊。
               """),

        Script(title: "01 开场｜10秒抓住注意力",
               content: """
               先别划走，这条能帮你省下至少三个小时。

               我今天要说的这个方法，是我自己踩了半年坑才总结出来的，特别简单，但大多数人不知道。看完你会明白，为什么你之前一直没效果。

               好，我们开始。
               """),

        Script(title: "02 科普｜为什么越睡越累",
               content: """
               你有没有过这种时候，明明睡了八个小时，醒来还是累？

               问题可能不在时长，在时间点。人的睡眠是分周期的，一个周期大概九十分钟。如果你正好在深睡阶段被闹钟叫醒，就会有那种怎么都睡不醒的感觉。

               试试把睡眠时间调到九十分钟的整数倍，比如七个半小时，或者六个小时。闹钟不是看几点，是看睡了几个周期。今晚就可以试。
               """),

        Script(title: "03 种草｜随身咖啡",
               content: """
               如果你每天靠咖啡续命，但又不满意速溶的味道，可以试试这个。

               用法特别简单，撕开、倒进杯子、热水一冲，三十秒搞定。味道接近现磨，苦味干净，不酸。我一般包里放两颗，下午犯困的时候来一颗，比奶茶清爽，也不容易心慌。

               关键是体积小，出差、通勤都能带。下面链接有试吃装，想试的可以看看。
               """),

        Script(title: "04 直播｜开场留人",
               content: """
               欢迎刚进来的朋友，先别急着走，停留三十秒，我告诉你今天这场能拿到什么。

               今天准备了三样东西：第一，新品的第一波价格，比平时低；第二，我会现场演示怎么用，你不用看说明书；第三，评论区会抽三位送同款。

               想要哪个，扣在公屏上，我按你们说得最多的先讲。
               """),

        Script(title: "05 Vlog｜周末的一天",
               content: """
               早上七点半，没设闹钟，自然醒。这种感觉很久没有过了。

               烧水、冲咖啡、坐在窗边发了一会儿呆。今天没什么计划，就想把周末过慢一点。

               中午去了菜市场，买了西红柿和鸡蛋，做个最简单的番茄炒蛋。下午看了半本书，睡着了两次。晚上出门走了走，风很舒服。

               这一天什么都没干，但我觉得很值。
               """),

        Script(title: "06 干货｜3个专注力方法",
               content: """
               很多人说自己专注力差，其实是方法不对。分享三个我一直在用的。

               第一，把手机放到看不见的地方。注意是看不见，不是倒扣在桌上——只要它在视野里，你的大脑就会分一半注意力给它。

               第二，用二十五分钟计时，只做一件事，时间到了就停。哪怕正进入状态也要停，这样大脑才不会抵触。

               第三，开始前先写下这段时间要完成的具体动作，越具体越好，比如「写完第三段」，而不是「写稿子」。

               这三个不需要意志力，试试就知道。
               """),

        Script(title: "07 情感｜致焦虑的你",
               content: """
               如果你现在很焦虑，先别急着解决。

               我想说的是，焦虑很多时候不是因为事情真的有多难，而是因为你在同时想太多件事。把它们写下来，你会发现真正紧急的其实只有一两件。

               剩下的，要么以后再说，要么根本不会发生。你不需要今天就把人生想清楚，你只需要把眼前这一步走稳。

               慢慢来，真的来得及。
               """),

        Script(title: "08 探店｜巷子里的面馆",
               content: """
               这家面馆藏在老巷子最里面，没有招牌，只有一块手写的小牌子。

               中午十二点去，已经排了二十分钟。点了一碗牛肉面，汤是那种熬了很久的清汤，不厚重，但很鲜。牛肉给得实在，炖得软烂。面条是手工的，有嚼劲。

               老板话不多，端上来就一句「趁热吃」。人均二十几块，想吃面的可以来，但别赶时间。
               """),

        Script(title: "09 观点｜AI会取代人吗",
               content: """
               很多人问我，AI 这么强，会不会取代人？

               我的答案是，它不会取代你，但会取代那些不用它的人。AI 能写代码、能画图、能写文案，但它不知道你要什么，也不知道什么东西是「对的」。

               判断力，才是这个时代最值钱的东西。所以与其焦虑，不如今天就用起来，哪怕只是让它帮你改一封邮件。用起来，你就已经领先了。
               """),

        Script(title: "10 播客｜片头",
               content: """
               欢迎收听这一期。

               今天聊一个我最近反复在想的问题：我们到底是怎么做决定的？表面上看，我们以为自己是理性的，但事实上，大多数决定都是情绪先到，理由后补。

               这一期我会结合几个真实的例子，说说这个偏差是怎么影响我们的。准备好了，我们开始。
               """),

        Script(title: "11 门店｜新店开业",
               content: """
               我们新店开业了，就在原来那家的隔壁，面积大了一倍，位置也更好找。

               新品类加了几个，都是这段时间大家问得最多的。开业前三天有几样活动：第一，到店就送小样；第二，消费满额直接减，不是券，是当场减；第三，老客户带新客户，两个人都有礼。

               地址在评论区，导航搜店名就能到。这几天人会比较多，建议错峰来。
               """),

        Script(title: "12 节日｜祝福口播",
               content: """
               又快到中秋了。今年好像过得特别快，一转眼大半年就过去了。

               借这条视频，想对看到的人说一句：中秋快乐。不管你现在是在家人身边，还是一个人，希望这一轮月亮都能让你觉得，生活还是有盼头的。

               记得给家里打个电话，不用说什么大事，就问问吃饭了没。
               """),

        Script(title: "13 结尾｜引导关注",
               content: """
               看到这里，说明这条视频对你多少有点用。

               如果觉得有收获，点个赞，让更多人看到。如果你有类似的问题，评论区告诉我，我会挑几个认真回复。

               这个号会持续更新，都是我自己真正在用的方法，不跳舞、不蹭热点。想看什么，关注之后慢慢翻。
               """),

        Script(title: "14 复盘｜我的一周",
               content: """
               这周做了三件事，汇报一下。

               第一，把拖了一个月的事终于做完了，发现真正做起来只用了两个小时，之前的焦虑全是白费。

               第二，每天走路三十分钟，坚持了五天，精神状态明显好过之前。

               第三，戒掉了睡前刷手机，改成看书，虽然只看了半本，但睡眠深了很多。

               下周继续。改变不用大，能坚持就行。
               """)
    ]
}
