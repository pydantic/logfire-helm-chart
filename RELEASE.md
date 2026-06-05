# Releasing the chart

Releases are driven by the `version:` field in `charts/logfire/Chart.yaml`. The `.github/workflows/release.yml` workflow runs on every push to `main` and invokes [`helm/chart-releaser-action`](https://github.com/helm/chart-releaser-action), which packages the chart, creates a GitHub Release with tag `logfire-X.Y.Z`, uploads the `.tgz` as a release asset, and updates `index.yaml` on the `gh-pages` branch. Because `skip_existing: true` is set, the action only publishes versions that are not already in the index — so a release is produced exactly when `Chart.yaml`'s `version:` is bumped to a value that has not been released before.

The workflow inspects `Chart.yaml`'s `version:` string to decide whether the release is a pre-release: a SemVer suffix with a hyphen (e.g. `0.13.24-rc.1`, `0.13.24-beta.0`) is treated as a pre-release; a plain `X.Y.Z` is treated as stable.

## Stable release

1. Open a PR against `main` that bumps `charts/logfire/Chart.yaml` `version:` (and, where relevant, `appVersion:`). Follow the PR template — the `## Summary` and `## Upgrade notes` sections are scraped into the GitHub Release body by the workflow.
2. Merge to `main`. The workflow creates tag `logfire-X.Y.Z`, a GitHub Release, publishes the chart to the Pages index, copies `charts/logfire/README.md` to `gh-pages`, and rewrites the release notes from the PR body.

## Pre-release (RC)

Pre-releases let you publish a chart for internal testing without committing to a stable version. They land in the same `index.yaml` as stable releases; Helm hides them from default installs unless the consumer pins `--version` or passes `--devel` (see the install section in the chart README).

1. Open a PR against `main` that bumps `charts/logfire/Chart.yaml` `version:` to a SemVer pre-release, e.g.:
   ```yaml
   version: 0.13.24-rc.1
   ```
2. Merge to `main`. The workflow:
   - publishes `logfire-0.13.24-rc.1.tgz` to the Pages index;
   - creates a GitHub Release for tag `logfire-0.13.24-rc.1` with `prerelease=true` and not marked as "latest";
   - rewrites that release's notes from the PR body;
   - skips the `gh-pages` README overwrite, so the public docs site keeps tracking the last stable release.
3. Internal testers install with the version pinned:
   ```sh
   helm install logfire pydantic/logfire --version 0.13.24-rc.1
   ```

Iterate by opening another PR that bumps the suffix (`-rc.2`, `-rc.3`, …). When the change is ready to ship, open a final PR setting `version:` to the stable value (e.g. `0.13.24`); the normal stable-release flow takes over from there.

### Notes

- Any SemVer pre-release identifier works (`-rc.1`, `-beta.0`, `-alpha.2`, …); the workflow keys on the hyphen.
- Because RCs flow through `main` like any other change, no separate publishing path or branch is required. The `index.yaml` always reflects the latest merged state; the `gh-pages` README intentionally only updates on stable releases so the docs site matches what default (non-`--devel`) installs get.
- `chart-releaser-action` has no native pre-release flag (tracked in [helm/chart-releaser#468](https://github.com/helm/chart-releaser/pull/468)); the `prerelease=true` flip and "latest" suppression are done by follow-up steps in `release.yml`.
