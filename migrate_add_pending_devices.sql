-- 修复缺失的 pending_devices 表
-- 如果从旧版本升级，可能缺少此表

CREATE TABLE IF NOT EXISTS pending_devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mac_address TEXT UNIQUE NOT NULL,
  first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  hostname TEXT,
  status TEXT DEFAULT 'pending'
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_pending_devices_status ON pending_devices(status);
CREATE INDEX IF NOT EXISTS idx_pending_devices_mac ON pending_devices(mac_address);
