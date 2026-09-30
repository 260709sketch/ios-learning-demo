import SwiftUI

struct EqualizerView: View {
    @ObservedObject private var equalizer = Equalizer.shared
    @State private var showingSavePreset = false
    @State private var presetName = ""

    var body: some View {
        List {
            Section {
                Toggle("启用均衡器", isOn: Binding(
                    get: { equalizer.isEnabled },
                    set: { equalizer.setEnabled($0) }
                ))
            }

            if equalizer.isEnabled {
                Section("预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EqualizerPreset.allCases.filter { $0 != .custom }) { preset in
                                Button {
                                    equalizer.applyPreset(preset)
                                } label: {
                                    Text(preset.displayName)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(equalizer.selectedPreset == preset ? Color.accentColor : Color.gray.opacity(0.2))
                                        .foregroundColor(equalizer.selectedPreset == preset ? .white : .primary)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if !equalizer.customPresets.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(equalizer.customPresets) { preset in
                                    HStack(spacing: 4) {
                                        Button {
                                            equalizer.applyCustomPreset(preset)
                                        } label: {
                                            Text(preset.name)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(equalizer.selectedCustomPresetName == preset.name ? Color.accentColor : Color.gray.opacity(0.2))
                                                .foregroundColor(equalizer.selectedCustomPresetName == preset.name ? .white : .primary)
                                                .cornerRadius(8)
                                        }
                                        Button(role: .destructive) {
                                            equalizer.deleteCustomPreset(preset)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.gray)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button {
                        showingSavePreset = true
                    } label: {
                        Label("保存为自定义预设", systemImage: "square.and.arrow.down")
                    }
                }

                Section("前置放大器") {
                    VStack {
                        Slider(value: Binding(
                            get: { equalizer.preampGain },
                            set: { equalizer.setPreampGain($0) }
                        ), in: -Equalizer.maximumGain...Equalizer.maximumGain, step: 0.5)
                        Text(String(format: "%.1f dB", equalizer.preampGain))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("频段调节") {
                    VStack(spacing: 12) {
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(Array(Equalizer.bandFrequencies.enumerated()), id: \.offset) { index, frequency in
                                VStack(spacing: 8) {
                                    Text(String(format: "%.1f", equalizer.bandGains[index]))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(height: 20)
                                    Slider(value: Binding(
                                        get: { equalizer.bandGains[index] },
                                        set: { equalizer.setBandGain(at: index, to: $0) }
                                    ), in: -Equalizer.maximumGain...Equalizer.maximumGain, step: 0.5)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 40, height: 120)
                                    Text(frequencyLabel(frequency))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(width: 40)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        equalizer.reset()
                    } label: {
                        Label("重置为默认", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .navigationTitle("均衡器")
        .alert("保存预设", isPresented: $showingSavePreset) {
            TextField("预设名称", text: $presetName)
            Button("取消", role: .cancel) { presetName = "" }
            Button("保存") {
                if equalizer.saveCustomPreset(name: presetName) {
                    presetName = ""
                }
            }
        } message: {
            Text("输入自定义预设名称")
        }
    }

    private func frequencyLabel(_ freq: Double) -> String {
        if freq >= 1000 {
            return "\(Int(freq / 1000))k"
        }
        return "\(Int(freq))"
    }
}
