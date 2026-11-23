import SwiftUI

/// 録音中の画面（全画面）。録音していることがはっきり分かるようにする（ガイドライン 2.5.14）。
struct RecordingView: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirmingStop = false

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 28) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.phase == .recording ? .red : .orange)
                    .frame(width: 12, height: 12)
                Text(recorder.phase == .recording ? "録音中" : "止まっています")
                    .font(.headline)
                    .foregroundStyle(recorder.phase == .recording ? .red : .orange)
            }
            .padding(.top, 40)

            Text(recorder.title ?? "無題の会議")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                VStack(spacing: 16) {
                    Text(Formatting.clock(recorder.elapsed(at: context.date)))
                        .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                    LevelBar(level: recorder.phase == .recording ? recorder.level : 0)
                        .frame(height: 8)
                        .padding(.horizontal, 48)
                }
            }

            if let notice = recorder.notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            if !recorder.gaps.isEmpty {
                Text("録れていない時間: \(recorder.gaps.count) か所（合計 \(Formatting.duration(recorder.gaps.reduce(0) { $0 + $1.duration })))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if recorder.phase == .interrupted {
                Button {
                    recorder.resume()
                } label: {
                    Label("再開", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)
            }
            Button {
                confirmingStop = true
            } label: {
                Label("止める", systemImage: "stop.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 24)
            .confirmationDialog("録音を止めますか？", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("止めて議事録を作る", role: .destructive) { recorder.stop() }
                Button("続ける", role: .cancel) {}
            } message: {
                Text("止めると、録音をサーバーへ送って議事録を作ります。")
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.red.gradient)
                    .frame(width: proxy.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.2), value: level)
            }
        }
        .accessibilityHidden(true)
    }
}
