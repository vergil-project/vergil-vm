# Off-Platform Cloud Setup (GCP)

A step-by-step guide to standing up the cloud-account prerequisites for the
**off-platform VM backend** (vergil-vm #199): a billed cloud project, host
credentials, permissions, and nested-virtualization quota — everything the
OpenTofu modules need before `vrg-vm create` can stand up a real cloud VM.

This guide is **GCP-first** (the primary target). An **Azure** section captures the
parity steps when that path is set up.

> **The cloud setup is a macOS-host activity.** `gcloud` and the GCP Console run on
> your Mac, and the credential you create here (`gcloud` Application Default
> Credentials) is **host-local — it does not propagate into VMs** the way the GitHub
> App credentials do. It is a distinct class of credential, managed only on the
> operator's Mac.

## When you need this

Only repos that declare the off-platform backend in their `vergil.toml`
(`[vm.<identity>] backend = "off-platform"`) need a cloud project. The default local
Lima backend needs none of this. Today the one consumer is the native-x86 MQ cluster
lab.

## What you will end up with

- A GCP project with billing enabled and the Compute Engine API on.
- `gcloud` installed and authenticated on your Mac (Application Default Credentials).
- IAM permissions to create instances, disks, and firewall rules.
- Confirmed nested-virtualization quota and a working machine-type + region.
- An SSH keypair for the instance.

---

<!--
  CAPTURE-AS-WE-GO. Each step below is filled in with the EXACT commands, console
  paths, and screenshots that actually worked during the first real setup
  (vergil-vm #204). Steps not yet walked through are marked TODO and must not be
  guessed — replace them with verified content only.
-->

## Prerequisites

- A **Google account** that can sign in to [console.cloud.google.com](https://console.cloud.google.com).
- **Homebrew** on your Mac (for the gcloud install below).
- A way to pay: GCP requires a **billing account** (a payment method) before you can
  run instances. We set that up in a later step; you just need a card available.

## Step 1 — Install the Google Cloud CLI (macOS)

The Google Cloud CLI is a Homebrew **cask** named `gcloud-cli`. Install it with:

```bash
brew install --cask gcloud-cli
```

> **Gotcha:** `brew install gcloud` does **not** work — there is no `gcloud`
> *formula*. Homebrew errors with *"No available formula with the name gcloud"* and
> suggests the cask: *"To install gcloud-cli, run: `brew install --cask gcloud-cli`"*.

This installs the Google Cloud SDK (v573.0.0 at the time of writing; it pulls
`python@3.14` as a dependency) and links the core binaries — `gcloud`, `gsutil`,
`bq` — into `/opt/homebrew/bin`, which is already on your `PATH`. So `gcloud` works
immediately; no `PATH` edit is needed for the core tool.

Optionally, enable shell completion and put the SDK's *additional* components on
`PATH` (for `gcloud components install …`) by sourcing the init scripts from your
shell profile (zsh):

```bash
echo 'source "/opt/homebrew/share/google-cloud-sdk/path.zsh.inc"' >> ~/.zshrc
echo 'source "/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc"' >> ~/.zshrc
exec zsh
```

Verify the install:

```bash
gcloud version          # -> Google Cloud SDK 573.0.0, bq, core, gsutil, ...
gcloud auth list        # -> "No credentialed accounts." until you log in (Step 2)
gcloud config list      # -> active configuration: [default], no project yet
```

## Step 2 — Authenticate gcloud (user login)

Log in with your Google account. This opens a browser for the OAuth consent and
stores your *user* credential (used to run `gcloud` commands as you):

```bash
gcloud auth login
```

Pick the Google account you'll use for this project and grant access. Then confirm
the account is active:

```bash
gcloud auth list        # -> your account, marked ACTIVE (*)
```

> This user login is separate from the **Application Default Credentials** that
> OpenTofu uses (Step 6). You need both: the user login to drive `gcloud`, and ADC
> for `tofu`.

## Step 3 — Create the GCP project (TODO)

## Step 3 — Create the GCP project (TODO)

## Step 4 — Enable billing (TODO)

## Step 5 — Enable the Compute Engine API (TODO)

## Step 6 — Application Default Credentials for OpenTofu (TODO)

## Step 7 — IAM permissions (TODO)

## Step 8 — Nested-virtualization quota (TODO)

## Step 9 — Confirm a nested-virt machine type + region (TODO)

## Step 10 — SSH keypair (TODO)

## Next — declare the profile and create the VM (TODO)

---

## Azure (parity — TODO when the Azure path is set up)

The same shape: a subscription with billing, `az login`, a nested-virtualization-capable
SKU, region, and quota.
