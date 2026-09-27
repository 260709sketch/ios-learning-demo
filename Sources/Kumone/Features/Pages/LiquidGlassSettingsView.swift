#if os(iOS)
import SwiftUI

/// 第三方液态玻璃 DIY 设置页面
struct LiquidGlassSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Form {
            Section("预设") {
                Picker("预设", selection: $settings.liquidGlassPreset) {
                    ForEach(LiquidGlassPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text("选择预设会应用对应参数；调整下方参数后自动切换为自定义")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("参数调节") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("色调透明度")
                        Spacer()
                        Text(String(format: "%.2f", settings.liquidGlassConfig.tintOpacity))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.liquidGlassConfig.tintOpacity },
                        set: { settings.liquidGlassConfig.tintOpacity = $0; settings.liquidGlassPreset = .custom }
                    ), in: 0...1)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("背景模糊")
                        Spacer()
                        Text(String(format: "%.2f", settings.liquidGlassConfig.blurRadius))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.liquidGlassConfig.blurRadius },
                        set: { settings.liquidGlassConfig.blurRadius = $0; settings.liquidGlassPreset = .custom }
                    ), in: 0...1)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("玻璃厚度")
                        Spacer()
                        Text(String(format: "%.0f", settings.liquidGlassConfig.glassThickness))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.liquidGlassConfig.glassThickness },
                        set: { settings.liquidGlassConfig.glassThickness = $0; settings.liquidGlassPreset = .custom }
                    ), in: 0...20)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("折射率")
                        Spacer()
                        Text(String(format: "%.2f", settings.liquidGlassConfig.refractiveIndex))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.liquidGlassConfig.refractiveIndex },
                        set: { settings.liquidGlassConfig.refractiveIndex = $0; settings.liquidGlassPreset = .custom }
                    ), in: 1.0...2.0)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("色散强度")
                        Spacer()
                        Text(String(format: "%.0f", settings.liquidGlassConfig.dispersionStrength))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { settings.liquidGlassConfig.dispersionStrength },
                        set: { settings.liquidGlassConfig.dispersionStrength = $0; settings.liquidGlassPreset = .custom }
                    ), in: 0...30)
                }
            }

            Section("预览") {
                LiquidGlassPreview()
                    .frame(height: 80)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Button(role: .destructive) {
                    settings.liquidGlassConfig = .default
                    settings.liquidGlassPreset = .white
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("第三方液态玻璃调节")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 预览背景模式
private enum PreviewBackground: String, CaseIterable, Identifiable {
    case image = "图"
    case light = "浅"
    case dark = "深"
    case blank = "空"

    var id: String { rawValue }
}

/// 液态玻璃效果预览
private struct LiquidGlassPreview: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewBg: PreviewBackground = .image

    var body: some View {
        VStack(spacing: 8) {
            Picker("预览背景", selection: $previewBg) {
                ForEach(PreviewBackground.allCases) { bg in
                    Text(bg.rawValue).tag(bg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ZStack {
                // 背景
                previewBackgroundView

                // 液态玻璃预览
                HStack(spacing: 20) {
                    Circle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.9))
                            .frame(width: 100, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.6))
                            .frame(width: 60, height: 8)
                    }

                    Spacer()

                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .background {
                    LiquidGlassBackground(config: settings.liquidGlassConfig, contentScaleFactor: 0.5)
                        .id(settings.liquidGlassConfig)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .frame(height: 160)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var previewBackgroundView: some View {
        switch previewBg {
        case .image:
            // 彩色渐变模拟图片内容
            LinearGradient(
                colors: [.blue, .purple, .pink, .orange, .yellow],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 加一些圆形模拟图片元素
            .overlay {
                HStack(spacing: 20) {
                    Circle().fill(.red.opacity(0.6)).frame(width: 50, height: 50)
                    Circle().fill(.green.opacity(0.6)).frame(width: 30, height: 30)
                    Spacer()
                    Circle().fill(.blue.opacity(0.6)).frame(width: 40, height: 40)
                }
                .padding(20)
            }
        case .light:
            Color.white
            // 浅色模式下加一些灰色元素
            .overlay {
                HStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.3)).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(.gray.opacity(0.4)).frame(width: 80, height: 10)
                        RoundedRectangle(cornerRadius: 4).fill(.gray.opacity(0.2)).frame(width: 50, height: 8)
                    }
                    Spacer()
                }
                .padding(20)
            }
        case .dark:
            Color.black
            // 深色模式下加一些白色元素
            .overlay {
                HStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.2)).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.3)).frame(width: 80, height: 10)
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15)).frame(width: 50, height: 8)
                    }
                    Spacer()
                }
                .padding(20)
            }
        case .blank:
            Color.clear
        }
    }
}
#endif
