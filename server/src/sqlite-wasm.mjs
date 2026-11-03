import { prepareMemorySchema } from './memory.mjs';

/**
 * Wraps an in-memory sql.js (SQLite compiled to WebAssembly) database in the
 * small part of the better-sqlite3 API the relay uses: prepared statements
 * with positional parameters, `exec`, `pragma`, nested transactions and
 * `close`. Nothing is ever exported or written outside process memory.
 *
 * @param {object} SQL an initialized sql.js module
 */
export function createWasmMemoryDatabase(SQL) {
  const db = new SQL.Database();
  const bind = params => params.map(value => {
    if (value === undefined) return null;
    if (typeof value === 'boolean') return value ? 1 : 0;
    if (typeof value === 'bigint') return Number(value);
    return value;
  });
  // Statements are cached per SQL text, as better-sqlite3 callers expect
  // `prepare` to be cheap enough to call on every request.
  const statements = new Map();
  const statement = sql => {
    let prepared = statements.get(sql);
    if (!prepared) { prepared = db.prepare(sql); statements.set(sql, prepared); }
    return prepared;
  };
  const rows = (sql, params, limit = Infinity) => {
    const prepared = statement(sql);
    const result = [];
    try {
      prepared.bind(bind(params));
      while (result.length < limit && prepared.step()) result.push(prepared.getAsObject());
    } finally { prepared.reset(); }
    return result;
  };
  let depth = 0;
  const database = {
    prepare(sql) {
      return {
        run(...params) {
          const prepared = statement(sql);
          try {
            prepared.bind(bind(params));
            prepared.step();
          } finally { prepared.reset(); }
          const changes = db.getRowsModified();
          const lastInsertRowid = changes ? db.exec('SELECT last_insert_rowid()')[0].values[0][0] : 0;
          return { changes, lastInsertRowid };
        },
        get: (...params) => rows(sql, params, 1)[0],
        all: (...params) => rows(sql, params),
      };
    },
    exec(sql) { db.exec(sql); return database; },
    pragma(text) { db.exec(`PRAGMA ${text}`); },
    transaction(fn) {
      return (...args) => {
        // Savepoints give nested transactions the same all-or-nothing scope
        // that better-sqlite3 provides.
        const name = `relay_tx_${depth++}`;
        db.exec(`SAVEPOINT ${name}`);
        try {
          const value = fn(...args);
          db.exec(`RELEASE ${name}`);
          return value;
        } catch (error) {
          db.exec(`ROLLBACK TO ${name}`);
          db.exec(`RELEASE ${name}`);
          throw error;
        } finally { depth--; }
      };
    },
    close() {
      for (const prepared of statements.values()) prepared.free();
      statements.clear();
      db.close();
    },
  };
  return prepareMemorySchema(database);
}
