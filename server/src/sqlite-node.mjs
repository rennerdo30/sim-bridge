import Database from 'better-sqlite3';
import { prepareMemorySchema } from './memory.mjs';

/** Node relay database: SQLite held only in process memory. */
export function createMemoryDatabase() {
  const database = new Database(':memory:');
  return prepareMemorySchema(database);
}

/**
 * The WebAssembly engine used on Cloudflare. Node can run it too, so the
 * full relay test suite verifies both engines.
 */
export async function createWasmDatabaseForNode() {
  const { default: initSqlJs } = await import('sql.js');
  const { createWasmMemoryDatabase } = await import('./sqlite-wasm.mjs');
  return createWasmMemoryDatabase(await initSqlJs());
}
