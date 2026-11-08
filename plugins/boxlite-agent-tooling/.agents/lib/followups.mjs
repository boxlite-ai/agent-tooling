import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, statSync } from 'node:fs';
import { isAbsolute, join, relative, sep } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const MAX_DRAFT_BYTES = 8 * 1024 * 1024;
// The separate budget covers bounded sessions, grants, and reconciliation metadata.
const MAX_STATE_BYTES = 2 * MAX_DRAFT_BYTES;
const MAX_RECORDS = 2048;
const HISTORY_PAGE_SIZE = 50;
const STATE_VERSION = 2;
const MARKER = '<!-- boxlite-followup:';
const REPOSITORY = /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/i;
const ISSUE_URL = /^https:\/\/github\.com\/[a-z0-9_.-]+\/[a-z0-9_.-]+\/issues\/[1-9][0-9]*$/i;

function digest(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function bounded(value, max, label) {
  requireValue(typeof value === 'string' && value.trim() && !value.includes('\0') &&
    Buffer.byteLength(value) <= max, `Invalid ${label}`);
  return value;
}

/** Bound the serialized size of metadata stored outside the draft budget. */
function identifier(value, bytes, label) {
  bounded(value, bytes, label);
  requireValue(Buffer.byteLength(JSON.stringify(value)) <= bytes, `Invalid ${label}`);
  return value;
}

/** An unknown owner or denied signal leaves the handle in place. */
function processExited(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); }
  catch (error) { return error.code === 'ESRCH'; }
  return false;
}

export function git(cwd, ...args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('GIT_')));
  return execFileSync('git', ['-C', cwd, ...args], {
    env, encoding: 'utf8', timeout: 3000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
}

export function containsPath(root, path) {
  const difference = relative(root, path);
  return !difference || (!isAbsolute(difference) && difference !== '..' && !difference.startsWith(`..${sep}`));
}

/** Match worktrees by filesystem identity and derive old keys only for recovery. */
export function cloneIdentity(cwd, { legacy = false, legacyPath } = {}) {
  requireValue(legacyPath === undefined || isAbsolute(legacyPath), 'Previous Git common directory must be absolute');
  const dir = realpathSync(git(cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'));
  const { dev, ino, birthtimeNs } = statSync(dir, { bigint: true });
  return legacy || legacyPath
    ? digest([legacyPath ?? dir, dev.toString(), ino.toString()])
    : digest([dev.toString(), ino.toString(), birthtimeNs.toString()]);
}

function privateDirectory(path, create) {
  if (create && !existsSync(path)) mkdirSync(path, { mode: 0o700, recursive: true });
  const info = lstatSync(path);
  requireValue(info.isDirectory() && (process.getuid === undefined ||
    (info.uid === process.getuid() && (info.mode & 0o077) === 0)), 'Follow-up state directory must be private');
}

function binding(state, caller, handle, clone) {
  const session = state.sessions[handle];
  requireValue(caller?.root === true && caller.clone === clone && session?.phase === 'open' &&
    session.native === caller.native && session.instance === caller.instance &&
    session.prompt === caller.prompt && Number.isSafeInteger(caller.cursor) && caller.cursor >= 0,
  'Queue handle does not match the live root session, clone, and prompt');
  return session;
}

function draftRevisions(state, handle) {
  return Object.values(state.drafts).filter(draft => draft.handle === handle && draft.status === 'pending')
    .map(({ id, revision }) => ({ id, revision })).sort((a, b) => a.id.localeCompare(b.id));
}

function grantDigest(state, draft) {
  return digest([state.clone, draft.handle, draft.id, draft.revision, draft.route,
    state.enrollment[draft.route], draft.title, draft.body, 'public']);
}

export function eligibleFollowup(state, draft) {
  return draft.status === 'pending' && state.releases[draft.id] === draft.revision &&
    state.enrollment[draft.route] && state.grants[draft.id] === grantDigest(state, draft);
}

function draftStatus(state, { draft, grant, release, attempt }) {
  return {
    ...draft, enrolled: state.enrollment[draft.route] ?? null,
    approved: grant === grantDigest(state, draft), released: release === draft.revision, attempt: attempt ?? null,
  };
}

/**
 * Use separate SQLite databases for transport ownership and durable attempts.
 * A crash releases transport ownership while preserving the recorded attempt.
 */
export function openFollowupQueue(stateRoot, clone, { initialize = false, registryRoot, legacyClone, requireLegacy = false } = {}) {
  requireValue(/^[a-f0-9]{64}$/.test(clone), 'Invalid clone identity');
  requireValue(!legacyClone || /^[a-f0-9]{64}$/.test(legacyClone), 'Invalid legacy clone identity');
  privateDirectory(stateRoot, initialize);
  const root = realpathSync(stateRoot);
  let journal = clone;
  const journalFile = name => join(root, journal, name);

  /** Validate both database paths before opening a bound journal. */
  function checkQueue(create) {
    const directory = join(root, journal);
    if (create && !existsSync(directory)) initializeQueue(root, directory, journal);
    privateDirectory(directory, false);
    for (const name of ['queue.sqlite', 'lock.sqlite']) {
      requireValue(lstatSync(journalFile(name)).isFile(), 'Follow-up state is missing or unsafe');
    }
  }

  if (registryRoot) {
    privateDirectory(registryRoot, initialize);
    const registryPath = join(registryRoot, 'roots.sqlite');
    if (existsSync(registryPath)) requireValue(lstatSync(registryPath).isFile(), 'Follow-up registry is unsafe');
    const registry = new DatabaseSync(registryPath);
    try {
      registry.exec(`PRAGMA busy_timeout = 1000;
        CREATE TABLE IF NOT EXISTS roots (clone TEXT PRIMARY KEY, path TEXT NOT NULL, identity TEXT NOT NULL);
        BEGIN IMMEDIATE;`);
      registry.exec('CREATE TABLE IF NOT EXISTS journal_keys (clone TEXT PRIMARY KEY, journal TEXT NOT NULL)');
      const rootFor = registry.prepare('SELECT path, identity FROM roots WHERE clone = ?');
      const current = rootFor.get(clone);
      const previous = legacyClone ? rootFor.get(legacyClone) : undefined;
      const bound = current ?? previous;
      journal = current
        ? registry.prepare('SELECT journal FROM journal_keys WHERE clone = ?').get(clone)?.journal ?? clone
        : previous ? legacyClone : clone;
      if (requireLegacy) {
        requireValue(previous && journal === legacyClone, 'Legacy follow-up journal was not found for this clone');
      }
      requireValue(bound || initialize, 'Run init to bind this clone to its follow-up state directory');
      requireValue(!bound || bound.path === root, 'Clone already uses another follow-up state directory');
      requireValue(/^[a-f0-9]{64}$/.test(journal), 'Invalid follow-up journal key');
      if (!bound) {
        const unknown = registry.prepare(`SELECT 1 FROM roots WHERE NOT EXISTS (
          SELECT 1 FROM journal_keys WHERE roots.clone IN (journal_keys.clone, journal_keys.journal)
        ) LIMIT 1`).get();
        requireValue(!unknown, 'Open existing follow-up journals before initializing a new clone, or supply the previous Git common directory');
      }
      checkQueue(!bound);
      const { dev, ino } = statSync(journalFile('queue.sqlite'), { bigint: true });
      const identity = `${dev}:${ino}`;
      requireValue(!bound || bound.identity === identity, 'Bound follow-up journal was replaced');
      if (!current) registry.prepare('INSERT INTO roots VALUES (?, ?, ?)').run(clone, root, identity);
      registry.prepare('INSERT OR IGNORE INTO journal_keys VALUES (?, ?)').run(clone, journal);
      registry.exec('COMMIT');
    } finally {
      registry.close();
    }
  } else {
    checkQueue(initialize);
  }

  /** Hold the transport lock until an asynchronous publisher finishes. */
  function locked(action) {
    const lock = new DatabaseSync(journalFile('lock.sqlite'));
    let db;
    let deferred = false;
    const finish = () => {
      try { db?.close(); } finally { lock.close(); }
    };
    try {
      lock.exec('BEGIN IMMEDIATE');
      db = new DatabaseSync(journalFile('queue.sqlite'));
      const raw = db.prepare('SELECT document FROM queue WHERE id = 1').get()?.document;
      requireValue(typeof raw === 'string' && Buffer.byteLength(raw) <= MAX_STATE_BYTES, 'Unreadable follow-up state');
      const state = JSON.parse(raw);
      requireValue((state.version === 1 || state.version === STATE_VERSION) && state.clone === journal,
        'Follow-up state belongs to another clone or version');
      db.exec('CREATE TABLE IF NOT EXISTS completed (id TEXT PRIMARY KEY, record TEXT NOT NULL)');
      const completed = {
        get: id => JSON.parse(db.prepare('SELECT record FROM completed WHERE id = ?').get(id)?.record ?? 'null'),
        page: (before = null) => db.prepare(`SELECT rowid, record FROM completed
          WHERE rowid < COALESCE(?, 9223372036854775807) ORDER BY rowid DESC LIMIT ?`)
          .all(before, HISTORY_PAGE_SIZE + 1),
      };
      /** Commit the live queue and completed records together. */
      const save = () => {
        const retiring = Object.values(state.drafts).filter(draft =>
          draft.status !== 'pending' && state.attempts[draft.id]?.status !== 'pending');
        db.exec('BEGIN IMMEDIATE');
        try {
          const insert = db.prepare('INSERT INTO completed VALUES (?, ?)');
          for (const draft of retiring) {
            const { id } = draft;
            insert.run(id, JSON.stringify({ draft, grant: state.grants[id], release: state.releases[id],
              attempt: state.attempts[id] }));
            delete state.drafts[id];
            delete state.grants[id];
            delete state.releases[id];
            delete state.attempts[id];
          }
          const encoded = JSON.stringify(state);
          requireValue(Buffer.byteLength(encoded) <= MAX_STATE_BYTES, 'Follow-up state is full');
          db.prepare('UPDATE queue SET document = ? WHERE id = 1').run(encoded);
          db.exec('COMMIT');
        } catch (error) {
          db.exec('ROLLBACK');
          throw error;
        }
      };
      if (state.version === 1) {
        // Fence older writers under the same lock before moving any drafts to history.
        state.version = STATE_VERSION;
        for (const [handle, session] of Object.entries(state.sessions)) {
          if (session.owner === undefined) delete state.sessions[handle];
        }
        save();
      }
      const result = action(state, save, completed);
      if (result instanceof Promise) {
        deferred = true;
        return result.finally(finish);
      }
      return result;
    } finally {
      if (!deferred) finish();
    }
  }

  return {
    clone,
    /** Replace stale handles before admitting a new root session. */
    start(caller) {
      return locked((state, save) => {
        requireValue(caller.root === true && caller.clone === clone, 'Queue startup requires the live root session');
        for (const name of ['native', 'instance', 'prompt']) identifier(caller[name], 256, name);
        for (const [handle, session] of Object.entries(state.sessions)) {
          if (session.native === caller.native || processExited(session.owner)) delete state.sessions[handle];
        }
        requireValue(Object.keys(state.sessions).length < MAX_RECORDS, 'Follow-up session table is full');
        const handle = randomUUID();
        state.sessions[handle] = { native: caller.native, instance: caller.instance, prompt: caller.prompt, owner: process.pid, phase: 'open' };
        save();
        return handle;
      });
    },

    prompt(caller, handle, prompt) {
      return locked((state, save) => {
        const session = binding(state, caller, handle, clone);
        session.prompt = identifier(prompt, 256, 'prompt');
        delete session.ack;
        delete session.seal;
        delete session.requested;
        save();
      });
    },

    /** Check the current session binding before recording or acknowledging revisions. */
    capture(caller, { handle, action, ...input }) {
      return locked((state, save, completed) => {
        const session = binding(state, caller, handle, clone);
        const revisions = () => draftRevisions(state, handle);
        if (action === 'list') return { drafts: revisions() };
        if (action === 'acknowledge') {
          requireValue(Array.isArray(input.drafts) && input.drafts.length <= MAX_RECORDS, 'Expected draft revisions');
          const current = revisions();
          const supplied = input.drafts.map(({ id, revision }) => ({ id, revision }));
          requireValue(supplied.every(draft => typeof draft.id === 'string' && Number.isSafeInteger(draft.revision)),
            'Invalid draft revision');
          supplied.sort((a, b) => a.id.localeCompare(b.id));
          requireValue(digest(supplied) === digest(current), 'Acknowledge the exact pending draft revisions');
          session.ack = { cursor: caller.cursor, digest: digest(current) };
          delete session.seal;
          save();
          return { acknowledged: current };
        }
        if (action === 'resolve') {
          const draft = state.drafts[input.id];
          requireValue(draft?.handle === handle && draft.revision === input.revision, 'Draft revision is stale');
          requireValue(!input.url || (input.url.length <= 510 && ISSUE_URL.test(input.url)), 'Expected a GitHub issue URL');
          draft.status = 'resolved';
          if (input.url) draft.url = input.url;
          save();
          return { id: draft.id, revision: draft.revision, status: draft.status };
        }
        requireValue(action === 'record', 'Unknown queue action');
        requireValue(input.route === 'tooling' || input.route === 'consumer', 'Invalid draft route');
        const repository = bounded(input.repository, 200, 'affected repository').toLowerCase();
        requireValue(REPOSITORY.test(repository), 'Invalid affected repository');
        const operation = bounded(input.operation, 128, 'operation').trim().toLowerCase();
        const failure = bounded(input.failure, 128, 'failure mode').trim().toLowerCase();
        const id = digest([repository, operation, failure]);
        const old = state.drafts[id] ?? completed.get(id)?.draft;
        if (old?.status === 'filed' || old?.status === 'resolved') {
          return { id, revision: old.revision, status: old.status };
        }
        requireValue(old || Object.keys(state.drafts).length < MAX_RECORDS, 'Follow-up queue is full');
        const title = bounded(input.title, 256, 'title');
        const body = bounded(input.body, 16 * 1024, 'body');
        const evidence = bounded(input.evidence, 8192, 'evidence');
        requireValue(!title.includes('\n') && !title.includes('\r') && !title.includes(MARKER) && !body.includes(MARKER),
          'Draft contains a multiline title or reserved marker');
        const marker = old?.marker ?? `${MARKER}${randomUUID()} -->`;
        const finalBody = `${body}\n\n${marker}`;
        if (old?.handle === handle && old.title === title && old.body === finalBody &&
            old.evidence === evidence && old.route === input.route) {
          return { id, revision: old.revision, status: old.status };
        }
        const revision = (old?.revision ?? 0) + 1;
        state.drafts[id] = { id, revision, handle, marker, title, body: finalBody, evidence, route: input.route, status: 'pending' };
        requireValue(Buffer.byteLength(JSON.stringify(state.drafts)) <= MAX_DRAFT_BYTES, 'Follow-up queue is full');
        delete state.grants[id];
        delete state.releases[id];
        save();
        return { id, revision, status: 'pending' };
      });
    },

    /** Seal only the revisions acknowledged at the current cursor. */
    checkpoint(caller, handle, response) {
      return locked((state, save) => {
        const session = binding(state, caller, handle, clone);
        if (session.ack?.cursor === caller.cursor && session.ack.digest === digest(draftRevisions(state, handle))) {
          if (response) session.seal = { ...session.ack, response: identifier(response, 256, 'Stop response') };
          else delete session.seal;
          save();
          return response ? 'sealed' : 'incomplete';
        }
        delete session.seal;
        const outcome = session.requested ? 'incomplete' : 'request';
        session.requested = true;
        save();
        return outcome;
      });
    },

    close(caller, handle) {
      return locked((state, save) => {
        binding(state, caller, handle, clone).phase = 'closing';
        save();
      });
    },

    /** Release revisions only for the exact sealed response after closure. */
    finish(caller, handle, verifiedResponse) {
      return locked((state, save) => {
        const session = state.sessions[handle];
        if (caller.root !== true || caller.clone !== clone ||
            session?.native !== caller.native || session.instance !== caller.instance ||
            session.prompt !== caller.prompt) return 0;
        delete state.sessions[handle];
        let released = 0;
        const drafts = draftRevisions(state, handle);
        if (session.phase === 'closing' && verifiedResponse && session.seal?.response === verifiedResponse &&
            session.seal.cursor === caller.cursor && session.seal.digest === digest(drafts)) {
          for (const { id, revision } of drafts) {
            state.releases[id] = revision;
            released += 1;
          }
        }
        save();
        return released;
      });
    },

    /** Return active drafts and bounded recent history in queue order. */
    status() {
      return locked((state, _save, completed) => {
        const active = Object.values(state.drafts).map(draft => ({
          draft, grant: state.grants[draft.id], release: state.releases[draft.id], attempt: state.attempts[draft.id],
        }));
        const recent = completed.page().slice(0, HISTORY_PAGE_SIZE).reverse().map(row => JSON.parse(row.record));
        return [...recent, ...active].map(record => draftStatus(state, record));
      });
    },

    /** Read older completed drafts using an exclusive row cursor. */
    history(before = null) {
      requireValue(before === null || (Number.isSafeInteger(before) && before > 0), 'Invalid history cursor');
      return locked((state, _save, completed) => {
        const rows = completed.page(before);
        const page = rows.slice(0, HISTORY_PAGE_SIZE);
        return {
          drafts: page.map(row => draftStatus(state, JSON.parse(row.record))),
          nextBefore: rows.length > HISTORY_PAGE_SIZE ? page.at(-1).rowid : null,
        };
      });
    },

    /** Replace the destination generation so prior grants cannot carry over. */
    enroll(route, target) {
      return locked((state, save) => {
        requireValue(route === 'tooling' || route === 'consumer', 'Invalid enrollment route');
        if (target === null) delete state.enrollment[route];
        else {
          identifier(target.id, 256, 'GitHub repository ID');
          identifier(target.name, 256, 'GitHub repository name');
          requireValue(REPOSITORY.test(target.name) &&
            (route !== 'tooling' || target.name.toLowerCase() === 'boxlite-ai/agent-tooling'), 'Invalid enrollment target');
          state.enrollment[route] = { id: target.id, name: target.name, generation: randomUUID() };
        }
        save();
      });
    },

    review(id) {
      return locked(state => {
        const draft = state.drafts[id];
        requireValue(draft?.status === 'pending' && state.enrollment[draft.route], 'Draft or enrollment unavailable');
        return { ...draft, target: state.enrollment[draft.route], digest: grantDigest(state, draft) };
      });
    },

    approve(id, reviewedDigest, release) {
      return locked((state, save) => {
        const draft = state.drafts[id];
        requireValue(draft?.status === 'pending' && state.enrollment[draft.route] &&
          grantDigest(state, draft) === reviewedDigest, 'Draft or destination changed during review');
        state.grants[id] = reviewedDigest;
        if (release) state.releases[id] = draft.revision;
        save();
      });
    },

    // Only the operator-owned publisher receives this transaction capability.
    publish: locked,
  };
}

function initializeQueue(root, directory, clone) {
  const staging = mkdtempSync(join(root, '.init-'));
  try {
    for (const name of ['queue.sqlite', 'lock.sqlite']) {
      const file = join(staging, name);
      const db = new DatabaseSync(file);
      try {
        if (name === 'queue.sqlite') {
          db.exec('CREATE TABLE queue (id INTEGER PRIMARY KEY CHECK(id = 1), document TEXT NOT NULL)');
          db.prepare('INSERT INTO queue VALUES (1, ?)').run(JSON.stringify({
            version: STATE_VERSION, clone, sessions: {}, drafts: {}, enrollment: {}, grants: {}, releases: {}, attempts: {},
          }));
        }
        if (process.getuid !== undefined) chmodSync(file, 0o600);
      } finally {
        db.close();
      }
    }
    try { renameSync(staging, directory); }
    catch (error) {
      if (!['ENOTEMPTY', 'EEXIST'].includes(error.code)) throw error;
    }
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}
