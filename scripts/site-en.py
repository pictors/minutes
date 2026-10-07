#!/usr/bin/env python3
# 公開ページの英語版（site/en/index.html）を、日本語版（site/index.html）から作る。
# 使い方: python3 scripts/site-en.py
#   日本語版を直したらこれを実行する。下の置き換え（日本語 → 英語）はどれも回数を確かめるので、
#   日本語版の文を変えると止まる。そのときは対応する行を直す。
#   アプリの画面に似せた飾り（aria-hidden）はアプリと同じ日本語のまま残す。
import os, re, sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
src = open("site/index.html", encoding="utf-8").read()
s = src

def rep(a, b, count=1):
    global s
    n = s.count(a)
    if n != count:
        sys.exit(f"一致の数が違う（{n} != {count}）: {a[:90]!r}")
    s = s.replace(a, b)

# 頭
rep('<html lang="ja" class="no-js">', '<html lang="en" class="no-js">')
rep('<title>Minutes — Mac の議事録アプリ</title>', '<title>Minutes — Meeting minutes for your Mac</title>')
rep('content="Mac で会議を録音し、話者付きの文字起こし・要約・決定事項・アクションまでまとめる議事録アプリ。録音とライブ字幕はこの Mac の中で。無料・オープンソース。"',
    'content="Minutes records your meetings on your Mac and writes the minutes: a transcript with speakers, a summary, decisions, and action items. Recording and live captions stay on your Mac. Free and open source."')
rep('content="Minutes — 会議は、話すことに集中しよう。"', 'content="Minutes — Focus on the conversation."')
rep('content="Mac で会議を録音し、話者付きの文字起こしと要約から議事録を作るアプリ。無料・オープンソース。"',
    'content="A Mac app that records your meetings and writes the minutes from a transcript with speakers and a summary. Free and open source."')
rep('<meta property="og:url" content="https://minutes.tools/">', '<meta property="og:url" content="https://minutes.tools/en/">')
rep('https://minutes.tools/assets/og-image.jpg', 'https://minutes.tools/assets/og-image-en.jpg')
for attr in ('href', 'src', 'srcset', 'poster'):
    s = s.replace(f'{attr}="assets/', f'{attr}="../assets/')
rep('>本文へ</a>', '>Skip to content</a>')

# ナビ
rep('<nav aria-label="ページ内"', '<nav aria-label="On this page"')
rep('href="#features">できること</a>', 'href="#features">Features</a>')
rep('href="#screens">画面</a>', 'href="#screens">Screens</a>')
rep('href="#privacy">送信先</a>', 'href="#privacy">Privacy</a>')
rep('href="#waitlist">待機リスト</a>', 'href="#waitlist">Waitlist</a>')
rep('aria-label="GitHub のリポジトリ"', 'aria-label="GitHub repository"')
rep('href="en/" hreflang="en" lang="en">EN</a>', 'href="../" hreflang="ja" lang="ja">JA</a>')
rep('Minutes.dmg">ダウンロード</a>', 'Minutes.dmg">Download</a>')

# 最初の画面
rep('        Mac の議事録アプリ\n      </p>', '        Meeting minutes for your Mac\n      </p>')
rep('<span class="inline-block">会議は、</span><br class="max-sm:hidden"><span class="inline-block"><span class="bg-linear-to-r from-accent to-violet bg-clip-text text-transparent">話すこと</span>に</span><span class="inline-block">集中しよう。</span>',
    'Focus on the<br class="max-sm:hidden"> <span class="bg-linear-to-r from-accent to-violet bg-clip-text text-transparent">conversation</span>.')
rep('>Minutes は、Mac で会議を録音して、話者付きの文字起こし・要約・決定事項・アクションまでまとめる議事録アプリです。録音とライブ字幕は、この Mac の中で行います。</p>',
    '>Minutes records your meetings on your Mac and writes the minutes: a transcript with speakers, a summary, decisions, and action items. Recording and live captions stay on your Mac.</p>')
rep('          Mac 用をダウンロード\n', '          Download for Mac\n')
rep('          ソースコード\n', '          Source code\n')
rep('>無料・オープンソース ・ macOS 26 以降 ・ Apple Silicon</p>', '>Free and open source · macOS 26 or later · Apple Silicon · Japanese interface</p>')
rep('alt="Minutes のウィンドウ。左に会議の一覧、右に要約・決定事項・アクション・話者付きの文字起こし。"',
    'alt="The Minutes window: the list of meetings on the left; the summary, decisions, action items, and the transcript with speakers on the right."')

# 紹介映像
rep('<p class="eyebrow text-[#a9adff]">15 秒の紹介</p>', '<p class="eyebrow text-[#a9adff]">15-second introduction</p>')
rep('<span class="inline-block">Mac で、</span><span class="inline-block">録音するだけ。</span>', 'Just record on your Mac.')
rep('aria-label="Minutes の紹介映像（15 秒）"', 'aria-label="A 15-second introduction to Minutes"')
rep('<track kind="captions" src="../assets/promo-ja.vtt" srclang="ja" label="日本語">', '<track kind="captions" src="../assets/promo-en.vtt" srclang="en" label="English" default>')
rep('<span>画面の会議と名前は架空です</span>', '<span>Japanese narration · The meetings and names are fictional</span>')
rep('data-on="音を消す" data-off="音を出す"', 'data-on="Mute" data-off="Sound on"')
rep('<span class="sound-label">音を出す</span>', '<span class="sound-label">Sound on</span>')

# できること
rep('<p class="eyebrow">できること</p>', '<p class="eyebrow">Features</p>')
rep('<span class="inline-block">議事録は、</span><span class="inline-block">Minutes が書く。</span>', 'Let Minutes take the minutes.')
rep('>会議アプリの音と自分の声を録り、会議が終わったら、選んだサービスで文字起こしと要約を作ります。メニューバーに常駐して、会議を待ちます。</p>',
    '>Minutes records the meeting app’s audio and your own voice. When the meeting ends, it transcribes and summarizes with the services you choose. It lives in the menu bar and waits for your next meeting.</p>')
rep('<strong>声を分けて録音。</strong>Meet・Teams・Zoom などの会議アプリの音と、マイクの自分の声を別々に録ります。誰が話したかを分けやすくなります。',
    '<strong>Two separate tracks.</strong> The meeting app’s audio (Meet, Teams, Zoom, …) and your microphone are recorded separately, so speakers are easier to tell apart.')
rep('<strong>ライブ字幕。</strong>録音中の字幕は、この Mac の中（macOS の音声認識）で作ります。',
    '<strong>Live captions.</strong> Captions during the meeting are made on your Mac with macOS speech recognition.')
rep('<span class="inline-block">要約も、</span><span class="inline-block">決定事項も、</span><span class="inline-block">アクションも。</span>', 'Summary, decisions, and action items.')
rep('<strong>文字起こしと要約。</strong>会議が終わると、話者付きの文字起こし・要約・決定事項・アクション・未決の論点を作ります。どれも根拠の発言へ戻れます。',
    '<strong>Transcript and summary.</strong> After the meeting, Minutes writes a transcript with speakers, a summary, decisions, action items, and open questions — each linked back to what was said.')
rep('aria-label="作るもの"', 'aria-label="What Minutes writes"')
rep('ring-line">要約</li>', 'ring-line">Summary</li>')
rep('ring-line">決定事項</li>', 'ring-line">Decisions</li>')
rep('ring-line">アクション</li>', 'ring-line">Action items</li>')
rep('ring-line">未決の論点</li>', 'ring-line">Open questions</li>')
rep('ring-line">話者付きの文字起こし</li>', 'ring-line">Transcript with speakers</li>')
rep('alt="会議の詳細。要約、根拠の時刻と話者が付いた決定事項、担当と期限が付いたアクション。"',
    'alt="Meeting details: the summary, decisions with the time and speaker they came from, and action items with owners and due dates."')
rep('<strong>話者の名前。</strong>一度選べば、同じ話者の発言すべてに名前が付きます。相手のマイクが拾った周りの会話は、話者ごとに外せます。',
    '<strong>Speaker names.</strong> Name a speaker once and every line is updated. Voices picked up around the other person’s microphone can be excluded per speaker.')
rep('<strong>検索と書き出し。</strong>タイトル・参加者・本文・要約を全文検索。会議ごとに Markdown と JSON で書き出し、好きなフォルダへ。',
    '<strong>Search and export.</strong> Full-text search across titles, attendees, transcripts, and summaries. Export each meeting as Markdown and JSON to any folder.')
rep('<strong>予定の会議は自動で。</strong>カレンダーの予定の時刻に会議アプリから音がすると、録音するかを確かめてから始めます。',
    '<strong>Calendar meetings.</strong> When a calendar meeting starts and the meeting app plays audio, Minutes asks before it starts recording.')

# 画面
rep('<p class="eyebrow">画面</p>', '<p class="eyebrow">Screens</p>')
rep('<span class="inline-block">メニューバーから、</span><span class="inline-block">議事録まで。</span>', 'From the menu bar to the minutes.')
rep('>録音の開始・停止と今日の予定はメニューバーのパネルから。議事録はウィンドウで読み、編集し、探せます。</p>',
    '>Start and stop recording and see today’s meetings from the menu bar panel. Read, edit, and search the minutes in the window.</p>')
rep('alt="メニューバーのパネル。録音ボタン、今日と今週の会議時間。"', 'alt="The menu bar panel with the record button and meeting time for today and this week."')
rep('<strong>メニューバーのパネル。</strong>録音の開始・停止と、今日の会議時間や予定をここから。',
    '<strong>The menu bar panel.</strong> Start and stop recording, and see today’s meeting time and schedule.')
rep('alt="初回の案内の試しの録音。会議アプリの音と自分の声のメーター、ライブ字幕。"',
    'alt="The test recording in the first-run guide, with level meters for the meeting app and your voice, and live captions."')
rep('<strong>初回の案内。</strong>試しの録音で、音と字幕が届くかを確かめます。',
    '<strong>The first-run guide.</strong> A test recording checks that audio and captions come through.')
rep('>画面の会議と名前は架空です。</p>', '>The meetings and names shown are fictional. The app’s interface is in Japanese.</p>')

# 送信先
rep('<p class="eyebrow">送信先</p>', '<p class="eyebrow">Privacy</p>')
rep('<span class="inline-block">どこへ送るかは、</span><span class="inline-block">会議ごとに決める。</span>', 'You decide what leaves your Mac, per meeting.')
rep('>会議ごとに「クラウド OK」か「ローカルのみ」を選べます。音声と議事録は、この Mac に保存します。</p>',
    '>Each meeting is either “cloud OK” or “local only”. Audio and minutes are stored on your Mac.</p>')
rep('>クラウド OK</h3><p class="text-[14px] text-ink-2">選んだサービスへ送る</p>', '>Cloud OK</h3><p class="text-[14px] text-ink-2">Sent to the services you choose</p>')
rep('>ローカルのみ</h3><p class="text-[14px] text-ink-2">この Mac から出さない</p>', '>Local only</h3><p class="text-[14px] text-ink-2">Nothing leaves your Mac</p>')
rep('>録音した音声</dt>', '>Recorded audio</dt>', 2)
rep('>文字起こし・会議名・参加者</dt>', '>Transcript, title, attendees</dt>', 2)
rep('>書き出し・同期</dt>', '>Export and sync</dt>', 2)
rep('>会議のあと、選んだ文字起こしのサービス（ElevenLabs / OpenAI）へ送ります。精度を上げるため、参加者の名前と用語も送ります。</dd>',
    '>Sent after the meeting to the transcription service you chose (ElevenLabs or OpenAI), with attendee names and terms to improve accuracy.</dd>')
rep('>選んだ要約の手段へ送ります（Codex は OpenAI、Claude Code と Anthropic API は Anthropic）。</dd>',
    '>Sent to the summarizer you chose (Codex: OpenAI; Claude Code and the Anthropic API: Anthropic).</dd>')
rep('>選んだフォルダへコピーします。</dd>', '>Copied to the folder you chose.</dd>')
rep('>送りません。この Mac の中で文字起こしします。</dd>', '>Never sent. Transcribed on your Mac.</dd>')
rep('>送りません。要約は作りません。</dd>', '>Never sent. No summary is made.</dd>')
rep('>しません。</dd>', '>Not exported.</dd>')
rep('<span>ライブ字幕は、いつもこの Mac の中で作ります。</span>', '<span>Live captions are always made on your Mac.</span>')
rep('<span>利用状況の送信（テレメトリ）はしません。このページも解析のスクリプトを読み込みません。</span>', '<span>No telemetry. This page loads no analytics either.</span>')
rep('<span>API キーは Keychain に保存します。</span>', '<span>API keys are stored in the Keychain.</span>')
rep('<span>新しい版の確認のため、1 日に 1 回 GitHub から更新の情報を読みます（設定で止められます）。</span>',
    '<span>Minutes checks GitHub for a new version once a day (you can turn this off).</span>')
rep('<span>初めて使うときに、macOS の音声認識モデル（Apple）と、話者分離のモデル（Hugging Face）をダウンロードします。</span>',
    '<span>On first use, Minutes downloads macOS speech models (from Apple) and speaker diarization models (from Hugging Face).</span>')
rep('<span>音声は既定で 30 日後に削除します（書き出しが済んだ会議だけ）。文字起こしと議事録は残ります。</span>',
    '<span>Audio is deleted after 30 days by default (only for exported meetings). Transcripts and minutes are kept.</span>')
rep('<span>録音することを参加者に伝え、必要な同意を得るのは、Minutes を使う人の責任です。法律と、所属する組織のルールに従ってください。参加者に知らせる文面は、アプリからいつでもコピーできます。</span>',
    '<span>You are responsible for telling attendees that you are recording and for obtaining any consent required by law or your organization. Minutes can copy a notice text for you at any time.</span>')

# 必要なもの
rep('<p class="eyebrow">はじめる前に</p>', '<p class="eyebrow">Before you start</p>')
rep('>使うのに必要なもの</h2>', '>What you need</h2>')
rep('<li>Apple Silicon の Mac</li>', '<li>A Mac with Apple Silicon</li>')
rep('<li>macOS 26 以降</li>', '<li>macOS 26 or later</li>')
rep('<li class="text-ink-3">アプリの画面は日本語です。</li>', '<li class="text-ink-3">The app’s interface is in Japanese.</li>')
rep('>文字起こし（どれか 1 つ）</h3>', '>Transcription (one of)</h3>')
rep('<li>ElevenLabs Scribe v2（おすすめ・API キー）</li>', '<li>ElevenLabs Scribe v2 (recommended, API key)</li>')
rep('<li>OpenAI（API キー）</li>', '<li>OpenAI (API key)</li>')
rep('<li>この Mac の中（キー不要・精度は下がる）</li>', '<li>On your Mac (no key, lower accuracy)</li>')
rep('>要約（どれか 1 つ）</h3>', '>Summary (one of)</h3>')
rep('<li>Codex（ChatGPT のログイン）</li>', '<li>Codex (ChatGPT sign-in)</li>')
rep('<li>Claude Code（Claude のログイン）</li>', '<li>Claude Code (Claude sign-in)</li>')
rep('<li>Anthropic API（API キー）</li>', '<li>Anthropic API (API key)</li>')
rep('<li>要約しない</li>', '<li>No summary</li>')

# 待機リスト
rep('<p class="eyebrow text-[#a9adff]">待機リスト</p>', '<p class="eyebrow text-[#a9adff]">Waitlist</p>')
rep('<span class="inline-block">キーなしで使える版を、</span><span class="inline-block">準備しています。</span>', 'A version that works without keys is coming.')
rep('>API キーやログインを用意しなくても、文字起こしと要約まで使える有料の版を考えています。関心があれば、待機リストに登録してください。準備ができたらお知らせします。</p>',
    '>We are planning a paid version that transcribes and summarizes without your own API keys or sign-ins. Join the waitlist and we will let you know when it is ready.</p>')
rep('        待機リストに登録する\n', '        Join the waitlist\n')
rep('>登録は外部のフォームで受け付けます。メールアドレスは、この版の案内のためだけに使います。</p>',
    '>The waitlist uses an external form. We use your email address only to tell you about this version.</p>')

# ソースコード
rep('<span class="inline-block">ソースコードは、</span><span class="inline-block">すべて公開しています。</span>', 'All of the source code is open.')
rep('>アプリと CLI のソースコードは Apache License 2.0 で公開しています。不具合の報告や改善の提案は GitHub で受け付けます。</p>',
    '>The app and the command-line tool are licensed under the Apache License 2.0. Report bugs and suggest improvements on GitHub.</p>')
rep('          GitHub で見る\n', '          View on GitHub\n')
rep('/releases">リリース</a>', '/releases">Releases</a>')
rep('CONTRIBUTING.md">貢献の手順</a>', 'CONTRIBUTING.md">Contributing</a>')
rep('SECURITY.md">セキュリティ</a>', 'SECURITY.md">Security</a>', 2)
rep('LICENSE">ライセンス</a>', 'LICENSE">License</a>', 2)
rep('NOTICE">第三者の帰属表示</a>', 'NOTICE">Third-party notices</a>')
rep('TRADEMARKS.md">名前とロゴ</a>', 'TRADEMARKS.md">Trademarks</a>')

# フッター
rep('aria-label="フッター"', 'aria-label="Footer"')
rep('href="en/" hreflang="en" lang="en">English</a>', 'href="../" hreflang="ja" lang="ja">日本語</a>')

# スクリプトのコメント
rep('// 紹介映像は見えている間だけ音なしで流し、ボタンで音を出す。動きを減らす設定なら自動では流さない。', '// Plays the introduction muted while it is in view; the button turns the sound on. With reduced motion, it does not autoplay.')
rep('// 見えてきた区画を浮かび上がらせる（動きを減らす設定では CSS が何もしない）', '// Fades sections in as they come into view (the CSS does nothing with reduced motion).')
rep('<!-- 横にはみ出す飾り（最初の画面の光など）はここで切る。body で切ると指定がビューポートへ移るだけで、iPhone の Safari はページを横に動かせてしまう -->',
    '<!-- Decorations that stick out sideways (such as the glow behind the hero) are clipped here. On body, the clip only moves to the viewport, and Safari on iPhone can still move the page sideways. -->')
rep('<!-- 最初の画面 -->', '<!-- Hero -->')
rep('<!-- 議事録ができたときの通知（飾り） -->', '<!-- Notification when the minutes are ready (decorative; the app UI is Japanese) -->')
rep('<!-- 録音中のパネル（飾り） -->', '<!-- Recording panel (decorative) -->')
rep('<!-- 紹介映像 -->', '<!-- Introduction video -->')
rep('<!-- できること -->', '<!-- Features -->')
rep('<!-- 画面 -->', '<!-- Screens -->')
rep('<!-- 送信先 -->', '<!-- Privacy -->')
rep('<!-- 必要なもの -->', '<!-- Requirements -->')
rep('<!-- 待機リスト -->', '<!-- Waitlist -->')
rep('<!-- ソースコード -->', '<!-- Open source -->')

# 飾り（アプリの画面に似せた部分）はアプリと同じ日本語のまま。日本語の字形で出すため lang="ja" を付ける
def mark_ja(m):
    cls = m.group(1)
    return m.group(0) if "hero-glow" in cls else f'<div aria-hidden="true" lang="ja" class="{cls}"'
s, n = re.subn(r'<div aria-hidden="true" class="([^"]*)"', mark_ja, s)
open("site/en/index.html", "w", encoding="utf-8").write(s)

# 残った日本語は、飾り（lang="ja"）と言語の切り替えだけのはず。--verbose でその行を出す
jp = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff00-\uffef]")
rest = [(i + 1, line.strip()[:100]) for i, line in enumerate(s.splitlines()) if jp.search(line)]
decorations = s.count('lang="ja" class=')
print(f"書き出しました: site/en/index.html（日本語が残る行 {len(rest)}、飾り {decorations} 個）")
if "--verbose" in sys.argv:
    for n, line in rest:
        print(n, line)
