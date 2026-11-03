import React from 'react'

export function ChartContractPanel({ record }) {
  return <section className="rounded border p-3">
    <strong>Custom panel active</strong>
    <p>{record.message || 'No record message'}</p>
  </section>
}
