import Foundation
import GRDB

/// 统一管理 PaperRss SQLite 数据库的所有 Schema 版本迁移。
///
/// 遵循 Architecture Contract (INV-11)：所有 Schema 变更必须通过统一的 `DatabaseMigrator` 演进，
/// 禁止在业务代码中执行 ad-hoc 的 `CREATE TABLE IF NOT EXISTS`。
public enum DatabaseMigrations {
    /// 返回已注册所有版本迁移的 `DatabaseMigrator` 实例。
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // 生产与调试均严格防止意外擦除数据库
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1-create-library-schema") { db in
            // 1. accounts (账号主表)
            try db.execute(sql: """
            CREATE TABLE accounts (
                id              TEXT PRIMARY KEY NOT NULL,
                type            TEXT NOT NULL,
                display_name    TEXT NOT NULL,
                endpoint_url    TEXT,
                username        TEXT,
                is_enabled      INTEGER NOT NULL DEFAULT 1,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL,

                CHECK (type IN ('local', 'freshRSS'))
            );

            CREATE INDEX idx_accounts_type
            ON accounts(type);
            """)

            // 2. folders (分类目录)
            try db.execute(sql: """
            CREATE TABLE folders (
                id              TEXT PRIMARY KEY NOT NULL,
                account_id      TEXT NOT NULL,
                external_id     TEXT,
                name            TEXT NOT NULL,
                sort_order      INTEGER NOT NULL DEFAULT 0,
                is_deleted      INTEGER NOT NULL DEFAULT 0,
                updated_at      REAL NOT NULL,

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE
            );

            CREATE INDEX idx_folders_account
            ON folders(account_id, is_deleted, sort_order, name);

            CREATE UNIQUE INDEX idx_folders_remote_identity
            ON folders(account_id, external_id)
            WHERE external_id IS NOT NULL;
            """)

            // 3. feeds (订阅源)
            try db.execute(sql: """
            CREATE TABLE feeds (
                id                  TEXT PRIMARY KEY NOT NULL,
                account_id          TEXT NOT NULL,
                external_id         TEXT,
                title               TEXT NOT NULL,
                site_url            TEXT,
                feed_url            TEXT NOT NULL,
                etag                TEXT,
                last_modified       TEXT,
                last_refreshed_at   REAL,
                is_deleted          INTEGER NOT NULL DEFAULT 0,
                updated_at          REAL NOT NULL,
                stored_icon_url     TEXT,
                sort_order          INTEGER NOT NULL DEFAULT 0,

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE
            );

            CREATE INDEX idx_feeds_account
            ON feeds(account_id, is_deleted, sort_order, title);

            CREATE INDEX idx_feeds_url
            ON feeds(account_id, feed_url);

            CREATE UNIQUE INDEX idx_feeds_remote_identity
            ON feeds(account_id, external_id)
            WHERE external_id IS NOT NULL;
            """)

            // 4. feed_folders (Feed 与 Folder 多对多关联)
            try db.execute(sql: """
            CREATE TABLE feed_folders (
                feed_id     TEXT NOT NULL,
                folder_id   TEXT NOT NULL,

                PRIMARY KEY(feed_id, folder_id),

                FOREIGN KEY(feed_id)
                    REFERENCES feeds(id)
                    ON DELETE CASCADE,

                FOREIGN KEY(folder_id)
                    REFERENCES folders(id)
                    ON DELETE CASCADE
            );

            CREATE INDEX idx_feed_folders_folder
            ON feed_folders(folder_id, feed_id);
            """)

            // 5. items (文章身份层)
            try db.execute(sql: """
            CREATE TABLE items (
                id              TEXT PRIMARY KEY NOT NULL,
                account_id      TEXT NOT NULL,
                external_id     TEXT NOT NULL,
                feed_id         TEXT NOT NULL,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL,

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE,

                FOREIGN KEY(feed_id)
                    REFERENCES feeds(id)
                    ON DELETE CASCADE
            );

            CREATE UNIQUE INDEX idx_items_remote_identity
            ON items(account_id, external_id);

            CREATE INDEX idx_items_feed
            ON items(feed_id);
            """)

            // 6. articles (文章内容层)
            try db.execute(sql: """
            CREATE TABLE articles (
                item_id             TEXT PRIMARY KEY NOT NULL,
                title               TEXT NOT NULL,
                author              TEXT,
                url                 TEXT,
                published_at        REAL,
                summary             TEXT NOT NULL DEFAULT '',
                content_html        TEXT,
                content_updated_at  REAL NOT NULL,

                FOREIGN KEY(item_id)
                    REFERENCES items(id)
                    ON DELETE CASCADE
            );

            CREATE INDEX idx_articles_published
            ON articles(published_at DESC);
            """)

            // 7. article_states (文章已读/标星状态层)
            try db.execute(sql: """
            CREATE TABLE article_states (
                item_id          TEXT PRIMARY KEY NOT NULL,
                is_read          INTEGER NOT NULL DEFAULT 0,
                is_starred       INTEGER NOT NULL DEFAULT 0,
                date_arrived     REAL NOT NULL,
                updated_at       REAL NOT NULL,

                FOREIGN KEY(item_id)
                    REFERENCES items(id)
                    ON DELETE CASCADE
            );

            CREATE INDEX idx_article_states_unread
            ON article_states(is_read, item_id);

            CREATE INDEX idx_article_states_starred
            ON article_states(is_starred, item_id);
            """)

            // 8. article_state_outbox (待同步至远端的状态突变持久化队列)
            try db.execute(sql: """
            CREATE TABLE article_state_outbox (
                account_id          TEXT NOT NULL,
                item_id             TEXT NOT NULL,
                state_key           TEXT NOT NULL,
                desired_value       INTEGER NOT NULL,
                revision            INTEGER NOT NULL DEFAULT 1,
                updated_at          REAL NOT NULL,
                attempt_count       INTEGER NOT NULL DEFAULT 0,
                next_attempt_at     REAL,
                last_error          TEXT,

                PRIMARY KEY(account_id, item_id, state_key),

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE,

                FOREIGN KEY(item_id)
                    REFERENCES items(id)
                    ON DELETE CASCADE,

                CHECK(state_key IN ('read', 'starred'))
            );

            CREATE INDEX idx_article_state_outbox_ready
            ON article_state_outbox(account_id, next_attempt_at, updated_at);
            """)

            // 9. article_caches (文章网页提取正文缓存)
            try db.execute(sql: """
            CREATE TABLE article_caches (
                item_id             TEXT PRIMARY KEY NOT NULL,
                text                TEXT NOT NULL,
                html                TEXT,
                image_urls_json     TEXT,
                fetched_at          REAL NOT NULL,
                source_url          TEXT,
                is_sanitized        INTEGER NOT NULL DEFAULT 0,

                FOREIGN KEY(item_id)
                    REFERENCES items(id)
                    ON DELETE CASCADE
            );
            """)

            // 10. ai_artifacts (AI 摘要、全文翻译与划词解析产物)
            try db.execute(sql: """
            CREATE TABLE ai_artifacts (
                id                      TEXT PRIMARY KEY NOT NULL,
                account_id              TEXT,
                item_id                 TEXT,
                subject_key             TEXT NOT NULL,
                kind                    TEXT NOT NULL,
                content_hash            TEXT NOT NULL,
                model                   TEXT NOT NULL,
                target_language         TEXT NOT NULL,
                prompt_version          INTEGER NOT NULL DEFAULT 1,
                content                 TEXT NOT NULL DEFAULT '',
                segments_json           TEXT,
                selection_text          TEXT,
                selection_article_hash  TEXT,
                selection_anchor_json   TEXT,
                is_complete             INTEGER NOT NULL DEFAULT 0,
                is_deleted              INTEGER NOT NULL DEFAULT 0,
                created_at              REAL NOT NULL,
                updated_at              REAL NOT NULL,

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE,

                FOREIGN KEY(item_id)
                    REFERENCES items(id)
                    ON DELETE SET NULL
            );

            CREATE INDEX idx_ai_artifacts_article_lookup
            ON ai_artifacts(item_id, kind, content_hash, updated_at DESC);

            CREATE INDEX idx_ai_artifacts_subject_lookup
            ON ai_artifacts(subject_key, kind, content_hash, updated_at DESC);
            """)

            // 11. account_sync_state (账号同步进度与错误状态)
            try db.execute(sql: """
            CREATE TABLE account_sync_state (
                account_id                  TEXT PRIMARY KEY NOT NULL,
                initial_sync_completed      INTEGER NOT NULL DEFAULT 0,
                last_sync_started_at        REAL,
                last_sync_completed_at      REAL,
                last_full_reconcile_at      REAL,
                last_article_fetch_at       REAL,
                consecutive_failure_count   INTEGER NOT NULL DEFAULT 0,
                last_error                  TEXT,

                FOREIGN KEY(account_id)
                    REFERENCES accounts(id)
                    ON DELETE CASCADE
            );
            """)
        }

        return migrator
    }
}
