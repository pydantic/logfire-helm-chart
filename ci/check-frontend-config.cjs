const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const path = require('node:path')
const vm = require('node:vm')

const root = path.resolve(__dirname, '..')
const rendered = execFileSync('helm', [
  'template', 'frontend-config-test', path.join(root, 'charts/logfire'),
  '--set-string', 'adminEmail=test@example.com',
  '--set-string', 'objectStore.uri=s3://test-bucket',
  '--set', 'existingSecret.enabled=true',
  '--set-string', 'existingSecret.name=logfire-secrets',
  '--set', 'postgresSecret.enabled=true',
  '--set-string', 'postgresSecret.name=postgres-secrets',
  '--show-only', 'templates/logfire-frontend-service-config.yaml',
], { encoding: 'utf8' })
const config = rendered.split('  config.1.js: |\n')[1].split('\n---')[0]
  .split('\n').map((line) => line.slice(4)).join('\n')

function runConfig(initial, failure) {
  const storage = new Map(Object.entries(initial))
  const context = {
    window: {},
    localStorage: {
      getItem(key) {
        if (failure === 'read') throw new Error('Storage is blocked')
        return storage.get(key) ?? null
      },
      setItem(key, value) {
        if (failure === 'write') throw new Error('Storage is full')
        storage.set(key, value)
      },
    },
  }
  vm.runInNewContext(config, context)
  assert.equal(context.window.appConfig.selfHosted, true)
  return { storage, context }
}

const fresh = runConfig({})
assert.deepEqual(JSON.parse(fresh.storage.get('disableFeatureFlags')), ['whats_new'])
vm.runInNewContext(config, fresh.context)
assert.deepEqual(JSON.parse(fresh.storage.get('disableFeatureFlags')), ['whats_new'])

const existing = runConfig({
  featureFlags: '["public_conversations"]',
  disableFeatureFlags: '["profiles"]',
})
assert.deepEqual(JSON.parse(existing.storage.get('disableFeatureFlags')), ['profiles', 'whats_new'])
assert.equal(existing.storage.get('featureFlags'), '["public_conversations"]')

const alreadyDisabled = runConfig({ disableFeatureFlags: '["profiles","whats_new"]' })
assert.equal(alreadyDisabled.storage.get('disableFeatureFlags'), '["profiles","whats_new"]')

for (const [malformed, enabledFlags, disabledFlags] of [
  ['{', [], ['whats_new']],
  ['null', [], ['whats_new']],
  ['{}', [], ['whats_new']],
  ['[null,"profiles",1]', ['profiles'], ['profiles', 'whats_new']],
]) {
  const result = runConfig({ disableFeatureFlags: malformed })
  assert.deepEqual(JSON.parse(result.storage.get('disableFeatureFlags')), disabledFlags)
  const malformedEnabled = runConfig({ featureFlags: malformed })
  assert.deepEqual(JSON.parse(malformedEnabled.storage.get('featureFlags')), enabledFlags)
  assert.deepEqual(JSON.parse(malformedEnabled.storage.get('disableFeatureFlags')), ['whats_new'])
}
for (const failure of ['read', 'write']) runConfig({}, failure)

console.log('Generated frontend config preserves overrides and tolerates unavailable storage.')
