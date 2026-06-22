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

<!--
  The next three steps are the WEB CONSOLE part — the first-time Google Cloud
  sign-up, project creation, and billing. This is the most confusing part of the
  whole setup and the reason this guide exists. GCP's onboarding UI changes over
  time, so these are captured from what actually appeared during the #204
  walkthrough, with screenshots. Do not guess screens — capture the real flow.
-->

## Step 2 — Sign up for Google Cloud in the Console (free trial)

Go to [console.cloud.google.com](https://console.cloud.google.com) signed in with your
Google account. A brand-new account lands on the Console with a **free-trial
onboarding** front and centre:

![Google Cloud free-trial welcome screen: "Try Google Cloud with $300 in free credits", 90 days, no billing during free trial, with a "Try for free" button](img/off-platform-cloud-setup/02a-free-trial-welcome.png)

What it offers: **$300 in free credits, 90 days, and "no billing during the free
trial."** Click **Try for free** (or **Start free trial** in the top banner) to begin.

**The one decision here — free trial vs. paid:**

- **Take the free trial.** The $300 credit offsets the cost of the off-platform VM
  while you validate the setup, and — importantly — the credit **carries over if you
  later upgrade to a paid account**, so claiming it first costs you nothing.
- **A payment method (card) is still required** to start the trial. Google uses it to
  verify identity; you are **not** charged during the trial unless you explicitly
  upgrade to a paid account or exceed the credit.
- **Expect to upgrade to paid later.** Free-trial accounts come with **restricted
  quotas** — a nested-virt instance for the lab is large (~16 vCPU), and the trial's
  default vCPU quota in a region is likely too low. You will probably need to upgrade
  to a full (paid) billing account to get the quota — we hit this for real at
  Step 9 (quota). The $300 credit still applies after upgrading.

Click **Try for free** and continue to the sign-up form (country, Terms of Service,
and the payment method) — captured in Steps 3–4.

## Step 3 — Create your first project (Console) (TODO — web)

## Step 4 — Set up a billing account (Console) (TODO — web; the fiddly part)

## Step 5 — Authenticate gcloud (CLI: login + select project)

Once the account, project, and billing exist, point the CLI at them. Log in with your
Google account (opens a browser for OAuth and stores your *user* credential):

```bash
gcloud auth login
gcloud auth list                    # -> your account, marked ACTIVE (*)
gcloud config set project <PROJECT_ID>
gcloud config list                  # -> account + project set
```

> This user login is separate from the **Application Default Credentials** OpenTofu
> uses (Step 7). You need both: the user login to drive `gcloud`, and ADC for `tofu`.

## Step 6 — Enable the Compute Engine API (TODO)

## Step 7 — Application Default Credentials for OpenTofu (TODO)

## Step 8 — IAM permissions (TODO)

## Step 9 — Nested-virtualization quota (TODO)

## Step 10 — Confirm a nested-virt machine type + region (TODO)

## Step 11 — SSH keypair (TODO)

## Next — declare the profile and create the VM (TODO)

---

## Azure (parity — TODO when the Azure path is set up)

The same shape: a subscription with billing, `az login`, a nested-virtualization-capable
SKU, region, and quota.
