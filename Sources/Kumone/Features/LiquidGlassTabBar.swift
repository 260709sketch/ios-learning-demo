#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// 液态玻璃底部栏：底部栏普通毛玻璃 + 选中项液态玻璃药丸（点击/长按抬起效果）
struct LiquidGlassTabBar: View {
    struct Item: Identifiable {
        let tab: IOSTab
        let title: LocalizedStringKey
        let icon: String
        var id: IOSTab { tab }
    }

    let items: [Item]
    @Binding var selection: IOSTab
    var onReselect: (IOSTab) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: SettingsManager

    /// Finger x (in content space) while actively dragging the pill; nil at rest.
    @State private var dragX: CGFloat?
    @State private var isDragging = false

    private let innerInset: CGFloat = 4
    private let contentHeight: CGFloat = 56
    private let settle = Animation.spring(response: 0.35, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            let count = max(items.count, 1)
            let cellW = geo.size.width / CGFloat(count)
            let selectedIndex = items.firstIndex { $0.tab == selection } ?? 0
            let restX = cellW * (CGFloat(selectedIndex) + 0.5)
            let pillX = isDragging
                ? min(max(dragX ?? restX, cellW / 2), geo.size.width - cellW / 2)
                : restX

            ZStack(alignment: .leading) {
                selectionPill
                    .frame(width: cellW - 8, height: contentHeight)
                    .position(x: pillX, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .animation(settle, value: selection)

                HStack(spacing: 0) {
                    ForEach(items) { item in
                        itemLabel(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(cellW: cellW, count: count))
        }
        .frame(height: contentHeight)
        .padding(innerInset)
        .background { LiquidGlassBackground(config: settings.liquidGlassConfig, contentScaleFactor: 0.3) }
        .overlay {
            Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                                   lineWidth: 0.5)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func itemLabel(_ item: LiquidGlassTabBar.Item) -> some View {
        let isSelected = selection == item.tab
        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 23, weight: .semibold))
                .symbolVariant(.fill)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(isSelected
                         ? AnyShapeStyle(Theme.accent)
                         : AnyShapeStyle(Color.primary.opacity(0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The sliding indicator — a bar-height capsule with faint tint.
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark
                  ? Color.white.opacity(0.10)
                  : Color.black.opacity(0.075))
    }

    private func index(for x: CGFloat, cellW: CGFloat, count: Int) -> Int {
        min(max(Int(x / cellW), 0), count - 1)
    }

    private func dragGesture(cellW: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging && abs(value.translation.width) < 8 { return }
                isDragging = true
                dragX = value.location.x
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if tab != selection { selection = tab }
            }
            .onEnded { value in
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if isDragging {
                    withAnimation(settle) { selection = tab; dragX = nil }
                } else if tab == selection {
                    onReselect(tab)
                } else {
                    withAnimation(settle) { selection = tab }
                }
                isDragging = false
            }
    }
}

/// 液态玻璃背景：用 UIViewRepresentable 包装液态玻璃效果
struct LiquidGlassBackground: UIViewRepresentable {
    var style: LiquidGlassEffect.Style = .regular
    var config: LiquidGlassConfig? = nil
    var contentScaleFactor: CGFloat = 1.0  // 降低渲染分辨率提升性能

    @State private var isScrolling = false

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let glassView = createGlassView(isScrolling: isScrolling)
        glassView.frame = container.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(glassView)

        // 监听全局滑动状态
        context.coordinator.cancellable = ScrollDetector.shared.$isScrolling
            .receive(on: DispatchQueue.main)
            .sink { [weak container] scrolling in
                guard let container else { return }
                container.subviews.forEach { $0.removeFromSuperview() }
                let glassView = createGlassView(isScrolling: scrolling)
                glassView.frame = container.bounds
                glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(glassView)
            }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 配置变化时重新创建液态玻璃视图
        uiView.subviews.forEach { $0.removeFromSuperview() }
        let glassView = createGlassView(isScrolling: isScrolling)
        glassView.frame = uiView.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        uiView.addSubview(glassView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var cancellable: AnyCancellable?
    }

    private func createGlassView(isScrolling: Bool) -> UIView {
        let view: UIView
        // 滑动时保持液态玻璃效果，只降帧率和分辨率，不换成毛玻璃
        let scale = isScrolling ? contentScaleFactor * 0.6 : contentScaleFactor
        let baseFps = config?.preferredFramesPerSecond ?? 60
        let fps = isScrolling ? max(24, baseFps / 2) : baseFps

        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: style.nativeStyle)
            view = UIVisualEffectView(effect: effect)
        } else {
            let effect: LiquidGlassEffect
            if let config = config {
                effect = LiquidGlassEffect(customLiquidGlass: config.toLiquidGlass)
            } else {
                effect = LiquidGlassEffect(style: style, isNative: false)
            }
            view = LiquidGlassEffectView(effect: effect, preferredFramesPerSecond: fps)
        }
        view.contentScaleFactor = max(0.1, scale)
        return view
    }
}
#endif
