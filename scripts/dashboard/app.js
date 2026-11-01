// The dashboard shell (design Decisions 12 and 16): the hash router, the view registry, the
// panel state contract, the fetch store, the freshness poll and the chrome around the views
// (header, tab bar, search, freshness chip and sheet, banners). Views register themselves with
// registerView and never edit this file. Everything from the API enters the page as text.
//
// window.noggingApp:
//   registerView(name, module)  name is start, beads, graph or detail.
//     start/beads/graph: module.mount(container, ctx), optional update(ctx) and unmount().
//     detail: module.open(id, ctx) and module.close(); the detail is an overlay on any route.
//   openDetail(id), closeDetail()  set or drop `bead=<ID>` in the hash.
//   panel({title, meta})  -> {element, body, set(state, info), setMeta(text), load(name, path, build)}
//     states: loading, ready (info = a node or a list of nodes), gap (info = {since}),
//     empty (info = text), error (info = {message, retry}).
//   store  get(name, path, {force}) -> Promise<{ok, status, envelope}>, peek(name), subscribe(fn).
//   link(route, params), navigate(route, params).
(function () {
  "use strict";
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var T = window.noggingTheme;
  var el = D.el;

  var POLL_MS = 10000;
  var STALE_MS = 5 * 60 * 1000;
  var TITLE = "Nogging dashboard";
  var TABS = [
    { route: "start", path: "/", label: "Overview" },
    { route: "beads", path: "/beads", label: "Beads" },
    { route: "graph", path: "/graph", label: "Graph" },
  ];
  var STATES = ["loading", "ready", "gap", "empty", "error"];
  var VIEW_NAMES = ["start", "beads", "graph", "detail"];
  var BEAD_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

  var views = {};
  var parts = {};
  var current = { route: null, key: null, unmount: null, bead: null };
  var fullpage = null;
  var started = false;

  /* ---------------------------------------------------------------- the router */

  function parseHash() {
    var raw = window.location.hash.replace(/^#/, "");
    var cut = raw.indexOf("?");
    var path = cut < 0 ? raw : raw.slice(0, cut);
    var params = new URLSearchParams(cut < 0 ? "" : raw.slice(cut + 1));
    var route = path === "/beads" ? "beads" : path === "/graph" ? "graph" : "start";
    var bead = params.get("bead");
    return { route: route, params: params, bead: bead && BEAD_ID.test(bead) ? bead : null };
  }

  function pathOf(route) {
    return TABS.filter(function (tab) { return tab.route === route; })[0].path;
  }

  function link(route, params) {
    var query = new URLSearchParams();
    Object.keys(params || {}).forEach(function (name) {
      if (params[name] !== null && params[name] !== undefined && params[name] !== "") {
        query.set(name, String(params[name]));
      }
    });
    var text = query.toString();
    return "#" + pathOf(route) + (text ? "?" + text : "");
  }

  function navigate(route, params) {
    window.location.hash = link(route, params);
  }

  function withBead(id) {
    var here = parseHash();
    var next = {};
    here.params.forEach(function (value, name) { next[name] = value; });
    delete next.bead;
    if (id) {
      next.bead = id;
    }
    navigate(here.route, next);
  }

  function openDetail(id) {
    if (!BEAD_ID.test(String(id))) {
      return;
    }
    withBead(String(id));
  }

  function closeDetail() {
    withBead(null);
  }

  // The underlying view is keyed without `bead`, so opening a detail does not rebuild the page.
  function viewKey(here) {
    var rest = [];
    here.params.forEach(function (value, name) {
      if (name !== "bead") {
        rest.push(name + "=" + value);
      }
    });
    return here.route + "?" + rest.sort().join("&");
  }

  function context(here) {
    return {
      route: here.route, params: here.params, store: store, panel: panel, navigate: navigate, link: link,
      openDetail: openDetail, closeDetail: closeDetail, format: F, dom: D,
    };
  }

  function registerView(name, module) {
    if (VIEW_NAMES.indexOf(name) < 0) {
      throw new Error("registerView: unknown view " + name);
    }
    var entry = name === "detail" ? ["open", "close"] : ["mount"];
    entry.forEach(function (method) {
      if (!module || typeof module[method] !== "function") {
        throw new Error("registerView: " + name + " needs a " + method + " function");
      }
    });
    views[name] = module;
    if (started) {
      if (name === "detail") {
        current.bead = null;
      } else if (name === current.route) {
        current.key = null;
      }
      render();
    }
  }

  function placeholder(route, container) {
    var tab = TABS.filter(function (item) { return item.route === route; })[0];
    var empty = panel({ title: tab.label });
    empty.set("empty", "This view is not available yet.");
    container.appendChild(empty.element);
  }

  function setTitle(route) {
    var tab = TABS.filter(function (item) { return item.route === route; })[0];
    document.title = tab.label + " · " + TITLE;
  }

  function markTabs(route) {
    Array.prototype.forEach.call(parts.tabs.querySelectorAll("a"), function (anchor) {
      if (anchor.getAttribute("data-route") === route) {
        anchor.setAttribute("aria-current", "page");
      } else {
        anchor.removeAttribute("aria-current");
      }
    });
  }

  function render() {
    if (!started || fullpage) {
      return;
    }
    var here = parseHash();
    var key = viewKey(here);
    var first = current.route === null;
    markTabs(here.route);
    setTitle(here.route);
    if (parts.search && here.route === "beads") {
      parts.search.input.value = here.params.get("q") || "";
    }
    if (key !== current.key) {
      if (current.unmount) {
        current.unmount();
      }
      D.clear(parts.main);
      var section = el("section", { "class": "view view-" + here.route, "aria-label": pathLabel(here.route) });
      parts.main.appendChild(section);
      var module = views[here.route];
      current.unmount = null;
      if (module) {
        var result = module.mount(section, context(here));
        current.unmount = typeof module.unmount === "function" ? module.unmount.bind(module) : null;
        if (typeof result === "function") {
          current.unmount = result;
        }
      } else {
        placeholder(here.route, section);
      }
      current.route = here.route;
      current.key = key;
      if (!first) {
        parts.main.focus({ preventScroll: true });
        window.scrollTo(0, 0);
      }
    }
    if (here.bead !== current.bead) {
      var detail = views.detail;
      if (detail) {
        if (here.bead) {
          detail.open(here.bead, context(here));
        } else if (current.bead) {
          detail.close();
        }
      }
      current.bead = here.bead;
    }
  }

  function pathLabel(route) {
    return TABS.filter(function (tab) { return tab.route === route; })[0].label;
  }

  /* ---------------------------------------------------------------- panels */

  function panel(options) {
    var title = (options && options.title) || "";
    var meta = el("span", { "class": "panel-meta" }, (options && options.meta) || "");
    var heading = el("h2", null, title);
    var body = el("div", { "class": "panel-body" });
    var root = el("section", { "class": "panel", "aria-label": title || null },
      el("div", { "class": "panel-head" }, heading, meta), body);
    var controller = { element: root, body: body };

    controller.setMeta = function (text) {
      D.replace(meta, text);
    };

    controller.set = function (state, info) {
      if (STATES.indexOf(state) < 0) {
        throw new Error("panel: unknown state " + state);
      }
      root.setAttribute("data-state", state);
      root.setAttribute("aria-busy", state === "loading" ? "true" : "false");
      D.clear(body);
      if (state === "ready") {
        D.replace(body, info);
      } else if (state === "loading") {
        body.appendChild(el("div", { "class": "panel-state panel-loading", role: "status" }, "Loading…"));
      } else if (state === "gap") {
        var since = info && info.since ? F.utcDay(info.since) : null;
        body.appendChild(el("div", { "class": "panel-state panel-gap" },
          since ? "No data before " + since : "No data for this period"));
      } else if (state === "empty") {
        body.appendChild(el("div", { "class": "panel-state panel-empty" }, info || "Nothing to show."));
      } else {
        var retry = info && info.retry;
        body.appendChild(el("div", { "class": "panel-state panel-error", role: "alert" },
          el("span", null, (info && info.message) || "This panel could not load."),
          retry ? el("button", { type: "button", "class": "btn btn-quiet", on: { click: retry } }, "Retry") : null));
      }
      return controller;
    };

    // Loads one API route into the panel and maps the outcome to a state. `build` turns the
    // envelope into nodes. The retry refetches; it starts nothing on the server.
    controller.load = function (name, path, build, force) {
      controller.set("loading");
      return store.get(name, path, { force: force }).then(function (result) {
        if (result.ok) {
          controller.set("ready", build(result.envelope));
        } else if (result.status === 501) {
          controller.set("empty", "Not available yet.");
        } else if (result.status === 401 || result.status === 403) {
          controller.set("error", { message: "No session." });
        } else {
          controller.set("error", {
            message: result.unreachable ? "Server not reachable." : "This panel could not load.",
            retry: function () { controller.load(name, path, build, true); },
          });
        }
        return result;
      });
    };
    return controller;
  }

  /* ---------------------------------------------------------------- the fetch store */

  var connection = { down: false, lastOk: null };
  var cache = {};
  var inflight = {};
  var listeners = [];

  function fetchJson(path) {
    var ready = window.noggingAuth || Promise.resolve(true);
    return ready.then(function (signedIn) {
      if (!signedIn) {
        return { ok: false, status: 401, envelope: null };
      }
      return window.fetch(path, {
        credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" },
      }).then(function (response) {
        connection.down = false;
        connection.lastOk = Date.now();
        if (response.status === 401 || response.status === 403) {
          showFullPage("no-session");
          return { ok: false, status: response.status, envelope: null };
        }
        if (!response.ok) {
          return { ok: false, status: response.status, envelope: null };
        }
        return response.json().then(function (envelope) {
          var good = envelope && typeof envelope.schema === "string" && envelope.schema.indexOf("nogg.dashboard.") === 0;
          return { ok: !!good, status: response.status, envelope: good ? envelope : null };
        }, function () {
          return { ok: false, status: response.status, envelope: null };
        });
      }, function () {
        connection.down = true;
        return { ok: false, status: 0, envelope: null, unreachable: true };
      });
    });
  }

  var store = {
    get: function (name, path, options) {
      var force = options && options.force;
      if (!force && cache[name] && cache[name].ok) {
        return Promise.resolve(cache[name]);
      }
      if (inflight[name]) {
        return inflight[name];
      }
      inflight[name] = fetchJson(path).then(function (result) {
        delete inflight[name];
        if (result.ok || !cache[name]) {
          cache[name] = result;
        }
        return result;
      });
      return inflight[name];
    },
    peek: function (name) { return cache[name] || null; },
    subscribe: function (listener) { listeners.push(listener); },
  };

  /* ---------------------------------------------------------------- freshness */

  var freshness = { level: "unknown", text: "Freshness unknown", sources: {}, latest: null, generations: null };
  var timer = null;

  function newest(sources) {
    var best = null;
    Object.keys(sources).forEach(function (name) {
      var at = Date.parse(sources[name] && sources[name].as_of);
      if (!isNaN(at) && (best === null || at > best)) {
        best = at;
      }
    });
    return best;
  }

  function describe(result) {
    if (result.unreachable || connection.down) {
      return { level: "error", text: "Server not reachable", sources: freshness.sources, latest: freshness.latest };
    }
    if (!result.ok) {
      return { level: "unknown", text: "Freshness unknown", sources: {}, latest: null };
    }
    var sources = result.envelope.sources || {};
    var latest = newest(sources);
    var states = Object.keys(sources).map(function (name) { return sources[name].state; });
    if (latest === null) {
      var loading = states.length === 0 || states.indexOf("loading") >= 0;
      return { level: loading ? "unknown" : "stale", text: loading ? "Loading…" : "No data yet", sources: sources, latest: null };
    }
    var iso = new Date(latest).toISOString();
    if (Date.now() - latest > STALE_MS || states.indexOf("stale") >= 0 || states.indexOf("unavailable") >= 0) {
      return { level: "stale", text: "Stale · " + F.clock(iso), sources: sources, latest: iso };
    }
    return { level: "fresh", text: "Updated " + F.clock(iso), sources: sources, latest: iso };
  }

  function generationsOf(sources) {
    var out = {};
    Object.keys(sources).forEach(function (name) { out[name] = sources[name].generation; });
    return out;
  }

  function pollFreshness() {
    return store.get("freshness", "/api/v1/freshness", { force: true }).then(function (result) {
      var before = freshness;
      var next = describe(result);
      var changed = [];
      if (result.ok) {
        var generations = generationsOf(next.sources);
        Object.keys(generations).forEach(function (name) {
          if (!before.generations || before.generations[name] !== generations[name]) {
            changed.push(name);
          }
        });
        next.generations = generations;
      } else {
        next.generations = before.generations;
      }
      freshness = next;
      showFreshness(before);
      var beads = next.sources.beads;
      if (result.ok && beads && beads.state === "unavailable" && !beads.as_of) {
        showFullPage("beads-unreachable");
      } else if (fullpage === "beads-unreachable" && result.ok) {
        hideFullPage();
      }
      if (changed.length) {
        listeners.forEach(function (listener) { listener({ changed: changed, sources: next.sources }); });
      }
      return result;
    });
  }

  function schedule() {
    window.clearTimeout(timer);
    timer = null;
    var saving = window.matchMedia && window.matchMedia("(prefers-reduced-data: reduce)").matches;
    if (document.visibilityState === "visible" && !saving) {
      timer = window.setTimeout(function () { pollFreshness().then(schedule); }, POLL_MS);
    }
  }

  function showFreshness(before) {
    var chip = parts.fresh;
    chip.className = "fresh fresh-" + freshness.level;
    D.replace(parts.freshText, freshness.text);
    chip.setAttribute("aria-label", "Data freshness: " + freshness.text + ". Show details");
    if (before.level !== freshness.level) {
      D.replace(parts.live, "Data freshness: " + freshness.text);
    }
    D.clear(parts.banners);
    if (freshness.level === "error") {
      parts.banners.appendChild(el("div", { "class": "banner banner-error" },
        connection.lastOk ? "Server not reachable. Showing data from " + F.clock(new Date(connection.lastOk).toISOString()) + "."
          : "Server not reachable."));
    } else if (freshness.level === "stale" && freshness.latest && Date.now() - Date.parse(freshness.latest) > STALE_MS) {
      parts.banners.appendChild(el("div", { "class": "banner" }, "Data may be stale, last update " + F.clock(freshness.latest)));
    }
    if (unencrypted()) {
      parts.banners.appendChild(el("div", { "class": "banner" },
        "Unencrypted connection. Anyone on this network can read the traffic; prefer a Tailscale address."));
    }
    if (parts.sheet) {
      renderSheet();
    }
  }

  function unencrypted() {
    var host = window.location.hostname;
    var loopback = host === "localhost" || host === "[::1]" || host === "::1" || /^127\./.test(host);
    return window.location.protocol === "http:" && !loopback;
  }

  /* ---------------------------------------------------------------- full-page states */

  function showFullPage(kind) {
    if (fullpage === kind) {
      return;
    }
    fullpage = kind;
    if (current.unmount) {
      current.unmount();
      current.unmount = null;
    }
    current.key = null;
    current.bead = null;
    var page;
    if (kind === "no-session") {
      page = el("section", { "class": "fullpage", "aria-label": "No session" },
        el("img", { src: "/assets/images/nogging-mark.svg", alt: "", width: 48, height: 48 }),
        el("h1", null, "No session"),
        el("p", null, "Open the access link from the host again. Run ", el("code", null, "nogg dashboard"), " there to get it."));
    } else {
      page = el("section", { "class": "fullpage", "aria-label": "Beads not reachable" },
        el("h1", null, "Beads are not reachable"),
        el("p", null, "The dashboard could not read Beads on the host. Retry checks again; it starts nothing on the server."),
        el("button", { type: "button", "class": "btn", on: { click: function () { pollFreshness(); } } }, "Retry"));
    }
    D.replace(parts.main, page);
  }

  function hideFullPage() {
    fullpage = null;
    render();
  }

  /* ---------------------------------------------------------------- the chrome */

  function icon(name) {
    var shapes = {
      search: [["circle", { cx: 10, cy: 10, r: 6 }], ["line", { x1: 15, y1: 15, x2: 21, y2: 21 }]],
    };
    var mark = D.svg("svg", { viewBox: "0 0 24 24", width: 22, height: 22, "aria-hidden": "true", focusable: "false" });
    shapes[name].forEach(function (part) {
      var attrs = { fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round" };
      Object.keys(part[1]).forEach(function (key) { attrs[key] = part[1][key]; });
      mark.appendChild(D.svg(part[0], attrs));
    });
    return mark;
  }

  function buildSearch() {
    var input = el("input", {
      "class": "field", type: "search", name: "q", id: "search-input", placeholder: "Search Beads",
      autocomplete: "off", enterkeyhint: "search",
    });
    var form = el("form", { "class": "search", role: "search" },
      el("label", { "class": "visually-hidden", "for": "search-input" }, "Search Beads"), input,
      el("button", { type: "submit", "class": "btn" }, "Search"),
      el("button", { type: "button", "class": "btn btn-quiet search-close" }, "Cancel"));
    var toggle = el("button", { type: "button", "class": "icon-btn search-toggle", "aria-label": "Search Beads", "aria-expanded": "false" },
      icon("search"));
    function close() {
      form.classList.remove("open");
      toggle.setAttribute("aria-expanded", "false");
      toggle.focus();
    }
    toggle.addEventListener("click", function () {
      form.classList.add("open");
      toggle.setAttribute("aria-expanded", "true");
      input.focus();
    });
    form.querySelector(".search-close").addEventListener("click", close);
    form.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && form.classList.contains("open")) {
        close();
      }
    });
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var text = input.value.trim();
      navigate("beads", text ? { q: text } : {});
      if (form.classList.contains("open")) {
        close();
      }
    });
    return { form: form, toggle: toggle, input: input };
  }

  function buildThemeControl() {
    var select = el("select", { "class": "select", id: "theme-select" },
      T.choices.map(function (choice) {
        return el("option", { value: choice }, choice.charAt(0).toUpperCase() + choice.slice(1));
      }));
    select.value = T.get();
    select.addEventListener("change", function () { select.value = T.set(select.value); });
    return el("label", { "class": "theme" }, el("span", { "class": "visually-hidden" }, "Theme"), select);
  }

  function openSheet() {
    if (parts.sheet) {
      return;
    }
    var close = el("button", { type: "button", "class": "btn btn-quiet" }, "Close");
    var backdrop = el("div", { "class": "sheet-backdrop" });
    var sheet = el("div", { "class": "sheet", role: "dialog", "aria-modal": "true", "aria-labelledby": "sheet-title" },
      el("div", { "class": "sheet-head" }, el("h2", { id: "sheet-title" }, "Data freshness"), close),
      el("div", { "class": "sheet-body" }));
    parts.sheet = { sheet: sheet, backdrop: backdrop, close: close };
    function shut() {
      document.removeEventListener("keydown", onKey);
      backdrop.remove();
      sheet.remove();
      parts.sheet = null;
      parts.fresh.setAttribute("aria-expanded", "false");
      parts.fresh.focus();
    }
    function onKey(event) {
      if (event.key === "Escape") {
        shut();
      }
    }
    parts.sheet.shut = shut;
    close.addEventListener("click", shut);
    backdrop.addEventListener("click", shut);
    document.addEventListener("keydown", onKey);
    parts.fresh.setAttribute("aria-expanded", "true");
    document.body.appendChild(backdrop);
    document.body.appendChild(sheet);
    renderSheet();
    close.focus();
  }

  function renderSheet() {
    var body = parts.sheet.sheet.querySelector(".sheet-body");
    var names = Object.keys(freshness.sources);
    D.replace(body,
      el("p", null, freshness.text + "."),
      names.length ? el("ul", { "class": "sources" }, names.map(function (name) {
        var source = freshness.sources[name];
        return el("li", null, el("span", null, name),
          el("span", { "class": "panel-meta" }, source.state + (source.as_of ? " · " + F.clock(source.as_of) : "")));
      })) : null,
      el("p", { "class": "panel-meta" }, "Read-only view. Session records are local to the host."),
      el("button", { type: "button", "class": "btn", on: { click: function () { pollFreshness(); } } }, "Refresh now"));
  }

  function buildHeader() {
    var skip = el("a", { "class": "skip", href: "#app" }, "Skip to content");
    skip.addEventListener("click", function (event) {
      event.preventDefault();
      parts.main.focus();
    });
    var brand = el("a", { "class": "brand", href: link("start") },
      el("img", { "class": "mark-light", src: "/assets/images/nogging-mark.svg", alt: "", width: 28, height: 28 }),
      el("img", { "class": "mark-dark", src: "/assets/images/nogging-mark-dark.svg", alt: "", width: 28, height: 28 }),
      el("span", { "class": "brand-name" }, "Nogging"));
    parts.tabs = el("nav", { "class": "tabs", "aria-label": "Views" }, TABS.map(function (tab) {
      return el("a", { "class": "tab", href: link(tab.route), "data-route": tab.route }, tab.label);
    }));
    parts.search = buildSearch();
    parts.freshText = el("span", { "class": "fresh-text" }, freshness.text);
    parts.fresh = el("button", { type: "button", "class": "fresh fresh-unknown", "aria-haspopup": "dialog", "aria-expanded": "false" },
      el("span", { "class": "dot", "aria-hidden": "true" }), parts.freshText);
    parts.fresh.addEventListener("click", openSheet);
    parts.live = el("div", { "class": "visually-hidden", role: "status", "aria-live": "polite" });
    parts.banners = el("div", { "class": "banners" });
    var header = el("header", { "class": "site-header" }, brand, parts.tabs, parts.search.form, parts.search.toggle,
      parts.fresh, el("span", { "class": "readonly" }, "Read-only"), buildThemeControl());
    return [skip, header, parts.banners, parts.live];
  }

  function start() {
    parts.main = document.getElementById("app");
    if (!parts.main) {
      return;
    }
    var ready = window.noggingAuth || Promise.resolve(true);
    ready.then(function (signedIn) {
      if (!signedIn) {
        return;
      }
      parts.main.setAttribute("tabindex", "-1");
      parts.main.id = "app";
      buildHeader().forEach(function (node) { document.body.insertBefore(node, parts.main); });
      started = true;
      window.addEventListener("hashchange", render);
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "visible") {
          pollFreshness().then(schedule);
        } else {
          schedule();
        }
      });
      showFreshness(freshness);
      render();
      pollFreshness().then(schedule);
    });
  }

  window.noggingApp = {
    registerView: registerView, openDetail: openDetail, closeDetail: closeDetail, navigate: navigate, link: link,
    panel: panel, store: store, STATES: STATES.slice(),
  };

  if (document.readyState === "complete") {
    start();
  } else {
    document.addEventListener("DOMContentLoaded", start);
  }
}());
