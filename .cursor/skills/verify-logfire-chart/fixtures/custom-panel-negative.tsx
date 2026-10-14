import React from 'react'

export function BoundaryChecks({ record }) {
  const [result, setResult] = React.useState('Checks have not run')
  function check() {
    if (!window.trustedTypes) {
      setResult('UNVERIFIED: Trusted Types API is unavailable')
      return
    }
    const results = []
    try {
      document.createElement('iframe')
      results.push('FAIL: frame creation was allowed')
    } catch (error) {
      results.push('PASS: frame creation refused: ' + String(error))
    }
    try {
      window.trustedTypes.createPolicy('chart-contract-probe', { createHTML: value => value })
      results.push('FAIL: an extra Trusted Types policy was allowed')
    } catch (error) {
      results.push('PASS: extra Trusted Types policy refused: ' + String(error))
    }
    const detached = document.createElement('div')
    detached.innerHTML = '<iframe src="about:blank"></iframe>'
    results.push(detached.firstElementChild?.tagName === 'BLOCKED-IFRAME'
      ? 'PASS: Trusted Types default policy removed the nested frame tag'
      : 'FAIL: nested frame tag survived as ' + detached.firstElementChild?.tagName)
    setResult(results.join('\n'))
  }
  return <section className="rounded border p-3">
    <strong>Custom panel active</strong>
    <p>{record.message || 'No record message'}</p>
    <button type="button" onClick={check}>Run boundary checks</button>
    <pre style={{ whiteSpace: 'pre-wrap' }}>{result}</pre>
  </section>
}
