# amanebo-oracle-relaunch

Relaunches the Amaneɛbɔ VPS (Oracle Ampere A1, region af-casablanca-1) from its preserved boot
volume by retrying `oci compute instance launch` until capacity appears, then attaching the
reserved public IP and waiting for the API health check.

`retry-launch.sh` is a copy of `deploy/oracle/retry-launch.sh` in the main project. The
workflow in `.github/workflows/relaunch.yml` runs it on GitHub-hosted runners every six hours,
each job polling for up to 5h40m, so the loop keeps going with no laptop involved.

## Secrets (Settings → Secrets and variables → Actions)

| Secret | Content |
|---|---|
| `OCI_CONFIG` | the `[DEFAULT]` block of `~/.oci/config` (user, fingerprint, tenancy, region) |
| `OCI_PRIVATE_KEY` | the API signing key PEM |
| `LAUNCH_ENV` | the generated `launch.env` (compartment, AD, boot volume, subnet, reserved IP, sizes) |

## Operating it

- **Watch:** the Actions tab, or `gh run list -R AhianyoElisha/amanebo-oracle-relaunch`.
- **Start a job now:** "Run workflow" on the Actions page, or `gh workflow run relaunch.yml`.
- **Stop polling:** `gh workflow disable relaunch.yml`. The workflow disables itself after a
  successful launch, or when it finds an instance of that name already exists.
- **Exit codes** from the script: 0 launched · 2 service limit (needs pay-as-you-go) · 3 deadline ·
  1 other error. 429 throttling and network errors are retried, not fatal.
- **Minutes:** a public repository has no Actions minutes cap. A private repository is capped at
  2,000 free minutes a month, about 33 hours of polling.
