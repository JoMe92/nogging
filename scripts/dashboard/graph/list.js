// The text alternative to the graph (design Decision 16, Graph): the same nodes as an ordered
// list in topological order, each with its status and "Blocked by: …". It hangs on the draw
// hook of render.js, so it follows every scope and every redraw. The choice between the
// graph and the list outlives a redraw, so a refresh does not flip the page back.
(function () {
  "use strict";
  var G = window.noggingGraph;
  if (!G) {
    return;
  }
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var el = D.el;
  var showList = false;

  // Edges point from blocker to blocked and run left to right, so layer, then row, then ID is a
  // topological order. A reversed edge (a cycle broken for layout) is still blocker to blocked.
  function ordered(nodes) {
    return nodes.slice().sort(function (a, b) {
      return a.x - b.x || a.y - b.y || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    });
  }

  function blockers(data) {
    var found = {};
    data.edges.forEach(function (edge) {
      (found[edge.to] = found[edge.to] || []).push(edge.from);
    });
    return found;
  }

  function item(node, names, blocked, ctx) {
    var group = node.kind === "group";
    var by = (blocked[node.id] || []).map(function (id) { return names[id]; }).sort();
    var label = group
      ? el("span", { "class": "graph-list-id" }, node.title)
      : el("button", { type: "button", "class": "graph-list-id", on: { click: function () { ctx.openDetail(node.id); } } }, node.id);
    return el("li", { "class": "graph-list-item" + (node.status === "closed" ? " graph-list-closed" : ""), "data-id": node.id },
      D.statusBadge(node.status),
      label,
      group ? null : el("span", { "class": "graph-list-title" }, F.title(node.title)),
      node.kind === "ghost" ? el("span", { "class": "panel-meta" }, "Outside this scope") : null,
      node.critical ? el("span", { "class": "panel-meta" }, "On the longest chain") : null,
      el("span", { "class": "graph-list-blocked" }, "Blocked by: " + (by.length ? by.join(", ") : "none")));
  }

  function list(data, ctx) {
    var names = {};
    data.nodes.forEach(function (node) { names[node.id] = node.kind === "group" ? node.title : node.id; });
    var blocked = blockers(data);
    return el("ol", { "class": "graph-list", "aria-label": "Beads in dependency order" },
      ordered(data.nodes).map(function (node) { return item(node, names, blocked, ctx); }));
  }

  G.hooks.drawn.push(function (drawing, data, ctx) {
    var text = list(data, ctx);
    var toggle = el("button", { type: "button", "class": "btn btn-quiet graph-view-toggle" });
    function apply() {
      drawing.element.classList.toggle("graph-list-mode", showList);
      text.hidden = !showList;
      D.replace(toggle, showList ? "Show graph" : "Show list");
    }
    toggle.addEventListener("click", function () {
      showList = !showList;
      apply();
    });
    var tools = G.tools ? G.tools(drawing) : null;
    if (tools) {
      tools.appendChild(toggle);
    } else {
      drawing.element.insertBefore(el("div", { "class": "graph-tools" }, toggle), drawing.scroller);
    }
    drawing.scroller.parentNode.insertBefore(text, drawing.scroller.nextSibling);
    apply();
  });
}());
