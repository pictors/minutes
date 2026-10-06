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
        return migrator
    }
}
