import SwiftUI

/// 屏幕尺寸适配工具
/// 以 iPhone 14 Pro (393x852) 为基准，对不同屏幕尺寸进行等比缩放
enum ScreenAdapter {
    /// 基准屏幕高度（iPhone 14 Pro）
    static let referenceHeight: CGFloat = 852

    /// 基准屏幕宽度
    static let referenceWidth: CGFloat = 393

    /// 当前屏幕高度
    static var screenHeight: CGFloat {
        #if os(iOS)
        return UIScreen.main.bounds.height
        #else
        return NSScreen.main?.visibleFrame.height ?? 852
        #endif
    }

    /// 当前屏幕宽度
    static var screenWidth: CGFloat {
        #if os(iOS)
        return UIScreen.main.bounds.width
        #else
        return NSScreen.main?.visibleFrame.width ?? 393
        #endif
    }

    /// 高度缩放因子（以基准高度为参考）
    /// 限制在 0.85 ~ 1.15 之间，避免过小或过大
    static var heightScale: CGFloat {
        let scale = screenHeight / referenceHeight
        return min(max(scale, 0.85), 1.15)
    }

    /// 宽度缩放因子
    static var widthScale: CGFloat {
        let scale = screenWidth / referenceWidth
        return min(max(scale, 0.85), 1.15)
    }

    /// 综合缩放因子（取宽高缩放的较小值，保证不变形）
    static var scale: CGFloat {
        min(heightScale, widthScale)
    }

    /// 按高度缩放尺寸
    static func h(_ value: CGFloat) -> CGFloat {
        value * heightScale
    }

    /// 按宽度缩放尺寸
    static func w(_ value: CGFloat) -> CGFloat {
        value * widthScale
    }

    /// 按综合比例缩放尺寸
    static func s(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    /// 按高度缩放字体
    static func font(_ size: CGFloat) -> Font {
        .system(size: size * heightScale)
    }
}
