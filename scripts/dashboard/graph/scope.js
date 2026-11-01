// The graph's scopes (design Decision 16, Graph): the ready frontier, which is the default, the
// neighbourhood of one Bead with a depth, and the list of changes that leads to one change's
// flow. It plugs into render.js through hooks.chooser, which render.js calls for every route it
// does not draw itself, and through hooks.drawn for the scope picker and for collapsed groups.
//
// Route: #/graph?scope=ready | scope=bead&id=<ID>&depth=<1..5> | scope=change[&id=<change>],
// each with closed=collapse. "Open in graph" in the detail is ctx.link("graph", {scope: "bead", id: ID, depth: 2}).
(function () {
  "use strict";
  var App = window.noggingApp;
  var G = window.noggingGraph;
  if (!App || !G) {
    return;
  }
  var D = window.noggingDom;
  var el = D.el;

  var PHONE = "(max-width: 599px)";
  var BEAD = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
  var MAX_DEPTH = 5;
  var DEPTHS = [1, 2, 3];
  var refreshActive = null;

  function scopeOf(params) {
    var kind = params.get("scope");
    var id = params.get("id");
    if (kind === "bead" && BEAD.test(id || "")) {
      var depth = parseInt(params.get("depth"), 10);
      return { kind: "bead", id: id, depth: depth >= 1 && depth <= MAX_DEPTH ? depth : 1 };
    }
    return { kind: kind === "change" ? "change" : "ready" };
  }

  // The current route with some parameters replaced; null drops one. `bead=` is the detail's.
  function linkWith(ctx, changes) {
    var next = {};
    ctx.params.forEach(function (value, name) { if (name !== "bead") { next[name] = value; } });
    Object.keys(changes).forEach(function (name) { next[name] = changes[name]; });
    return ctx.link("graph", next);
  }

  function choice(label, href, current) {
    return el("a", { "class": "btn btn-quiet graph-scope-link", href: href, "aria-current": current ? "page" : null }, label);
  }

  function beadForm(ctx, scope) {
    var input = el("input", {
      "class": "field", type: "text", id: "graph-bead", name: "bead", maxlength: 64, autocomplete: "off",
      autocapitalize: "off", spellcheck: "false", placeholder: "SPEC-…", value: scope.id || null,
    });
    var note = el("span", { "class": "panel-meta", role: "status" });
    var form = el("form", { "class": "graph-bead-form", novalidate: true },
      el("label", { "for": "graph-bead" }, "Bead"), input,
      el("button", { type: "submit", "class": "btn btn-quiet" }, "Show neighbourhood"), note);
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var id = input.value.trim();
      if (!BEAD.test(id)) {
        D.replace(note, "Enter a Bead ID such as SPEC-abcd.");
        return;
      }
      ctx.navigate("graph", { scope: "bead", id: id, depth: scope.depth || 1 });
    });
    return form;
  }

  // Which scope is open, as links, and the neighbourhood's depth. Navigation only: nothing here writes.
  function picker(ctx, scope) {
    var depths = scope.kind !== "bead" ? null : el("div", { "class": "graph-depths", role: "group", "aria-label": "Depth" },
      el("span", { "class": "panel-meta" }, "Depth"),
      DEPTHS.concat(scope.depth > DEPTHS[DEPTHS.length - 1] ? [scope.depth] : []).map(function (depth) {
        return choice(String(depth), ctx.link("graph", { scope: "bead", id: scope.id, depth: depth, closed: ctx.params.get("closed") }), depth === scope.depth);
      }));
    return el("nav", { "class": "graph-scope", "aria-label": "Graph scope" },
      el("div", { "class": "graph-scope-links" },
        choice("Ready frontier", ctx.link("graph", { scope: "ready" }), scope.kind === "ready"),
        choice("Changes", ctx.link("graph", { scope: "change" }), scope.kind === "change"),
        scope.kind === "bead" ? choice("Neighbourhood of " + scope.id, linkWith(ctx, {}), true) : null),
      beadForm(ctx, scope), depths);
  }

  function title(scope) {
    return scope.kind === "bead" ? "Neighbourhood of " + scope.id : "Ready frontier";
  }

  function query(scope, closed) {
    var scoped = scope.kind === "bead" ? "bead:" + scope.id : "ready";
    return "/api/v1/graph?scope=" + encodeURIComponent(scoped) + (scope.kind === "bead" ? "&depth=" + scope.depth : "") +
      (closed ? "&closed=collapse" : "");
  }

  function about(scope, data) {
    var beads = data.nodes.filter(function (node) { return node.kind === "bead"; }).length;
    return beads + " Bead" + (beads === 1 ? "" : "s") + " · " + data.layers + " layer" + (data.layers === 1 ? "" : "s");
  }

  function emptyText(scope, envelope) {
    var state = envelope.sources && envelope.sources.beads && envelope.sources.beads.state;
    if (state === "loading") {
      return "Loading…";
    }
    return scope.kind === "bead" ? scope.id + " is not in the data." : "Nothing is ready right now.";
  }

  function closedLink(ctx, closed) {
    var collapse = closed !== "collapse";
    return el("a", { "class": "graph-toggle", href: linkWith(ctx, { closed: collapse ? "collapse" : null }) },
      collapse ? "Collapse closed Beads" : "Show closed Beads");
  }

  function mountScope(container, ctx, scope) {
    var closed = ctx.params.get("closed") === "collapse" ? "collapse" : "show";
    var path = query(scope, closed === "collapse");
    var name = "graph:" + path;
    var panel = ctx.panel({ title: title(scope) });
    var media = window.matchMedia(PHONE);
    var last = null;

    function build(envelope) {
      last = envelope;
      var data = envelope.data;
      panel.setMeta(about(scope, data));
      if (!data.nodes.length) {
        return el("div", { "class": "panel-state panel-empty" }, emptyText(scope, envelope));
      }
      var found = [];
      if (scope.kind === "bead") {
        found.push(el("p", { "class": "panel-meta" }, "Blockers up to " + scope.depth + " step" + (scope.depth === 1 ? "" : "s") +
          " upstream and the Beads they block up to " + scope.depth + " downstream of " + scope.id + "."));
      }
      var drawing = G.draw(data, ctx);
      return found.concat([drawing.element]);
    }

    function redraw() {
      if (last) {
        panel.set("ready", build(last));
      }
    }

    container.appendChild(closedLink(ctx, closed));
    container.appendChild(panel.element);
    panel.load(name, path, build, true);
    refreshActive = function () {
      ctx.store.get(name, path, { force: true }).then(function (result) {
        if (result.ok && refreshActive) {
          panel.set("ready", build(result.envelope));
        }
      });
    };
    media.addEventListener("change", redraw);
    return function () {
      refreshActive = null;
      media.removeEventListener("change", redraw);
    };
  }

  function mountChanges(container, ctx) {
    var panel = ctx.panel({ title: "Changes" });
    container.appendChild(panel.element);
    panel.load("graph-changes", "/api/v1/changes", function (envelope) {
      var rows = (envelope.data.changes || []).filter(function (row) { return row.change; });
      if (!rows.length) {
        return el("div", { "class": "panel-state panel-empty" }, "No change has Beads yet.");
      }
      return el("ul", { "class": "graph-changes" }, rows.map(function (row) {
        return el("li", null, el("a", { href: ctx.link("graph", { scope: "change", id: row.change }) }, row.change),
          el("span", { "class": "panel-meta" }, row.total + " Bead" + (row.total === 1 ? "" : "s")));
      }));
    }, true);
    return function () {};
  }

  G.hooks.chooser = function (container, ctx) {
    var scope = scopeOf(ctx.params);
    container.appendChild(picker(ctx, scope));
    return scope.kind === "change" ? mountChanges(container, ctx) : mountScope(container, ctx, scope);
  };

  // Every drawing: a collapsed group expands into its Beads, the centre of a neighbourhood is
  // marked, and a change flow gets the scope picker that render.js does not draw itself.
  G.hooks.drawn.push(function (drawing, data, ctx) {
    var scope = scopeOf(ctx.params);
    data.nodes.forEach(function (node) {
      var shape = drawing.nodes[node.id];
      if (node.kind === "group" && shape) {
        var expand = function () { ctx.navigate("graph", paramsWithout(ctx, "closed")); };
        shape.setAttribute("role", "button");
        shape.setAttribute("tabindex", "0");
        shape.setAttribute("aria-label", node.title + ", activate to show them");
        shape.addEventListener("click", expand);
        shape.addEventListener("keydown", function (event) {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            expand();
          }
        });
      } else if (scope.kind === "bead" && shape && node.id === scope.id) {
        shape.classList.add("graph-centre");
      }
    });
    if (ctx.params.get("scope") === "change") {
      drawing.element.insertBefore(picker(ctx, { kind: "change" }), drawing.element.firstChild);
    }
  });

  function paramsWithout(ctx, name) {
    var next = {};
    ctx.params.forEach(function (value, key) { if (key !== name && key !== "bead") { next[key] = value; } });
    return next;
  }

  App.store.subscribe(function (event) {
    if (refreshActive && event.changed.indexOf("beads") >= 0) {
      refreshActive();
    }
  });
}());
