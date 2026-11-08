import Foundation
import Combine

// MARK: - 拼音

/// 用系统自带的 CFStringTransform 取拼音，不需要外部数据表。
enum Py {
    private static var cache: [Character: [String]] = [:]

    static func syllables(_ ch: Character) -> [String] {
        if let c = cache[ch] { return c }
        let s = String(ch)
        let isHan = s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        guard isHan else {
            cache[ch] = []
            return []
        }
        let m = NSMutableString(string: s)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        let t = (m as String).lowercased()
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "'" }).map(String.init)
        cache[ch] = parts
        return parts
    }

    private static let initials: [String] = [
        "zh", "ch", "sh",
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
        "j", "q", "x", "r", "z", "c", "s", "y", "w"
    ]

    static func split(_ syl: String) -> (String, String) {
        for i in initials where syl.hasPrefix(i) {
            return (i, String(syl.dropFirst(i.count)))
        }
        return ("", syl)
    }

    /// 容易混的声母分组（平翘舌、n/l、f/h、b/p、d/t、g/k）
    static func group(_ ini: String) -> Int {
        switch ini {
        case "zh", "z", "j": return 1
        case "ch", "c", "q": return 2
        case "sh", "s", "x": return 3
        case "n", "l", "r": return 4
        case "f", "h": return 5
        case "b", "p": return 6
        case "d", "t": return 7
        case "g", "k": return 8
        case "": return -1
        default: return -2
        }
    }

    static func stem(_ fin: String) -> String {
        if fin.hasSuffix("ng") { return String(fin.dropLast(2)) }
        if fin.hasSuffix("n") { return String(fin.dropLast()) }
        return fin
    }

    /// 两个无调音节的代价：0 = 完全一样，100 = 毫不相干
    static func sylCost(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let (ia, fa) = split(a)
        let (ib, fb) = split(b)
        let ga = group(ia), gb = group(ib)
        let sameI = ia == ib
        let confI = !sameI && ga == gb && ga > 0
        let sameF = fa == fb
        let nearF = !sameF && stem(fa) == stem(fb)
        if sameF {
            return confI ? 28 : (sameI ? 55 : 62)
        }
        if nearF {
            return confI ? 45 : 72
        }
        if sameI { return 80 }
        return 100
    }
}

// MARK: - 台本预处理

struct PreparedScript {
    let text: String
    /// 只留汉字 / 英数，标点空白全去掉
    let norm: [Character]
    /// norm[i] 在 text 里的 UTF-16 偏移，用来给 AttributedString 划「已读」区间
    let offsets: [Int]
    /// 每个字的全部读音（多音字会有多个）
    let pinyins: [[String]]
    /// 每个自然句在 norm 里的起始下标
    let sentenceStarts: [Int]

    init(text: String) {
        self.text = text
        var n: [Character] = []
        var o: [Int] = []
        var starts: [Int] = []
        var pending = true
        var i16 = 0
        for ch in text {
            if PreparedScript.keep(ch) {
                if pending {
                    starts.append(n.count)
                    pending = false
                }
                n.append(ch)
                o.append(i16)
            } else if PreparedScript.isBreak(ch) {
                pending = true
            }
            i16 += String(ch).utf16.count
        }
        norm = n
        offsets = o
        pinyins = n.map { Py.syllables($0) }
        sentenceStarts = starts
    }

    static func keep(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first else { return false }
        let v = u.value
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        if v >= 0x3400 && v <= 0x4DBF { return true }
        if v >= 0x41 && v <= 0x5A { return true }
        if v >= 0x61 && v <= 0x7A { return true }
        if v >= 0x30 && v <= 0x39 { return true }
        return false
    }

    /// 句读符号，用来断句
    static func isBreak(_ c: Character) -> Bool {
        return "。！？!?；;\n\r，,".contains(c)
    }

    var isEmpty: Bool { norm.isEmpty }

    /// 游标附近的一批短句（按句读切开），拿去当语音识别的提示词。
    ///
    /// 读稿是「已知内容」场景：把接下来要念的原句喂给 SFSpeechRecognizer，
    /// 它会优先往这些词上靠，同音字（在/再、是/事）和人名地名会准很多。
    /// 只取游标附近，不整篇塞——提示词越杂，反而越容易把远处的词听进来。
    func nearbySentences(cursor: Int, back: Int = 2, ahead: Int = 12) -> [String] {
        let heads = sentenceStarts
        guard !heads.isEmpty, !norm.isEmpty else { return [] }
        let n = norm.count
        let c = min(max(cursor, 0), n)
        var idx = 0
        for (k, h) in heads.enumerated() where h <= c { idx = k }
        let lo = max(0, idx - back)
        let hi = min(heads.count - 1, idx + ahead)
        guard lo <= hi else { return [] }
        var out: [String] = []
        for k in lo...hi {
            let a = heads[k]
            let b = (k + 1 < heads.count) ? heads[k + 1] : n
            guard b > a, b - a >= 2 else { continue }
            out.append(String(norm[a..<b]))
        }
        return out
    }
}

// MARK: - 对齐

/// 台本约束下的模糊对齐。
///
/// ── v1.7 重写（只保留一条通道）───────────────────────────────
///
/// 旧版有两条病灶，正好对应用户的两个反馈：
///   ① 「读稿子以外的话，它还是跳到下一句去了」
///   ② 「跳下去以后再读上一句，它不回头，一直往后面放」
///
/// ① 来自「句子锚点」通道：拿识别尾部 6 个字去比每一句的开头，同音给半分，
///    阈值 0.70 意味着「3 个字完全一样 + 3 个字读音像」就能通过。随口一句
///    「然后我们开始吧」很容易撞上前面某句的开头。而且它排在常规对齐之前跑。
/// ② 同一条通道只往前找，常规对齐又只回看 20 字，于是「读回上一句」在代码里
///    根本不存在。
///
/// 现在只有一条通道：自由起点编辑距离 DP，一次扫描 [游标-240, 游标+win]。
/// 每个候选位置同时算出三个量：
///   raw = 代价 / (100 × 有效对齐字数)  —— 对齐上的那部分像不像
///   eff = 有效对齐字数                —— 这一跳有多少证据支撑
///   run = 末尾连续同音的长度            —— 是不是在整句整句地念
///
/// 三条硬规则（都写在 pass() 里）：
///   - 证据少就不许走远：只说 2 个字最多挪 2 格；
///   - 跳得越远要求越像，往前 20 字以上必须落在句首附近；
///   - 往回退不额外加严，但同样要「真的在念上一段」。
final class Follower {
    private let script: PreparedScript
    private(set) var cursor = 0

    private var stall = 0
    private var creeped = 0
    private var grow = 0
    private var lastSpokenLen = 0
    private var lastMatchAt = Date()
    private(set) var lastScore: Float = 1
    private(set) var lastStep = 0

    /// 最近一次大步前进（>40 字）的时刻。两秒半之内再来一次大步前进就不认——
    /// 连续两跳说明它是在「顺着重复的字往下滑」，不是在跟着人念。
    private var bigJumpAt = Date.distantPast
    /// 大步跳转之前的游标。跳过去以后连着十几帧读不上，就退回这里。
    private var jumpBack: Int? = nil
    /// 这一跳落在哪儿。五秒后如果只从落点往前挪了不到十五个字，就判定跳错了。
    private var jumpTo = 0
    private var jumpBackDeadline = Date.distantPast
    /// 被判成「跳错了」的落点。
    ///
    /// v6：没有这个记录，回退之后会立刻又选中同一个错地方（证据一模一样），
    /// 于是「跳过去 → 五秒后退回来 → 再跳过去」，用户看到的就是画面来回抽。
    /// 现在这一段二十秒内不再作为候选。
    private var badLanding: Int? = nil
    private var badAt = Date.distantPast

    /// 插入 / 漏一个字的代价
    private let GAP = 45
    /// 算「连成串」时允许的读音差：只认同音和极近音
    private let GOOD = 32
    /// 往回找多远：够覆盖一到两句，重读上一句能拉回来
    private let BACK = 240

    /// ── v1.13：跨度硬上限 ─────────────────────────────────────
    /// 「识别乱跑、直接跑到文末」的机器原因：窗口在卡住时会一路放大到 1000 字，
    /// 而「末尾连续对上 7 个字」这条无条件放行，于是台本里任何一处重复的句子
    /// （口号、产品名、开场白）都能把光标一次性拽出几百字。到那儿以后再念原文
    /// 也对不上，只能关掉重来。
    ///
    /// 现在给「一次最多挪多远」定死：
    ///   - 普通情况一步不超过 90 字（约两句）；
    ///   - 只有整句原样念出来（末尾连续 9 字以上全同音 + 落在句首）才允许 300 字，
    ///     这是给「跳到下一段接着读」留的口子；
    ///   - 超过 300 字一律不认——那已经不是跟读，是跑飞了。
    private let MAX_STEP = 90
    private let MAX_STEP_FAR = 300

    private var d: [Int] = []
    private var prev: [Int] = []
    private var run: [Int] = []
    private var prevRun: [Int] = []
    private var ins: [Int] = []
    private var prevIns: [Int] = []
    /// 沿最优路径「读音对得上」的字数（不要求连续），比平均代价更能扛零散错字
    private var good: [Int] = []
    private var prevGood: [Int] = []

    /// 句子起点，构造时取一次。别写成计算属性——每个候选位置都会查一次，
    /// 计算属性会每次都复制一遍数组，直接把这个函数拖成性能瓶颈。
    private let heads: [Int]

    init(_ s: PreparedScript) {
        script = s
        heads = s.sentenceStarts
    }

    private var n: Int { script.norm.count }

    // MARK: 门槛

    /// 探针越短越容易碰巧对上，阈值必须越**严**（旧版写反了：短探针反而放得最松）。
    /// 参考量级：14 字里错 3 个字（代价 80）≈ 0.17；错 5 个 ≈ 0.29。
    private func thFor(_ k: Int) -> Float {
        if k >= 12 { return 0.38 }
        if k >= 9 { return 0.34 }
        if k >= 7 { return 0.30 }
        if k >= 5 { return 0.26 }
        return 0.20
    }

    /// 这个候选位置该不该放行
    private func pass(_ jump: Int, _ raw: Float, _ runLen: Int, _ eff: Int, _ good: Int) -> Bool {
        let dist = abs(jump)
        let th = thFor(eff)

        // 第零道：跨度硬上限。这一道排在所有「放行」之前——哪怕是整句全对上了，
        // 也不许一步跳到几百字以外。少了它，台本里重复的开场白就会把画面甩到文末。
        if dist > MAX_STEP_FAR { return false }

        // 硬证据：末尾连续对上 5 个字以上。识别器可能把前面一截听成乱码，
        // 但「刚说出口的这几个字」它几乎不会错——比平均代价可靠得多。
        // 少了这两条，光标一落后十几格就再也追不回来（就是「读了不翻页」）。
        if runLen >= 5 && dist <= 24 { return true }
        // 原来这里是「runLen >= 7 无条件放行」：7 个字全同音确实很硬，但台本里
        // 「大家好，我是XXX」这种重复句照样能全中，于是它成了乱跑的主要出口。
        if runLen >= 7 && dist <= 60 { return true }
        // 命中率高：十几个字里有四分之三同音，位置基本不会错
        if eff >= 8 && good >= (eff * 3) / 4 && dist <= 16 { return true }

        // 第一道：证据长度上限。这几个字最多能证明光标走了多远。
        // 「只说两个字就把画面拽走二十格」就是漏了这一道。
        var maxD: Int
        if eff <= 3 { maxD = 3 }
        else if eff <= 5 { maxD = 8 }
        else if eff <= 7 { maxD = 20 }
        else if eff <= 9 { maxD = 45 }
        else { maxD = MAX_STEP }

        // 只念关键词时探针天然短（「不会取代人」五个字），但它是原样念出来的：
        // 读音几乎全中且连成串，这种可以跳远。随口说的话串不起来。
        // 原来这里直接放成 Int.max，等于给「重复短句」开了一条通往文末的路。
        if dist > maxD && eff >= 4 && raw <= 0.12 && runLen >= eff {
            maxD = runLen >= 9 ? MAX_STEP_FAR : MAX_STEP
        }
        if dist > maxD { return false }

        if dist <= 6 { return raw <= th }
        if jump > 0 {
            if dist <= 20 { return raw <= th * 0.84 }
            // 跳读是从下一句的开头读起的，所以对齐的**起点**应该落在句首。
            // 不能只看终点：念了 6 个字，终点就在句首后面 6 个字
            let end = jump + cursor
            let onHead = nearSentenceStart(end, 3) || nearSentenceStart(end - eff, 4)
            if dist <= MAX_STEP {
                if onHead { return raw <= th * 0.62 }
                return raw <= th * 0.38 && runLen >= min(4, eff)
            }
            // 走到这儿说明跨度超过了两句：必须整句原样念出来，而且正好落在句首。
            // 「跳读」在真机上长这样——用户看着稿子从下一段开头念，尾音是完整的。
            return onHead && runLen >= 9 && raw <= th * 0.34
        }
        if dist <= 20 { return raw <= th * 0.92 }
        return raw <= th * 0.78
    }

    /// 同样准的情况下优先离得近的，避免撞上重复句子时一下跳到后面。
    /// 惩罚随距离开方增长：30 字约 0.05、90 字约 0.09、250 字约 0.14。
    /// 旧版是线性且封顶 0.09，一百字和一千字的「距离感」几乎没差别。
    private func distPenalty(_ jump: Int) -> Float {
        if jump >= 0 { return min(0.20, 0.009 * Float(jump).squareRoot()) }
        return min(0.06, 0.0004 * Float(-jump))
    }

    /// 这个位置是不是（或紧挨着）某个句子的开头。二分查找，句子起点是升序的
    private func nearSentenceStart(_ i: Int, _ tol: Int) -> Bool {
        let s = heads
        guard !s.isEmpty else { return false }
        var lo = 0, hi = s.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if s[mid] < i - tol { lo = mid + 1 }
            else if s[mid] > i + tol { hi = mid - 1 }
            else { return true }
        }
        return false
    }

    /// 两个字的读音代价。多音字取最优组合
    private func cost(_ i: Int, _ a: Character, _ apy: [String]) -> Int {
        if script.norm[i] == a { return 0 }
        let bpy = script.pinyins[i]
        if apy.isEmpty || bpy.isEmpty { return 60 }
        var best = 100
        for x in apy {
            for y in bpy {
                let v = Py.sylCost(x, y)
                if v < best { best = v }
            }
        }
        return best
    }

    // MARK: 推进

    func advance(_ spRaw: [Character]) -> Int {
        let total = n
        guard total > 0 else { return 0 }
        let m = spRaw.count
        guard m >= 2 else { return cursor }
        if cursor >= total { return cursor }

        // 只取尾部：识别结果是累积的，最早那部分早就对过了
        let probeLen = min(14, m)
        let sp = Array(spRaw[(m - probeLen)...])
        let spPy = sp.map { Py.syllables($0) }

        // 卡得越久看得越远，但「看得远」只在证据够足时才作数，见 pass()。
        // 上限压到 320：原来放到 1000 等于把整篇都当候选，随便一个重复句就能命中。
        // 放大得比旧版早（3 拍、8 拍）：用户读跳一段，两三秒内就该追上，
        // 而不是先卡五六秒才肯往后看。
        var win = 150
        if stall >= 3 { win = 220 }
        if stall >= 8 { win = 320 }

        let e = best(sp, spPy, cursor, BACK, win)
        if e >= 0 {
            if e != cursor { return commit(e, m) }
            // 正好停在正确位置：不算卡住
            lastStep = 0
            stall = 0
            creeped = 0
            lastMatchAt = Date()
            lastSpokenLen = m
            return cursor
        }

        lastStep = 0
        stall += 1
        if m > lastSpokenLen { grow += 1 } else { grow = 0 }

        // 大步跳过去以后又连着十来帧对不上：基本可以断定是跳错了。
        // 用户最难受的不是没跟上，而是一次乱跑之后整篇都废了、只能退出去重来。
        // 这里自动退回跳之前的位置（只回退，不前进，所以不会来回抖）。
        // 判定「跳错了」用两个信号：时间过了五秒，而且从落点几乎没往前走。
        // 只看「卡了几拍」不靠谱——错的位置撞上「我们」「这个」会不停伪造成功。
        if let back = jumpBack, Date() > jumpBackDeadline, cursor - jumpTo < 15 {
            jumpBack = nil
            bigJumpAt = Date.distantPast        // 回退之后允许它重新找，别被自己的抑制卡死
            badLanding = jumpTo                 // 但这个落点二十秒内不许再来
            badAt = Date()
            cursor = back
            stall = 0
            grow = 0
            creeped = 0
            lastMatchAt = Date()
            lastSpokenLen = m
            lastScore = 1
            lastStep = 0
            return cursor
        }

        // 一直在说但一直没对上：挪一点，别让画面僵死。
        // 但一轮最多 4 个字——挪多了就成了「不对也在往后放」，正是用户反馈的现象
        if stall >= 18 && grow >= 3 && creeped < 4 && cursor < total - 3
            && Date().timeIntervalSince(lastMatchAt) > 3.0 {
            cursor += 1
            creeped += 1
            lastMatchAt = Date()
            stall = 12
            lastSpokenLen = m
            grow = 0
            lastScore = 1
            lastStep = 1
            return cursor
        }
        lastSpokenLen = m
        return cursor
    }

    /// 一次成功的推进（可前可后）
    private func commit(_ e: Int, _ m: Int) -> Int {
        let from = cursor
        let moved = e - from
        lastStep = moved
        cursor = e
        stall = 0
        grow = 0
        creeped = 0
        lastMatchAt = Date()
        lastSpokenLen = m

        if moved > 40 {
            bigJumpAt = Date()
            // 记下「从哪儿跳的、跳到哪儿」，五秒后从落点没往前走就退回去
            jumpBack = from
            jumpTo = e
            jumpBackDeadline = Date().addingTimeInterval(5.0)
        } else if jumpBack != nil, cursor - jumpTo >= 15 {
            // 从落点往前走了十几个字：这一段是真读下来了，这一跳是对的
            jumpBack = nil
        }
        return cursor
    }

    // MARK: 自由起点编辑距离

    private func best(_ sp: [Character],
                      _ spPy: [[String]],
                      _ after: Int,
                      _ back: Int,
                      _ win: Int) -> Int {
        let k = sp.count
        let total = n
        let lo = max(0, after - back)
        let hi = min(total, after + win)
        if hi - lo < k { return -1 }

        if d.count < k + 1 {
            d = [Int](repeating: 0, count: k + 1)
            prev = d
            run = d
            prevRun = d
            ins = d
            prevIns = d
            good = d
            prevGood = d
        }

        // 初始行：探针前 j 个字全当「识别多出来的」
        prev[0] = 0
        prevRun[0] = 0
        prevIns[0] = 0
        prevGood[0] = 0
        for j in 1...k {
            prev[j] = j * GAP
            prevRun[j] = 0
            prevIns[j] = j
            prevGood[j] = 0
        }

        var bestI = -1
        var bestRank = Float.greatestFiniteMagnitude
        var bestRaw: Float = 1
        /// 两秒半内已经大步前进过一次（见 commit），这一轮再大步前进就不认
        let recentBig = Date().timeIntervalSince(bigJumpAt) < 2.5
        /// 上次跳错的落点，二十秒内不再选它（否则回退后会立刻原样再跳一次）
        var bad = -100000
        if let b = badLanding, Date().timeIntervalSince(badAt) < 20 { bad = b }

        var i = lo + 1
        while i <= hi {
            let idx = i - 1
            d[0] = 0                                  // 起点自由
            run[0] = 0
            ins[0] = 0
            good[0] = 0

            var j = 1
            while j <= k {
                let c = cost(idx, sp[j - 1], spPy[j - 1])

                let sub = prev[j - 1] + c
                let del = prev[j] + GAP               // 台本这个字没被识别出来
                let add = d[j - 1] + GAP              // 识别多吐了一个字

                var v = sub
                var cnt = prevIns[j - 1]
                if del < v { v = del; cnt = prevIns[j] }
                if add < v { v = add; cnt = ins[j - 1] + 1 }
                d[j] = v
                ins[j] = cnt

                // 沿最优路径数的「末尾连续对上了几个字」
                run[j] = c <= GOOD ? prevRun[j - 1] + 1 : 0
                good[j] = (c <= GOOD ? 1 : 0)
                    + (v == sub ? prevGood[j - 1] : (v == del ? prevGood[j] : good[j - 1]))
                j += 1
            }

            // 真正对齐上的字数。DP 允许把探针前面一截当噪声扔掉，如果按 k 归一化，
            // 扔得越多反而越容易过（每字只罚 45）——这是「长探针比短探针还容易通过」
            // 的漏洞，按有效长度归一化堵上。
            var eff = k - ins[k]
            if eff < 1 { eff = 1 }

            let jump = i - after
            let raw = Float(d[k]) / (100.0 * Float(eff))
            // 两秒半内刚大步前进过一次，这一轮不许再大步前进（往回退不算）。
            // 「顺着重复的字一路往下滑」的典型形态就是连着一跳接一跳。
            let blocked = recentBig && jump > 40
            // 只拦「远跳」：真读到那一段时是一字一字挪过去的（jump 很小），
            // 不能因为那儿曾经跳过错就把它整段封死。
            let poisoned = abs(i - bad) <= 15 && jump > 25
            if !blocked && !poisoned && pass(jump, raw, run[k], eff, good[k]) {
                var rank = raw + distPenalty(jump)
                if nearSentenceStart(i, 1) { rank -= 0.015 }
                if rank < bestRank {
                    bestRank = rank
                    bestRaw = raw
                    bestI = i
                }
            }

            let t1 = prev; prev = d; d = t1
            let t2 = prevRun; prevRun = run; run = t2
            let t3 = prevIns; prevIns = ins; ins = t3
            let t4 = prevGood; prevGood = good; good = t4
            i += 1
        }

        if bestI > 0 { lastScore = bestRaw }
        return bestI
    }

    /// 一句话读完了（识别到停顿），下次从当前游标接着找
    func onUtteranceEnd() {
        lastSpokenLen = 0
        grow = 0
        creeped = 0
    }

    /// 手动把游标挪到某处（用户双击台本指定起点）。
    /// 所有「跳转」相关的状态一起清掉，否则刚定的位置会被上一次的后悔药拽回去。
    func jump(_ i: Int) {
        cursor = min(max(0, i), n)
        stall = 0
        creeped = 0
        grow = 0
        jumpBack = nil
        bigJumpAt = Date.distantPast
        badLanding = nil
        lastMatchAt = Date()
        lastSpokenLen = 0
        lastScore = 1
        lastStep = 0
    }
}

// MARK: - 给界面用的引擎

final class PrompterEngine: ObservableObject {
    @Published private(set) var cursor = 0
    @Published private(set) var prepared: PreparedScript
    @Published private(set) var lastStep = 0

    private var follower: Follower

    init(text: String = "") {
        let p = PreparedScript(text: text)
        prepared = p
        follower = Follower(p)
    }

    func reset(_ text: String) {
        let p = PreparedScript(text: text)
        prepared = p
        follower = Follower(p)
        cursor = 0
        lastStep = 0
    }

    /// 送入识别文本（可以带标点、空格，这里自己洗）
    func feed(_ spoken: String) {
        let chars = Array(spoken).filter { PreparedScript.keep($0) }
        let c = follower.advance(chars)
        if c != cursor {
            lastStep = c - cursor
            cursor = c
        }
    }

    /// 「已读」部分在原文里的结束位置（UTF-16）
    var readEnd: Int {
        let n = prepared.offsets.count
        if cursor <= 0 { return 0 }
        if cursor >= n { return prepared.text.utf16.count }
        return prepared.offsets[cursor]
    }

    /// 原文里的 UTF-16 位置 → 台本下标（双击定位用）
    func normIndex(forUTF16 off: Int) -> Int {
        let o = prepared.offsets
        if o.isEmpty { return 0 }
        var lo = 0, hi = o.count - 1, ans = o.count
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if o[mid] >= off { ans = mid; hi = mid - 1 } else { lo = mid + 1 }
        }
        return min(ans, o.count)
    }

    /// 手动指定跟读起点。落在句子中间时自动退到这一句的开头——
    /// 人都是「从这句重新念」，不会从半句开始。
    func jump(to index: Int) {
        var i = min(max(0, index), prepared.norm.count)
        if let s = prepared.sentenceStarts.last(where: { $0 <= i }) { i = s }
        follower.jump(i)
        cursor = i
        lastStep = 0
    }

    var percent: Int {
        let n = prepared.norm.count
        if n == 0 { return 0 }
        return min(100, cursor * 100 / n)
    }

    /// 游标之后的一小段，状态条上提示「现在在这儿」
    var upcoming: String {
        let n = prepared.norm.count
        guard cursor < n else { return "" }
        let end = min(n, cursor + 12)
        return String(prepared.norm[cursor..<end])
    }

    var atEnd: Bool {
        cursor >= prepared.norm.count - 1
    }
}
