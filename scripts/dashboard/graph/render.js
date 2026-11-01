// The graph view (design Decisions 11, 12 and 16): one change drawn as SVG from the positions
// the server computed. This file holds no layout: `x` and `y` are abstract units, scaled here to
// the node size of the device. Text enters the SVG as text nodes through dom.js.
//
// window.noggingGraph, for the other graph files:
//   draw(data, ctx) -> {element, svg, nodes}: the drawing of one /api/v1/graph answer.
//   hooks.drawn: functions called with that result after each draw, in order.
//   hooks.chooser: replaces the plain list of changes shown when the route names no scope.
(function () {
  "use strict";
  var App = window.noggingApp;
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var el = D.el;
  var svg = D.svg;

  var PHONE = "(max-width: 599px)";
  var SIZES = {
    desktop: { width: 200, height: 64, gapX: 72, gapY: 24, chars: 30 },
    phone: { width: 148, height: 56, gapX: 48, gapY: 16, chars: 21 },
  };
  var MARGIN = 20;
  var CHANGE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
  var hooks = { drawn: [], chooser: null };
  var refreshActive = null;

  function size() {
    return window.matchMedia(PHONE).matches ? SIZES.phone : SIZES.desktop;
  }

  // The centre of a slot in pixels.
  function centre(x, y, box) {
    return { x: MARGIN + x * (box.width + box.gapX) + box.width / 2, y: MARGIN + y * (box.height + box.gapY) + box.height / 2 };
  }

  // Straight through each slot of a long edge, curved across the gaps between layers.
  function edgePath(points, box) {
    var spots = points.map(function (point) { return centre(point[0], point[1], box); });
    if (spots.length === 1) {
      var top = spots[0].y - box.height / 2;
      return "M" + (spots[0].x + 24) + " " + top + " C" + (spots[0].x + 24) + " " + (top - box.gapY) + " " +
        (spots[0].x - 24) + " " + (top - box.gapY) + " " + (spots[0].x - 24) + " " + top;
    }
    var half = (spots[spots.length - 1].x >= spots[0].x ? 1 : -1) * box.width / 2;
    var path = "M" + (spots[0].x + half) + " " + spots[0].y;
    for (var index = 1; index < spots.length; index += 1) {
      var start = spots[index - 1].x + half;
      var end = spots[index].x - half;
      var middle = (start + end) / 2;
      path += " C" + middle + " " + spots[index - 1].y + " " + middle + " " + spots[index].y + " " + end + " " + spots[index].y;
      if (index < spots.length - 1) {
        path += " L" + (spots[index].x + half) + " " + spots[index].y;
      }
    }
    return path;
  }

  function arrow(id, name) {
    return svg("marker", { id: id, viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" },
      svg("path", { "class": name, d: "M0 0 L10 5 L0 10 Z" }));
  }

  function edgeClass(edge, closed) {
    var names = ["graph-edge"];
    if (edge.critical) {
      names.push("graph-edge-critical");
    }
    if (edge.reversed) {
      names.push("graph-edge-reversed");
    } else if (closed[edge.from] && closed[edge.to]) {
      names.push("graph-edge-closed");
    }
    return names.join(" ");
  }

  function drawEdge(edge, closed, box) {
    return svg("path", {
      "class": edgeClass(edge, closed), d: edgePath(edge.points, box), fill: "none",
      "marker-end": "url(#" + (edge.critical ? "graph-arrow-critical" : "graph-arrow") + ")",
    });
  }

  // At most two lines of about `chars` characters, broken at spaces, the last one cut with an ellipsis.
  function wrap(text, chars) {
    var words = text.split(/\s+/);
    var lines = [""];
    words.forEach(function (word) {
      var line = lines[lines.length - 1];
      if (line && (line + " " + word).length > chars) {
        lines.push(word);
      } else {
        lines[lines.length - 1] = line ? line + " " + word : word;
      }
    });
    var shown = lines.slice(0, 2);
    var last = shown.length - 1;
    if (lines.length > 2 || shown[last].length > chars) {
      shown[last] = shown[last].slice(0, chars - 1).replace(/\s+$/, "") + "…";
    }
    return shown;
  }

  function nodeName(node) {
    if (node.kind === "group") {
      return node.title;
    }
    return node.id + ", " + F.status(node.status) + ", " + F.title(node.title) +
      (node.kind === "ghost" ? ", outside this change" : "") + (node.critical ? ", on the longest dependency chain" : "");
  }

  function drawNode(node, ctx, box) {
    var spot = centre(node.x, node.y, box);
    var names = ["graph-node", "graph-" + node.kind, "status-" + (D.SHAPES[node.status] ? node.status : "unknown")];
    if (node.status === "closed") {
      names.push("graph-closed");
    }
    if (node.critical) {
      names.push("graph-critical");
    }
    var mark = D.statusMark(node.status);
    mark.setAttribute("x", 8);
    mark.setAttribute("y", 7);
    var title = node.kind === "group" ? node.title : F.title(node.title);
    var parts = [
      svg("title", null, nodeName(node)),
      svg("rect", { "class": "graph-box", width: box.width, height: box.height, rx: 6 }),
      mark,
      svg("text", { "class": "graph-id", x: 30, y: 20 }, node.kind === "group" ? "Closed" : node.id),
    ];
    wrap(title, box.chars).forEach(function (line, index) {
      parts.push(svg("text", { "class": "graph-title", x: 8, y: 37 + index * 15 }, line));
    });
    var attrs = {
      "class": names.join(" "), "data-id": node.id,
      transform: "translate(" + (spot.x - box.width / 2) + " " + (spot.y - box.height / 2) + ")",
    };
    if (node.kind !== "group") {
      attrs.role = "link";
      attrs.tabindex = 0;
      attrs["aria-label"] = nodeName(node);
      attrs.on = {
        click: function () { ctx.openDetail(node.id); },
        keydown: function (event) {
          if (event.key === "Enter") {
            ctx.openDetail(node.id);
          }
        },
      };
    }
    return svg("g", attrs, parts);
  }

  function lineSample(name, label) {
    return el("li", null,
      svg("svg", { width: 32, height: 12, viewBox: "0 0 32 12", "aria-hidden": "true", focusable: "false" },
        svg("line", { "class": name, x1: 1, y1: 6, x2: 31, y2: 6 })),
      el("span", null, label));
  }

  function legend() {
    return el("ul", { "class": "graph-legend", "aria-label": "Legend" },
      Object.keys(D.SHAPES).map(function (status) { return el("li", null, D.statusBadge(status)); }),
      lineSample("graph-edge graph-edge-critical", "Longest dependency chain"),
      lineSample("graph-edge", "Blocks"),
      lineSample("graph-edge graph-edge-closed", "Both ends closed"),
      lineSample("graph-edge graph-edge-reversed", "Reversed to break a cycle"),
      el("li", null, el("span", { "class": "graph-ghost-sample", "aria-hidden": "true" }), el("span", null, "Outside this change")));
  }

  // Why the drawing differs from the plain data: reported cycles, an unmarked chain, left-out nodes.
  function notices(data) {
    var found = [];
    var count = data.cycles.length;
    if (count) {
      found.push(el("div", { "class": "banner", role: "status" },
        "bd dep cycles reports " + count + " dependency cycle" + (count === 1 ? "" : "s") + ": " +
        data.cycles.map(function (cycle) { return cycle.concat(cycle[0]).join(" → "); }).join("; ") + "."));
    }
    if (data.edges.some(function (edge) { return edge.reversed; })) {
      found.push(el("div", { "class": "banner", role: "status" },
        "No longest dependency chain is marked because this scope contains a cycle. Reversed edges are dashed."));
    }
    if (data.hidden) {
      var drawn = data.total - data.hidden;
      found.push(el("p", { "class": "panel-meta" }, "Showing " + drawn + " of " + data.total + " nodes. " +
        data.hidden + " are hidden, in closed groups or left out to stay within 80."));
    }
    return found;
  }

  function draw(data, ctx) {
    var box = size();
    var right = 0;
    var bottom = 0;
    var closed = {};
    var nodes = {};
    data.nodes.forEach(function (node) {
      right = Math.max(right, node.x);
      bottom = Math.max(bottom, node.y);
      closed[node.id] = node.status === "closed";
    });
    var width = 2 * MARGIN + right * (box.width + box.gapX) + box.width;
    var height = 2 * MARGIN + bottom * (box.height + box.gapY) + box.height;
    var edges = svg("g", { "class": "graph-edges" }, data.edges.map(function (edge) { return drawEdge(edge, closed, box); }));
    var shapes = svg("g", { "class": "graph-nodes" }, data.nodes.map(function (node) {
      nodes[node.id] = drawNode(node, ctx, box);
      return nodes[node.id];
    }));
    var canvas = svg("svg", {
      "class": "graph-canvas", role: "group", "aria-label": "Dependency graph, left to right",
      width: width, height: height, viewBox: "0 0 " + width + " " + height,
    }, svg("defs", null, arrow("graph-arrow", "graph-arrow"), arrow("graph-arrow-critical", "graph-arrow-critical")), edges, shapes);
    var scroller = el("div", { "class": "graph-scroll" }, canvas);
    var drawing = { element: el("div", { "class": "graph" }, notices(data), scroller, legend()), svg: canvas, nodes: nodes, scroller: scroller };
    hooks.drawn.forEach(function (hook) { hook(drawing, data, ctx); });
    return drawing;
  }

  function summary(data) {
    var beads = data.nodes.filter(function (node) { return node.kind === "bead"; }).length;
    return beads + " Bead" + (beads === 1 ? "" : "s") + " · " + data.layers + " layer" + (data.layers === 1 ? "" : "s");
  }

  function closedLink(ctx, change, closed) {
    var next = closed === "collapse" ? "show" : "collapse";
    return el("a", { "class": "graph-toggle", href: ctx.link("graph", { scope: "change", id: change, closed: next === "collapse" ? next : null }) },
      next === "collapse" ? "Collapse closed Beads" : "Show closed Beads");
  }

  function mountChange(container, ctx, change) {
    var closed = ctx.params.get("closed") === "collapse" ? "collapse" : "show";
    var path = "/api/v1/graph?scope=" + encodeURIComponent("change:" + change) + (closed === "collapse" ? "&closed=collapse" : "");
    var name = "graph:" + change + ":" + closed;
    var panel = ctx.panel({ title: change });
    var media = window.matchMedia(PHONE);
    var last = null;
    var scroller = null;

    function build(envelope) {
      last = envelope;
      var data = envelope.data;
      panel.setMeta(summary(data));
      if (!data.nodes.length) {
        var state = envelope.sources && envelope.sources.beads && envelope.sources.beads.state;
        return el("div", { "class": "panel-state panel-empty" }, state === "loading" ? "Loading…" : "No Beads in this change.");
      }
      var keep = scroller ? { left: scroller.scrollLeft, top: scroller.scrollTop } : null;
      var drawing = draw(data, ctx);
      scroller = drawing.scroller;
      window.requestAnimationFrame(function () {
        if (keep && scroller === drawing.scroller) {
          scroller.scrollLeft = keep.left;
          scroller.scrollTop = keep.top;
        }
      });
      return drawing.element;
    }

    function redraw() {
      if (last) {
        panel.set("ready", build(last));
      }
    }

    container.appendChild(closedLink(ctx, change, closed));
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

  function mountChooser(container, ctx) {
    var panel = ctx.panel({ title: "Graph" });
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
  }

  App.store.subscribe(function (event) {
    if (refreshActive && event.changed.indexOf("beads") >= 0) {
      refreshActive();
    }
  });

  window.noggingGraph = { draw: draw, hooks: hooks };

  App.registerView("graph", {
    mount: function (container, ctx) {
      var change = ctx.params.get("scope") === "change" ? ctx.params.get("id") : null;
      if (change && CHANGE.test(change)) {
        return mountChange(container, ctx, change);
      }
      return (hooks.chooser || mountChooser)(container, ctx);
    },
  });
}());
