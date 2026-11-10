# Contributing

Thanks for helping. This toolkit touches production sites, so changes should be
conservative and well tested.

## Ground rules

- Scripts must work with `bash` 3.2+ (macOS) and bash 4+ (Linux VPS): no
  associative arrays, `mapfile`, or `${var,,}`.
- Use `set -euo pipefail` and the helpers in `lib/common.sh` (`run`, `src_ssh`,
  `dst_wp`, `log_*`, `confirm`).
- Anything that changes state must go through `run`/`dst_wp` so `--dry-run` works.
- Never put credentials on command lines or in the repo. Use `example.com`,
  `example.org` and documentation IP ranges (203.0.113.0/24) in examples.
- Every script supports `-h/--help`, `-n/--dry-run`, `--env FILE`, `-v`.

## Development

```bash
make test     # runs tests/run.sh (no bats required)
make lint     # shellcheck -x on all scripts
make syntax   # bash -n on all scripts
```

### Tests

`tests/run.sh` runs every `test_*` function in `tests/test_*.sh` in an isolated
sandbox. `tests/shims/` contains stand-ins for `ssh`, `rsync`, `mysqldump`, `wp`,
`curl`, `php` and `df`, put first in `PATH`. They record each call in `$SHIM_LOG` and
read behaviour from `SHIM_*` environment variables. Add a shim variable rather
than touching the network.

Add tests for new flags, error paths, and dry-run behaviour.

## Pull requests

1. Open an issue first for larger changes.
2. Keep PRs focused; update `README.md` and `CHANGELOG.md`.
3. Make sure `make syntax test lint` passes.
