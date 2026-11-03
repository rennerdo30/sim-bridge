import assert from 'node:assert/strict';
import test from 'node:test';
import { retention, TRANSIENT_TTL_MS, RECEIPT_TTL_MS } from '../src/memory.mjs';
import { createMemoryDatabase } from '../src/sqlite-node.mjs';

test('relational transaction state uses only memory journal and temporary storage', () => {
  const db = createMemoryDatabase();
  try {
    assert.equal(db.name, ':memory:');
    assert.equal(db.pragma('journal_mode', { simple: true }), 'memory');
    assert.equal(db.pragma('temp_store', { simple: true }), 2);
    assert.equal(db.pragma('foreign_keys', { simple: true }), 1);
    assert.throws(() => db.transaction(() => {
      db.prepare('INSERT INTO bridges VALUES (?, ?, ?, ?)').run('bridge', 'hashed-verifier', 'synthetic-time', 1);
      throw new Error('synthetic rollback');
    })(), /synthetic rollback/);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM bridges').get().n, 0);
  } finally { db.close(); }
});

test('retention configuration may shorten but never extend the five-minute and 24-hour caps', () => {
  assert.equal(TRANSIENT_TTL_MS, 300000); assert.equal(RECEIPT_TTL_MS, 86400000);
  for (const value of [undefined, '', 'nonsense', '0', '-1', '1.5', Infinity]) assert.equal(retention(value, TRANSIENT_TTL_MS), TRANSIENT_TTL_MS);
  assert.equal(retention('100', TRANSIENT_TTL_MS), 100);
  assert.equal(retention('86400000', TRANSIENT_TTL_MS), TRANSIENT_TTL_MS);
  assert.equal(retention('9999999999', RECEIPT_TTL_MS), RECEIPT_TTL_MS);
});
