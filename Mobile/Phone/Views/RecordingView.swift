import SwiftUI

/// 録音中の画面（全画面）。録音していることがはっきり分かるようにする（ガイドライン 2.5.14）。
/// 大きな経過時間、音量の波、止めるボタン。電話・Siri で止まっているあいだは色と文言で知らせ、再開のボタンを出す。
struct RecordingView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingStop = false
    @State private var history = LevelHistory()

    var body: some View {
        let recorder = model.recorder
        let recording = recorder.phase == .recording
        VStack(spacing: 0) {
            StatusPill(text: recording ? "録音中" : "止まっています", tint: recording ? Palette.record : Palette.amber,
                       systemImage: recording ? "record.circle.fill" : "pause.circle.fill", isBusy: recording)
                .scaleEffect(1.15)
                .padding(.top, 28)
                .animation(Motion.symbol, value: recording)

            Text(recorder.title ?? "無題の会議")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Spacer(minLength: 12)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                BigTimerText(seconds: recorder.elapsed(at: context.date), size: 88, isDimmed: !recording)
            }
            .frame(maxWidth: .infinity)

            LevelWaveform(levels: history.levels, tint: recording ? Palette.record : .secondary)
                .frame(height: 64)
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .opacity(recording ? 1 : 0.35)

            if let notice = recorder.notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.amber)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .transition(Motion.content(reduceMotion: reduceMotion))
            }
            if !recorder.gaps.isEmpty {
                InfoChip(text: "録れていない時間 \(recorder.gaps.count) か所・合計 \(Formatting.duration(recorder.gaps.reduce(0) { $0 + $1.duration }))", systemImage: "scissors")
                    .padding(.top, 14)
            }

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                if recorder.phase == .interrupted {
                    Button {
                        recorder.resume()
                    } label: {
                        HStack(spacing: 12) {
                            PillGlyph(kind: .resume, size: 34)
                            Text("録音を再開")
                        }
                    }
                    .buttonStyle(PillButtonStyle(height: 58))
                    .transition(Motion.content(reduceMotion: reduceMotion))
                }
                Button {
                    confirmingStop = true
                } label: {
                    HStack(spacing: 12) {
                        PillGlyph(kind: .stop, size: 36)
                        Text("止める")
                    }
                }
                .buttonStyle(PillButtonStyle(height: 62))
                .confirmationDialog("録音を止めますか？", isPresented: $confirmingStop, titleVisibility: .visible) {
                    Button("止めて議事録を作る", role: .destructive) { recorder.stop() }
                    Button("続ける", role: .cancel) {}
                } message: {
                    Text("止めると、録音をサーバーへ送って議事録を作ります。")
                }
            }
            .padding(.bottom, 28)
            .animation(Motion.layout, value: recorder.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.page.ignoresSafeArea())
        .interactiveDismissDisabled()
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.phase)
        .onAppear { history.start { model.recorder.phase == .recording ? model.recorder.level : 0 } }
        .onDisappear { history.stop() }
    }
}
