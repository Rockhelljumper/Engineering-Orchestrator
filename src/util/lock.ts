import * as fs from 'node:fs';
import { randomBytes } from 'node:crypto';
import { isProcessAlive } from './fsx.ts';

interface LockInfo {
  pid: number;
  owner: string;
  acquiredAt: string;
  /** Random per acquisition, so release removes only the lock this instance created. */
  nonce: string;
}

/** Lock files held by FileLock instances in this process. */
const heldHere = new Set<string>();

/**
 * Cross-process exclusive lock using O_EXCL file creation, which is atomic on local
 * filesystems on Linux, macOS and Windows. A lock whose holder process no longer exists
 * is treated as stale and taken over.
 */
export class FileLock {
  readonly file: string;
  readonly owner: string;
  private held = false;
  private nonce = '';

  constructor(file: string, owner: string) {
    this.file = file;
    this.owner = owner;
  }

  tryAcquire(): boolean {
    for (let i = 0; i < 2; i++) {
      try {
        const fd = fs.openSync(this.file, 'wx', 0o600);
        this.nonce = randomBytes(8).toString('hex');
        const info: LockInfo = { pid: process.pid, owner: this.owner, acquiredAt: new Date().toISOString(), nonce: this.nonce };
        fs.writeSync(fd, JSON.stringify(info));
        fs.closeSync(fd);
        // A holder paused between the create and the write (longer than an empty lock stays
        // fresh) can have its file removed as stale and replaced by a contender's; it must not
        // then believe it holds the lock.
        if (!this.stillOurs()) {
          this.nonce = '';
          return false;
        }
        this.held = true;
        heldHere.add(this.file);
        return true;
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code;
        // Windows reports EPERM while a just-deleted lock file is still open elsewhere
        // ("delete pending"); the lock is changing hands, so treat it as busy.
        if (process.platform === 'win32' && (code === 'EPERM' || code === 'EACCES')) return false;
        if (code !== 'EEXIST') throw err;
        if (!this.removeIfStale()) return false;
      }
    }
    return false;
  }

  /** Spin with short sleeps until acquired or the timeout passes. */
  acquire(timeoutMs = 10_000): void {
    const deadline = Date.now() + timeoutMs;
    while (!this.tryAcquire()) {
      if (Date.now() > deadline) throw new Error(`lock busy: ${this.file} (${describe(this.file)})`);
      sleepSync(5 + Math.floor(Math.random() * 10));
    }
  }

  private stillOurs(): boolean {
    try {
      return (JSON.parse(fs.readFileSync(this.file, 'utf8')) as LockInfo).nonce === this.nonce;
    } catch {
      return false;
    }
  }

  release(): void {
    if (!this.held) return;
    this.held = false;
    heldHere.delete(this.file);
    try {
      // Only remove the lock if it is still ours (a stale-lock takeover may have replaced it).
      const info = JSON.parse(fs.readFileSync(this.file, 'utf8')) as LockInfo;
      if (info.nonce === this.nonce) fs.unlinkSync(this.file);
    } catch {
      // already gone
    }
  }

  /**
   * Remove the lock file if its holder is gone. Two contenders can both see the same stale
   * lock; without care the slower one would delete the fresh lock the faster one just made.
   * So removal happens only while holding a short-lived breaker lock, after re-checking.
   * Returns true if the caller should retry acquiring.
   */
  private removeIfStale(retried = false): boolean {
    if (!fs.existsSync(this.file)) return true; // released between our create and this check
    if (!isStale(this.file)) return false;
    const breaker = `${this.file}.break`;
    let fd: number;
    try {
      fd = fs.openSync(breaker, 'wx', 0o600);
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (process.platform === 'win32' && (code === 'EPERM' || code === 'EACCES')) return false; // delete pending
      if (code !== 'EEXIST') throw err;
      // A breaker left by a process killed in this tiny window is cleared after 10s, and the
      // takeover goes ahead at once (it used to need a second attempt).
      let expired = false;
      try {
        if (Date.now() - fs.statSync(breaker).mtimeMs > 10_000) {
          fs.unlinkSync(breaker);
          expired = true;
        }
      } catch {
        // gone already
      }
      return expired && !retried ? this.removeIfStale(true) : false;
    }
    fs.closeSync(fd);
    try {
      if (!isStale(this.file)) return false;
      try {
        fs.unlinkSync(this.file);
      } catch {
        // removed by its holder meanwhile
      }
      return true;
    } finally {
      try {
        fs.unlinkSync(breaker);
      } catch {
        // cleared as stale by another process
      }
    }
  }
}

function isStale(file: string): boolean {
  let info: LockInfo;
  try {
    info = JSON.parse(fs.readFileSync(file, 'utf8')) as LockInfo;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return false;
    // Holder may be mid-write. Unreadable content older than 30s is stale. An empty file is
    // written by the same call that created it, microseconds later; one that is still empty
    // after 2 s was left by a holder killed between the two (found by the M2-0 kill runs).
    try {
      const st = fs.statSync(file);
      return Date.now() - st.mtimeMs > (st.size === 0 ? 2_000 : 30_000);
    } catch {
      return false;
    }
  }
  // Our own pid: held if an instance in this process holds it, else left by a dead process
  // whose pid was reused.
  if (info.pid === process.pid) return !heldHere.has(file);
  return !isProcessAlive(info.pid);
}

/**
 * Who holds a lock, for an error message: the holder and whether it is alive, or why nobody
 * may take it yet (an empty lock still being written, or a takeover's breaker left by a kill).
 */
export function describeLock(file: string): string {
  let body: string;
  try {
    body = fs.readFileSync(file, 'utf8');
  } catch {
    return 'the lock is gone';
  }
  const parts: string[] = [];
  try {
    const info = JSON.parse(body) as LockInfo;
    parts.push(`held by ${info.owner} (pid ${info.pid}, ${isProcessAlive(info.pid) ? 'running' : 'not running'})`);
  } catch {
    parts.push('the lock file is empty or partial (its holder may have been killed while writing it; it is taken over after 2 s)');
  }
  try {
    const age = Date.now() - fs.statSync(`${file}.break`).mtimeMs;
    parts.push(`a takeover is in progress or was cut short by a kill (${file}.break, ${Math.round(age / 1000)} s old; cleared after 10 s)`);
  } catch {
    // no breaker
  }
  return parts.join('; ');
}

function describe(file: string): string {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return 'unreadable';
  }
}

const sab = new Int32Array(new SharedArrayBuffer(4));
export function sleepSync(ms: number): void {
  Atomics.wait(sab, 0, 0, ms);
}

export function withLock<T>(file: string, owner: string, fn: () => T, timeoutMs?: number): T {
  const lock = new FileLock(file, owner);
  lock.acquire(timeoutMs);
  try {
    return fn();
  } finally {
    lock.release();
  }
}
