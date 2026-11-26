import SwiftUI

/// 上のバーの決まり（SPEC §5.7）: バーは地を塗らず、送った本文はシステムのぼかし（scroll edge effect）の下を通る。
/// 上のバーを持つ画面（一覧・会議の画面・シート・シートの中で進んだ先）は、題名を付けるところで、すべてこれを付ける。
/// - ぼかしは soft を明示する。iOS 27 の実機では、指定しないと半透明の帯と境目の線（hard）になった（iOS 26.5 では指定しなくても soft だった）。
///   この指定は、中にあるスクロールにも届く。
/// - バーの明暗はアプリの明暗に固定する。下を通る濃い色（通知の誘いの青いボタンなど）があると、システムがバーを暗い側に切り替え、
///   時刻や題名の文字が白くなって、薄い灰色の上で読みにくくなった。
struct TransparentNavigationBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

extension View {
    /// 上のバーを透かす（TransparentNavigationBar）
    func transparentNavigationBar() -> some View {
        modifier(TransparentNavigationBar())
    }
}
