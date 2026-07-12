// Smoke test for the cairn_node native addon.
//
// Proves: the addon loads (require succeeds), the napi class registers, a
// sync getter call works (FFI seam without the async runtime), an async
// Promise method works (tokio_rt path), and a full query round-trip works
// (rusqlite-bundled linked + serde_json serializes) — all without a native
// crash and without any network (in-memory SQLite, no subscribe()).
//
// Run: node smoke.cjs  (after building the addon, see scripts below)
'use strict';

const path = require('path');

const addonPath = path.join(__dirname, 'cairn_node.node');
let addon;
try {
  addon = require(addonPath);
} catch (e) {
  console.error('FAIL: require addon threw:', e);
  process.exit(1);
}
console.log('[1] require(addon) OK — exports:', Object.keys(addon));

const CairnClient = addon.CairnClient;
if (typeof CairnClient !== 'function') {
  console.error('FAIL: CairnClient class missing from exports');
  process.exit(1);
}

// Construct (sync). No network, no disk — in-memory SQLite.
const client = new CairnClient('ws://localhost:0', null, ':memory:');
console.log('[2] new CairnClient(...) OK');

// Sync getter — proves a non-Promise FFI call works.
const url = client.url;
console.log('[3] sync getter url =', JSON.stringify(url));

(async () => {
  try {
    await client.connect();
    console.log('[4] await connect() OK (opened in-memory SQLite, built SyncClient)');

    const rowsJson = await client.query('SELECT 1 AS one');
    console.log('[5] await query(SELECT 1 AS one) =', rowsJson);

    const parsed = JSON.parse(rowsJson);
    if (!Array.isArray(parsed) || parsed.length !== 1 || parsed[0].one !== 1) {
      throw new Error('unexpected query shape: ' + rowsJson);
    }

    await client.close();
    console.log('[6] await close() OK');

    console.log('PASS: cairn_node addon loads + constructs + async query round-trips');
    process.exit(0);
  } catch (e) {
    console.error('FAIL during async methods:', e);
    process.exit(1);
  }
})();
