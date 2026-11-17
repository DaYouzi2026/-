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
    /// 场景分类，如「开场留人」「干货科普」。老存档没有这个字段，解码时给空串。
    var category: String = ""
    var updatedAt = Date()

    /// 非空白字数，建对象时算一次、之后随 `content` 走。
    ///
    /// 原来 `charCount` 是计算属性：首页每张卡片渲染要扫全文三遍（标签一次、
    /// 估时一次、搜索过滤再一次），长稿子几千字，滚动时全压在主线程上。
    private(set) var chars: Int

    init(id: UUID = UUID(), title: String, content: String,
         category: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.category = category
        self.updatedAt = updatedAt
        self.chars = Script.countChars(content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, category, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        // 老存档没有 category，容错成空串
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? ""
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

extension Script {
    /// 内置场景分类。「全部」只用于筛选栏，不会写进台本。
    static let categories = ["全部", "开场留人", "干货科普", "情感共鸣",
                             "种草带货", "生活记录", "结尾引导"]

    /// 每个分类的品牌色（和聚光灯主题同一套暖色系）
    static let categoryPalette: [String: UInt32] = [
        "开场留人": 0xD97B2C,
        "干货科普": 0x1F6B4F,
        "情感共鸣": 0xB85C8B,
        "种草带货": 0x2E6FB7,
        "生活记录": 0x7A6BBF,
        "结尾引导": 0xC08A2E,
    ]

    /// 旧版（无分类、带编号）内置台本标题，升级迁移时清掉，避免和新库重复。
    static let legacyTitles: Set<String> = [
        "欢迎词", "01 开场｜10秒抓住注意力", "02 科普｜为什么越睡越累",
        "03 种草｜随身咖啡", "04 直播｜开场留人", "05 Vlog｜周末的一天",
        "06 干货｜3个专注力方法", "07 情感｜致焦虑的你", "08 探店｜巷子里的面馆",
        "09 观点｜AI会取代人吗", "10 播客｜片头", "11 门店｜新店开业",
        "12 节日｜祝福口播", "13 结尾｜引导关注", "14 复盘｜我的一周",
    ]
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

    /// 示例库的种子版本。升级时把旧示例换成分类精选库，用户自己的稿子一律不碰。
    private static let samplesSeedKey = "tidanci.samples.seed"
    private static let samplesSeedVersion = 3

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

    /// 老用户升级后本地已有 scripts.json。做两件事：
    /// 1) 清掉旧版内置示例（无分类、且标题在旧清单里）——它们要被精选库替换；
    /// 2) 按标题去重加入精选库。
    /// 用户自己新建、或改名/改内容后的稿子不在这两个条件里，原样保留。
    private func seedNewSamplesIfNeeded() {
        let ud = UserDefaults.standard
        guard ud.integer(forKey: Store.samplesSeedKey) < Store.samplesSeedVersion else { return }

        scripts.removeAll { s in
            s.category.isEmpty && Script.legacyTitles.contains(s.displayTitle)
        }
        let existing = Set(scripts.map { $0.displayTitle })
        for s in Store.samples where !existing.contains(s.displayTitle) {
            scripts.append(s)
        }
        ud.set(Store.samplesSeedVersion, forKey: Store.samplesSeedKey)
        saveScripts()
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
        // ── 开场留人 ──────────────────────────────
        Script(title: "先别划走，这三点能帮你省半年",
               content: """
               先别划走。

               接下来这三点，是我踩了半年坑才总结出来的。

               很多人第一条就做错了，但几乎没人提。

               看完你会明白，为什么你之前一直没效果。

               我们开始。
               """,
               category: "开场留人"),

        Script(title: "如果你也经常感到累，这条是给你看的",
               content: """
               如果你也经常觉得累，不是身体累，是那种心里提不起劲的累。

               那这条，是给你看的。

               我不打算讲大道理，只想跟你说一件事——

               这不怪你。

               往下看，我告诉你为什么。
               """,
               category: "开场留人"),

        Script(title: "大多数人都做反了",
               content: """
               这件事，大多数人都做反了。

               包括以前的我。

               我一直以为，只要够努力、够坚持，就一定能成。

               后来才发现，方向错了，越努力偏得越远。

               今天我用三分钟，把这个坑给你讲清楚。
               """,
               category: "开场留人"),

        Script(title: "一个反问开场",
               content: """
               我问你一个问题。

               如果明天就得离开现在的城市，你最舍不得的会是什么？

               先别急着回答，想三秒。

               很多人想到最后会发现，答案不是钱，也不是工作。

               而是一个很久没联系的人，或者一件一直没做的事。

               这就是今天想聊的。
               """,
               category: "开场留人"),

        // ── 干货科普 ──────────────────────────────
        Script(title: "为什么明明睡够了，还是很累",
               content: """
               你有没有过这种时候，明明睡了八个小时，醒来还是累？

               问题可能不在时长，在时间点。

               人的睡眠是分周期的，一个周期大概九十分钟。

               如果你正好在深睡阶段被闹钟叫醒，就会有那种怎么都睡不醒的感觉。

               试试把睡眠时间调到九十分钟的整数倍，比如七个半小时。

               闹钟不是看几点，是看睡了几个周期。今晚就可以试。
               """,
               category: "干货科普"),

        Script(title: "三个提升专注力的方法",
               content: """
               很多人说自己专注力差，其实是方法不对。分享三个我一直在用的。

               第一，把手机放到看不见的地方。

               注意是看不见，不是倒扣在桌上。只要它在视野里，你的大脑就会分一半注意力给它。

               第二，用二十五分钟计时，只做一件事，时间到了就停。

               哪怕正进入状态也要停，这样大脑才不会抵触。

               第三，开始前先写下这段时间要完成的具体动作。

               比如写完第三段，而不是写稿子。越具体越好。

               这三个不需要意志力，试试就知道。
               """,
               category: "干货科普"),

        Script(title: "收藏了几百条，为什么还是没变",
               content: """
               你收藏夹里是不是躺着几百条有用的内容，一条都没真正用过？

               这不是你的自制力问题，是方法问题。

               收藏的动作，会让大脑误以为已经掌握了，于是就不再行动。

               破解办法只有一句话：看到有用的，立刻做一件最小的事。

               哪怕只是把它写进待办，或者马上试一分钟。

               知识不是收藏进来的，是用出来的。

               从今天起，收藏之前先问自己：这条，我今天能用吗？
               """,
               category: "干货科普"),

        Script(title: "十分钟法则，治拖延",
               content: """
               拖延的时候，我们总想着要把整件事做完，所以迟迟不敢开始。

               试试十分钟法则。

               告诉自己，只做十分钟，到点就停，绝不勉强。

               难的从来不是做完，而是开始。

               一旦开始了十分钟，你会发现事情没想象中那么可怕，很多时候就顺势做下去了。

               就算真的只做了十分钟，也比盯着它焦虑一整天强。

               今天那件一直拖着的事，现在就做十分钟。
               """,
               category: "干货科普"),

        // ── 情感共鸣 ──────────────────────────────
        Script(title: "如果你现在很焦虑，先别急着解决",
               content: """
               如果你现在很焦虑，先别急着解决。

               我想说的是，焦虑很多时候不是因为事情真的有多难，而是因为你在同时想太多件事。

               把它们写下来。

               你会发现，真正紧急的其实只有一两件。

               剩下的，要么以后再说，要么根本不会发生。

               你不需要今天就把人生想清楚，你只需要把眼前这一步走稳。

               慢慢来，真的来得及。
               """,
               category: "情感共鸣"),

        Script(title: "致还在熬的那个人",
               content: """
               如果你正处在最难的那段时间，我想跟你说几句实在话。

               你现在感觉撑不下去，不是因为你不够强，是因为你真的已经扛了很久了。

               别急着否定这段时间。

               很多成长，都是在没人看见的时候悄悄发生的。

               你今天做的每一件小事，都没有白费，只是还没到兑现的时候。

               再撑一撑。

               会好的，虽然慢，但会。
               """,
               category: "情感共鸣"),

        Script(title: "关于慢慢来",
               content: """
               我们总怕自己慢。

               怕同龄人跑得快，怕进度落后，怕来不及。

               可你回头看看，这一路你其实已经走了很远。

               只是你习惯盯着还没走到的地方，忘了看已经走过的。

               有些事就是急不来，它需要在时间里慢慢发酵。

               你只管按时浇水、晒太阳，剩下的交给时间。

               别慌，你有你的节奏。
               """,
               category: "情感共鸣"),

        // ── 种草带货 ──────────────────────────────
        Script(title: "每天靠咖啡续命的，可以试试这个",
               content: """
               如果你每天靠咖啡续命，但又不满意速溶的味道，可以试试这个。

               用法特别简单，撕开、倒进杯子、热水一冲，三十秒搞定。

               味道接近现磨，苦味干净，不酸。

               我一般包里放两颗，下午犯困的时候来一颗，比奶茶清爽，也不容易心慌。

               关键是体积小，出差、通勤都能带。

               下面链接有试吃装，想试的可以看看。
               """,
               category: "种草带货"),

        Script(title: "判断一个东西值不值，看这三点",
               content: """
               买东西前，我一般会问自己三个问题，能帮你少花很多冤枉钱。

               第一，不用它会怎样？

               如果答案是什么都不会，那多半是可买可不买。

               第二，我会用几次？

               一次性的新鲜感，通常不值得那个价格。

               第三，同价位有没有更好的替代？

               花两分钟对比一下，往往能省不少。

               冲动消费的本质，是没给自己留两分钟的冷静时间。
               """,
               category: "种草带货"),

        Script(title: "直播间开场，先把人留住",
               content: """
               欢迎刚进来的朋友，先别急着走。

               停留三十秒，我告诉你今天这场能拿到什么。

               第一，新品的第一波价格，比平时低。

               第二，我会现场演示怎么用，你不用看说明书。

               第三，评论区会抽三位送同款。

               想要哪个，扣在公屏上，我按你们说得最多的先讲。
               """,
               category: "种草带货"),

        // ── 生活记录 ──────────────────────────────
        Script(title: "没什么计划的周末，也挺好",
               content: """
               早上七点半，没设闹钟，自然醒。

               这种感觉很久没有过了。

               烧水、冲咖啡、坐在窗边发了一会儿呆。

               今天没什么计划，就想把周末过慢一点。

               中午去了菜市场，买了西红柿和鸡蛋，做个最简单的番茄炒蛋。

               下午看了半本书，睡着了两次。晚上出门走了走，风很舒服。

               这一天什么都没干，但我觉得很值。
               """,
               category: "生活记录"),

        Script(title: "这周做了三件事，汇报一下",
               content: """
               这周做了三件事，汇报一下。

               第一，把拖了一个月的事终于做完了。

               真正做起来只用了两个小时，之前的焦虑全是白费。

               第二，每天走路三十分钟，坚持了五天，精神状态明显好过之前。

               第三，戒掉了睡前刷手机，改成看书。

               虽然只看了半本，但睡眠深了很多。

               下周继续。改变不用大，能坚持就行。
               """,
               category: "生活记录"),

        Script(title: "早起三十天，我发现了什么",
               content: """
               早起三十天，说点真实的感受。

               最大的变化不是多了时间，而是早上那段时间完全属于自己。

               没有消息，没有打扰，可以安静地想事情。

               我一般会先喝杯水，然后写三句今天最重要的事。

               就这三句，让一整天都不至于乱掉。

               当然也有没做到的时候，周末照样睡到中午。

               没关系，能连着做到，就已经比从前强了。
               """,
               category: "生活记录"),

        // ── 结尾引导 ──────────────────────────────
        Script(title: "看到这里，说明对你有点用",
               content: """
               看到这里，说明这条视频对你多少有点用。

               如果觉得有收获，点个赞，让更多人看到。

               如果你有类似的问题，评论区告诉我，我会挑几个认真回复。

               这个号会持续更新，都是我自己真正在用的方法，不跳舞、不蹭热点。

               想看什么，关注之后慢慢翻。
               """,
               category: "结尾引导"),

        Script(title: "最后说一句",
               content: """
               最后说一句。

               这个方法不难，难的是真的去做。

               大多数人看完就划走了，而你看到了这里，已经赢过很多人。

               不用等准备好了再开始，边做边调整就好。

               如果这条帮到了你，点个赞或者留句话，让我知道有人在看。

               我们下一条见。
               """,
               category: "结尾引导"),

        Script(title: "把这句话送给你",
               content: """
               用一句话收个尾。

               你不需要很厉害才能开始，但需要开始了才会变得厉害。

               别等那个完美的时机，它不会来。

               今天就动手，哪怕只是很小的一步。

               如果你愿意，评论区打个字，就当是给自己立个小小的约定。

               我会一条条看。

               谢谢你看到这里。
               """,
               category: "结尾引导")
    ]
}
