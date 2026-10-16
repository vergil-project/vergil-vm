# Dependency Updates

Most of vergil-vm's pinned versions are not in a language lockfile, so
vergil-tooling's built-in updaters cannot see them. The repo supplies its own
updater instead: a dependency-update hook that bumps what is safe to bump and
reports the rest.

## How It Runs

The hook is declared in `vergil.toml`:

```toml
[dependency-update]
hook = "scripts/dev/update-deps.sh"
```

`vrg-release` ends with an update-deps stage, which runs after the release is
tagged and published. That stage runs vergil-tooling's dependency-update
pipeline. The repo hook is the last updater in that pipeline, so it sees what
the built-in updaters have already changed. vergil-tooling runs it inside the
dev container from the root of the update worktree, with `VRG_DEPS_REPORT` set
to the file it appends held-back entries to.

The hook (`scripts/dev/update-deps.sh`) only edits files. It never commits;
vergil-tooling commits its changes as `chore(deps): repo hook`. Its pure
helpers (version sorting, the `NERDCTL_VERSION` rewrite, report lines) live in
`scripts/dev/update-deps-lib.sh`, which is sourced and never run directly.

## What It Bumps

| Dependency | Where it is pinned | Update |
| ---------- | ------------------ | ------ |
| OpenTofu providers (`hashicorp/google`, `hashicorp/azurerm`) | `versions.tf` and `.terraform.lock.hcl` in each module under `opentofu/modules/*/vm` and `opentofu/modules/*/volume` | `tofu init -upgrade` per module, within the existing `~>` ranges |
| nerdctl (`nerdctl-full` bundle) | `NERDCTL_VERSION` in every `opentofu/modules/*/vm/cloud-init.yaml.skel` | Newest stable release within the current major |

For the providers, each module is initialised with a throwaway data directory
(`TF_DATA_DIR` set to a temporary directory, removed afterwards), so no
`.terraform/` state is left in the tree. The OpenTofu registry serves hashes
for every platform a provider publishes, so `tofu init` alone refreshes each
`.terraform.lock.hcl` for the full platform set.

For nerdctl, the hook first checks that every cloud-init skeleton pins the same
`NERDCTL_VERSION`, and fails if they disagree. When it bumps the version it
rewrites every skeleton, then runs `scripts/build-cloud-init.sh` to regenerate
each `cloud-init.yaml`. This pin applies only to the off-platform cloud VMs;
Lima VMs get the nerdctl bundle that Lima ships.

## What It Only Reports

Some updates need a deliberate change, so the hook reports them and leaves the
files alone. Each one is written to the held-back report that vergil-tooling
prints at the end of the run:

| Dependency | Reported when |
| ---------- | ------------- |
| Lima | The newest Lima release has a higher major than the `minimumLimaVersion` floor in `templates/agent.yaml.skel` |
| Node.js | The newest Node.js LTS major is higher than the NodeSource `setup_<N>.x` in `templates/provision/10-base.sh` |
| nerdctl | A nerdctl release exists in a newer major than the pinned `NERDCTL_VERSION` |

## Failure Behaviour

Every lookup, parse and tool run is checked. If a release list cannot be
fetched or parsed, an expected pin is missing, or `tofu` or
`build-cloud-init.sh` fails, the hook exits non-zero. There is no silent "no
change" result.

A non-zero exit fails the dependency update. Because the hook fails before
validation, nothing is pushed: no `dependency-update` PR is opened and no fix
task is filed. The release itself is already published, so only the
update-deps stage fails. `vrg-release` records the failure on the release
tracking issue and exits non-zero.

If the hook succeeds but validation of its changes fails, vergil-tooling keeps
the `dependency-update` labelled PR open and files a fix task for it.

## GitHub API Rate Limit

The nerdctl and Lima release lists come from the GitHub REST API
(`api.github.com/repos/<owner>/<repo>/releases`), called without
authentication. Unauthenticated requests share a low hourly limit per IP
address. When the limit is exhausted, the request fails, the hook exits
non-zero, and the update fails loudly as described above. Wait for the limit
to reset and run the update again.

## Running It by Hand

From the repository root:

```bash
vrg-container-run -- env VRG_DEPS_REPORT=/workspace/.vergil/deps-report.jsonl \
  scripts/dev/update-deps.sh
```

The hook requires `VRG_DEPS_REPORT` and refuses to run without it. Any bumps
are left as uncommitted changes in the working tree, and any held-back entries
are appended to `.vergil/deps-report.jsonl` as JSON lines.

## Testing

`tests/check-update-deps-hook.sh` tests the hook. It runs in
`vrg-validate` through `scripts/bin/validate-custom`, offline, with stubs in
place of the network and tool calls.
