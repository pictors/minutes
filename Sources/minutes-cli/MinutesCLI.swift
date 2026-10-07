import Foundation
import MinutesCore

@main
struct MinutesCLI {
    static let version = "0.1.0 (Phase 0)"

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(64)
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "record": try await RecordCommand.run(rest)
            case "live": try await LiveCommand.run(rest)
            case "transcribe": try await TranscribeCommand.run(rest)
            case "eval": try EvalCommand.run(rest)
            case "cut": try CutCommand.run(rest)
            case "repair-rate": try RepairRateCommand.run(rest)
            case "process": try await ProcessCommand.run(rest)
            case "processes": try ProcessesCommand.run(rest)
            case "devices": try DevicesCommand.run(rest)
            case "assets": try await AssetsCommand.run(rest)
            case "bench": try BenchCommand.run(rest)
            case "help", "--help", "-h": printUsage()
            case "version", "--version": Console.out(version)
            default:
                Console.error("不明なコマンド: \(command)")
                printUsage()
                exit(64)
            }
        } catch let error as ArgumentError {
            Console.error(error.localizedDescription)
            exit(64)
        } catch {
            Console.error(error.localizedDescription)
            exit(1)
        }
    }

    static func printUsage() {
        Console.out("""
        minutes-cli \(version) — Phase 0 spike / 評価ツール

        使い方:
          minutes-cli record --app <bundle-id> [--app ...] --out <dir> [options]
              Process Tap + マイクの 2 トラック録音（AAC + 16 kHz WAV）。Ctrl-C で停止。
              --duration <sec>       指定秒数で自動停止
              --log-interval <sec>   統計ログの間隔（既定 10）
              --no-mic / --no-system トラックを省く
              --all-system-audio     アプリを限定せず全システム音声を録る
              --clock-device <uid>   aggregate のクロックに使う出力デバイス UID
              --mic-device <uid>     マイク入力デバイス UID（`devices` で確認。既定はシステムの入力）
              --tap-autostart        対象アプリが音を出すまで IO を始めない
              --title <text>         recording.json に記録するタイトル

          minutes-cli live --app <bundle-id> [--out <dir>] [--mic] [--locale ja-JP] [--duration <sec>]
              SpeechAnalyzer のライブ字幕を stdout に流し、確定までの遅延を記録する。
          minutes-cli live --file <wav> [--fast]
              録音せず音声ファイルを実時間ペースで流して同じ計測をする（--fast で最速）。
              --fast-results で SpeechTranscriber の fastResults を有効化、--no-volatile で途中結果を止める。

          minutes-cli transcribe <dir|file> --provider elevenlabs|openai|local [options]
              録音フォルダ（system_16k.wav / mic_16k.wav）から transcript.<provider>.json を作る。
              --mic-provider same|local|none   mic トラックのプロバイダ（既定 same）
              --language ja  --locale ja-JP  --keyterms a,b  --num-speakers N  --no-diarize
              --cluster-threshold 0.6（local の話者クラスタリング閾値。大きいほど話者をまとめる）
              --known-speaker "名前=/path/ref.wav"（OpenAI、最大 4 人）
              --out <path>

          minutes-cli eval <transcript.json> <reference.txt> [--track all|system|mic] [--strip-speaker-prefix] [--json]
              CER（NFKC 正規化・空白と記号除去後の編集距離）と話者数を出力する。

          minutes-cli cut <input> <output.wav> --start <sec|mm:ss> [--duration <sec> | --end <sec>]
              音声の一部を 16 kHz mono WAV に切り出す（実録音からの評価区間、known-speaker の参照音声）。

          minutes-cli process <recording-dir> [--provider elevenlabs|openai|local] [--privacy cloud_ok|local_only] [--title t]
              Phase 1 の後処理パイプライン（final → マージ → 要約 → 保存 → 書き出し）を録音フォルダに掛ける。
              --db <path>（既定: ~/Library/Application Support/Minutes/minutes.sqlite）--export-dir --sync-dir --no-summary
              --force step,step で完了済みステップを再実行（例: --force summarize,store,export）
              --summary-provider codex|claude-code|anthropic|none（既定: codex）--summary-model <model>
              --codex-path <absolute-path> --claude-path <absolute-path>
              --summary-only で保存済み本文から要約だけを更新（本文・根拠 ID は保持）
              --language ja|en で会議の言語を決める（省略すると新しい会議はライブ字幕から自動判定）。--summary-language ja|en で要約の言語
              Codex の要約は codex login、Claude Code の要約は claude auth login のログインを使用。ANTHROPIC_API_KEY は不要。

          minutes-cli repair-rate <recording-dir> --out <new-dir> --track system|mic --sample-rate <Hz>
              一定の入力レート誤認を原本から別フォルダへ補正。指定値と録音時計を照合する。
              原音・DB は変更しない。補正コピーに process を実行すると新しい会議として処理できる。

          minutes-cli processes [--app <bundle-id> ...]
              Core Audio に見えているプロセス一覧（録音対象の確認用）。

          minutes-cli devices [--json]
              マイク入力デバイスの一覧（uid と既定入力）。

          minutes-cli assets [--locale ja-JP] [--install]
              SpeechTranscriber のモデル状態の確認とダウンロード。

          minutes-cli bench [--seconds 60] [--keep]
              録音中の書き出し処理（整合・AAC・16 kHz WAV）の CPU を合成音声で測る（G7 の内訳。デバイス・許可は不要）。

        API キー: 環境変数または .env の ELEVENLABS_API_KEY / OPENAI_API_KEY
        """)
    }
}
