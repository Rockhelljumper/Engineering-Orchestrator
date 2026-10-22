import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';

export function writeAll(fd: number, data: string | Buffer): void {
  const buf = typeof data === 'string' ? Buffer.from(data) : data;
  let off = 0;
  while (off < buf.length) off += fs.writeSync(fd, buf, off, buf.length - off);
}

/**
 * Refuse a directory that someone other than its owner could change: it must be a real
 * directory (not a symlink), owned by the current user, with no group or other write
 * permission. The controller relies on the state root being out of reach of agents and other
 * local users (threat model T10); this check makes a misconfigured root fail closed instead
 * of silently trusting it. POSIX only: on Windows the state root's ACLs are set and checked
 * before the pilot tier relies on them (M2).
 */
export function assertPrivateDir(dir: string): void {
  if (process.platform === 'win32') return;
  const st = fs.lstatSync(dir);
  if (!st.isDirectory()) throw new Error(`${dir} must be a directory, not a link or file`);
  const euid = process.geteuid?.();
  if (euid !== undefined && st.uid !== euid) throw new Error(`${dir} is owned by uid ${st.uid}, not by the current user (${euid})`);
  if ((st.mode & 0o022) !== 0) {
    throw new Error(`${dir} is writable by group or others (mode ${(st.mode & 0o777).toString(8)}); run "chmod go-w" on it`);
  }
}

/**
 * Write a file so that readers see either the old or the new content, never a mix:
 * write to a temp file, fsync it, rename over the target, then fsync the directory
 * where the platform allows it (not possible on Windows, where rename is still atomic
 * within a volume).
 */
export function writeFileAtomic(file: string, data: string | Buffer, mode = 0o600): void {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`);
  const fd = fs.openSync(tmp, 'w', mode);
  try {
    writeAll(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  renameWithRetry(tmp, file);
  fsyncDir(dir);
}

/**
 * On Windows a rename over a file that another process (or a scanner) has open fails
 * transiently with EPERM/EACCES/EBUSY; retry briefly. Elsewhere rename never needs this.
 */
function renameWithRetry(from: string, to: string): void {
  const deadline = Date.now() + 2_000;
  for (;;) {
    try {
      fs.renameSync(from, to);
      return;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      const transient = process.platform === 'win32' && (code === 'EPERM' || code === 'EACCES' || code === 'EBUSY');
      if (!transient || Date.now() > deadline) throw err;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
}

export function fsyncDir(dir: string): void {
  if (process.platform === 'win32') return;
  let fd: number | undefined;
  try {
    fd = fs.openSync(dir, 'r');
    fs.fsyncSync(fd);
  } catch {
    // Some filesystems refuse fsync on directories; the rename is still durable on the common ones.
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** Append one line and fsync before returning. */
export function appendLineDurable(file: string, line: string): void {
  const fd = fs.openSync(file, 'a', 0o600);
  try {
    writeAll(fd, line.endsWith('\n') ? line : line + '\n');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

export function readJson<T>(file: string): T {
  return JSON.parse(fs.readFileSync(file, 'utf8')) as T;
}

export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}
