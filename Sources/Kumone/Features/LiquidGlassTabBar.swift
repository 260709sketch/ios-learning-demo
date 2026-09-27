#if os(iOS)
import SwiftUI
import UIKit

/// 液态玻璃底部栏：基于 LiquidGlassKit 的 Metal 渲染实现
/// 与 GlassTabBar 结构相同，只是背景换成液态玻璃效果
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
        .background { LiquidGlassBackground() }
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

    /// The sliding indicator — a liquid glass capsule.
    private var selectionPill: some View {
        LiquidGlassBackground()
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.25), lineWidth: 0.5)
            }
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
    func makeUIView(context: Context) -> UIView {
        if #available(iOS 26.0, *) {
            // iOS 26+ 使用原生 UIGlassEffect（lens映射到regular）
            let effect = UIGlassEffect(style: .regular)
            return UIVisualEffectView(effect: effect)
        } else {
            // iOS 16-25 使用自定义 Metal 液态玻璃实现，lens预设更通透
            let effect = LiquidGlassEffect(style: .lens, isNative: false)
            return LiquidGlassEffectView(effect: effect)
        }
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 液态玻璃效果自动更新，无需手动处理
    }
}
#endif
