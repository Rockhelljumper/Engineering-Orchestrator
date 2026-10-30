import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { AnchorError, type AnchorBackend, type AnchorHead } from './anchor.ts';

/**
 * Client for the eo-anchor service (M2 Phase B, R1): the rollback anchor held by a separate
 * account on its own disk, reached over a Unix socket. It replaces the anchor directory when
 * EO_ANCHOR_SOCKET (or the controller's anchorSocket option) is set.
 *
 * The service, not this client, enforces the rules: only the controller's uid may connect,
 * each advance must be the exact next journal record (or an exact retry), an unknown state
 * root starts only at seq 1 from genesis unless an operator granted otherwise, and forget
 * needs an operator's grant. Every refusal is recorded on the anchor disk and locks that
 * state root until an operator clears it, so a refusal here is final for this process.
 *
 * Node cannot read a Unix socket peer's credentials, so each call runs a small Python helper
 * (services/anchor/eo_anchor_client.py) that checks the socket belongs to root or the anchor
 * account before it sends anything. Calls are synchronous, like the directory anchor's, because
 * the journal records each append's head before the append returns.
 */

const HELPER = fileURLToPath(new URL('../services/anchor/eo_anchor_client.py', import.meta.url));

interface Reply {
  ok: boolean;
  refused?: boolean;
  reason?: string;
  error?: string;
  anchorId?: string;
  protocol?: number;
  head?: AnchorHead | null;
}

export class AnchorServiceClient implements AnchorBackend {
  readonly dir: string;
  readonly id: string;
  private readonly socket: string;

  private constructor(socket: string, id: string) {
    this.socket = socket;
    this.dir = `eo-anchor service at ${socket}`;
    this.id = id;
  }

  static open(socket: string): AnchorServiceClient {
    const r = call(socket, { op: 'hello' });
    if (r.protocol !== 1 || typeof r.anchorId !== 'string' || !/^[0-9a-f]{32}$/.test(r.anchorId)) {
      throw new AnchorError(`the anchor service at ${socket} gave an unexpected greeting`);
    }
    return new AnchorServiceClient(socket, r.anchorId);
  }

  read(rootId: string): AnchorHead | null {
    return this.head(call(this.socket, { op: 'read', rootId }), rootId);
  }

  rawHead(rootId: string): string | null {
    try {
      const h = this.read(rootId);
      return h ? Buffer.from(JSON.stringify(h)).toString('base64') : null;
    } catch {
      return null;
    }
  }

  advance(rootId: string, keyId: string, root: string, journalSeq: number, journalMac: string, prevJournalMac?: string): AnchorHead {
    if (prevJournalMac === undefined) throw new AnchorError('the anchor service needs the previous journal MAC with every advance');
    const h = this.head(call(this.socket, { op: 'advance', rootId, keyId, root, seq: journalSeq, journalMac, prevJournalMac }), rootId);
    if (!h || h.journalSeq !== journalSeq || h.journalMac !== journalMac) throw new AnchorError(`the anchor service did not record journal seq ${journalSeq} of ${rootId}`);
    return h;
  }

  forget(rootId: string): void {
    const r = call(this.socket, { op: 'forget', rootId });
    if (r.head !== null) throw new AnchorError(`the anchor service did not drop the head of ${rootId}`);
  }

  private head(r: Reply, rootId: string): AnchorHead | null {
    if (r.anchorId !== this.id) throw new AnchorError(`the anchor service's id changed from ${this.id} to ${r.anchorId ?? 'none'}`);
    const h = r.head ?? null;
    if (h && (h.rootId !== rootId || h.anchorId !== this.id || !Number.isInteger(h.journalSeq) || h.journalSeq < 1)) {
      throw new AnchorError(`the anchor service returned a head that is not for ${rootId}`);
    }
    return h;
  }
}

function call(socket: string, req: Record<string, unknown>): Reply {
  let out: string;
  try {
    out = execFileSync(process.env['EO_PYTHON'] ?? 'python3', ['-I', HELPER, '--socket', socket, ...serverUserArgs()], {
      input: JSON.stringify(req),
      encoding: 'utf8',
      timeout: 30_000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (err) {
    const e = err as { stdout?: string; message: string };
    out = e.stdout ?? '';
    if (!out.trim()) throw new AnchorError(`cannot reach the anchor service at ${socket}: ${e.message}`);
  }
  let r: Reply;
  try {
    r = JSON.parse(out) as Reply;
  } catch {
    throw new AnchorError(`the anchor service at ${socket} sent an unreadable reply`);
  }
  if (!r.ok) {
    if (r.refused) throw new AnchorError(`the anchor service refused the request: ${r.reason ?? 'no reason given'}`);
    throw new AnchorError(`the anchor service failed: ${r.error ?? r.reason ?? 'unknown error'}`);
  }
  return r;
}

/** Tests run the service as the test user; production checks for the eo-anchor account. */
function serverUserArgs(): string[] {
  const u = process.env['EO_ANCHOR_SERVER_USER'];
  return u ? ['--server-user', u] : [];
}
