# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `compare.sh`: read-only parity report between the source and the target site.
  Compares WordPress core version, active theme, active plugins, table prefix,
  permalink structure, posts per post type, terms per taxonomy, comments, users,
  and the number of files in `wp-content/uploads` (pruning the same cache and
  backup directories that `pull-files.sh` excludes, plus upload paths listed in
  `RSYNC_EXTRA_EXCLUDES`). Missing content fails; extra content on the target
  warns. `--tolerance PCT` / `COMPARE_TOLERANCE` for a site that is still live,
  `--skip-wp`, `--skip-files`, and a TSV report in `work/reports/` or `--report FILE`.
- Test shims answer the new WP-CLI and SQL probes for both ends (`SHIM_SRC_*`,
  `SHIM_DST_*`).

## [0.1.0] - 2026-11-10

### Added
- `preflight.sh`: SSH access, PHP version comparison, disk space, database size,
  WP-CLI on both ends, and a report of cache, backup and server-bound plugins.
- `pull-files.sh`: resumable rsync over SSH with cache and backup excludes,
  retry on transient errors, `--only`, `--delete`, `--bwlimit`, ownership fixing.
- `pull-db.sh`: `mysqldump --single-transaction` streamed over SSH and gzipped,
  integrity checks, SHA-256 file, pre-import backup, WP-CLI import.
- `fix-urls.sh`: WP-CLI search-replace dry run then apply, with JSON-escaped,
  http and protocol-relative variants, and Elementor CSS and cache flushes.
- `verify.sh`: status checks via `curl --resolve` before DNS cutover, mixed
  content and old-host scan, login form, wp-admin redirect and WP-Cron checks.
- `dns-checklist.md` and `rollback.md`.
- Shell test harness with PATH shims, and CI (ShellCheck, tests on Linux and macOS).
