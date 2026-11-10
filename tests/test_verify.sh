#!/usr/bin/env bash

test_verify_dry_run_sends_no_requests() {
  run_script verify.sh --dry-run
  assert_rc 0
  assert_contains "curl"
  assert_contains "--resolve www.example.com:443:203.0.113.10"
  assert_log_lacks "curl "
}

test_verify_passes_on_healthy_site() {
  run_script verify.sh
  assert_rc 0
  assert_contains "/ -> 200"
  assert_contains "wp-login.php serves the login form"
  assert_contains "wp-admin redirects to wp-login.php"
  assert_contains "no mixed content"
  assert_contains "0 failed"
}

test_verify_uses_resolve_for_both_ports() {
  run_script verify.sh
  assert_log_contains "--resolve www.example.com:443:203.0.113.10"
  assert_log_contains "--resolve www.example.com:80:203.0.113.10"
}

test_verify_insecure_by_default_and_secure_flag() {
  run_script verify.sh
  assert_log_contains " -k "
  : >"$SHIM_LOG"
  run_script verify.sh --secure
  assert_log_lacks " -k "
}

test_verify_fails_on_unexpected_status() {
  printf '/robots.txt 500\n' >"$T/map"
  SHIM_CURL_MAP="$T/map" run_script verify.sh
  assert_rc 1
  assert_contains "/robots.txt -> 500"
}

test_verify_detects_mixed_content() {
  SHIM_HOME_BODY='<html><script src="http://cdn.example.com/a.js"></script></html>' run_script verify.sh
  assert_rc 1
  assert_contains "mixed content"
  assert_contains "cdn.example.com/a.js"
}

test_verify_ignores_plain_http_anchor_links() {
  SHIM_HOME_BODY='<html><a href="http://other.example.net/">x</a></html>' run_script verify.sh
  assert_rc 0
  assert_contains "no mixed content"
}

test_verify_detects_css_url_mixed_content() {
  SHIM_HOME_BODY='<style>.a{background:url(http://img.example.com/x.png)}</style>' run_script verify.sh
  assert_rc 1
  assert_contains "mixed content"
}

test_verify_detects_old_host_references() {
  SHIM_HOME_BODY='<link href="https://old.example.org/x.css">' run_script verify.sh --old-host old.example.org
  assert_rc 1
  assert_contains "old host 'old.example.org' still referenced"
}

test_verify_connection_error_is_a_failure() {
  SHIM_CURL_DOWN=1 run_script verify.sh
  assert_rc 1
  assert_contains "connection error"
}

test_verify_wp_admin_must_redirect_to_login() {
  printf '/wp-admin/ 404\n' >"$T/map"
  SHIM_CURL_MAP="$T/map" run_script verify.sh
  assert_rc 1
  assert_contains "wp-admin returned 404"
}

test_verify_extra_checks_accept_multiple_codes() {
  printf '/old/ 301\n' >"$T/map"
  SHIM_CURL_MAP="$T/map" run_script verify.sh --check /old/=301,308
  assert_rc 0
  assert_contains "/old/ -> 301"
}

test_verify_extra_url_from_env() {
  echo 'VERIFY_EXTRA_URLS="/about/=200"' >>"$T/migrate.env"
  run_script verify.sh
  assert_contains "/about/ -> 200"
}

test_verify_check_option_validates_format() {
  run_script verify.sh --check nonsense
  assert_rc 2
  assert_contains "PATH=CODES"
}

test_verify_rejects_bad_ip() {
  run_script verify.sh --ip "1.2.3.4; rm -rf /"
  assert_rc 2
  assert_contains "Invalid IP"
}

test_verify_requires_scheme() {
  run_script verify.sh --url www.example.com
  assert_rc 2
  assert_contains "must start with"
}

test_verify_cron_warns_when_disabled_without_system_cron() {
  SHIM_DISABLE_CRON=1 run_script verify.sh
  assert_contains "wp-cron.php reachable"
  assert_contains "12 cron event(s)"
}

test_verify_ip_and_url_flags_override_env() {
  run_script verify.sh --ip 198.51.100.7 --url https://shop.example.com
  assert_log_contains "--resolve shop.example.com:443:198.51.100.7"
}
