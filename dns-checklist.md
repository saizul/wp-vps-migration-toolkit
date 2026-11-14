# DNS cutover checklist

Do the DNS change last, only after `./verify.sh` passes against the new IP.
Replace `example.com` and the IPs with your own values.

## 1. Two to three days before

- [ ] Note where DNS is actually hosted: `dig +short NS example.com`
      (registrar, cPanel, Cloudflare, or other).
- [ ] Export or screenshot **every** existing record. A zone file export is best.
- [ ] Lower the TTL of the `A`/`AAAA`/`CNAME` records for the apex and `www` to
      **300 seconds**. Wait at least the old TTL (often 14400 s = 4 h, sometimes
      86400 s) before cutover, otherwise resolvers keep serving the old IP.
- [ ] Do **not** lower or touch MX/TXT TTLs unless you are also moving mail.
- [ ] Check what else lives on the old server: subdomains, cron jobs, mail
      boxes, FTP accounts, add-on domains, cPanel redirects.

## 2. Preserve email (most common migration mistake)

If mail stays with the old host or a third party (Google Workspace, Zoho, etc.),
the **only** DNS change is the web `A` record(s).

- [ ] `MX` records unchanged (`dig +short MX example.com`).
- [ ] The `mail` / `webmail` / `smtp` hostnames: if they are `A` records pointing to
      the old server, keep them there. If they were `CNAME`d to the apex, repoint
      them to the old IP explicitly, or mail clients will break.
- [ ] `SPF` (`TXT` starting `v=spf1`) still authorises the real sender. If the old
      SPF used `a` or `mx` mechanisms or `+ip4:<old server IP>`, adding the VPS as a
      sender is only needed if the VPS also sends mail (WordPress `wp_mail`).
      Prefer an SMTP plugin with a transactional provider. Keep a single SPF record.
- [ ] `DKIM` selectors (`selector._domainkey`) are copied verbatim. cPanel's default
      selector is `default._domainkey`; losing it silently breaks signing.
- [ ] `DMARC` (`_dmarc`) copied. Consider `p=none` with `rua=` reporting for the
      week of the migration, then tighten.
- [ ] Send a test message to an external mailbox and inspect the headers for
      `spf=pass dkim=pass dmarc=pass`.

## 3. Cutover day

- [ ] Final sync: `./pull-files.sh --only wp-content/uploads` and, if content changes
      continuously (WooCommerce, forms, comments), put the old site in maintenance mode,
      run `./pull-db.sh`, `./fix-urls.sh`, `./compare.sh`, then `./verify.sh`.
- [ ] Issue the TLS certificate on the VPS (CloudPanel: Let's Encrypt in the site
      settings; plain Nginx: certbot). HTTP-01 needs DNS to point at the VPS, so
      either use DNS-01, or import the old certificate temporarily, or accept a short
      window using `VERIFY_INSECURE=1` for testing only.
- [ ] Change the `A` record (and `AAAA` if the VPS has IPv6; remove stale `AAAA`
      that points to the old host).
- [ ] Watch propagation: `dig +short example.com @1.1.1.1`, `@8.8.8.8`, and your
      authoritative servers.
- [ ] Keep the old server **running and unchanged** (read-only if possible) for at
      least a full TTL cycle plus 48 hours. Do not cancel hosting yet.

## 4. Cloudflare notes

- **Proxied (orange cloud)**: DNS changes take effect almost immediately because
  clients resolve to Cloudflare. Change the origin IP in the `A` record and
  purge Cloudflare cache. Test the origin directly with `./verify.sh` first.
- SSL/TLS mode: use **Full (strict)** once the origin has a valid certificate. Never
  leave it on **Flexible** with a WordPress site that forces HTTPS (redirect loop).
- Origin certificate: you can install a Cloudflare Origin CA certificate on the VPS
  while the record is proxied, which avoids the Let's Encrypt HTTP-01 chicken-and-egg.
- If you are moving DNS **to** Cloudflare at the same time, do it as a separate step:
  add the site, let Cloudflare import records, **compare against your export**
  (MX, SPF, DKIM, DMARC, and the `mail` host must be DNS-only / grey cloud), then
  change nameservers. Do not combine this with the origin change.
- Mail-related records (`mail`, `smtp`, `imap`, `webmail`) must be **DNS only**.
- Real visitor IPs: configure `real_ip_header CF-Connecting-IP` (Nginx `ngx_http_realip_module`
  with Cloudflare ranges) so rate limits and security plugins see visitors, not Cloudflare.
- Purge cache and disable Rocket Loader / Auto Minify temporarily if anything
  looks broken after cutover.

## 5. After cutover

- [ ] `./verify.sh --secure` using the public DNS (no `--resolve` difference: should be identical).
- [ ] Search Console: check Coverage/Pages and Crawl Stats for 5xx or soft 404 spikes.
- [ ] Submit the sitemap again; confirm `robots.txt` has no `Disallow: /` left from a staging copy.
- [ ] Confirm "Discourage search engines" (Settings > Reading) is **off**.
- [ ] Check forms, checkout, scheduled posts, backups, and uptime monitor targets.
- [ ] Raise TTL back to 3600-14400 once stable.
- [ ] After a week with no issues: cancel/downgrade the old hosting, but keep a final
      backup for 30 days.
