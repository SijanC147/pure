import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {compareVersions, formulaVersion, parseTag, publish, releaseBinding, renderFormula, requireTapChecks, requireWorkflowBinding, validateProof, type Api, type ReleaseProof} from './homebrew-release.mts';
const tag = 'v1.28.3+20260906070809';
const checksum = 'a'.repeat(64);
test('timestamp tags preserve the base version and reject injection or impossible dates', () => {
  assert.deepEqual(parseTag(tag), {version: tag.slice(1), baseVersion: '1.28.3'});
  assert.deepEqual(parseTag('v1.28.3'), {version: '1.28.3', baseVersion: '1.28.3'});
  for (const invalid of ['v01.2.3+20260906070809', 'v1.2.3+20260230010203', 'v1.2.3+20260101250000', `${tag}"\n system "bad`]) assert.throws(() => parseTag(invalid));
});
test('base precedes timestamp in downgrade detection', () => {
  assert.equal(compareVersions('1.28.3+20260906070809', '1.28.3+20260906070810'), -1);
  assert.equal(compareVersions('1.28.3+20260906070810', '1.28.4'), -1);
  assert.equal(compareVersions('1.28.3+20260906070810', '1.23.7'), 1);
  assert.equal(compareVersions('1.28.3', '1.28.3'), 0);
  assert.throws(() => compareVersions('garbage', '1.28.3'));
});
test('formula pins explicit full version and preserves the external async dependency', () => {
  const formula = renderFormula(tag, checksum);
  assert.equal(formulaVersion(formula), tag.slice(1));
  assert.ok(formula.includes(`version "${tag.slice(1)}"`));
  assert.ok(!formula.includes('zsh_function.install "async.zsh" => "async"'));
  assert.ok(formula.includes('depends_on "zsh-async"'));
  assert.throws(() => renderFormula(tag, 'invalid'));
  assert.equal(formulaVersion('  url "https://github.com/SijanC147/pure/archive/refs/tags/v1.23.7.tar.gz"'), '1.23.7');
});
const archive = Buffer.from('archive fixture');
const sha = (v: string | Uint8Array) => createHash('sha256').update(v).digest('hex');
const formula = renderFormula(tag, sha(archive));
const proof: ReleaseProof = {tag, ...parseTag(tag), sourceVersion: '1.28.3', commit: 'b'.repeat(40), releaseId: 123, archiveSha256: sha(archive), formulaSha256: sha(formula)};
test('proof rejects archive, formula and metadata tampering', () => {
  validateProof(proof, archive, formula);
  assert.throws(() => validateProof(proof, Buffer.from('other'), formula));
  assert.throws(() => validateProof(proof, archive, `${formula}\n`));
  assert.throws(() => validateProof({...proof, version: '1.2.3'}, archive, formula));
});
function fixture(overrides: Record<string, unknown> = {}): Api {
  const source = 'repos/SijanC147/pure'; const commit = 'b'.repeat(40); const main = 'c'.repeat(40);
  const responses: Record<string, unknown> = {
    [`${source}/releases/tags/${encodeURIComponent(tag)}`]: {id: 123, tag_name: tag, draft: false, prerelease: false, published_at: '2026-09-06T05:08:09Z'},
    [`${source}/git/ref/tags/${encodeURIComponent(tag)}`]: {object: {type: 'commit', sha: commit}},
    [`${source}/git/ref/heads/main`]: {object: {type: 'commit', sha: main}},
    [`${source}/compare/${commit}...${main}`]: {status: 'ahead'},
    [`${source}/contents/package.json?ref=${commit}`]: {content: Buffer.from('{"version":"1.28.3"}').toString('base64')},
    [`${source}/contents/pure.zsh?ref=${commit}`]: {content: Buffer.from('prompt_pure_state[version]="1.28.3"').toString('base64')},
    ...overrides,
  };
  return async <T,>(path: string, method = 'GET') => {assert.equal(method, 'GET'); assert.ok(path in responses, path); return responses[path] as T;};
}
test('release binding accepts main ancestors, not unrelated or moved releases', async () => {
  assert.equal((await releaseBinding(tag, fixture())).commit, 'b'.repeat(40));
  await assert.rejects(releaseBinding(tag, fixture({[`repos/SijanC147/pure/compare/${'b'.repeat(40)}...${'c'.repeat(40)}`]: {status: 'diverged'}})), /ancestor/);
  await assert.rejects(releaseBinding(tag, fixture({[`repos/SijanC147/pure/releases/tags/${encodeURIComponent(tag)}`]: {id: 123, tag_name: tag, draft: true}})), /published/);
  await assert.rejects(releaseBinding(tag, fixture({[`repos/SijanC147/pure/contents/package.json?ref=${'b'.repeat(40)}`]: {content: Buffer.from('{"version":"1.28.4"}').toString('base64')}})), /versions disagree/);
});
test('timestamp releases permit coherent source versions newer than the tag base', async () => {
  const next = fixture({
    [`repos/SijanC147/pure/contents/package.json?ref=${'b'.repeat(40)}`]: {content: Buffer.from('{"version":"1.28.4"}').toString('base64')},
    [`repos/SijanC147/pure/contents/pure.zsh?ref=${'b'.repeat(40)}`]: {content: Buffer.from('prompt_pure_state[version]="1.28.4"').toString('base64')},
  });
  assert.equal((await releaseBinding(tag, next)).sourceVersion, '1.28.4');
});
test('workflow retry must execute the exact published tag and repository', () => {
  const env = {GITHUB_ACTIONS: 'true', GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REPOSITORY: 'SijanC147/pure', GITHUB_SHA: proof.commit, GITHUB_REF: `refs/tags/${tag}`};
  requireWorkflowBinding(tag, proof.commit, env);
  requireWorkflowBinding(tag, proof.commit, {...env, GITHUB_EVENT_NAME: 'release'});
  for (const change of [{GITHUB_REF: 'refs/heads/main'}, {GITHUB_SHA: 'd'.repeat(40)}, {GITHUB_REPOSITORY: 'other/pure'}, {GITHUB_EVENT_NAME: 'pull_request'}]) assert.throws(() => requireWorkflowBinding(tag, proof.commit, {...env, ...change}));
});
async function artifact(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'pure-publication-test-'));
  await writeFile(join(directory, 'release.json'), JSON.stringify(proof));
  await writeFile(join(directory, 'pure.rb'), formula);
  await writeFile(join(directory, 'archive.tar.gz'), archive);
  return directory;
}
test('publication retries adopt exact tap content without writes and refuse downgrade', async () => {
  const base = 'd'.repeat(40); const tap = 'repos/SijanC147/homebrew-formulas';
  const directory = await artifact();
  const request = (current: string) => fixture({[`${tap}/git/ref/heads/main`]: {object: {sha: base}}, [`${tap}/contents/Formula/pure.rb?ref=${base}`]: {content: Buffer.from(current).toString('base64')}});
  await publish(directory, request(formula), async () => archive, {});
  await assert.rejects(publish(directory, request(renderFormula('v1.28.4+20260906070809', checksum)), async () => archive, {}), /downgrade/);
  await assert.rejects(publish(directory, request(formula), async () => Buffer.from('changed'), {}), /archive changed/);
});
test('publication creates one-path PR and merges only its verified immutable head', async () => {
  const directory = await artifact(); const tap = 'repos/SijanC147/homebrew-formulas';
  const base = 'd'.repeat(40); const head = 'e'.repeat(40); const mergedSha = 'f'.repeat(40); const branch = `release/pure-${tag}`;
  let merged = false; const writes: {path: string; method: string; body: unknown}[] = [];
  const pull = {number: 12, state: 'open', merged_at: null, head: {sha: head, ref: branch, repo: {full_name: 'SijanC147/homebrew-formulas'}}, base: {sha: base, ref: 'main', repo: {full_name: 'SijanC147/homebrew-formulas'}}};
  const readSource = fixture();
  const request: Api = async <T,>(path: string, method = 'GET', body?: unknown): Promise<T> => {
    if (path.startsWith('repos/SijanC147/pure/')) return readSource<T>(path, method, body);
    if (method !== 'GET') writes.push({path, method, body});
    const value = (() => {
      if (path.endsWith('/git/ref/heads/main')) return {object: {sha: merged ? mergedSha : base}};
      if (path.includes('/contents/')) return {content: Buffer.from(merged ? formula : '  version "1.23.7"').toString('base64')};
      if (path.includes('/git/matching-refs/')) return [];
      if (path.includes('/check-runs?')) return {total_count: 0, check_runs: []};
      if (path.includes('/status?')) return {total_count: 0, statuses: []};
      if (path.includes('/actions/workflows?')) return {total_count: 0, workflows: []};
      if (path.endsWith(`/git/commits/${base}`)) return {tree: {sha: base}};
      if (path.endsWith('/git/trees')) {assert.deepEqual((body as {tree: unknown[]}).tree, [{path: 'Formula/pure.rb', mode: '100644', type: 'blob', content: formula}]); return {sha: head};}
      if (path.endsWith('/git/commits')) return {sha: head};
      if (path.endsWith('/git/refs')) return {};
      if (path.includes('/pulls?')) return [];
      if (path.endsWith('/pulls') || path.endsWith('/pulls/12')) return pull;
      if (path.includes('/pulls/12/files')) return [{filename: 'Formula/pure.rb', status: 'modified'}];
      if (path.endsWith('/pulls/12/merge')) {assert.deepEqual(body, {sha: head, merge_method: 'merge'}); merged = true; return {merged: true, sha: mergedSha};}
      throw new Error(`Unexpected path ${path}`);
    })();
    return value as T;
  };
  await publish(directory, request, async () => archive, {});
  assert.equal(writes.length, 5);
  assert.ok(writes.every(write => write.path.startsWith(tap)));
});
test('tap checks reject failing, pending and missing configured CI without mutation', async () => {
  const head = 'e'.repeat(40); const prefix = 'repos/SijanC147/homebrew-formulas';
  const checks = (checkRuns: unknown[], statuses: unknown[], workflows: unknown[]) => fixture({
    [`${prefix}/commits/${head}/check-runs?filter=latest&per_page=100`]: {total_count: checkRuns.length, check_runs: checkRuns},
    [`${prefix}/commits/${head}/status?per_page=100`]: {total_count: statuses.length, statuses},
    [`${prefix}/actions/workflows?per_page=100`]: {total_count: workflows.length, workflows},
  });
  await requireTapChecks(head, checks([], [], []));
  await requireTapChecks(head, checks([{status: 'completed', conclusion: 'success'}], [{state: 'success'}], [{state: 'active'}]));
  await assert.rejects(requireTapChecks(head, checks([{status: 'completed', conclusion: 'failure'}], [], [])), /pending or failed/);
  await assert.rejects(requireTapChecks(head, checks([{status: 'in_progress', conclusion: null}], [], [])), /pending or failed/);
  await assert.rejects(requireTapChecks(head, checks([], [{state: 'pending'}], [])), /pending or failed/);
  await assert.rejects(requireTapChecks(head, checks([], [], [{state: 'active'}])), /not reported/);
});
