# wp-vps-migration-toolkit

Bash scripts for moving WordPress sites from shared hosting / cPanel to a VPS
running [CloudPanel](https://www.cloudpanel.io/) or plain Nginx, with a dry run
and a safety check at every step.

You run the scripts **on the new VPS**. They pull files and the database from the
old host over SSH, rewrite URLs with WP-CLI, and test the new server by IP before you
touch DNS.

```
old host (cPanel)  --ssh/rsync-->  VPS (this toolkit runs here)
   preflight.sh      checks          pull-files.sh   rsync, resumable
                                     pull-db.sh      mysqldump | gzip, verified
                                     fix-urls.sh     wp search-replace + flush
                                     compare.sh      source vs target parity
                                     verify.sh       curl --resolve before DNS
```

## Features

- `--dry-run` on every script: prints each command, executes nothing.
- `set -euo pipefail`, timestamped logs (also written to `work/logs/`).
- No passwords stored: SSH key/agent only; DB credentials are read on the source
  host from `wp-config.php` and never appear in local process lists.
- Resumable file transfer with retries, cache and backup excludes.
- Database dump verified with `gzip -t`, a completion marker and SHA-256, plus an
  automatic backup of the target DB before import.
- URL rewriting that also handles JSON-escaped URLs (Elementor, blocks).
- Content parity report: posts per type, terms, comments, users, active plugins and
  theme, table prefix, permalinks and upload file counts compared on both ends.
- Pre-DNS verification: status codes, mixed content, leftover old domain, login form, cron.
- Works with bash 3.2+ (tested on macOS and Linux).

## Requirements

On the VPS: `bash`, `ssh`, `rsync` (3.1+ recommended), `gzip`, `curl`, `php`, and
[WP-CLI](https://wp-cli.org/). On the source: SSH access with key authentication,
`mysqldump`, `rsync`; WP-CLI is optional but recommended (cPanel usually allows it
under SSH, see your host's docs).

## Install

```bash
git clone https://github.com/<you>/wp-vps-migration-toolkit.git
cd wp-vps-migration-toolkit
cp migrate.env.example migrate.env
$EDITOR migrate.env
chmod 600 migrate.env
```

## Runbook

Create the empty site on the VPS first (CloudPanel: *Sites > Add Site > WordPress*
or PHP site; plain Nginx: see `docs/nginx-wordpress.conf.example`) and create an empty
database plus a `wp-config.php` with the **new** database credentials:

```bash
cd /home/example/htdocs/www.example.com
wp config create --dbname=NEWDB --dbuser=NEWUSER --prompt=dbpass
```

1. **Lower DNS TTL** to 300 s two to three days ahead ([dns-checklist.md](dns-checklist.md)).
2. **Preflight**

   ```bash
   ./preflight.sh --dry-run   # see what will be run
   ./preflight.sh
   ```

   Fix every `FAIL`. Read the `WARN` list: cache plugins to purge, stale backups,
   security plugins that wrote server rules, PHP version jumps.
3. **First file sync** (can run while the old site is live; repeat as needed)

   ```bash
   ./pull-files.sh --dry-run
   ./pull-files.sh
   ```

   `wp-config.php` and `.htaccess` are excluded by default (the VPS has its own
   credentials; Apache rules do nothing on Nginx). If rsync is interrupted, run it
   again; partial files resume.
4. **Rehearse** the database step and URL rewrite on a staging hostname or just
   to see the output (`--dry-run` first), then:

   ```bash
   ./pull-db.sh                # dump, verify, back up target DB, import
   ./fix-urls.sh               # SRC_URL -> DST_URL, dry run first, then confirm
   ```

   If the final domain stays the same (`SRC_URL` equals `DST_URL`), `fix-urls.sh` has
   nothing to do and exits; only a protocol or host change needs it.
5. **Compare** source and target content (read-only on both ends)

   ```bash
   ./compare.sh --dry-run
   ./compare.sh                # exact match expected after a fresh dump + sync
   ./compare.sh --tolerance 2  # old site still live: allow 2% drift per count
   ```

   It fails when the target is missing content: fewer posts of any type (including
   custom post types such as WooCommerce products), terms, comments, users or upload files,
   a plugin active only on the source, a different active theme, permalink structure
   or table prefix (a target `wp-config.php` whose `$table_prefix` does not match the
   imported tables shows the install screen). More on the target, or a different core
   version, is a warning. Upload subdirectories that `pull-files.sh` excludes (caches,
   Elementor CSS, backup archives, and `wp-content/uploads/...` entries in
   `RSYNC_EXTRA_EXCLUDES`) are left out of the count on both ends. A TSV report is
   written to `work/reports/compare-*.tsv` (or `--report FILE`).
6. **Verify before DNS**

   ```bash
   ./verify.sh --dry-run
   ./verify.sh                 # uses DST_IP with the real Host header
   ./verify.sh --check /pricing/=200 --check /old-url/=301
   ```

7. **Cutover**: maintenance mode on the old site, run `./pull-files.sh --only wp-content/uploads`,
   `./pull-db.sh`, `./fix-urls.sh`, `./compare.sh`, `./verify.sh`, issue TLS, then switch DNS.
   Follow [dns-checklist.md](dns-checklist.md) and keep [rollback.md](rollback.md) at hand.
8. **After**: `./verify.sh --secure`, purge caches, resubmit sitemaps, re-check Search Console.

## Script reference

| Script | Purpose | Notable options |
| --- | --- | --- |
| `preflight.sh` | Read-only readiness report | `-n`, `--env` |
| `pull-files.sh` | rsync over SSH | `--only PATH`, `--delete`, `--with-wp-config`, `--with-htaccess`, `--bwlimit`, `--fix-perms` |
| `pull-db.sh` | Dump, verify, import | `--export-only`, `--import-only`, `--file`, `-y` |
| `fix-urls.sh` | WP-CLI search-replace | `--old`, `--new`, `--no-variants`, `--skip-flush`, `-y` |
| `compare.sh` | Read-only source/target parity report | `--tolerance PCT`, `--skip-wp`, `--skip-files`, `--report FILE` |
| `verify.sh` | Pre-DNS smoke tests | `--ip`, `--url`, `--check PATH=CODES`, `--secure`, `--old-host` |

Common options: `-n/--dry-run`, `-v/--verbose`, `-y/--yes`, `--env FILE`, `-h/--help`.
Exit codes: `0` success, `1` failure, `2` usage error.

### Configuration

All settings live in `migrate.env` (see [migrate.env.example](migrate.env.example)):
source SSH details, WordPress paths, URLs, `DST_IP`, and optional tuning
(`RSYNC_EXTRA_EXCLUDES`, `RSYNC_RETRIES`, `WP_CLI_ARGS`, `VERIFY_EXTRA_URLS`,
`COMPARE_TOLERANCE`).
`MIGRATE_ENV=/path/to/file` can replace `--env`.

### What gets excluded from the file sync

See [config/rsync-excludes.txt](config/rsync-excludes.txt): page-cache directories,
`object-cache.php`/`advanced-cache.php` drop-ins, Elementor generated CSS, backup
plugin archives, SQL dumps, `error_log`, cPanel directories. Add more via
`RSYNC_EXTRA_EXCLUDES`.

### Verifying what you ship

```bash
make syntax   # bash -n
make test     # shell test harness with PATH shims (no network, no bats needed)
make lint     # shellcheck
```

## Limitations

- Single-site installs. Multisite needs `--network` search-replace and domain table edits.
- `compare.sh` counts rows in core tables only; plugin tables (for example WooCommerce
  HPOS orders in `wc_orders`) are not compared. Check those with `wp db query` by hand.
- The toolkit does not issue TLS certificates, change DNS, or migrate mailboxes.
- cPanel accounts without SSH access cannot use it; use an archive export instead.
- Translate Apache-specific `.htaccess` rules (redirects, security headers) to Nginx by hand.

## License

MIT, see [LICENSE](LICENSE). Author: [Saizul Amin](https://saizul.com).
