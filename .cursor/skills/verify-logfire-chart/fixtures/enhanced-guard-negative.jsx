<div>{(() => {
  try {
    fetch('/version.json?enhanced_guard_probe=1')
    return 'FAIL: renderer fetch was available'
  } catch (error) {
    return 'PASS: ' + String(error)
  }
})()}</div>
