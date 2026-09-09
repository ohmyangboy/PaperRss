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

        migrator.registerMigration("v2-clean-local-account-sync-state") { db in
            try db.execute(sql: """
            DELETE FROM account_sync_state
            WHERE account_id = 'local-default';
            """)
        }

        migrator.registerMigration("v3-normalize-local-item-external-identity") { db in
            guard try db.tableExists("items") else { return }
            try db.execute(sql: """
            UPDATE items
            SET external_id = id
            WHERE account_id IN (
                SELECT id FROM accounts WHERE type = 'local'
            );
            """)
        }

        migrator.registerMigration("v4-add-article-cache-normalization-revision") { db in
            guard try db.tableExists("article_caches") else { return }
            try db.execute(sql: """
            ALTER TABLE article_caches
            ADD COLUMN normalization_revision INTEGER NOT NULL DEFAULT 0;
            """)
        }

        migrator.registerMigration("v5-add-ai-artifact-execution-fingerprint") { db in
            guard try db.tableExists("ai_artifacts") else { return }
            try db.execute(sql: "ALTER TABLE ai_artifacts ADD COLUMN provider_id TEXT;")
            try db.execute(sql: "ALTER TABLE ai_artifacts ADD COLUMN configuration_fingerprint TEXT;")
            try db.execute(sql: """
            CREATE INDEX idx_ai_artifacts_exact_execution
            ON ai_artifacts(item_id, kind, content_hash, configuration_fingerprint, updated_at DESC);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_ai_artifacts_subject_execution
            ON ai_artifacts(subject_key, kind, content_hash, configuration_fingerprint, updated_at DESC);
            """)
        }

        migrator.registerMigration("v6-canonicalize-current-ai-summaries") { db in
            guard try db.tableExists("ai_artifacts") else { return }
            try db.execute(sql: """
            WITH ranked AS (
                SELECT id,
                       ROW_NUMBER() OVER (
                           PARTITION BY subject_key
                           ORDER BY updated_at DESC, created_at DESC, id DESC
                       ) AS position
                FROM ai_artifacts
                WHERE kind = 'summary'
                  AND is_complete = 1
                  AND is_deleted = 0
            )
            UPDATE ai_artifacts
            SET is_deleted = 1
            WHERE kind = 'summary'
              AND id NOT IN (SELECT id FROM ranked WHERE position = 1);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_ai_artifacts_current_summary
            ON ai_artifacts(subject_key, kind, is_complete, is_deleted, updated_at DESC);
            """)
        }

        migrator.registerMigration("v7-auto-translation") { db in
            try db.execute(sql: """
            CREATE TABLE auto_translation_rules (
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                scope TEXT NOT NULL CHECK(scope IN ('feed', 'folder', 'article')),
                entity_id TEXT NOT NULL,
                rule TEXT NOT NULL CHECK(rule IN ('off', 'foreignLanguage')),
                PRIMARY KEY(account_id, scope, entity_id)
            );
            CREATE TABLE source_language_hints (
                scope TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                hints_json TEXT NOT NULL,
                PRIMARY KEY(scope, entity_id)
            );
            """)
            if try db.tableExists("article_caches") {
                try db.execute(sql: "ALTER TABLE article_caches ADD COLUMN language_hints_json TEXT;")
            }
            // 兼容只包含部分旧表的迁移测试与恢复数据库。
            for (table, scope, key) in [("items", "article", "id"), ("feeds", "feed", "id"), ("folders", "folder", "id")] {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: """
                CREATE TRIGGER auto_translation_delete_\(table) AFTER DELETE ON \(table) BEGIN
                    DELETE FROM auto_translation_rules WHERE scope = '\(scope)' AND entity_id = OLD.\(key);
                    DELETE FROM source_language_hints WHERE scope = '\(scope)' AND entity_id = OLD.\(key);
                END;
                """)
            }
        }

        migrator.registerMigration("v8-auto-translation-name-rules") { db in
            try db.execute(sql: """
            CREATE TABLE auto_translation_name_rules (
                id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                payload_json TEXT NOT NULL
            );
            """)
        }

        migrator.registerMigration("v9-simple-translation-feed-lists") { db in
            // 旧模式及继承规则退役；只保留用户对单篇文章的手动关闭记录。
            try db.execute(sql: """
                CREATE TABLE translation_feed_lists (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
                    list TEXT NOT NULL CHECK(list IN ('whitelist', 'blacklist')),
                    PRIMARY KEY(account_id, feed_id)
                );
                CREATE TABLE translation_article_exemptions (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    item_id TEXT NOT NULL,
                    PRIMARY KEY(account_id, item_id)
                );
                INSERT INTO translation_article_exemptions(account_id, item_id)
                    SELECT account_id, entity_id FROM auto_translation_rules WHERE scope = 'article' AND rule = 'off';
                DROP TRIGGER IF EXISTS auto_translation_delete_items;
                DROP TRIGGER IF EXISTS auto_translation_delete_feeds;
                DROP TRIGGER IF EXISTS auto_translation_delete_folders;
                DROP TABLE auto_translation_rules;
                DROP TABLE auto_translation_name_rules;
                """)
            for (table, scope) in [("items", "article"), ("feeds", "feed")] {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: """
                    CREATE TRIGGER translation_delete_\(table) AFTER DELETE ON \(table) BEGIN
                        DELETE FROM source_language_hints WHERE scope = '\(scope)' AND entity_id = OLD.id;
                    END;
                    """)
            }
            if try db.tableExists("items") {
                try db.execute(sql: """
                    CREATE TRIGGER translation_delete_exemptions AFTER DELETE ON items BEGIN
                        DELETE FROM translation_article_exemptions WHERE account_id = OLD.account_id AND item_id = OLD.id;
                    END;
                    """)
            }
        }

        migrator.registerMigration("v10-sanitize-freshrss-placeholder-icons") { db in
            guard try db.tableExists("feeds") else { return }
            let columns = try db.columns(in: "feeds")
            guard columns.contains(where: { $0.name == "stored_icon_url" }) else { return }

            // 清理被 FreshRSS 内部占位图 (/f.php) 污染的 stored_icon_url。
            // 优先用同一个数据库中相同 feed_url 且拥有有效真实图标（不含 /f.php）的记录恢复。
            try db.execute(sql: """
                UPDATE feeds
                SET stored_icon_url = (
                    SELECT f2.stored_icon_url
                    FROM feeds f2
                    WHERE f2.feed_url = feeds.feed_url
                      AND f2.stored_icon_url IS NOT NULL
                      AND f2.stored_icon_url != ''
                      AND f2.stored_icon_url NOT LIKE '%f.php%'
                    LIMIT 1
                )
                WHERE stored_icon_url LIKE '%f.php%';
            """)
        }

        migrator.registerMigration("v11-deduplicate-feed-articles") { db in
            guard try db.tableExists("items") && db.tableExists("articles") else { return }

            // 1. 针对同一 feed 内按 URL 重复的 items 进行去重与状态/产物融合
            try db.execute(sql: """
                CREATE TEMP TABLE duplicate_item_pairs AS
                WITH ranked_items AS (
                    SELECT i.id AS redundant_item_id,
                           i.feed_id,
                           a.url,
                           FIRST_VALUE(i.id) OVER (
                               PARTITION BY i.feed_id, a.url
                               ORDER BY i.created_at DESC, i.updated_at DESC, i.id DESC
                           ) AS surviving_item_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY i.feed_id, a.url
                               ORDER BY i.created_at DESC, i.updated_at DESC, i.id DESC
                           ) AS rank_num
                    FROM items i
                    JOIN articles a ON a.item_id = i.id
                    WHERE a.url IS NOT NULL AND TRIM(a.url) != ''
                )
                SELECT redundant_item_id, surviving_item_id
                FROM ranked_items
                WHERE rank_num > 1;
            """)

            // 1.1 将冗余 item 上的 ai_artifacts 转移给 surviving item (若 surviving item 尚无该 kind 的产物)
            if try db.tableExists("ai_artifacts") {
                try db.execute(sql: """
                    UPDATE ai_artifacts
                    SET item_id = (
                        SELECT p.surviving_item_id
                        FROM duplicate_item_pairs p
                        WHERE p.redundant_item_id = ai_artifacts.item_id
                    )
                    WHERE item_id IN (SELECT redundant_item_id FROM duplicate_item_pairs)
                      AND NOT EXISTS (
                        SELECT 1 FROM ai_artifacts a2
                        JOIN duplicate_item_pairs p ON p.surviving_item_id = a2.item_id
                        WHERE p.redundant_item_id = ai_artifacts.item_id
                          AND a2.kind = ai_artifacts.kind
                      );
                """)
            }

            // 1.2 将冗余 item 的已读/标星状态融合迁移给 surviving item
            if try db.tableExists("article_states") {
                try db.execute(sql: """
                    UPDATE article_states
                    SET is_read = 1
                    WHERE item_id IN (
                        SELECT p.surviving_item_id
                        FROM duplicate_item_pairs p
                        JOIN article_states s ON s.item_id = p.redundant_item_id
                        WHERE s.is_read = 1
                    );

                    UPDATE article_states
                    SET is_starred = 1
                    WHERE item_id IN (
                        SELECT p.surviving_item_id
                        FROM duplicate_item_pairs p
                        JOIN article_states s ON s.item_id = p.redundant_item_id
                        WHERE s.is_starred = 1
                    );
                """)
            }

            // 1.3 删除冗余 items
            try db.execute(sql: """
                DELETE FROM items WHERE id IN (SELECT redundant_item_id FROM duplicate_item_pairs);
                DROP TABLE duplicate_item_pairs;
            """)

            // 2. 清理已软删除远端 feeds 残留的 items
            if try db.tableExists("feeds") {
                try db.execute(sql: """
                    DELETE FROM items
                    WHERE feed_id IN (
                        SELECT id FROM feeds
                        WHERE is_deleted = 1 AND account_id != 'local-default'
                    );
                """)
            }

            // 3. 全局外键对齐与防御级联清理 (迁移期间 foreign_keys 禁用，显式模拟外键 ON DELETE SET NULL 与 ON DELETE CASCADE)
            if try db.tableExists("ai_artifacts") {
                try db.execute(sql: """
                    UPDATE ai_artifacts
                    SET item_id = NULL
                    WHERE item_id IS NOT NULL
                      AND item_id NOT IN (SELECT id FROM items);
                """)
            }

            try db.execute(sql: """
                DELETE FROM articles WHERE item_id NOT IN (SELECT id FROM items);
            """)

            if try db.tableExists("article_states") {
                try db.execute(sql: """
                    DELETE FROM article_states WHERE item_id NOT IN (SELECT id FROM items);
                """)
            }

            if try db.tableExists("article_caches") {
                try db.execute(sql: """
                    DELETE FROM article_caches WHERE item_id NOT IN (SELECT id FROM items);
                """)
            }

            if try db.tableExists("article_state_outbox") {
                try db.execute(sql: """
                    DELETE FROM article_state_outbox WHERE item_id NOT IN (SELECT id FROM items);
                """)
            }
        }

        return migrator
    }
}
