#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repo = path.resolve(__dirname, '..');
const workflow = fs.readFileSync(path.join(repo, '.github/workflows/release.yml'), 'utf8');
const step = workflow.split('      - name: Update release notes from PR body\n')[1]?.split('\n      - name:')[0];
if (!step) throw new Error('Release notes workflow step not found');
const script = step.split('          script: |\n')[1].split('\n').map(line => line.slice(12)).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const updateNotes = new AsyncFunction('require', 'core', 'github', 'context', script);

async function check(summary) {
  const automaticNotes = '### Automatic changelog\n- Previous generated notes';
  const unrelatedSummary = 'Only change the CI configuration.';
  let body = automaticNotes;
  const github = { rest: {
    repos: {
      getReleaseByTag: async () => ({ data: { id: 1, body } }),
      getCommit: async () => ({ data: { sha: 'release-commit' } }),
      listPullRequestsAssociatedWithCommit: async ({ commit_sha }) => ({ data: [{
        number: commit_sha === 'release-commit' ? 1 : 2,
        merged_at: '2026-01-01',
        base: { ref: 'main' },
      }] }),
      updateRelease: async args => { body = args.body; },
    },
    pulls: { get: async ({ pull_number }) => ({ data: {
      body: `## Summary\n${pull_number === 1 ? summary : unrelatedSummary}`,
      html_url: `https://example.com/pull/${pull_number}`,
    } }) },
  } };
  const args = [require, { info() {} }, github, {
    repo: { owner: 'example', repo: 'chart' },
    sha: 'later-ci-only-commit',
  }];
  const expected = '<!-- BEGIN PR NOTES -->\n## Summary\n\n'
    + summary + '\n\nPR: https://example.com/pull/1\n<!-- END PR NOTES -->'
    + '\n\n---\n\n' + automaticNotes;
  await updateNotes(...args);
  assert.equal(body, expected, 'Release notes must use the release PR and preserve literal prose');
  await updateNotes(...args);
  assert.equal(body, expected, 'Repeating the update must preserve the complete release notes');
  console.log(`PASS literal release prose and repeat updates: ${summary}`);
}

(async () => {
  process.chdir(repo);
  for (const summary of [
    'Normal release prose.',
    'Keep the literal replacement examples $& and $$ in the docs.',
    "Keep the literal replacement examples $` and $' in the docs.",
  ]) {
    await check(summary);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
