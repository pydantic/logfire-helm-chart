# Chart tests

This directory holds the chart's helm-unittest suites, deliberately kept small.

**Policy: unit tests only for what a real deployment cannot show us.**
Everything else is covered by the integration suite in `tests/integration/`,
which runs against a real cluster install in CI (kind + `ct install` + `helm
install`).

A test belongs here only if it is one of:

1. **Values validation contract** (`validation_test.yaml`): bad values must fail
   `helm install` with a clear message. Integration tests only exercise valid
   values, so nothing else covers this.
2. **Cross-template coupling** (`secrets_test.yaml`, `service_addressing_test.yaml`):
   two templates must agree on a secret key name, service DNS name, port, or
   scheme. A mismatch deploys cleanly and fails at runtime with no hint of the
   cause. The TLS/topology matrices matter because CI only deploys one variant.
3. **Security gating** (`gateway_oauth_client_test.yaml`): credentials and OAuth
   clients must not be exposed in configurations where they are unsafe.

Do not add tests that assert rendered field shape (resource values, security
context merges, config-text regexes, one-toggle-one-assert presence checks). They
restate the template, churn on every refactor, and a real install plus the
integration suite already catches what matters there.

When deleting or rewriting a suite here, check first whether its scenario is
already exercised by `tests/integration/` — if not, port it there rather than
losing it.
