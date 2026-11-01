// A small sortable, paged table that also draws its rows as cards (design Decision 16, Table).
// It knows nothing about Beads: a view hands it columns and a card builder. Sorting and paging
// are client-side, 50 rows at a time, so the DOM stays small and focus and screen readers keep
// working (no virtual scroll). Every value enters the page as a text node through noggingDom.
//
// window.noggingTable:
//   create(spec) -> {element, render(view)}
//     spec: {label, columns, card(row), href(row), onSort(key), onPage(page), onOpen(row),
//            pageSize (default 50), tieBreak(key) -> comparator or null}
//       column: {key, label, value(row) (the sort value; null sorts last), cell(row) -> node,
//                sortable (default true)}
//     view: {rows, sort: {key, dir: "asc"|"desc"}, page}  rows are already filtered.
//     render returns {page, pages, total, start, end} with the page clamped to what exists.
//   sortRows(rows, column, dir, tieBreak), pageSlice(total, page, size), compareValues(a, b)
(function () {
  "use strict";
  var PAGE_SIZE = 50;

  function missing(value) {
    return value === null || value === undefined || value === "" || (typeof value === "number" && isNaN(value));
  }

  // Numbers numerically, text without regard to case and with digits in runs ("SPEC-9" < "SPEC-10").
  function compareValues(a, b) {
    if (typeof a === "number" && typeof b === "number") {
      return a - b;
    }
    return String(a).localeCompare(String(b), "en", { sensitivity: "base", numeric: true });
  }

  // A missing value sorts last in either direction. Ties go to `tieBreak`, then to the Bead ID,
  // so the order never depends on the order the server sent.
  function sortRows(rows, column, dir, tieBreak) {
    var sign = dir === "desc" ? -1 : 1;
    return rows.slice().sort(function (a, b) {
      var left = column.value(a);
      var right = column.value(b);
      if (missing(left) !== missing(right)) {
        return missing(left) ? 1 : -1;
      }
      var order = missing(left) ? 0 : sign * compareValues(left, right);
      if (order === 0 && tieBreak) {
        order = tieBreak(a, b);
      }
      return order !== 0 ? order : compareValues(a.id, b.id);
    });
  }

  function pageSlice(total, page, size) {
    var pages = Math.max(1, Math.ceil(total / size));
    var current = Math.min(Math.max(1, Math.floor(page) || 1), pages);
    var start = (current - 1) * size;
    return { page: current, pages: pages, total: total, start: start, end: Math.min(total, start + size) };
  }

  function create(spec) {
    var D = window.noggingDom;
    var el = D.el;
    var size = spec.pageSize || PAGE_SIZE;
    var columns = spec.columns;
    var byKey = {};
    var heads = {};

    columns.forEach(function (column) { byKey[column.key] = column; });

    var headRow = el("tr", null, columns.map(function (column) {
      var th = el("th", { scope: "col", "class": "col-" + column.key });
      if (column.sortable === false) {
        th.appendChild(document.createTextNode(column.label));
        return th;
      }
      var mark = el("span", { "class": "sort-mark", "aria-hidden": "true" });
      var button = el("button", {
        type: "button", "class": "sort-btn", "data-focus": "sort:" + column.key,
        on: { click: function () { spec.onSort(column.key); } },
      }, column.label, mark);
      th.appendChild(button);
      heads[column.key] = { th: th, mark: mark };
      return th;
    }));
    var tbody = el("tbody");
    var table = el("table", { "class": "bead-table" },
      el("caption", { "class": "visually-hidden" }, spec.label),
      el("thead", null, headRow), tbody);
    var cards = el("ul", { "class": "bead-cards", "aria-label": spec.label });

    // A click that no link or button took opens the row, so a whole row or card is a target.
    function opens(node, row) {
      node.addEventListener("click", function (event) {
        var target = event.target;
        if (target && target.closest && target.closest("a, button, input, label")) {
          return;
        }
        spec.onOpen(row);
      });
    }

    var status = el("span", { "class": "pager-status" });
    var prev = el("button", { type: "button", "class": "btn btn-quiet", "data-focus": "page:prev" }, "Previous");
    var next = el("button", { type: "button", "class": "btn btn-quiet", "data-focus": "page:next" }, "Next");
    var pager = el("nav", { "class": "pager", "aria-label": "Pages" }, prev, status, next);
    var shown = { page: 1, pages: 1 };
    // aria-disabled and not `disabled`, so a button that was just used keeps keyboard focus.
    prev.addEventListener("click", function () {
      if (shown.page > 1) { spec.onPage(shown.page - 1); }
    });
    next.addEventListener("click", function () {
      if (shown.page < shown.pages) { spec.onPage(shown.page + 1); }
    });

    var element = el("div", { "class": "bead-results" }, el("div", { "class": "table-wrap" }, table), cards, pager);

    function render(view) {
      var column = byKey[view.sort.key] || columns[0];
      var sorted = sortRows(view.rows, column, view.sort.dir, spec.tieBreak ? spec.tieBreak(column.key) : null);
      var slice = pageSlice(sorted.length, view.page, size);
      Object.keys(heads).forEach(function (key) {
        var active = key === column.key;
        if (active) {
          heads[key].th.setAttribute("aria-sort", view.sort.dir === "desc" ? "descending" : "ascending");
        } else {
          heads[key].th.setAttribute("aria-sort", "none");
        }
        D.replace(heads[key].mark, active ? (view.sort.dir === "desc" ? "▼" : "▲") : "");
      });
      D.clear(tbody);
      D.clear(cards);
      sorted.slice(slice.start, slice.end).forEach(function (row) {
        var tr = el("tr", { "class": "bead-row" }, columns.map(function (col) {
          return el("td", { "class": "col-" + col.key }, col.cell(row));
        }));
        opens(tr, row);
        tbody.appendChild(tr);
        var card = el("li", { "class": "bead-card" }, spec.card(row));
        opens(card, row);
        cards.appendChild(card);
      });
      shown = slice;
      pager.hidden = slice.pages === 1;
      prev.setAttribute("aria-disabled", slice.page === 1 ? "true" : "false");
      next.setAttribute("aria-disabled", slice.page === slice.pages ? "true" : "false");
      D.replace(status, slice.total === 0 ? "" :
        (slice.start + 1) + "–" + slice.end + " of " + slice.total + " · Page " + slice.page + " of " + slice.pages);
      return slice;
    }

    return { element: element, render: render };
  }

  window.noggingTable = {
    create: create, sortRows: sortRows, pageSlice: pageSlice, compareValues: compareValues, PAGE_SIZE: PAGE_SIZE,
  };
}());
