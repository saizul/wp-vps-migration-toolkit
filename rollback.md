# Rollback plan

A migration is safe only when you can undo it quickly. Prepare this *before*
cutover.

## Principles

1. The old server is the rollback. Keep it online and unchanged until you are
   confident (at least one full DNS TTL plus 48 hours, ideally a week).
2. Keep TTL at 300 s until the new server is proven.
3. After cutover, writes (orders, comments, form entries, user registrations)
   may land on the **new** server. Decide up front how you will carry them back.

## Before cutover

- [ ] Take a fresh full backup of the source (files and DB) independent of this toolkit.
- [ ] Record the old `A`/`AAAA` values and the exact DNS zone export.
- [ ] Put the old site into a state that cannot diverge by accident: disable its
      cron jobs for emails or imports that would duplicate on both servers.
- [ ] Note the dump you imported: `work/db/*.sql.gz` and its `.sha256`.
- [ ] `pull-db.sh` writes `work/db/pre-import-*.sql`, a backup of the target database
      before each import. Keep it.

## Triggers for rollback

Roll back if any of these cannot be fixed within your agreed window (for example 30 minutes):

- Checkout, login, or form submissions fail.
- Sustained 5xx responses or a redirect loop.
- Email stops sending/receiving.
- Database corruption or missing content.

## Procedure

1. **Switch DNS back**: set the `A` (and `AAAA`) record to the old IP. With a
   300 s TTL most clients return within minutes. On Cloudflare, change the origin
   IP and purge the cache.
2. **Freeze the new site** so it stops accepting writes: maintenance mode
   (`wp maintenance-mode activate`) or `return 503;` in Nginx.
3. **Recover writes made on the new server** (if any):
   - Orders: export from WooCommerce (Orders > Export, or `wp wc shop_order list`)
     and re-enter or import on the old site.
   - Comments / form entries: `wp db query` or plugin export.
   - Uploads: `rsync -avz newvps:/path/wp-content/uploads/ old:/path/wp-content/uploads/`
     (reverse direction) with `--dry-run` first.
4. **Confirm the old site** with `curl -I https://example.com` and check it is served by
   the old IP (`curl --resolve example.com:443:OLD_IP -I https://example.com/`).
5. **Old site URLs**: if you ever ran `fix-urls.sh` on the *old* host (you should not),
   reverse it with `./fix-urls.sh --old NEW --new OLD`.
6. Re-check email deliverability and search-engine access (`robots.txt`, no noindex).
7. Write down what failed, fix it on the VPS, and schedule a new cutover.

## Restoring the target database only

If the problem is only the imported data and DNS has not moved:

```bash
wp db reset --yes --path=/home/example/htdocs/www.example.com
wp db import work/db/pre-import-YYYYMMDD-HHMMSS.sql --path=/home/example/htdocs/www.example.com
```

## After a successful migration

Do not decommission the old host immediately. Archive a final backup, wait a full
billing/traffic cycle, then remove it.
