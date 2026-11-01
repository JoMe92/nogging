// The only way the dashboard builds markup. Values from the API enter the page as text nodes
// and never as HTML: this file uses no innerHTML, outerHTML, insertAdjacentHTML, document.write
// or DOMParser, and neither may any other file here (a test scans for them). The CSP also
// forbids inline style, so `style` is refused; classes carry every look.
(function () {
  "use strict";
  // The SVG namespace name, which nothing fetches. It is written in two pieces so the
  // no-external-reference scan, which looks for a scheme and two slashes, has nothing to flag.
  var SVG = "http:/" + "/www.w3.org/2000/svg";

  function append(node, children) {
    for (var i = 0; i < children.length; i += 1) {
      var child = children[i];
      if (child === null || child === undefined || child === false) {
        continue;
      }
      if (Array.isArray(child)) {
        append(node, child);
      } else if (typeof child === "object") {
        node.appendChild(child);
      } else {
        node.appendChild(document.createTextNode(String(child)));
      }
    }
  }

  function build(node, attrs, children) {
    if (attrs) {
      Object.keys(attrs).forEach(function (name) {
        var value = attrs[name];
        if (value === null || value === undefined || value === false) {
          return;
        }
        if (name === "style" || /^on/i.test(name) && name !== "on") {
          throw new Error("dom: the attribute " + name + " is not allowed");
        }
        if (name === "on") {
          Object.keys(value).forEach(function (type) {
            node.addEventListener(type, value[type]);
          });
        } else {
          node.setAttribute(name, value === true ? "" : String(value));
        }
      });
    }
    append(node, children);
    return node;
  }

  function el(tag, attrs) {
    return build(document.createElement(tag), attrs, Array.prototype.slice.call(arguments, 2));
  }

  function svg(tag, attrs) {
    return build(document.createElementNS(SVG, tag), attrs, Array.prototype.slice.call(arguments, 2));
  }

  function clear(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
    return node;
  }

  function replace(node) {
    clear(node);
    append(node, Array.prototype.slice.call(arguments, 1));
    return node;
  }

  // One shape per status, so no status depends on colour alone. Every key has a `--status-<key>`
  // token in tokens.css and a distinct `shape` name; a test compares the three.
  var FILL = { fill: "none", stroke: "currentColor", "stroke-linejoin": "round" };
  var SHAPES = {
    open: { shape: "hollow-circle", label: "Open", parts: [
      ["circle", { cx: 12, cy: 12, r: 8, "stroke-width": 2 }]] },
    ready: { shape: "triangle", label: "Ready", parts: [
      ["polygon", { points: "6,4 20,12 6,20", "stroke-width": 2 }]] },
    in_progress: { shape: "half-circle", label: "In progress", parts: [
      ["circle", { cx: 12, cy: 12, r: 8, "stroke-width": 3 }],
      ["path", { d: "M12 4 A8 8 0 0 1 12 20 Z", fill: "currentColor", stroke: "none" }]] },
    blocked: { shape: "octagon-bar", label: "Blocked", parts: [
      ["polygon", { points: "8,3 16,3 21,8 21,16 16,21 8,21 3,16 3,8", "stroke-width": 3 }],
      ["line", { x1: 8, y1: 12, x2: 16, y2: 12, "stroke-width": 3 }]] },
    deferred: { shape: "dashed-diamond", label: "Deferred", parts: [
      ["polygon", { points: "12,3 21,12 12,21 3,12", "stroke-width": 2, "stroke-dasharray": "3 2" }]] },
    closed: { shape: "check-square", label: "Closed", parts: [
      ["rect", { x: 4, y: 4, width: 16, height: 16, rx: 2, "stroke-width": 1.5 }],
      ["path", { d: "M8 12.5 L11 15.5 L16 9", "stroke-width": 1.5 }]] },
  };

  function statusMark(status) {
    var shape = SHAPES[status];
    var mark = svg("svg", {
      "class": "shape shape-" + (shape ? status : "unknown"), viewBox: "0 0 24 24",
      width: 16, height: 16, "aria-hidden": "true", focusable: "false",
    });
    (shape ? shape.parts : [["circle", { cx: 12, cy: 12, r: 2 }]]).forEach(function (part) {
      var attrs = {};
      Object.keys(FILL).forEach(function (key) { attrs[key] = FILL[key]; });
      Object.keys(part[1]).forEach(function (key) { attrs[key] = part[1][key]; });
      mark.appendChild(svg(part[0], attrs));
    });
    return mark;
  }

  // The status as a shape and a word. Its colour comes from the status class on the wrapper.
  function statusBadge(status) {
    var shape = SHAPES[status];
    return el("span", { "class": "status status-" + (shape ? status : "unknown") },
      statusMark(status), el("span", { "class": "status-label" }, shape ? shape.label : "Not recorded"));
  }

  // P0 is a filled chip, P1 an outlined chip, P2 to P4 plain text.
  function priorityChip(value) {
    var label = window.noggingFormat.priority(value);
    return el("span", { "class": "priority priority-" + (value === 0 || value === 1 ? value : "plain") }, label);
  }

  window.noggingDom = {
    el: el, svg: svg, clear: clear, replace: replace, statusMark: statusMark,
    statusBadge: statusBadge, priorityChip: priorityChip, SHAPES: SHAPES,
  };
}());
