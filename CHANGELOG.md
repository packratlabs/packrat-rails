# Changelog

## 0.5.0

- **Browser events.** The gem adds a script to every HTML page that sends page views, clicks,
  JavaScript errors, the page's requests and Web Vitals to Packrat. They are on after you upgrade,
  with nothing to set up. Set `config.browser = false` to turn them off, pass a lambda to choose
  pages by request, or use `packrat_browser` and `skip_packrat_browser` in a controller. See
  [Browser events](README.md#browser-events).
- The boot line says `sending traces, logs and browser events` while browser events are on.
- If your app sets a content security policy, add the ingest host to `connect-src`.
