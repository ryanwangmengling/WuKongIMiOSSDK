-- Round 3: 移植 Android 202604150900.sql 的复合索引
-- 对应 Android commit 5b69519（补 5 个索引），来源 wkim/src/main/assets/wk_sql/202604150900.sql
-- 说明：idx_message_id 在 baseline 201911270513.sql 已存在（IF NOT EXISTS 保证幂等）。

CREATE INDEX IF NOT EXISTS idx_msg_message_id ON message(message_id);
CREATE INDEX IF NOT EXISTS idx_msg_channel_order ON message(channel_id, channel_type, order_seq);
CREATE INDEX IF NOT EXISTS idx_msg_channel_seq ON message(channel_id, channel_type, message_seq);
CREATE INDEX IF NOT EXISTS idx_reminders_channel_done ON reminders(channel_id, channel_type, done);
CREATE INDEX IF NOT EXISTS idx_msg_flame ON message(flame, is_deleted);
