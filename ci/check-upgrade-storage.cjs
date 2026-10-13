const assert = require('node:assert/strict')
const { execFileSync, spawnSync } = require('node:child_process')
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const root = path.resolve(__dirname, '..')
const target = process.env.CT_TARGET_BRANCH || 'main'
const configResult = spawnSync('ct', [
  'list-changed', '--config', path.join(root, 'ci/ct.yaml'),
  '--target-branch', target, '--print-config',
], { cwd: root, encoding: 'utf8' })
assert.equal(configResult.status, 0, configResult.stderr)
const config = configResult.stderr
const extraSetArgs = /^HelmExtraSetArgs: (.*)$/m.exec(config)?.[1].trim().split(/\s+/) || []
const remote = /^Remote: (.*)$/m.exec(config)?.[1]
assert.ok(remote, 'Chart-testing must report its target remote')

const temp = mkdtempSync(path.join(os.tmpdir(), 'logfire-upgrade-storage-'))
try {
  const values = path.join(temp, 'previous-values.yaml')
  writeFileSync(values, execFileSync('git', [
    'show', `${remote}/${target}:charts/logfire/ci/ci-values.yaml`,
  ], { cwd: root }))
  const claim = execFileSync('helm', [
    'template', 'upgrade-storage-test', path.join(root, 'charts/logfire'),
    '--values', values, ...extraSetArgs,
    '--show-only', 'templates/logfire-python-object-store.yaml',
  ], { cwd: root, encoding: 'utf8' })
  assert.match(claim, /accessModes:\n\s+- ReadWriteOnce\n/)
  assert.doesNotMatch(claim, /ReadWriteMany/)
  assert.match(claim, /storage: "1Gi"/)
  console.log('Previous revision values keep the upgrade claim compatible with single-node Kind storage.')
} finally {
  rmSync(temp, { recursive: true, force: true })
}
