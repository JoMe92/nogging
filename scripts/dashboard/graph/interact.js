// Pan, zoom and keyboard for the drawn graph (design Decision 16, Graph). It hangs on the draw hook
// of render.js and adds nothing the data needs: the drawing is complete without it. Pointer Events
// carry mouse, touch and pen alike: one pointer pans, two pinch, a wheel zooms at the cursor, a
// double tap zooms 2x, and the keyboard moves between nodes. The viewport is one SVG group with a
// transform attribute, since the CSP forbids inline style. Nothing here fetches or writes.
//
// window.noggingGraph.tools(drawing) -> the toolbar above the drawing, made on first use, for list.js.
(function () {
  "use strict";
  var G = window.noggingGraph;
  if (!G) {
    return;
  }
  var D = window.noggingDom;
  var el = D.el;
  var svg = D.svg;

  var MIN_SCALE = 0.15;
  var MAX_SCALE = 4;
  var BUTTON_STEP = 1.4;
  var DOUBLE_TAP = 2;
  var TAP_SLOP = 6;
  var DOUBLE_TAP_MS = 320;
  var DOUBLE_TAP_REACH = 32;
  var KEY_PAN = 80;
  var KEEP_VISIBLE = 120;
  var PAD = 16;
  var TWEEN_MS = 180;
  var PHONE = "(max-width: 599px) and (orientation: portrait)";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var saved = {};

  G.tools = function (drawing) {
    if (!drawing.tools) {
      drawing.tools = el("div", { "class": "graph-tools", role: "toolbar", "aria-label": "Graph controls" });
      drawing.element.insertBefore(drawing.tools, drawing.scroller);
    }
    return drawing.tools;
  };

  function clamp(value, low, high) {
    return Math.min(Math.max(value, low), high);
  }

  // The pixel box of every node, read back from the drawing so this file knows no node size.
  function boxes(drawing) {
    var found = {};
    Object.keys(drawing.nodes).forEach(function (id) {
      var shape = drawing.nodes[id];
      var at = /translate\(\s*(-?[\d.]+)[\s,]+(-?[\d.]+)\s*\)/.exec(shape.getAttribute("transform") || "");
      var box = shape.querySelector(".graph-box");
      if (at && box) {
        found[id] = { x: Number(at[1]), y: Number(at[2]), w: Number(box.getAttribute("width")), h: Number(box.getAttribute("height")) };
      }
    });
    return found;
  }

  // The layers left to right: each with the pixel span it covers, and whether it holds open work.
  function layers(data, spots) {
    var byX = {};
    data.nodes.forEach(function (node) {
      var spot = spots[node.id];
      if (!spot) {
        return;
      }
      var layer = byX[node.x] = byX[node.x] || { x: node.x, left: Infinity, right: -Infinity, open: false };
      layer.left = Math.min(layer.left, spot.x);
      layer.right = Math.max(layer.right, spot.x + spot.w);
      layer.open = layer.open || (node.kind !== "group" && node.status !== "closed");
    });
    return Object.keys(byX).map(function (x) { return byX[x]; }).sort(function (a, b) { return a.x - b.x; });
  }

  // The node to move to: the nearest in the half plane of the arrow, a sideways step costing double.
  function neighbour(from, nodes, arrow) {
    var horizontal = arrow === "ArrowLeft" || arrow === "ArrowRight";
    var sign = arrow === "ArrowLeft" || arrow === "ArrowUp" ? -1 : 1;
    var best = null;
    var bestScore = Infinity;
    nodes.forEach(function (node) {
      var main = (horizontal ? node.x - from.x : node.y - from.y) * sign;
      var side = Math.abs(horizontal ? node.y - from.y : node.x - from.x);
      var score = main + 2 * side;
      if (main > 0 && (score < bestScore || (score === bestScore && node.id < best.id))) {
        best = node;
        bestScore = score;
      }
    });
    return best;
  }

  function first(nodes) {
    return nodes.slice().sort(function (a, b) { return a.x - b.x || a.y - b.y || (a.id < b.id ? -1 : 1); })[0] || null;
  }

  G.hooks.drawn.push(function (drawing, data, ctx) {
    var stage = drawing.scroller;
    var canvas = drawing.svg;
    var width = Number(canvas.getAttribute("width"));
    var height = Number(canvas.getAttribute("height"));
    var spots = boxes(drawing);
    var steps = layers(data, spots);
    var key = [data.scope, ctx.params.get("depth") || "", ctx.params.get("closed") || ""].join("|");
    var view = saved[key] || (saved[key] = { k: 1, x: 0, y: 0, auto: true });
    var pointers = {};
    var gesture = null;
    var lastTap = null;
    var swallow = false;
    var sized = false;
    var tween = null;
    var current = 0;

    canvas.removeAttribute("viewBox");
    var layer = svg("g", { "class": "graph-viewport" });
    Array.prototype.slice.call(canvas.childNodes).forEach(function (child) {
      if (child.nodeName !== "defs") {
        layer.appendChild(child);
      }
    });
    canvas.appendChild(layer);
    stage.classList.add("graph-stage");
    stage.setAttribute("tabindex", "0");
    stage.setAttribute("role", "group");
    stage.setAttribute("aria-label", "Graph. Arrow keys move between nodes, Shift and arrow keys pan, plus and minus zoom, 0 fits, Enter opens a Bead.");

    var label = el("span", { "class": "graph-stepper-label", role: "status" });
    var previous = tool("Previous layer", "‹", function () { stepTo(current - 1); }, "graph-step");
    var next = tool("Next layer", "›", function () { stepTo(current + 1); }, "graph-step");
    var stepper = el("div", { "class": "graph-stepper", role: "group", "aria-label": "Layers", hidden: steps.length < 2 }, previous, label, next);
    var zoom = el("div", { "class": "graph-zoomtools", role: "group", "aria-label": "Zoom" },
      tool("Zoom in", "+", function () { zoomBy(BUTTON_STEP, true); }),
      tool("Zoom out", "−", function () { zoomBy(1 / BUTTON_STEP, true); }),
      tool("Fit to screen", "Fit", function () { view.auto = true; place(true); }));
    var tools = G.tools(drawing);
    tools.appendChild(zoom);
    tools.appendChild(stepper);

    function tool(name, text, run, extra) {
      return el("button", { type: "button", "class": "btn btn-quiet graph-tool " + (extra || ""), "aria-label": name, on: { click: run } }, text);
    }

    function paint() {
      layer.setAttribute("transform", "translate(" + view.x + " " + view.y + ") scale(" + view.k + ")");
      current = Math.max(steps.length - 1, 0);
      for (var index = 0; index < steps.length; index += 1) {
        if (steps[index].right * view.k + view.x > 8) {
          current = index;
          break;
        }
      }
      D.replace(label, "Layer " + (current + 1) + " of " + steps.length);
      previous.disabled = current <= 0;
      next.disabled = current >= steps.length - 1;
    }

    // Keep part of the drawing in sight, so a pan can never lose it.
    function keep() {
      var room = Math.min(KEEP_VISIBLE, stage.clientWidth / 2, stage.clientHeight / 2);
      view.x = clamp(view.x, room - width * view.k, stage.clientWidth - room);
      view.y = clamp(view.y, room - height * view.k, stage.clientHeight - room);
    }

    function cancel() {
      if (tween) {
        window.cancelAnimationFrame(tween);
        tween = null;
      }
    }

    function show(target, smooth) {
      cancel();
      var from = { k: view.k, x: view.x, y: view.y };
      var begin = null;
      if (!smooth || reduced.matches) {
        view.k = target.k;
        view.x = target.x;
        view.y = target.y;
        keep();
        paint();
        return;
      }
      (function frame(now) {
        begin = begin === null ? now : begin;
        var done = Math.min((now - begin) / TWEEN_MS, 1);
        var eased = 1 - Math.pow(1 - done, 3);
        view.k = from.k + (target.k - from.k) * eased;
        view.x = from.x + (target.x - from.x) * eased;
        view.y = from.y + (target.y - from.y) * eased;
        keep();
        paint();
        tween = done < 1 ? window.requestAnimationFrame(frame) : null;
      }(window.performance.now()));
    }

    // Zoom about a point of the stage; the world point under it stays under it.
    function zoomed(factor, cx, cy) {
      var scale = clamp(view.k * factor, MIN_SCALE, MAX_SCALE);
      var ratio = scale / view.k;
      return { k: scale, x: cx - (cx - view.x) * ratio, y: cy - (cy - view.y) * ratio };
    }

    function zoomBy(factor, smooth, cx, cy) {
      view.auto = false;
      show(zoomed(factor, cx === undefined ? stage.clientWidth / 2 : cx, cy === undefined ? stage.clientHeight / 2 : cy), smooth);
    }

    function fit() {
      var scale = clamp(Math.min(stage.clientWidth / width, stage.clientHeight / height), MIN_SCALE, 1);
      return { k: scale, x: (stage.clientWidth - width * scale) / 2, y: (stage.clientHeight - height * scale) / 2 };
    }

    // On a phone held upright the flow keeps its height and its first layer with open work
    // sits at the left edge; "Layer 2 of 7" then steps from there.
    function start() {
      var all = fit();
      var scale = clamp(Math.min(stage.clientHeight / height, 1), MIN_SCALE, 1);
      if (!window.matchMedia(PHONE).matches || all.k >= scale - 0.001 || !steps.length) {
        return all;
      }
      var index = 0;
      steps.some(function (step, at) {
        index = at;
        return step.open;
      });
      return { k: scale, x: PAD - steps[index].left * scale, y: (stage.clientHeight - height * scale) / 2 };
    }

    function place(smooth) {
      if (!stage.clientWidth || !stage.clientHeight) {
        return;
      }
      show(view.auto ? start() : view, smooth);
    }

    function stepTo(index) {
      var target = steps[clamp(index, 0, steps.length - 1)];
      if (target) {
        view.auto = false;
        show({ k: view.k, x: PAD - target.left * view.k, y: view.y }, true);
      }
    }

    function reveal(id) {
      var spot = spots[id];
      if (!spot) {
        return;
      }
      var left = spot.x * view.k + view.x;
      var top = spot.y * view.k + view.y;
      var x = view.x;
      var y = view.y;
      if (left < PAD) {
        x += PAD - left;
      } else if (left + spot.w * view.k > stage.clientWidth - PAD) {
        x -= left + spot.w * view.k - (stage.clientWidth - PAD);
      }
      if (top < PAD) {
        y += PAD - top;
      } else if (top + spot.h * view.k > stage.clientHeight - PAD) {
        y -= top + spot.h * view.k - (stage.clientHeight - PAD);
      }
      if (x !== view.x || y !== view.y) {
        view.auto = false;
        show({ k: view.k, x: x, y: y }, true);
      }
    }

    function rect() {
      return stage.getBoundingClientRect();
    }

    function sizeKnown() {
      if (!sized && stage.clientWidth > 0 && stage.clientHeight > 0) {
        sized = true;
        place(false);
      }
    }

    /* ------------------------------------------------------------ pointers */

    function pinch() {
      var ids = Object.keys(pointers);
      var a = pointers[ids[0]];
      var b = pointers[ids[1]];
      var box = rect();
      return { distance: Math.max(Math.hypot(a.x - b.x, a.y - b.y), 1), x: (a.x + b.x) / 2 - box.left, y: (a.y + b.y) / 2 - box.top };
    }

    stage.addEventListener("pointerdown", function (event) {
      if (event.pointerType === "mouse" && event.button !== 0) {
        return;
      }
      cancel();
      pointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      var count = Object.keys(pointers).length;
      if (count === 1) {
        gesture = { moved: false, x: event.clientX, y: event.clientY, from: { x: view.x, y: view.y } };
      } else if (count === 2) {
        var now = pinch();
        gesture = { moved: true, pinching: true, distance: now.distance, k: view.k,
          world: { x: (now.x - view.x) / view.k, y: (now.y - view.y) / view.k } };
        Object.keys(pointers).forEach(function (id) {
          try { stage.setPointerCapture(Number(id)); } catch (ignored) { /* the pointer already ended */ }
        });
      }
    });

    stage.addEventListener("pointermove", function (event) {
      if (!pointers[event.pointerId] || !gesture) {
        return;
      }
      pointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      view.auto = false;
      if (gesture.pinching) {
        if (Object.keys(pointers).length === 2) {
          var now = pinch();
          view.k = clamp(gesture.k * now.distance / gesture.distance, MIN_SCALE, MAX_SCALE);
          view.x = now.x - gesture.world.x * view.k;
          view.y = now.y - gesture.world.y * view.k;
          keep();
          paint();
        }
        return;
      }
      var dx = event.clientX - gesture.x;
      var dy = event.clientY - gesture.y;
      if (!gesture.moved && Math.hypot(dx, dy) > TAP_SLOP) {
        gesture.moved = true;
        stage.classList.add("graph-panning");
        try { stage.setPointerCapture(event.pointerId); } catch (ignored) { /* the pointer already ended */ }
      }
      if (gesture.moved) {
        view.x = gesture.from.x + dx;
        view.y = gesture.from.y + dy;
        keep();
        paint();
      }
    });

    function release(event) {
      var known = pointers[event.pointerId];
      if (!known) {
        return;
      }
      delete pointers[event.pointerId];
      var left = Object.keys(pointers);
      if (gesture && gesture.pinching && left.length === 1) {
        var only = pointers[left[0]];
        gesture = { moved: true, x: only.x, y: only.y, from: { x: view.x, y: view.y } };
        return;
      }
      if (left.length) {
        return;
      }
      var done = gesture;
      gesture = null;
      stage.classList.remove("graph-panning");
      if (done && done.moved) {
        swallow = true;
        window.setTimeout(function () { swallow = false; }, 50);
      } else if (done && event.type === "pointerup" && event.pointerType !== "mouse") {
        var box = rect();
        var now = window.performance.now();
        if (lastTap && now - lastTap.at < DOUBLE_TAP_MS && Math.hypot(event.clientX - lastTap.x, event.clientY - lastTap.y) < DOUBLE_TAP_REACH) {
          lastTap = null;
          zoomBy(DOUBLE_TAP, true, event.clientX - box.left, event.clientY - box.top);
        } else {
          lastTap = { at: now, x: event.clientX, y: event.clientY };
        }
      }
    }
    stage.addEventListener("pointerup", release);
    stage.addEventListener("pointercancel", release);

    // A drag that ended over a node must not also open it.
    stage.addEventListener("click", function (event) {
      if (swallow) {
        event.stopPropagation();
        event.preventDefault();
        swallow = false;
      }
    }, true);

    stage.addEventListener("wheel", function (event) {
      event.preventDefault();
      cancel();
      var unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 400 : 1;
      var box = rect();
      zoomBy(Math.exp(-event.deltaY * unit * (event.ctrlKey ? 0.01 : 0.0015)), false, event.clientX - box.left, event.clientY - box.top);
    }, { passive: false });

    /* ------------------------------------------------------------ keyboard */

    function focusable() {
      return data.nodes.filter(function (node) { return drawing.nodes[node.id] && drawing.nodes[node.id].hasAttribute("tabindex"); });
    }

    function moveFocus(arrow) {
      var nodes = focusable();
      var here = nodes.filter(function (node) { return drawing.nodes[node.id] === document.activeElement; })[0];
      var target = here ? neighbour(here, nodes, arrow) : first(nodes);
      if (target) {
        drawing.nodes[target.id].focus({ preventScroll: true });
        reveal(target.id);
      }
    }

    var PAN = { ArrowLeft: [KEY_PAN, 0], ArrowRight: [-KEY_PAN, 0], ArrowUp: [0, KEY_PAN], ArrowDown: [0, -KEY_PAN] };
    stage.addEventListener("keydown", function (event) {
      if (event.altKey || event.ctrlKey || event.metaKey) {
        return;
      }
      if (PAN[event.key]) {
        if (event.shiftKey) {
          view.auto = false;
          show({ k: view.k, x: view.x + PAN[event.key][0], y: view.y + PAN[event.key][1] }, true);
        } else {
          moveFocus(event.key);
        }
      } else if (event.key === "+" || event.key === "=") {
        zoomBy(BUTTON_STEP, true);
      } else if (event.key === "-" || event.key === "_") {
        zoomBy(1 / BUTTON_STEP, true);
      } else if (event.key === "0") {
        view.auto = true;
        place(true);
      } else {
        return;
      }
      event.preventDefault();
    });

    stage.addEventListener("focusin", function (event) {
      var shape = event.target.closest ? event.target.closest(".graph-node") : null;
      if (shape) {
        reveal(shape.getAttribute("data-id"));
      }
    });

    /* ------------------------------------------------------------ size */

    paint();
    if (typeof window.ResizeObserver === "function") {
      new window.ResizeObserver(function () {
        if (sized) {
          place(false);
        } else {
          sizeKnown();
        }
      }).observe(stage);
    }
    window.requestAnimationFrame(sizeKnown);
  });
}());
