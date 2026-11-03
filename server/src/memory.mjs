export const TRANSIENT_TTL_MS = 5 * 60 * 1000;
export const RECEIPT_TTL_MS = 24 * 60 * 60 * 1000;

// Tests/operators may shorten retention, never extend the confidentiality cap.
export function retention(value, maximum) {
  const requested = Number(value);
  return Number.isInteger(requested) && requested > 0
    ? Math.min(requested, maximum) : maximum;
}

/**
 * Creates the relay tables in an in-memory SQLite database. The database is
 * supplied by the runtime: better-sqlite3 under Node, sql.js on Cloudflare.
 */
export function prepareMemorySchema(database) {
  database.pragma('temp_store = MEMORY');
  database.pragma('journal_mode = MEMORY');
  database.pragma('foreign_keys = ON');
  database.exec(`
    CREATE TABLE bridges (
      id TEXT PRIMARY KEY, invite_token TEXT NOT NULL, created_at TEXT NOT NULL,
      joinable INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE devices (
      id TEXT PRIMARY KEY, bridge_id TEXT NOT NULL REFERENCES bridges(id) ON DELETE CASCADE,
      name TEXT NOT NULL, capabilities TEXT NOT NULL, last_seen_at TEXT NOT NULL,
      is_owner INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE device_tokens (
      token_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE);
    CREATE TABLE messages (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
      bridge_id TEXT NOT NULL REFERENCES bridges(id) ON DELETE CASCADE,
      gateway_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      envelope TEXT NOT NULL, received_at TEXT NOT NULL);
    CREATE TABLE commands (
      id TEXT PRIMARY KEY, bridge_id TEXT NOT NULL REFERENCES bridges(id) ON DELETE CASCADE,
      target_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      requested_by TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      envelope TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, completed_at TEXT);
    CREATE TABLE message_upload_receipts (
      device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      upload_id TEXT NOT NULL, response TEXT NOT NULL, created_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, upload_id));
    CREATE INDEX devices_bridge_idx ON devices(bridge_id);
    CREATE INDEX messages_bridge_idx ON messages(bridge_id);
    CREATE INDEX commands_bridge_target_idx ON commands(bridge_id, target_device_id, status);
  `);
  return database;
}
