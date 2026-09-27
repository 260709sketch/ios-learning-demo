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

/// 液态玻璃效果预览
private struct LiquidGlassPreview: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 背景渐变，模拟内容
            LinearGradient(
                colors: [.blue, .purple, .pink, .orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
    }
}
#endif
