// The page script. packrat-rails adds it to every HTML page with its settings in data-config.
// It builds the SDK from its parts rather than its main entry point, which sets window.DD_RUM.
import { makeRumPublicApi } from "@datadog/browser-rum-core";
import { makeRecorderApiStub } from "@datadog/browser-rum-slim/esm/boot/stubRecorderApi.mjs";
import { makeProfilerApiStub } from "@datadog/browser-rum-slim/esm/boot/stubProfilerApi.mjs";

const HIDDEN = "[data-packrat-hide], [data-sentry-block], [data-sentry-mask]";
const REDACTED = "[redacted]";
const RENAMES = { ddsource: "source", "_dd.api": "api" };

const rename = (parameters) =>
  parameters
    .split("&")
    .map((pair) => {
      const at = pair.indexOf("=");
      const name = at < 0 ? pair : pair.slice(0, at);
      const renamed = RENAMES[name] ?? (name.startsWith("dd-") ? name.slice(3) : name);
      return renamed + (at < 0 ? "" : pair.slice(at));
    })
    .join("&");

const decode = (text) => {
  try {
    return decodeURIComponent(text.replace(/\+/g, " "));
  } catch {
    return text;
  }
};

// The same names the gem redacts from server URLs: a credential-named parameter, config.redact_keys
// whole, and filter_parameters anywhere in the name.
const redactor = ({ strict, redact = {} }) => {
  const segments = redact.segments ?? [];
  const keys = (redact.keys ?? []).map((key) => key.toLowerCase());
  const filters = (redact.filters ?? []).map((filter) => filter.toLowerCase());
  const credential = new RegExp(`^(?:[a-z0-9]+_)*(?:${segments.join("|")})(?:_[a-z0-9]+)*$`, "i");
  const sensitive = (name) => {
    const lower = name.toLowerCase();
    return (segments.length > 0 && credential.test(name)) || keys.includes(lower) || filters.some((filter) => lower.includes(filter));
  };

  return (url) => {
    if (typeof url !== "string") return url;
    const start = url.indexOf("?");
    if (start < 0) return url;
    if (strict) return url.slice(0, start);

    const end = url.indexOf("#", start);
    const query = url.slice(start + 1, end < 0 ? undefined : end);
    const pairs = query.split("&").map((pair) => {
      const at = pair.indexOf("=");
      return at >= 0 && sensitive(decode(pair.slice(0, at))) ? `${pair.slice(0, at)}=${REDACTED}` : pair;
    });
    return url.slice(0, start + 1) + pairs.join("&") + (end < 0 ? "" : url.slice(end));
  };
};

const start = (script) => {
  // An app that runs the SDK itself already records the page.
  if (!script || window.DD_RUM) return;

  const config = JSON.parse(script.getAttribute("data-config"));
  const clean = redactor(config);
  const rum = makeRumPublicApi(makeRecorderApiStub(), makeProfilerApiStub(), { sdkName: "rum-slim" });

  rum.init({
    // The SDK will not start without these, and nothing reads them behind a proxy.
    applicationId: "packrat",
    clientToken: "packrat",
    service: config.service,
    env: config.env,
    version: config.version,
    proxy: ({ path, parameters }) => `${config.intake}${path}?${rename(parameters)}&packrat=${config.packrat}`,
    sessionSampleRate: 100,
    sessionReplaySampleRate: 0,
    telemetrySampleRate: 0,
    trackUserInteractions: true,
    trackResources: true,
    trackLongTasks: true,
    sessionPersistence: "local-storage",
    enablePrivacyForActionName: !!config.strict,
    beforeSend: (event, context) => {
      const target = context?.events?.[0]?.target;
      if (event.type === "action" && event.action?.target && target instanceof Element && target.closest(HIDDEN)) {
        event.action.target.name = "(hidden)";
      }
      // Sentry's SDK on the same page files the error; this one still counts it and its click.
      if (event.type === "error" && window.__SENTRY__) {
        event.context = { ...event.context, "packrat.filed_by": "sentry" };
      }
      if (typeof event.view?.url === "string") event.view.url = clean(event.view.url);
      if (typeof event.view?.referrer === "string") event.view.referrer = clean(event.view.referrer);
      if (typeof event.resource?.url === "string") event.resource.url = clean(event.resource.url);
      if (typeof event.error?.resource?.url === "string") event.error.resource.url = clean(event.error.resource.url);
      return true;
    },
  });
  if (config.user) rum.setUser({ id: config.user });
};

try {
  start(document.currentScript);
} catch {
  // A page never breaks because of this script.
}
