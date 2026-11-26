import Foundation
import GRDB

/// スキーマとマイグレーション（SPEC §7.1 / §7.2）。GRDB の DatabaseMigrator で管理する。
public enum StoreSchema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
            CREATE TABLE meetings (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              platform TEXT,
              calendar_event_id TEXT,
              calendar_title TEXT,
              attendees_json TEXT,
              privacy_mode TEXT NOT NULL CHECK (privacy_mode IN ('cloud_ok','local_only')),
              status TEXT NOT NULL,
              audio_dir TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX meetings_started_idx ON meetings(started_at DESC);

            CREATE TABLE people (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              email TEXT,
              aliases_json TEXT,
              voice_samples_json TEXT,
              created_at TEXT NOT NULL
            );
            CREATE INDEX people_email_idx ON people(email);

            CREATE TABLE speakers (
              id TEXT PRIMARY KEY,
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              cluster_label TEXT NOT NULL,
              person_id TEXT REFERENCES people(id) ON DELETE SET NULL,
              display_name TEXT,
              UNIQUE (meeting_id, cluster_label)
            );

            CREATE TABLE segments (
              id INTEGER PRIMARY KEY,
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              source TEXT NOT NULL CHECK (source IN ('live','final')),
              t_start REAL NOT NULL,
              t_end REAL NOT NULL,
              speaker_id TEXT,
              cluster_label TEXT,
              text TEXT NOT NULL,
              confidence REAL
            );
            CREATE INDEX segments_meeting_idx ON segments(meeting_id, source, t_start);

            CREATE TABLE notes (
              meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
              summary_md TEXT,
              decisions_json TEXT,
              action_items_json TEXT,
              open_questions_json TEXT,
              user_notes_md TEXT,
              model TEXT,
              generated_at TEXT
            );

            CREATE TABLE pipeline_runs (
              id INTEGER PRIMARY KEY,
              meeting_id TEXT NOT NULL,
              step TEXT NOT NULL,
              status TEXT NOT NULL,
              provider TEXT,
              started_at TEXT,
              finished_at TEXT,
              error TEXT
            );
            CREATE INDEX pipeline_runs_meeting_idx ON pipeline_runs(meeting_id, step, id);

            CREATE TABLE export_log (
              id INTEGER PRIMARY KEY,
              meeting_id TEXT NOT NULL,
              target TEXT NOT NULL,
              exported_at TEXT NOT NULL,
              checksum TEXT,
              status TEXT NOT NULL
            );
            CREATE INDEX export_log_meeting_idx ON export_log(meeting_id, target, id);

            CREATE TABLE keyterms (
              term TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              created_at TEXT NOT NULL
            );
            """)

            // 全文検索: trigram（日本語は unicode61 だと分かち書きされない）。3 文字未満は LIKE にフォールバックする。
            try db.execute(sql: """
            CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='segments', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
              INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
              INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
              INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
              INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE VIRTUAL TABLE notes_fts USING fts5(meeting_id UNINDEXED, body, tokenize='trigram');
            """)
        }
        migrator.registerMigration("v2_recovery_and_transcript_revisions") { db in
            try db.execute(sql: """
            ALTER TABLE segments ADD COLUMN original_text TEXT;
            ALTER TABLE segments ADD COLUMN is_current INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE pipeline_runs ADD COLUMN fingerprint TEXT;
            CREATE TABLE transcript_revisions (
              id INTEGER PRIMARY KEY,
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              content TEXT NOT NULL,
              created_at TEXT NOT NULL,
              UNIQUE(meeting_id, content)
            );
            CREATE TABLE auto_record_attempts (
              occurrence TEXT PRIMARY KEY,
              expires_at TEXT NOT NULL
            );
            """)
        }
        migrator.registerMigration("v3_pending_audio_deletions") { db in
            try db.execute(sql: """
            CREATE TABLE pending_audio_deletions (
              meeting_id TEXT PRIMARY KEY,
              audio_dir TEXT NOT NULL
            );
            """)
        }
        migrator.registerMigration("v4_post_processing_jobs") { db in
            try db.execute(sql: """
            CREATE TABLE post_processing_jobs (
              meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
              status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'failed')),
              enqueued_at TEXT NOT NULL,
              started_at TEXT,
              error TEXT
            );
            """)
        }
        // 録音準備中に録った区間を会議から除くための録音原点、要約の鮮度判定用の入力ハッシュ。
        migrator.registerMigration("v5_recording_origin_and_summary_fingerprint") { db in
            try db.execute(sql: """
            ALTER TABLE meetings ADD COLUMN recording_started_at TEXT;
            ALTER TABLE notes ADD COLUMN input_fingerprint TEXT;
            """)
        }
        // タグ（JSON 配列）。タグ別スマートフォルダは json_each で引く。
        migrator.registerMigration("v6_meeting_tags") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN tags_json TEXT;")
        }
        // 背景の声（相手のマイクが拾った周りの会話）: 相手側の話者の音量と、除外の印（`BackgroundVoices`）。
        migrator.registerMigration("v7_speaker_level_and_exclusion") { db in
            try db.execute(sql: """
            ALTER TABLE speakers ADD COLUMN level_db REAL;
            ALTER TABLE speakers ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0;
            """)
        }
        // 会議の言語（日本語・英語）と、それを会議のあとの自動判定で決めたか。要約の言語（英語の会議は設定で日本語にもできる）。
        migrator.registerMigration("v8_meeting_language") { db in
            try db.execute(sql: """
            ALTER TABLE meetings ADD COLUMN language TEXT;
            ALTER TABLE meetings ADD COLUMN language_detected INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE meetings ADD COLUMN summary_language TEXT;
            """)
        }
        // サーバーで処理した会議の取り込み（iPhone・Apple Watch の録音。SPEC §4.5）:
        // 元の録音の ID、サーバーの文字起こしと要約をそのまま使う印、取り込みの記録（会議を消しても残し、同じ録音を取り込み直さない）。
        migrator.registerMigration("v9_cloud_import") { db in
            try db.execute(sql: """
            ALTER TABLE meetings ADD COLUMN cloud_recording_id TEXT;
            ALTER TABLE meetings ADD COLUMN cloud_processed INTEGER NOT NULL DEFAULT 0;
            CREATE UNIQUE INDEX meetings_cloud_recording_idx ON meetings(cloud_recording_id) WHERE cloud_recording_id IS NOT NULL;
            CREATE TABLE cloud_imports (
              recording_id TEXT PRIMARY KEY,
              meeting_id TEXT,
              status TEXT NOT NULL CHECK (status IN ('imported', 'failed')),
              attempts INTEGER NOT NULL DEFAULT 0,
              attempted_at TEXT NOT NULL,
              error TEXT
            );
            """)
        }
        // やることの済みの同期（P7、SPEC §5.6）: まだサーバーへ送っていない済み（会議・やることごとに最新の 1 つ。会議を消すと消える）と、
        // サーバーの済みをどこまで読んだかなどの小さな値（キーと値）。
        migrator.registerMigration("v10_cloud_action_checks") { db in
            try db.execute(sql: """
            CREATE TABLE cloud_action_pushes (
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              action_id TEXT NOT NULL,
              done INTEGER NOT NULL,
              queued_at TEXT NOT NULL,
              PRIMARY KEY (meeting_id, action_id)
            );
            CREATE TABLE cloud_state (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
        }
        // 題名・話者の名前の同期（P7、SPEC §5.6）: iPhone・Watch から取り込んだ会議を、この Mac で直したもののうち、まだサーバーへ
        // 送っていないもの（会議・欄ごとに最新の 1 つ。field は "title" か "speaker:<ラベル>"、value の NULL は名前を消した。会議を消すと消える）。
        migrator.registerMigration("v11_cloud_edit_pushes") { db in
            try db.execute(sql: """
            CREATE TABLE cloud_edit_pushes (
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              field TEXT NOT NULL,
              value TEXT,
              queued_at TEXT NOT NULL,
              PRIMARY KEY (meeting_id, field)
            );
            """)
        }
        // 題名を付けずに録った会議（SPEC §8.1）: 題名が仮の名前（アプリ名と日時）か、要約が付けた題名である印。
        // 人が題名を付けた・直した会議は 0（この列より前の会議もすべて 0 で、要約の入力は変わらない）。
        migrator.registerMigration("v12_title_auto") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN title_auto INTEGER NOT NULL DEFAULT 0;")
        }
        return migrator
    }
}
