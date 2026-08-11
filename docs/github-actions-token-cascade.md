# GitHub Actions token cascades

Events created with a repository's `GITHUB_TOKEN` do not normally start another workflow run.
Consequently, an Actions job that merges a pull request with that token can update `main` without
starting its `push` CI or a deploy chained from CI with `workflow_run`. GitHub makes exceptions for
`workflow_dispatch` and `repository_dispatch`, but neither restores an omitted push event.

This failure is silent: the pull-request checks pass and the merge succeeds. Diagnose it from the
pull request's `mergedBy.login` and the merge commit SHA. A merge by `app/github-actions` with no
push-event run whose `headSha` exactly equals the merge SHA was suppressed. Do not use
`commit.committer.name`; GitHub is the committer for both cascaded and suppressed merges.

## Fix

Use a dedicated fine-grained PAT for the merge step, limited to affected repositories with
`contents: write` and `pull-requests: write`. The canonical template uses the `AUTOMERGE_PAT` org
secret. When that secret is unavailable (including fork pull requests), it preserves the existing
merge behavior with `GITHUB_TOKEN` and emits
`::warning title=Auto-merge cascade suppressed::`.

A bridge workflow cannot repair the chain: the merge and its pull-request event are both produced
by `GITHUB_TOKEN`, so neither can start the bridge. Changing the merge identity is the operative
fix. A repository-scoped GitHub App token is the preferred follow-up when one is available because
it avoids PAT expiry and can be installation-scoped.

## Audit and verification

Keep the operator repository map outside this public repository, for example at
`~/.config/catalyst/automerge-cascade-repos.json`.

```bash
plugins/dev/scripts/audit-automerge-cascade.sh --audit
plugins/dev/scripts/audit-automerge-cascade.sh --verify --since 7d
plugins/dev/scripts/audit-automerge-cascade.sh --history --since 90d
```

`--audit` identifies workflow/token shape. `--verify` proves each recent merge has an exact-SHA
push run. `--history` lists gaps for operator review; replaying an old deploy is a per-repository
decision because a stale artifact can supersede newer code.

## Rollout runbook

1. Create `AUTOMERGE_PAT` as an organization secret visible to affected repositories.
2. Run `--rollout` without `--fix` and inspect its dry-run diff.
3. Run `--rollout --fix --limit 1` for the canary repository.
4. Merge the canary change and let a subsequent PR use normal auto-merge.
5. Require `--verify --since 1d` to report `cascaded`, then confirm its deploy workflow ran.
6. Only after that proof, run the full `--rollout --fix` fan-out.

The rollout marker makes repeated runs idempotent. Missing secrets fail open with the warning above.
