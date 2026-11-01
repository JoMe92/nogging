// The Bead detail (design Decision 16, Detail; requirement "The detail view shows one Bead with
// its evidence"). Data: /api/v1/beads/<id>, one `bead` plus a block per piece of evidence, each
// with the state and time of the source it came from. The view is an overlay on any route, opened
// by `bead=<ID>` in the address: a 480 px right panel from 600 px, the whole screen below.
//
// Focus: opening moves focus to the dialog, everything behind it is made inert so Tab cannot
// reach it, Escape and the close button end it, and focus goes back to what opened it. Opening
// another Bead from inside keeps the original trigger. Text uses `white-space: pre-wrap`; it is
// linkified with createElement only for known Bead IDs and the SHAs of this Bead's own commits,
// never for a URL. Null fields read "Not recorded". `assignee` never arrives from the server.
(function () {
  "use strict";
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var el = D.el;
  var NOT_RECORDED = F.NOT_RECORDED;
  var WORD = /[A-Za-z0-9][A-Za-z0-9_.-]*/g;
  var HEX = /^[0-9a-f]{7,40}$/;
  var STAGES = [["changed", "Changed"], ["commit", "Commit"], ["bead", "Bead"], ["full", "Full"]];
  var COUNTERS = [["fresh_input_tokens", "Fresh input"], ["cache_read_tokens", "Cache read"],
    ["cache_write_tokens", "Cache write"], ["output_tokens", "Output"], ["total_tokens", "Total"]];
  var SOURCE_NAMES = { git: "Git", sessions: "Sessions", tokens: "Tokens", tests: "Test runs" };

  var open = null;          // { id, ctx, root, dialog, body, title, trigger, inerted, token, stop }
  var subscribed = false;
  var serial = 0;           // numbers each load, so a late answer for another Bead is dropped

  /* ---------------------------------------------------------------- pure helpers */

  function text(value) {
    return value === null || value === undefined || value === "" ? NOT_RECORDED : String(value);
  }

  function count(value) {
    return typeof value === "number" ? value.toLocaleString("en-US") : NOT_RECORDED;
  }

  function seconds(value) {
    if (typeof value !== "number") {
      return NOT_RECORDED;
    }
    return value < 60 ? (Math.round(value * 10) / 10) + " s"
      : Math.floor(value / 60) + " min " + Math.round(value % 60) + " s";
  }

  function duration(session) {
    var start = Date.parse(session.started_at);
    var end = Date.parse(session.ended_at);
    if (isNaN(start)) {
      return NOT_RECORDED;
    }
    if (isNaN(end)) {
      return session.state === "running" ? "Running" : NOT_RECORDED;
    }
    if (end < start) {
      return NOT_RECORDED;
    }
    var minutes = Math.round((end - start) / 60000);
    return minutes < 1 ? "< 1 min" : minutes < 60 ? minutes + " min"
      : Math.floor(minutes / 60) + " h " + (minutes % 60 < 10 ? "0" : "") + (minutes % 60) + " min";
  }

  // One line saying how fresh a block is, from the state and time of its own source.
  function freshness(block) {
    var name = SOURCE_NAMES[block.source] || "Source";
    var at = block.as_of ? F.clock(block.as_of) : null;
    var line = { fresh: at && "updated " + at, stale: at && "stale, last update " + at,
      loading: "loading", unavailable: "unavailable", absent: "not read here" }[block.state];
    return name + " · " + (line || text(block.state));
  }

  // Why a block has no content, when its source gave none.
  function missing(block) {
    return { loading: "Still loading.", unavailable: "This source could not be read.",
      absent: "This source is not available here." }[block.state] || "No data from this source.";
  }

  // Splits `value` into text nodes and links. `known` maps a Bead ID to true, `shas` lists this
  // Bead's commit SHAs. Nothing that looks like a URL is ever turned into a link.
  function linkify(value, known, shas, makeBead, makeSha) {
    var nodes = [];
    var last = 0;
    var source = String(value);
    var match;
    WORD.lastIndex = 0;
    while ((match = WORD.exec(source)) !== null) {
      var word = match[0].replace(/[.-]+$/, "");
      var node = null;
      var from = Math.max(source.lastIndexOf(" ", match.index), source.lastIndexOf("\n", match.index));
      var to = source.slice(match.index).search(/\s/);
      var chunk = source.slice(from + 1, to < 0 ? source.length : match.index + to);
      if (chunk.indexOf("://") >= 0) {
        continue;        // a piece of a URL is never linked
      }
      if (known[word] === true) {
        node = makeBead(word);
      } else if (HEX.test(word) && shas.some(function (sha) { return sha.indexOf(word) === 0; })) {
        node = makeSha(word);
      }
      if (node) {
        nodes.push(source.slice(last, match.index), node);
        last = match.index + word.length;
      }
    }
    nodes.push(source.slice(last));
    return nodes;
  }

  /* ---------------------------------------------------------------- rendering */

  function beadHref(ctx, id) {
    var next = {};
    ctx.params.forEach(function (value, name) { next[name] = value; });
    next.bead = id;
    return ctx.link(ctx.route, next);
  }

  function section(title, block, children, id) {
    return el("section", { "class": "detail-block", "aria-labelledby": id },
      el("div", { "class": "detail-block-head" }, el("h3", { id: id }, title),
        block ? el("span", { "class": "detail-fresh" }, freshness(block)) : null),
      children);
  }

  function note(message) {
    return el("p", { "class": "detail-note" }, message);
  }

  function renderText(value, view, ctx, id) {
    var body = el("div", { "class": "detail-text", id: id },
      value ? linkify(value, view.known, view.shas, function (word) {
        return el("a", { href: beadHref(ctx, word), "class": "detail-ref" }, word);
      }, function (word) {
        return el("a", { href: "#", "class": "detail-ref detail-sha", on: { click: function (event) {
          event.preventDefault();
          var row = document.getElementById("commit-" + view.shas.filter(function (sha) { return sha.indexOf(word) === 0; })[0]);
          if (row) {
            row.scrollIntoView({ block: "nearest" });
            row.focus();
          }
        } } }, word);
      }) : NOT_RECORDED);
    return body;
  }

  function clamped(value, view, ctx, id) {
    var body = renderText(value, view, ctx, id);
    if (!value) {
      return body;
    }
    body.classList.add("detail-clamped");
    var toggle = el("button", { type: "button", "class": "btn btn-quiet detail-more", hidden: true,
      "aria-expanded": "false", "aria-controls": id });
    function label() {
      D.replace(toggle, body.classList.contains("detail-clamped") ? "Show all" : "Show less");
      toggle.setAttribute("aria-expanded", body.classList.contains("detail-clamped") ? "false" : "true");
    }
    toggle.addEventListener("click", function () {
      body.classList.toggle("detail-clamped");
      label();
    });
    label();
    // Measured once the text is in the page; a short note never shows the button.
    window.requestAnimationFrame(function () {
      if (body.scrollHeight > body.clientHeight + 1) {
        toggle.hidden = false;
      }
    });
    return [body, toggle];
  }

  function header(bead, ctx) {
    return el("div", { "class": "detail-head-meta" },
      D.statusBadge(bead.status), bead.ready ? el("span", { "class": "detail-ready" }, "Ready") : null,
      D.priorityChip(bead.priority), el("span", { "class": "detail-type" }, text(bead.issue_type)),
      el("code", { "class": "detail-id" }, bead.id),
      el("dl", { "class": "detail-times" },
        bead.change ? [el("dt", null, "Change"), el("dd", null, bead.change)] : null,
        el("dt", null, "Created"), el("dd", null, F.dateTime(bead.created_at)),
        el("dt", null, "Started"), el("dd", null, F.dateTime(bead.started_at)),
        el("dt", null, "Closed"), el("dd", null, F.dateTime(bead.closed_at)),
        el("dt", null, "Updated"), el("dd", null, F.dateTime(bead.updated_at))));
  }

  function neighbours(title, items, ctx, id) {
    return el("div", { "class": "detail-deps" }, el("h4", { id: id }, title + " (" + items.length + ")"),
      items.length ? el("ul", { "aria-labelledby": id }, items.map(function (item) {
        return el("li", null, el("a", { href: beadHref(ctx, item.id), "class": "detail-dep" },
          D.statusBadge(item.status), el("code", null, item.id),
          el("span", { "class": "detail-dep-title" }, item.title ? F.title(item.title) : NOT_RECORDED)),
        el("a", { href: ctx.link("graph", { scope: "bead", id: item.id }), "class": "detail-graph",
          "aria-label": "Open " + item.id + " in graph" }, "Open in graph"));
      })) : el("p", { "class": "detail-note" }, "None."));
  }

  function dependencies(data, ctx) {
    var deps = data.dependencies || { depends_on: [], blocks: [] };
    return section("Dependencies", null, [
      neighbours("Depends on", deps.depends_on, ctx, "detail-dep-on"),
      neighbours("Blocks", deps.blocks, ctx, "detail-dep-by"),
      el("a", { href: ctx.link("graph", { scope: "bead", id: data.bead.id }), "class": "btn btn-quiet detail-open-graph" },
        "Open in graph")], "detail-h-deps");
  }

  function commits(block, view, ctx) {
    var body;
    if (!block.available) {
      body = note(missing(block));
    } else if (!block.commits.length) {
      body = note("No commit names this Bead in its subject. Commits attach through the [" + view.id + "] token.");
    } else {
      body = [el("ul", { "class": "detail-commits" }, block.commits.map(function (commit) {
        return el("li", { id: "commit-" + commit.sha, tabindex: "-1" },
          el("code", { "class": "detail-sha", title: commit.sha }, commit.sha.slice(0, 7)),
          el("span", { "class": "detail-subject" }, linkify(text(commit.subject), view.known, [], function (word) {
            return el("a", { href: beadHref(ctx, word), "class": "detail-ref" }, word);
          }, function () { return null; })),
          el("span", { "class": "detail-lines" }, "+" + count(commit.production_lines) + " prod, +" + count(commit.test_lines) + " test"),
          el("time", { datetime: commit.at }, F.dateTime(commit.at)));
      })), el("p", { "class": "detail-total" }, "Total: " + count(block.production_lines) + " production lines, "
        + count(block.test_lines) + " test lines in " + block.commits.length + " commit" + (block.commits.length === 1 ? "" : "s") + ".")];
    }
    return section("Commits", block, body, "detail-h-commits");
  }

  function sessions(block) {
    var body;
    if (!block.available) {
      body = note(missing(block));
    } else if (!block.sessions.length) {
      body = note("No session record on this host names this Bead. Session records are host-local, so work "
        + "done elsewhere does not appear here.");
    } else {
      var columns = [["Agent", function (s) { return F.agent(s.agent); }], ["Model", function (s) { return text(s.requested_model); }],
        ["Effort", function (s) { return text(s.reasoning_effort); }], ["Tier", function (s) { return text(s.selection_tier); }],
        ["Role", function (s) { return text(s.role); }], ["Start", function (s) { return F.dateTime(s.started_at); }],
        ["End", function (s) { return F.dateTime(s.ended_at); }], ["Duration", duration],
        ["Exit reason", function (s) { return text(s.exit_reason); }]];
      body = [el("div", { "class": "detail-scroll", tabindex: "0", role: "region", "aria-label": "Sessions table" },
        el("table", { "class": "detail-sessions" },
          el("thead", null, el("tr", null, columns.map(function (column) { return el("th", { scope: "col" }, column[0]); }))),
          el("tbody", null, block.sessions.map(function (s) {
            return el("tr", null, columns.map(function (column) { return el("td", null, column[1](s)); }));
          })))),
        el("ul", { "class": "detail-cards" }, block.sessions.map(function (s) {
          return el("li", { "class": "detail-card" },
            el("strong", null, F.agent(s.agent) + " · " + text(s.role)),
            el("dl", null, columns.slice(1).filter(function (column) { return column[0] !== "Role"; }).map(function (column) {
              return [el("dt", null, column[0]), el("dd", null, column[1](s))];
            })));
        }))];
    }
    return section("Sessions", block, body, "detail-h-sessions");
  }

  function tokens(block) {
    var body;
    if (!block.available) {
      body = note(missing(block));
    } else if (!block.work) {
      body = note("No usage event is recorded for this Bead.");
    } else {
      var unknown = block.work.unknown_counters || {};
      var gaps = COUNTERS.filter(function (counter) { return unknown[counter[0]] > 0; });
      body = [el("dl", { "class": "detail-kv" }, COUNTERS.map(function (counter) {
        return [el("dt", null, counter[1]), el("dd", null, count((block.work.tokens || {})[counter[0]]))];
      })),
      gaps.length ? note("Some events lack: " + gaps.map(function (counter) { return counter[1].toLowerCase(); }).join(", ")
        + ". The totals count known values only.") : null];
    }
    if (block.available && block.partial && block.partial.length) {
      body = [body, note("Partial history for: " + block.partial.join(", ") + ".")];
    }
    if (block.available && block.pending_batches > 0) {
      body = [body, note(block.pending_batches + " usage batch" + (block.pending_batches === 1 ? " is" : "es are") + " waiting to be collected.")];
    }
    return section("Tokens", block, body, "detail-h-tokens");
  }

  function tests(block) {
    var body;
    if (!block.available) {
      body = note(missing(block));
    } else if (!block.stage_seconds) {
      body = note("No test run is recorded for this Bead.");
    } else {
      body = [el("dl", { "class": "detail-kv" }, STAGES.map(function (stage) {
        return [el("dt", null, stage[1]), el("dd", null, seconds(block.stage_seconds[stage[0]]))];
      })), note(count(block.runs) + " recorded run" + (block.runs === 1 ? "" : "s") + ".")];
    }
    return section("Test cost", block, body, "detail-h-tests");
  }

  function viewOf(data, ctx) {
    var known = {};
    var beads = ctx.store.peek("beads");
    var list = beads && beads.ok && beads.envelope.data && beads.envelope.data.beads || [];
    list.forEach(function (row) { known[row.id] = true; });
    var deps = data.dependencies || { depends_on: [], blocks: [] };
    deps.depends_on.concat(deps.blocks).forEach(function (item) { known[item.id] = true; });
    known[data.bead.id] = true;
    var shas = data.commits && data.commits.available ? data.commits.commits.map(function (c) { return c.sha; }) : [];
    return { id: data.bead.id, known: known, shas: shas };
  }

  function content(data, ctx) {
    var bead = data.bead;
    var view = viewOf(data, ctx);
    return [header(bead, ctx),
      section("Description", null, renderText(bead.description, view, ctx, "detail-description"), "detail-h-description"),
      section("Notes", null, clamped(bead.notes, view, ctx, "detail-notes"), "detail-h-notes"),
      bead.close_reason ? section("Close reason", null, renderText(bead.close_reason, view, ctx, "detail-close"), "detail-h-close") : null,
      dependencies(data, ctx),
      section("Labels", null, bead.labels && bead.labels.length
        ? el("ul", { "class": "detail-labels" }, bead.labels.map(function (label) { return el("li", null, label); }))
        : note(NOT_RECORDED), "detail-h-labels"),
      commits(data.commits, view, ctx), sessions(data.sessions), tokens(data.tokens), tests(data.tests)];
  }

  /* ---------------------------------------------------------------- the overlay */

  function inertOthers(root) {
    var made = [];
    Array.prototype.forEach.call(document.body.children, function (node) {
      if (node !== root && node.tagName !== "SCRIPT" && !node.hasAttribute("inert")) {
        node.setAttribute("inert", "");
        made.push(node);
      }
    });
    return made;
  }

  function build(ctx) {
    var title = el("h2", { id: "detail-title", tabindex: "-1" }, "Bead");
    var close = el("button", { type: "button", "class": "btn btn-quiet detail-close", "aria-label": "Close detail",
      on: { click: function () { ctx.closeDetail(); } } }, "Close");
    var body = el("div", { "class": "detail-body", "aria-live": "polite" });
    var dialog = el("aside", { "class": "detail", role: "dialog", "aria-modal": "true", "aria-labelledby": "detail-title" },
      el("header", { "class": "detail-head" }, title, close), body);
    var root = el("div", { "class": "detail-root" },
      el("div", { "class": "detail-backdrop", on: { click: function () { ctx.closeDetail(); } } }), dialog);
    return { root: root, dialog: dialog, body: body, title: title };
  }

  function show(state, id, data, result) {
    var ctx = state.ctx;
    D.clear(state.body);
    if (result && result.status === 404) {
      D.replace(state.title, id);
      D.replace(state.body, note("This Bead does not exist, or it was removed."));
    } else if (!data || !data.bead) {
      D.replace(state.title, id);
      D.replace(state.body, result && result.ok
        ? note("The Bead list is not loaded yet. This updates when it is.")
        : el("p", { "class": "detail-note", role: "alert" }, result && result.unreachable ? "Server not reachable. " : "The detail could not load. ",
          el("button", { type: "button", "class": "btn btn-quiet", on: { click: function () { load(state, true); } } }, "Retry")));
    } else {
      D.replace(state.title, F.title(data.bead.title));
      D.replace(state.body, content(data, ctx));
      document.title = id + " · Nogging dashboard";
    }
  }

  function load(state, force) {
    var token = state.token;
    var id = state.id;
    D.replace(state.body, el("p", { "class": "detail-note", role: "status" }, "Loading…"));
    return state.ctx.store.get("bead:" + id, "/api/v1/beads/" + encodeURIComponent(id), { force: force }).then(function (result) {
      if (open && open.token === token) {
        show(state, id, result.ok ? result.envelope.data : null, result);
      }
    });
  }

  function release() {
    if (!open) {
      return;
    }
    document.removeEventListener("keydown", open.keydown, true);
    open.root.parentNode && open.root.parentNode.removeChild(open.root);
    open.inerted.forEach(function (node) { node.removeAttribute("inert"); });
    var back = open.trigger && open.trigger.isConnected ? open.trigger : document.getElementById("app");
    open = null;
    if (back) {
      back.focus({ preventScroll: true });
    }
  }

  function subscribe(ctx) {
    if (subscribed) {
      return;
    }
    subscribed = true;
    ctx.store.subscribe(function () {
      if (open) {
        open.token = ++serial;
        load(open, true);
      }
    });
  }

  window.noggingApp.registerView("detail", {
    open: function (id, ctx) {
      subscribe(ctx);
      if (open) {
        // Another Bead from inside the panel: same overlay, same trigger.
        open.id = id;
        open.ctx = ctx;
        open.token = ++serial;
        load(open, true).then(function () { open && open.title.focus({ preventScroll: true }); });
        return;
      }
      var parts = build(ctx);
      var trigger = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
      open = { id: id, ctx: ctx, root: parts.root, dialog: parts.dialog, body: parts.body, title: parts.title,
        trigger: trigger, token: ++serial, inerted: [] };
      open.keydown = function (event) {
        if (event.key === "Escape" && open) {
          event.preventDefault();
          open.ctx.closeDetail();
        }
      };
      document.body.appendChild(parts.root);
      open.inerted = inertOthers(parts.root);
      document.addEventListener("keydown", open.keydown, true);
      D.replace(parts.title, id);
      parts.title.focus({ preventScroll: true });
      load(open, true);
    },
    close: function () {
      release();
    },
    logic: { linkify: linkify, duration: duration, freshness: freshness, seconds: seconds },
  });
}());
