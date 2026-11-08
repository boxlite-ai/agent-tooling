import { execFileSync } from 'node:child_process';
import { request } from 'node:https';
import { eligibleFollowup } from './followups.mjs';

const ISSUE_FIELDS = 'id url body repository { id } author { ... on User { id } }';
const VIEWER = 'query { viewer { id } }';
const REPOSITORY = 'query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) { id nameWithOwner } }';
const CREATE = `mutation($input:CreateIssueInput!) { createIssue(input:$input) { issue { ${ISSUE_FIELDS} } } }`;
const PAGE = `query($id:ID!,$cursor:String,$size:Int!) {
  node(id:$id) { ... on Repository {
    id issues(first:$size,after:$cursor,states:[OPEN,CLOSED],orderBy:{field:CREATED_AT,direction:ASC}) {
      nodes { ${ISSUE_FIELDS} } pageInfo { hasNextPage endCursor }
    }
  } }
}`;
const ISSUE_URL = /^https:\/\/github\.com\/[a-z0-9_.-]+\/[a-z0-9_.-]+\/issues\/[1-9][0-9]*$/i;
const MAX_RESPONSE = 4 * 1024 * 1024;
const PAGE_SIZE = 50;
const BACKOFF_MS = 60_000;

/** Send one GraphQL request and distinguish a proven unsent failure from uncertainty. */
export function githubClient(timeout = 5000) {
  const token = execFileSync('gh', ['auth', 'token', '--hostname', 'github.com'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout, maxBuffer: 4096,
  }).trim();
  if (!/^[a-zA-Z0-9_]+$/.test(token)) throw new Error('GitHub authentication is unavailable');

  return (query, variables, timeout) => new Promise((resolve, reject) => {
    const body = JSON.stringify({ query, variables });
    let tlsConnected = false;
    // A new agentless HTTPS request sends once. No redirect, proxy, Expect or retry handler.
    const req = request({
      hostname: 'api.github.com', path: '/graphql', method: 'POST', agent: false,
      signal: AbortSignal.timeout(timeout),
      headers: {
        authorization: `Bearer ${token}`, 'user-agent': 'boxlite-followups',
        'content-type': 'application/json', 'content-length': Buffer.byteLength(body),
      },
    }, res => {
      let bytes = 0;
      const chunks = [];
      res.on('error', reject);
      res.on('data', chunk => {
        bytes += chunk.length;
        if (bytes > MAX_RESPONSE) res.destroy(Object.assign(new Error('GitHub response exceeded the limit'), { responseTooLarge: true }));
        else chunks.push(chunk);
      });
      res.on('end', () => {
        let data;
        try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
        catch { return reject(new Error('Unreadable GitHub response')); }
        if (res.statusCode !== 200 || data?.errors !== undefined || !data?.data || typeof data.data !== 'object') {
          const error = new Error('GitHub request did not return a complete result');
          error.cursorRejected = Array.isArray(data?.errors) &&
            data.errors.some(item => /invalid cursor|cursor is invalid/i.test(item?.message ?? ''));
          const retryAfter = Number(res.headers['retry-after']);
          const reset = Number(res.headers['x-ratelimit-reset']);
          if (Number.isFinite(retryAfter) && retryAfter > 0) error.retryAt = Date.now() + retryAfter * 1000;
          if (res.headers['x-ratelimit-remaining'] === '0' && Number.isFinite(reset)) {
            error.retryAt = Math.max(error.retryAt ?? 0, reset * 1000);
          }
          return reject(error);
        }
        resolve(data.data);
      });
    });
    req.on('socket', socket => socket.once('secureConnect', () => { tlsConnected = true; }));
    req.on('error', error => {
      // This request owns a fresh TLS socket and cannot send HTTP before handshake.
      if (!tlsConnected) error.provenUnsent = true;
      reject(error);
    });
    req.end(body);
  });
}

export async function githubRepository(client, name) {
  const [owner, repo] = name.split('/');
  const { repository } = await client(REPOSITORY, { owner, name: repo }, 5000);
  if (!repository?.id || repository.nameWithOwner?.toLowerCase() !== name.toLowerCase()) {
    throw new Error('GitHub did not confirm the exact enrollment repository');
  }
  return { id: repository.id, name: repository.nameWithOwner };
}

/** Keep remote metadata within the journal reserve, including JSON escapes. */
function boundedField(value, bytes) {
  return typeof value === 'string' && value.length > 0 && Buffer.byteLength(JSON.stringify(value)) <= bytes;
}

/** Require the original repository, author, and marker before accepting a match. */
function matchingIssue(issue, attempt) {
  return boundedField(issue?.id, 256) && boundedField(issue.url, 512) && ISSUE_URL.test(issue.url) &&
    issue.repository?.id === attempt.target && issue.author?.id === attempt.author &&
    typeof issue.body === 'string' && issue.body.split(/\r?\n/).includes(attempt.marker);
}

function retire(draft, attempt, url) {
  draft.status = 'filed';
  draft.url = url;
  attempt.status = 'filed';
}

function defer(attempt, error) {
  attempt.nextAt = Math.max(Date.now() + BACKOFF_MS, error?.retryAt ?? 0);
}

/** Advance a read-only scan for an attempt whose create may have succeeded. */
async function reconcile(send, draft, attempt, save) {
  let page;
  const size = attempt.pageSize ?? PAGE_SIZE;
  try {
    const data = await send(PAGE, { id: attempt.target, cursor: attempt.cursor ?? null, size });
    if (data.node?.id !== attempt.target) throw new Error('GitHub target unavailable');
    page = data.node.issues;
    if (!Array.isArray(page?.nodes) || typeof page.pageInfo?.hasNextPage !== 'boolean' ||
        (page.pageInfo.hasNextPage && (!boundedField(page.pageInfo.endCursor, 512) || page.pageInfo.endCursor === attempt.cursor))) {
      throw new Error('Incomplete GitHub issue page');
    }
  } catch (error) {
    if (error.cursorRejected) {
      delete attempt.cursor;
      delete attempt.matches;
    }
    if (error.responseTooLarge && size > 1) attempt.pageSize = Math.floor(size / 2);
    else defer(attempt, error);
    save();
    return;
  }
  const matches = new Map(attempt.matches ?? []);
  for (const issue of page.nodes) {
    if (matchingIssue(issue, attempt)) matches.set(issue.id, issue.url);
  }
  if (matches.size > 1) {
    attempt.status = 'conflict';
  } else if (page.pageInfo.hasNextPage) {
    attempt.matches = [...matches];
    attempt.cursor = page.pageInfo.endCursor;
  } else if (matches.size === 1) {
    retire(draft, attempt, matches.values().next().value);
  } else {
    delete attempt.cursor;
    delete attempt.matches;
    defer(attempt);
  }
  save();
}

/** Schedule eligible drafts within one shared request and time budget. */
export async function drainFollowups(queue, client) {
  const deadline = performance.now() + 30_000;
  let requests = 0;
  let author;
  const remaining = () => Math.max(1, Math.floor(Math.min(5000, deadline - performance.now())));
  const canRequest = () => requests < 10 && performance.now() < deadline;
  const budgetError = () => Object.assign(new Error('Follow-up drain budget exhausted'), { provenUnsent: true });
  const send = (query, variables) => {
    if (!canRequest()) throw budgetError();
    client ??= githubClient(remaining());
    if (!canRequest()) throw budgetError();
    requests += 1;
    return client(query, variables, remaining());
  };
  while (canRequest()) {
    const worked = await queue.publish(async (state, save) => {
      // Resume after the last scheduled draft, including across drain invocations.
      const drafts = Object.values(state.drafts);
      const offset = drafts.findIndex(draft => draft.id === state.lastScheduled) + 1;
      const draft = [...drafts.slice(offset), ...drafts.slice(0, offset)].find(candidate => {
        const attempt = state.attempts[candidate.id];
        if (attempt?.nextAt > Date.now()) return false;
        if (attempt && attempt.status !== 'unsent') return attempt.status === 'pending';
        return eligibleFollowup(state, candidate) && requests + (author ? 1 : 2) <= 10;
      });
      if (!draft) return false;
      state.lastScheduled = draft.id;
      const existing = state.attempts[draft.id];
      if (existing && existing.status !== 'unsent') {
        await reconcile(send, draft, existing, save);
        return true;
      }
      if (!author) {
        const data = await send(VIEWER, {});
        author = data.viewer?.id;
        if (!boundedField(author, 256)) throw new Error('GitHub author identity is unavailable');
      }
      if (!canRequest()) return false;
      const target = state.enrollment[draft.route].id;
      const attempt = { status: 'pending', target, author, marker: draft.marker, revision: draft.revision };
      state.attempts[draft.id] = attempt;
      save();
      try {
        const data = await send(CREATE, { input: { repositoryId: target, title: draft.title, body: draft.body } });
        const issue = data.createIssue?.issue;
        if (matchingIssue(issue, attempt)) retire(draft, attempt, issue.url);
        else defer(attempt);
      } catch (error) {
        // Once dispatch is possible, even a missing or malformed response is ambiguous.
        if (error?.provenUnsent === true) attempt.status = 'unsent';
        defer(attempt, error);
      }
      save();
      return true;
    });
    if (!worked) break;
  }
  return { requests };
}
