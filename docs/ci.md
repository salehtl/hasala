# CI: concurrency, caches and weekly runs

The required checks, the jobs and the path rules are in `CLAUDE.md` ("CI").
This page has the details that only matter when you change the CI.

## Concurrency

- A new push to a pull request cancels the older run of that pull request.
- A push to `main` does not cancel an older run as a whole. But a newer push
  to `main` cancels the Mac jobs (`swift`, `ios-build`, `ios-tools` and each
  `ios` shard) of an older push, if they are in the queue or running. Each of
  these jobs has a job-level `concurrency` group for this. The reason: each
  push to `main` asks for six Mac jobs, and the account runs only five at the
  same time. Without the groups, the runs of `main` waited for hours.
- The newest push to `main` still runs its Mac jobs, because some pull
  requests merge before their Mac jobs finish.
- A manual run is not cancelled.

## Caches

The repository has 10 GB of Actions cache. Above it, GitHub deletes the
entries that were used least recently.

- `actions/cache` keeps the Go caches (`gate`, `vuln` only reads them), the
  Bun caches (`gate`, `web`) and the SwiftPM caches (`swift`, `ios-build`).
- `nix-community/cache-nix-action` keeps the Nix store in `gate`, `vuln`,
  `nixos-vm`, `web` and `ios-tools`. Each job has one entry, with the key
  `nix-<runner OS>-<job>-<hash of flake.lock>`.
- Only a push to `main` saves a Nix entry. Pull requests and manual runs only
  restore it. When `flake.lock` changes, a run restores the newest entry with
  the same prefix.
- Before a save, the job collects garbage until the store is at most
  `gc-max-store-size`. After a save, it deletes the older entries of the same
  prefix on `main` (`purge`). For this, these jobs have `actions: write`.
- Do not use `magic-nix-cache-action` again. It saved one entry for each
  store path, with a random suffix, also in the scopes of pull requests. On
  2026-10-20 it had 5300 entries (9.5 GB) for 974 different paths (1.5 GB).

## Weekly runs

`.github/workflows/vuln-weekly.yml` runs the same govulncheck on `main` each
Monday (job `vuln-weekly`, not required). This is necessary because new Go
advisories occur without new commits. It is a different workflow, thus it
does not record checks on the head of `main` with the required names.

`.github/workflows/ci-weekly.yml` runs each Sunday (not required):

- Job `ci` calls `ci.yml` (`workflow_call`). The event is `schedule`, thus
  `changes` starts all jobs and the path rules do not apply. This finds jobs
  that the path rules skipped for weeks. Its checks have the names
  `ci / <job>`, thus they are not the required names.
- Job `cache-usage` fails when the Actions cache of the repository is more
  than 8 GB (`gh api repos/{repo}/actions/cache/usage`).
- A pull request that changes `ci-weekly.yml` runs only `cache-usage`.
