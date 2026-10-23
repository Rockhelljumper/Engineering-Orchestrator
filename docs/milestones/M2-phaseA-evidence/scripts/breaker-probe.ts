import * as fs from 'node:fs';
import * as path from 'node:path';
const R = process.argv[2] as string;
const h = await import(path.join(R, 'tests/support/helpers.ts'));
const { Controller } = await import(path.join(R, 'src/controller.ts'));
const sb = h.sandbox();
const lock = path.join(sb.root, 'locks', 'controller.lock');
// A controller killed while taking over a dead controller's lock: the dead lock and a fresh breaker remain.
fs.writeFileSync(lock, JSON.stringify({ pid: 999999, owner: 'controller:dead', acquiredAt: new Date().toISOString(), nonce: 'x' }));
fs.writeFileSync(lock + '.break', '');
try { Controller.open(sb.root).close(); console.log('fresh breaker: opened'); } catch (e) { console.log('fresh breaker: refused:', (e as Error).message); }
const old = (Date.now() - 11_000) / 1000;
fs.utimesSync(lock + '.break', old, old);
try { Controller.open(sb.root).close(); console.log('breaker 11 s old: refused once? '); } catch (e) { console.log('breaker 11 s old, first open: refused:', (e as Error).message); }
try { Controller.open(sb.root).close(); console.log('breaker 11 s old, next open: opened'); } catch (e) { console.log('breaker 11 s old, next open: refused:', (e as Error).message); }
