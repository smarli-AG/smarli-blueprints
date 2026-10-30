# Runtime tests

A disposable Home Assistant in Docker that runs the cover blueprints from `automation/` together
with the packages from the `ha-packages` checkout next to this repo, both mounted read-only.

```powershell
.\bootstrap.ps1          # build the instance (once; ~5 minutes)
.\run-short.ps1          # core suites, ~20 minutes
.\run-long.ps1           # schedule suites, ~35 minutes; any time of day
.\check-config.ps1       # check_config on 2024.10 and 2025.4
```

Results: `.state\results.log` (git-ignored), including a `REFS` line per run with the branch and
commit of both repos.

Everything else — layout, overrides, entities, the gotchas, and what each test covers — is in
[`docs/test-environment.md`](../../docs/test-environment.md).
