import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AssistantViewModel()
    @State private var crownVolume = 1.0

    var body: some View {
        ZStack {
            CrownVolumeSurface(volume: $crownVolume)

            VStack(spacing: 6) {
                VoiceOrb(
                    phase: viewModel.phase,
                    action: viewModel.toggleVoiceMode
                )

                Text(viewModel.phase.label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(statusColor)

                if viewModel.phase != .speaking {
                    Text(viewModel.transcript)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, 8)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .onChange(of: crownVolume) { _, volume in
            viewModel.setPlaybackVolume(volume)
        }
        .accessibilityValue("Volume \(Int((crownVolume * 100).rounded())) percent")
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .failed:
            return .red
        case .off:
            return .white.opacity(0.45)
        default:
            return .cyan
        }
    }
}

private struct CrownVolumeSurface: View {
    @Binding var volume: Double
    @FocusState private var isFocused: Bool

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.015, green: 0.04, blue: 0.08),
                .black
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .digitalCrownRotation(
            $volume,
            from: 0,
            through: 1,
            by: 0.02,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .scrollIndicators(.never)
        .focusEffectDisabled()
        .digitalCrownAccessory {
            CrownVolumeIndicator(level: volume)
        }
        .defaultFocus($isFocused, true)
        .onAppear {
            isFocused = true
        }
    }
}

private struct CrownVolumeIndicator: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(height: geometry.size.height * max(0, min(level, 1)))
            }
        }
        .frame(width: 4, height: 36)
        .accessibilityHidden(true)
    }
}

private struct VoiceOrb: View {
    let phase: AssistantPhase
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(orbColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 76, height: 76)
                    .scaleEffect(pulse && phase.isActive ? 1.16 : 0.94)
                    .opacity(pulse && phase.isActive ? 0.05 : 0.75)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                orbColor.opacity(0.95),
                                orbColor.opacity(0.2),
                                Color.black.opacity(0.85)
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 37
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [.clear, orbColor, .white, .clear],
                                    center: .center
                                ),
                                lineWidth: 1.5
                            )
                            .padding(5)
                    }
                    .shadow(color: orbColor.opacity(0.65), radius: phase.isActive ? 13 : 4)
                    .frame(width: 64, height: 64)

                Image(systemName: phase.isActive ? "waveform" : "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: phase == .speaking
                    )
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(phase.isActive ? "Turn voice mode off" : "Turn voice mode on")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var orbColor: Color {
        switch phase {
        case .off:
            return Color(red: 0.2, green: 0.48, blue: 0.6)
        case .connecting, .thinking, .searching:
            return .orange
        case .listening:
            return .cyan
        case .speaking:
            return Color(red: 0.25, green: 0.65, blue: 1)
        case .failed:
            return .red
        }
    }
}
