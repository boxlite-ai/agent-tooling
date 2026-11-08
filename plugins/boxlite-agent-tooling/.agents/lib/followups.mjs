import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const MAX_STATE_BYTES = 8 * 1024 * 1024;
const MAX_RECORDS = 2048;
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

export function git(cwd, ...args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('GIT_')));
  return execFileSync('git', ['-C', cwd, ...args], {
    env, encoding: 'utf8', timeout: 3000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
}

export function cloneIdentity(cwd) {
  const dir = realpathSync(git(cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'));
  const { dev, ino } = statSync(dir, { bigint: true });
  return digest([dir, dev.toString(), ino.toString()]);
}

function privateDirectory(path, create) {
  if (create && !existsSync(path)) mkdirSync(path, { mode: 0o700, recursive: true });
  const info = lstatSync(path);
  requireValue(info.isDirectory() && (process.getuid === undefined ||
    (info.uid === process.getuid() && (info.mode & 0o077) === 0)), 'Follow-up state directory must be private');
}

function binding(state, caller, handle) {
  const session = state.sessions[handle];
  requireValue(caller?.root === true && caller.clone === state.clone && session?.phase === 'open' &&
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

// The lock database stays reserved while a durable attempt is committed in the state
// database and the same process owns the transport. A crash releases the lock, not the attempt.
export function openFollowupQueue(stateRoot, clone, { initialize = false } = {}) {
  requireValue(/^[a-f0-9]{64}$/.test(clone), 'Invalid clone identity');
  privateDirectory(stateRoot, initialize);
  const root = realpathSync(stateRoot);
  const directory = join(root, clone);
  if (initialize && !existsSync(directory)) initializeQueue(root, directory, clone);
  privateDirectory(directory, false);
  const statePath = join(directory, 'queue.sqlite');
  const lockPath = join(directory, 'lock.sqlite');
  for (const file of [statePath, lockPath]) {
    requireValue(lstatSync(file).isFile(), 'Follow-up state is missing or unsafe');
  }

  function locked(action) {
    const lock = new DatabaseSync(lockPath);
    let db;
    let deferred = false;
    const finish = () => {
      try { db?.close(); } finally { lock.close(); }
    };
    try {
      lock.exec('BEGIN IMMEDIATE');
      db = new DatabaseSync(statePath);
      const raw = db.prepare('SELECT document FROM queue WHERE id = 1').get()?.document;
      requireValue(typeof raw === 'string' && Buffer.byteLength(raw) <= MAX_STATE_BYTES, 'Unreadable follow-up state');
      const state = JSON.parse(raw);
      requireValue(state.version === 1 && state.clone === clone, 'Follow-up state belongs to another clone or version');
      const save = () => {
        const encoded = JSON.stringify(state);
        requireValue(Buffer.byteLength(encoded) <= MAX_STATE_BYTES, 'Follow-up state is full');
        db.prepare('UPDATE queue SET document = ? WHERE id = 1').run(encoded);
      };
      const result = action(state, save);
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
    start(caller) {
      return locked((state, save) => {
        requireValue(caller.root === true && caller.clone === clone, 'Queue startup requires the live root session');
        for (const name of ['native', 'instance', 'prompt']) bounded(caller[name], 256, name);
        for (const [handle, session] of Object.entries(state.sessions)) {
          if (session.native === caller.native) delete state.sessions[handle];
        }
        requireValue(Object.keys(state.sessions).length < MAX_RECORDS, 'Follow-up session table is full');
        const handle = randomUUID();
        state.sessions[handle] = { native: caller.native, instance: caller.instance, prompt: caller.prompt, phase: 'open' };
        save();
        return handle;
      });
    },

    prompt(caller, handle, prompt) {
      return locked((state, save) => {
        const session = binding(state, caller, handle);
        session.prompt = bounded(prompt, 256, 'prompt');
        delete session.ack;
        delete session.seal;
        delete session.requested;
        save();
      });
    },

    capture(caller, { handle, action, ...input }) {
      return locked((state, save) => {
        const session = binding(state, caller, handle);
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
          session.ack = { cursor: caller.cursor, drafts: current };
          delete session.seal;
          save();
          return { acknowledged: current };
        }
        if (action === 'resolve') {
          const draft = state.drafts[input.id];
          requireValue(draft?.handle === handle && draft.revision === input.revision, 'Draft revision is stale');
          requireValue(!input.url || ISSUE_URL.test(input.url), 'Expected a GitHub issue URL');
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
        const old = state.drafts[id];
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
        delete state.grants[id];
        delete state.releases[id];
        save();
        return { id, revision, status: 'pending' };
      });
    },

    checkpoint(caller, handle, response) {
      return locked((state, save) => {
        const session = binding(state, caller, handle);
        if (session.ack?.cursor === caller.cursor && digest(session.ack.drafts) === digest(draftRevisions(state, handle))) {
          if (response) session.seal = { ...session.ack, response };
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
        binding(state, caller, handle).phase = 'closing';
        save();
      });
    },

    finish(caller, handle, verifiedResponse) {
      return locked((state, save) => {
        const session = state.sessions[handle];
        if (caller.root !== true || caller.clone !== clone ||
            session?.native !== caller.native || session.instance !== caller.instance ||
            session.prompt !== caller.prompt) return 0;
        delete state.sessions[handle];
        let released = 0;
        if (session.phase === 'closing' && verifiedResponse && session.seal?.response === verifiedResponse &&
            session.seal.cursor === caller.cursor && digest(session.seal.drafts) === digest(draftRevisions(state, handle))) {
          for (const { id, revision } of session.seal.drafts) {
            state.releases[id] = revision;
            released += 1;
          }
        }
        save();
        return released;
      });
    },

    status() {
      return locked(state => Object.values(state.drafts).map(draft => ({
        ...draft, enrolled: state.enrollment[draft.route] ?? null,
        approved: state.grants[draft.id] === grantDigest(state, draft),
        released: state.releases[draft.id] === draft.revision,
        attempt: state.attempts[draft.id] ?? null,
      })));
    },

    enroll(route, target) {
      return locked((state, save) => {
        requireValue(route === 'tooling' || route === 'consumer', 'Invalid enrollment route');
        if (target === null) delete state.enrollment[route];
        else {
          bounded(target.id, 256, 'GitHub repository ID');
          requireValue(REPOSITORY.test(target.name) &&
            (route !== 'tooling' || target.name.toLowerCase() === 'boxlite-ai/agent-tooling'), 'Invalid enrollment target');
          state.enrollment[route] = { ...target, generation: randomUUID() };
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
            version: 1, clone, sessions: {}, drafts: {}, enrollment: {}, grants: {}, releases: {}, attempts: {},
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
