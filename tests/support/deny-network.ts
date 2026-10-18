// Preload (node --import) that records and refuses every outbound network API in the process.
// Used by the M1-6 test; EO_NET_LOG names the file that receives one line per attempt.
import * as fs from 'node:fs';
import { createRequire, syncBuiltinESMExports } from 'node:module';

// Patch the mutable CommonJS module objects (ESM namespace objects are read-only), then
// sync the builtins' ESM named exports so `import { connect } from 'node:net'` sees them too.
const require = createRequire(import.meta.url);
const net = require('node:net') as typeof import('node:net');
const dns = require('node:dns') as typeof import('node:dns');
const dgram = require('node:dgram') as typeof import('node:dgram');

const logFile = process.env['EO_NET_LOG'];

function deny(api: string, detail: unknown): never {
  if (logFile) fs.appendFileSync(logFile, JSON.stringify({ api, detail: String(detail), pid: process.pid }) + '\n');
  throw new Error(`network access denied by test preload: ${api}`);
}

const socketConnect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (this: import('node:net').Socket, ...args: unknown[]) {
  const first = args[0] as { path?: string } | string | undefined;
  // Local IPC (Unix sockets, Windows named pipes) is not network access.
  const isIpc = (typeof first === 'object' && first !== null && typeof first.path === 'string') || (typeof first === 'string' && Number.isNaN(Number(first)));
  if (isIpc) return (socketConnect as (...a: unknown[]) => import('node:net').Socket).apply(this, args);
  return deny('net.Socket.connect', JSON.stringify(args[0]));
} as typeof net.Socket.prototype.connect;

for (const name of ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny'] as const) {
  (dns as unknown as Record<string, unknown>)[name] = (host: unknown) => deny(`dns.${name}`, host);
  (dns.promises as unknown as Record<string, unknown>)[name] = (host: unknown) => deny(`dns.promises.${name}`, host);
}
(dgram as unknown as Record<string, unknown>)['createSocket'] = (t: unknown) => deny('dgram.createSocket', t);
globalThis.fetch = ((input: unknown) => deny('fetch', input)) as typeof fetch;
syncBuiltinESMExports();
