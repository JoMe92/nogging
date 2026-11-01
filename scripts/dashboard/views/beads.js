// The Bead table (design Decision 16, Table; requirement "The table lists every Bead").
// Data: /api/v1/beads, rows without descriptions or notes plus the `facets` counts. Filtering,
// sorting and paging run in the browser; the URL carries them, so a link reproduces the view:
//   status, type, priority, change, label  comma lists, a value matches when it is in the list
//   q          words that must all occur in the ID or the title
//   closed=1   include closed Beads (a `status=closed` filter includes them too)
//   sort, dir  a column key and asc or desc; no `sort` means priority, then most recently updated
//   page       1-based, 50 rows a page
//   change=(none) selects the Beads that carry no change label.
// Below 960 px rows are cards and the filters open as a bottom sheet; from 960 px it is a table
// with a sidebar. The page never scrolls sideways.
(function () {
  "use strict";
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var el = D.el;
  var NONE = "(none)";
  var DEBOUNCE_MS = 250;
  var MAX_LIST = 20;
  var FACETS = [
    { key: "status", label: "Status", text: function (v) { return F.status(v); } },
    { key: "type", label: "Type", text: function (v) { return v === NONE ? "Not recorded" : v.charAt(0).toUpperCase() + v.slice(1); } },
    { key: "priority", label: "Priority", text: function (v) { return v === NONE ? "Not recorded" : "P" + v; } },
    { key: "change", label: "Change", text: function (v) { return v === NONE ? "No change" : v; } },
    { key: "label", label: "Label", text: function (v) { return v === "openspec:task" ? "OpenSpec task" : v === "discovery" ? "Discovery" : v; } },
  ];
  var LABEL_CLASSES = ["openspec:task", "discovery"];

  /* ---------------------------------------------------------------- pure logic */

  function keyOf(value) {
    return value === null || value === undefined || value === "" ? NONE : String(value);
  }

  function list(text) {
    var seen = [];
    (text || "").split(",").forEach(function (part) {
      var item = part.trim().slice(0, 100);
      if (item && seen.indexOf(item) < 0 && seen.length < MAX_LIST) {
        seen.push(item);
      }
    });
    return seen;
  }

  function parseState(params) {
    var state = { q: (params.get("q") || "").slice(0, 200), closed: params.get("closed") === "1",
      sort: null, dir: "asc", page: 1 };
    FACETS.forEach(function (facet) { state[facet.key] = list(params.get(facet.key)); });
    var key = params.get("sort");
    if (COLUMN_KEYS.indexOf(key) >= 0) {
      state.sort = key;
      state.dir = params.get("dir") === "desc" ? "desc" : "asc";
    }
    var page = parseInt(params.get("page"), 10);
    state.page = page > 0 ? page : 1;
    return state;
  }

  // The URL form: only what differs from the default view.
  function toParams(state) {
    var out = {};
    FACETS.forEach(function (facet) {
      if (state[facet.key].length) { out[facet.key] = state[facet.key].join(","); }
    });
    if (state.q) { out.q = state.q; }
    if (state.closed) { out.closed = "1"; }
    if (state.sort) { out.sort = state.sort; out.dir = state.dir; }
    if (state.page > 1) { out.page = state.page; }
    return out;
  }

  function labelClasses(row) {
    var found = [];
    LABEL_CLASSES.forEach(function (name) {
      if ((row.labels || []).some(function (label) { return label === name || label.indexOf(name + ":") === 0; })) {
        found.push(name);
      }
    });
    return found;
  }

  function includesClosed(state) {
    return state.closed || state.status.indexOf("closed") >= 0;
  }

  // AND across the filters, OR within one. Closed Beads show only when asked for.
  function visibleRows(rows, state) {
    var words = state.q.toLowerCase().split(/\s+/).filter(Boolean);
    var showClosed = includesClosed(state);
    return rows.filter(function (row) {
      if (row.status === "closed" && !showClosed) { return false; }
      if (state.status.length && state.status.indexOf(keyOf(row.status)) < 0) { return false; }
      if (state.type.length && state.type.indexOf(keyOf(row.issue_type)) < 0) { return false; }
      if (state.priority.length && state.priority.indexOf(keyOf(row.priority)) < 0) { return false; }
      if (state.change.length && state.change.indexOf(keyOf(row.change)) < 0) { return false; }
      if (state.label.length && !labelClasses(row).some(function (name) { return state.label.indexOf(name) >= 0; })) {
        return false;
      }
      var hay = (row.id + " " + (row.title || "")).toLowerCase();
      return words.every(function (word) { return hay.indexOf(word) >= 0; });
    });
  }

  function activeFilters(state) {
    return FACETS.reduce(function (sum, facet) { return sum + state[facet.key].length; }, 0);
  }

  function ageSort(field) {
    // Newest first when ascending, the order of the shown "3 min", "5 d".
    return function (row) {
      var time = Date.parse(row[field]);
      return isNaN(time) ? null : -time;
    };
  }

  var COLUMNS = [
    { key: "id", label: "ID", value: function (row) { return row.id; } },
    { key: "status", label: "Status", value: function (row) { return STATUS_RANK[row.status] === undefined ? 99 : STATUS_RANK[row.status]; } },
    { key: "priority", label: "Priority", value: function (row) { return typeof row.priority === "number" ? row.priority : null; } },
    { key: "type", label: "Type", value: function (row) { return row.issue_type; } },
    { key: "title", label: "Title", value: function (row) { return F.title(row.title) === F.NOT_RECORDED ? null : F.title(row.title); } },
    { key: "change", label: "Change", value: function (row) { return row.change; } },
    { key: "updated", label: "Updated", value: ageSort("updated_at") },
    { key: "age", label: "Age", value: ageSort("created_at") },
  ];
  var STATUS_RANK = { open: 0, in_progress: 1, blocked: 2, deferred: 3, closed: 4 };
  var COLUMN_KEYS = COLUMNS.map(function (column) { return column.key; });
  var DEFAULT_SORT = { key: "priority", dir: "asc" };

  function effectiveSort(state) {
    return state.sort ? { key: state.sort, dir: state.dir } : DEFAULT_SORT;
  }

  // Priority ties go to the most recently updated; every other column ties on the ID.
  function tieBreak(key) {
    if (key !== "priority") { return null; }
    var updated = ageSort("updated_at");
    return function (a, b) {
      var left = updated(a);
      var right = updated(b);
      return left === right ? 0 : left === null ? 1 : right === null ? -1 : left - right;
    };
  }

  /* ---------------------------------------------------------------- the view */

  var active = null;       // the mounted view, for the one store subscription
  var subscribed = false;
  var saved = null;        // where the reader was when the view was rebuilt, to put them back

  // The cells of a row, or its card. Built once per row and column set, so a row costs one link.
  function rowParts(ctx, state, row, kind) {
    var link = el("a", { href: ctx.link("beads", Object.assign(toParams(state), { bead: row.id })), "class": "bead-link",
      "data-focus": (kind === "card" ? "card:" : "open:") + row.id }, F.title(row.title));
    var ready = row.ready && row.status === "open" ? D.statusBadge("ready") : null;
    if (kind === "card") {
      return [
        el("div", { "class": "card-top" }, el("span", { "class": "mono card-id" }, row.id),
          D.priorityChip(row.priority), D.statusBadge(row.status), ready),
        el("div", { "class": "card-title" }, link),
        el("div", { "class": "card-meta" }, el("span", null, row.change || "No change"),
          el("span", null, "Updated " + F.age(row.updated_at))),
      ];
    }
    function when(iso) {
      return el("time", { datetime: iso || null, title: F.dateTime(iso) }, F.age(iso));
    }
    return { id: el("span", { "class": "mono" }, row.id), status: [D.statusBadge(row.status), ready],
      priority: D.priorityChip(row.priority), type: keyOf(row.issue_type) === NONE ? F.NOT_RECORDED : row.issue_type,
      title: el("span", { "class": "clamp" }, link), change: row.change || "No change",
      updated: when(row.updated_at), age: when(row.created_at) };
  }

  function mount(container, ctx) {
    var state = parseState(ctx.params);
    var rows = [];
    var facets = {};
    var seenFacets = "";
    var timer = null;
    var alive = true;
    var parts = null;
    var restore = saved && Date.now() - saved.at < 3000 ? saved : null;
    saved = null;
    var panel = ctx.panel({ title: "Beads" });
    container.appendChild(panel.element);

    /* --- the URL. A discrete change goes through the shell, which rebuilds the view from the
       address (replacing the history entry, so Back is not a stack of filter clicks). Typing only
       rewrites the address in place, so the search field keeps focus and the phone its keyboard. */
    function address() {
      var params = toParams(state);
      var bead = new URLSearchParams(window.location.hash.replace(/^#[^?]*\??/, "")).get("bead");
      if (bead) { params.bead = bead; }
      return ctx.link("beads", params);
    }

    function remember(top) {
      var node = document.activeElement && document.activeElement.closest ? document.activeElement.closest("[data-focus]") : null;
      saved = { at: Date.now(), y: top ? null : window.pageYOffset, focus: node ? node.getAttribute("data-focus") : null };
    }

    function commit(top) {
      window.clearTimeout(timer);
      remember(top);
      window.location.replace(address());
    }

    function setList(key, value, on) {
      var at = state[key].indexOf(value);
      if (on && at < 0) { state[key].push(value); }
      if (!on && at >= 0) { state[key].splice(at, 1); }
      state.page = 1;
      commit(false);
    }

    function clearAll() {
      FACETS.forEach(function (facet) { state[facet.key] = []; });
      state.q = "";
      state.closed = false;
      state.page = 1;
      commit(true);
    }

    function sortBy(key) {
      var now = effectiveSort(state);
      state.sort = key;
      state.dir = now.key === key && now.dir === "asc" ? "desc" : "asc";
      state.page = 1;
      commit(false);
    }

    function goTo(page) {
      state.page = page;
      commit(true);
    }

    /* --- the filters: a sidebar from 960 px, a bottom sheet below */
    function options(facet) {
      var entries = (facets[facet.key] || []).map(function (entry) { return { value: keyOf(entry.value), count: entry.count }; });
      state[facet.key].forEach(function (value) {          // a value from the URL that no Bead has
        if (!entries.some(function (entry) { return entry.value === value; })) {
          entries.push({ value: value, count: 0 });
        }
      });
      return entries;
    }

    function check(label, checked, count, onChange, focus) {
      var box = el("input", { type: "checkbox", "data-focus": focus });
      box.checked = !!checked;
      box.addEventListener("change", function () { onChange(box.checked); });
      return el("label", { "class": "check" }, box, el("span", { "class": "check-text" }, label),
        count === null ? null : el("span", { "class": "check-count" }, count));
    }

    function filterGroups() {
      return FACETS.map(function (facet) {
        var entries = options(facet);
        if (!entries.length) { return null; }
        return el("fieldset", { "class": "filter-group" }, el("legend", null, facet.label),
          entries.map(function (entry) {
            return check(facet.text(entry.value), state[facet.key].indexOf(entry.value) >= 0, entry.count,
              function (on) { setList(facet.key, entry.value, on); }, "f:" + facet.key + ":" + entry.value);
          }));
      });
    }

    var sheetOpener = null;
    function trap(event) {
      if (event.key === "Escape") { closeSheet(); return; }
      if (event.key !== "Tab") { return; }
      var items = Array.prototype.filter.call(parts.filters.querySelectorAll("button, input"),
        function (node) { return node.offsetParent !== null; });
      if (!items.length) { return; }
      var first = items[0];
      var last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }

    function openSheet() {
      sheetOpener = document.activeElement;
      parts.filters.classList.add("open");
      parts.backdrop.classList.add("open");
      parts.filters.setAttribute("role", "dialog");
      parts.filters.setAttribute("aria-modal", "true");
      parts.filters.addEventListener("keydown", trap);
      parts.filtersButton.setAttribute("aria-expanded", "true");
      parts.sheetClose.focus();
    }

    function closeSheet() {
      parts.filters.classList.remove("open");
      parts.backdrop.classList.remove("open");
      parts.filters.removeAttribute("role");
      parts.filters.removeAttribute("aria-modal");
      parts.filters.removeEventListener("keydown", trap);
      parts.filtersButton.setAttribute("aria-expanded", "false");
      (sheetOpener && sheetOpener.focus ? sheetOpener : parts.filtersButton).focus();
    }

    /* --- the results, redrawn in place */
    var last = { row: null, cells: null };
    var table = window.noggingTable.create({
      label: "Beads",
      columns: COLUMNS.map(function (column) {
        return { key: column.key, label: column.label, value: column.value, cell: function (row) {
          if (last.row !== row) { last = { row: row, cells: rowParts(ctx, state, row, "cell") }; }
          return last.cells[column.key];
        } };
      }),
      card: function (row) { return rowParts(ctx, state, row, "card"); },
      tieBreak: tieBreak, onSort: sortBy, onPage: goTo, onOpen: function (row) { ctx.openDetail(row.id); },
    });

    function draw() {
      var shown = visibleRows(rows, state);
      last = { row: null, cells: null };
      state.page = table.render({ rows: shown, sort: effectiveSort(state), page: state.page }).page;
      var filtered = shown.length !== rows.length;
      D.replace(parts.count, shown.length + (filtered ? " of " + rows.length : "") + (rows.length === 1 ? " Bead" : " Beads"));
      parts.empty.hidden = shown.length > 0;
      table.element.hidden = shown.length === 0;
      var n = activeFilters(state);
      D.replace(parts.filtersLabel, "Filters (" + n + ")");
      parts.clear.hidden = !(n || state.q || state.closed);
      parts.closed.checked = includesClosed(state);
      D.replace(parts.sheetShow, "Show " + shown.length + (shown.length === 1 ? " Bead" : " Beads"));
      var header = document.getElementById("search-input");    // the header's field follows this one
      if (header) { header.value = state.q; }
    }

    function layout() {
      parts = {};
      parts.count = el("p", { "class": "result-count", role: "status", "aria-live": "polite" });
      parts.search = el("input", { "class": "field bead-search", type: "search", id: "bead-q", name: "q",
        placeholder: "Search ID or title", autocomplete: "off", enterkeyhint: "search", "data-focus": "q" });
      parts.search.value = state.q;
      parts.search.addEventListener("input", function () {
        window.clearTimeout(timer);
        timer = window.setTimeout(function () {
          state.q = parts.search.value.trim().slice(0, 200);
          state.page = 1;
          draw();
          window.history.replaceState(null, "", address());
        }, DEBOUNCE_MS);
      });
      parts.search.addEventListener("keydown", function (event) {
        if (event.key === "Enter") { event.preventDefault(); }
      });
      parts.filtersLabel = el("span", null, "Filters (0)");
      parts.filtersButton = el("button", { type: "button", "class": "btn btn-quiet filters-toggle", "aria-expanded": "false",
        "aria-controls": "bead-filters", "data-focus": "filters", on: { click: openSheet } }, parts.filtersLabel);
      parts.closed = el("input", { type: "checkbox", "data-focus": "closed" });
      parts.closed.addEventListener("change", function () {
        state.closed = parts.closed.checked;
        if (!state.closed) { state.status = state.status.filter(function (value) { return value !== "closed"; }); }
        state.page = 1;
        commit(false);
      });
      parts.clear = el("button", { type: "button", "class": "btn btn-quiet", on: { click: clearAll } }, "Clear filters");
      parts.sheetClose = el("button", { type: "button", "class": "btn", on: { click: closeSheet } }, "Done");
      parts.sheetShow = el("span", { "class": "panel-meta" });
      parts.groups = el("div", { "class": "filter-groups" }, filterGroups());
      parts.filters = el("aside", { id: "bead-filters", "class": "filters", "aria-labelledby": "filters-title" },
        el("div", { "class": "filters-head" }, el("h3", { id: "filters-title" }, "Filters"), parts.sheetShow, parts.sheetClose),
        parts.groups);
      parts.backdrop = el("div", { "class": "filters-backdrop", on: { click: closeSheet } });
      parts.empty = el("div", { "class": "panel-state panel-empty", role: "status" },
        el("span", null, "No Beads match these filters."),
        el("button", { type: "button", "class": "btn btn-quiet", on: { click: clearAll } }, "Clear filters"));
      seenFacets = JSON.stringify(facets);
      return el("div", { "class": "beads-layout" }, parts.backdrop, parts.filters,
        el("div", { "class": "beads-main" },
          el("div", { "class": "toolbar" },
            el("label", { "class": "visually-hidden", "for": "bead-q" }, "Search Beads"), parts.search,
            parts.filtersButton,
            el("label", { "class": "check" }, parts.closed, el("span", { "class": "check-text" }, "Include closed")),
            parts.clear),
          parts.count, parts.empty, table.element));
    }

    function take(envelope) {
      rows = envelope.data.beads || [];
      facets = envelope.data.facets || {};
    }

    // After the shell has scrolled to the top and focused <main>, put the reader back.
    function putBack() {
      var wanted = restore;
      restore = null;
      if (!wanted) { return; }
      window.setTimeout(function () {
        if (!alive || !parts) { return; }
        if (wanted.y === null) { parts.count.scrollIntoView({ block: "start" }); } else { window.scrollTo(0, wanted.y); }
        var here = document.activeElement;
        if (wanted.focus && (here === document.body || here === document.getElementById("app"))) {
          var target = Array.prototype.filter.call(container.querySelectorAll("[data-focus]"), function (node) {
            return node.getAttribute("data-focus") === wanted.focus && node.offsetParent !== null;
          })[0];
          if (target) { target.focus({ preventScroll: true }); }
        }
      }, 0);
    }

    active = {
      refresh: function () {
        ctx.store.get("beads", "/api/v1/beads", { force: true }).then(function (result) {
          if (!alive || !result.ok) { return; }
          take(result.envelope);
          if (!rows.length) { parts = null; panel.set("empty", "No Beads yet."); return; }
          if (!parts) { panel.set("ready", layout()); }
          else if (JSON.stringify(facets) !== seenFacets) {
            seenFacets = JSON.stringify(facets);
            D.replace(parts.groups, filterGroups());
          }
          draw();
        });
      },
    };

    panel.load("beads", "/api/v1/beads", function (envelope) {
      take(envelope);
      return rows.length ? layout() : el("p", { "class": "empty-note" }, "No Beads yet.");
    }).then(function (result) {
      if (alive && result.ok && rows.length) {
        draw();
        putBack();
      }
    });

    return function unmount() {
      alive = false;
      active = null;
      window.clearTimeout(timer);
      if (!saved || Date.now() - saved.at > 3000) { remember(false); }
    };
  }

  window.noggingApp.registerView("beads", {
    mount: function (container, ctx) {
      if (!subscribed) {
        subscribed = true;
        ctx.store.subscribe(function (change) {
          if (active && change.changed.indexOf("beads") >= 0) { active.refresh(); }
        });
      }
      return mount(container, ctx);
    },
    logic: {
      parseState: parseState, toParams: toParams, visibleRows: visibleRows, effectiveSort: effectiveSort,
      labelClasses: labelClasses, columns: COLUMNS, tieBreak: tieBreak, keyOf: keyOf, NONE: NONE,
    },
  });
}());
