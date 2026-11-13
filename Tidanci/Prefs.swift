import Foundation
import UIKit

/// 用户偏好的 key。用 @AppStorage 直接读写，各页面自动同步。
enum Pref {
    static let fontSize = "p.fontSize"
    static let lineGap = "p.lineGap"
    static let speed = "p.speed"
    static let mirror = "p.mirror"
    static let quality = "p.quality"
    static let fps = "p.fps"
    static let countdown = "p.countdown"
    static let autoSave = "p.autoSave"
    static let followOn = "p.followOn"
    static let dimRead = "p.dimRead"
    /// 当前选中的 Tab（0 台本 / 1 作品 / 2 我的），空态按钮靠它跳转
    static let tab = "p.tab"
    /// 只用本机语音识别（声音不出手机）
    static let speechOnDevice = "p.speechOnDevice"
    /// 前置镜头录制成镜像（与取景框一致）
    static let mirrorSave = "p.mirrorSave"
    /// 视频防抖档位：0 关 / 1 标准 / 2 电影级（存 Int，见 Stabilization）
    static let stabilization = "p.stabilization"

    // 提词框
    static let boxX = "p.box.x"
    static let boxY = "p.box.y"
    static let boxW = "p.box.w"
    static let boxH = "p.box.h"
    static let boxBorder = "p.box.border"
    static let boxFocus = "p.box.focus"

    // 美颜
    static let beautyOn = "b.on"
    static let bSmooth = "b.smooth"
    static let bWhiten = "b.whiten"
    static let bRosy = "b.rosy"
    static let bSlim = "b.slim"
    static let bEye = "b.eye"
    static let bPreset = "b.preset"
}

/// 拍摄画质。短边决定档位，实际能不能上到 4K60 由镜头决定。
enum VideoQuality: String, CaseIterable, Identifiable {
    case uhd
    case fhd
    case hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uhd: return "4K"
        case .fhd: return "1080P"
        case .hd: return "720P"
        }
    }

    var shortSide: CGFloat {
        switch self {
        case .uhd: return 2160
        case .fhd: return 1080
        case .hd: return 720
        }
    }

    var note: String {
        switch self {
        case .uhd: return "画质最好，文件最大，老机器可能不支持前置 4K"
        case .fhd: return "主流选择，够发平台，体积适中"
        case .hd: return "省空间，只适合试拍"
        }
    }
}

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue)fps" }
    var note: String {
        rawValue == 60 ? "动作更顺滑，光线暗时噪点会多一点" : "通用帧率，暗光更稳"
    }
}

/// 视频防抖。可选项：默认「标准」，和系统相机一致；走动多的口播可以上电影级。
///
/// 存的是 Int（@AppStorage 直接读），真正能不能生效由机型和当前画质决定 ——
/// 4K60 上电影级基本都不支持，落地时逐档降级，最终档位由 CameraRecorder 发回界面。
enum Stabilization: Int, CaseIterable, Identifiable {
    case off = 0
    case standard = 1
    case cinematic = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "关"
        case .standard: return "标准"
        case .cinematic: return "电影级"
        }
    }

    /// 设置页里那一行小字：说清代价，别让用户以为「开了就一定更好」
    var note: String {
        switch self {
        case .off: return "不防抖，手持走动会晃。画面最锐、最省电"
        case .standard: return "和系统相机一样，手抖基本抹平，4K60 也支持"
        case .cinematic: return "走动拍像上了稳定器，但高画质/高帧率可能不支持，会降回标准"
        }
    }
}

/// 台本按每分钟 260 字估时长
enum Estimate {
    static let charsPerMinute: Double = 260

    static func seconds(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(1, Int((Double(count) / charsPerMinute * 60).rounded()))
    }

    static func text(_ count: Int) -> String {
        let s = seconds(count)
        if s < 60 { return "约 \(s) 秒" }
        return "约 \(s / 60) 分 \(s % 60) 秒"
    }
}
