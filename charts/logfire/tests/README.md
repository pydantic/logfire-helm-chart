# Chart tests

This directory holds the chart's helm-unittest suites, deliberately kept small.

**Policy: unit tests only for what a real deployment cannot show us.**
Everything else is covered by the integration suite in `tests/integration/`,
which runs against a real cluster install in CI (kind + `ct install` + `helm
install` into a namespace enforcing the restricted Pod Security Standard).

A test belongs here only if it is one of:

1. **Values validation contract** (`validation_test.yaml`): bad values must fail
   `helm install` with a clear message. Integration tests only exercise valid
   values. The suite pins the cases listed in it, not every `fail` site in the
   validation helpers — add a case when you touch one.
2. **Cross-template coupling** (`secrets_test.yaml`, `service_addressing_test.yaml`,
   `autoscaling_test.yaml`):
   two templates must agree on a value: a secret key name, service DNS name,
   port, scheme, or shared constant. A mismatch deploys cleanly and fails at
   runtime with no hint of the cause. The TLS/topology matrices matter because CI
   only deploys one variant.
   Workload replicas and the enabled HPA or KEDA controller must also agree on
   which resource owns the replica count.
3. **Security gating** (`gateway_oauth_client_test.yaml`): credentials and OAuth
   clients must not be exposed in configurations where they are unsafe.
4. **Contracts with things outside the chart** (`rate_limits_test.yaml`,
   `resource_shape_test.yaml`, `rustfs_test.yaml`, and the two
   `*_security_context_test.yaml` suites): env keys the SDK-facing services read,
   legacy values paths that must keep working across upgrades, and
   `securityContext` merge precedence. A rename or a silently ignored value
   breaks customers or cluster admission, and no install catches it.

Do not add tests that assert rendered field shape for its own sake: per-image
resource values, default security contexts, config-text regexes, or
one-toggle-one-assert presence checks. They restate the template, churn on every
refactor, and a real install plus the integration suite already catches what
matters there.

When deleting or rewriting a suite here, check first whether its scenario is
already exercised by `tests/integration/` — if not, port it there rather than
losing it.
