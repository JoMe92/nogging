// Charts of the start page (design Decisions 10 and 16): bars, stacks, a histogram and the fixed
// readout. Every chart is SVG built through dom.js, so values enter as text. A chart takes
// finished numbers: bucketing happens in the view, the statistics on the server.
//
// A bucket is one of three things, and only the first is ever drawn as a bar:
//   a number         a real value, 0 included, because the source covers that period;
//   null             no data, drawn as a hatched band, never as a zero bar;
//   (absent series)  the source does not exist here; the view shows "not available here".
// A tap, a hover or the keyboard selects a bucket; its values appear in the readout under the chart.
//
// window.noggingCharts:
//   stacks({buckets, series, unit, label}) -> {element}
//     buckets: [{label, gap: bool, gapText}], series: [{key, label, className, values: [number|null]}]
//   bars({buckets, values, unit, label}) -> {element}  one series, class "series-1"
//   histogram({bins: [{label, count}], marks: [{label, index}], unit, label}) -> {element}
//   rows({rows: [{label, value, href}], unit, label}) -> {element}  horizontal bars, one per row
//   tableToggle(chart, table) -> {element}  a chart with a "Table" button that swaps in `table`
//   table({head: [..], rows: [[..]], caption}) -> element
(function () {
  "use strict";
  var D = window.noggingDom;
  var el = D.el;
  var svg = D.svg;

  var WIDTH = 640;
  var HEIGHT = 180;
  var LEFT = 36;
  var TOP = 10;
  var BOTTOM = 22;
  var counter = 0;

  function niceMax(value) {
    if (!(value > 0)) {
      return 1;
    }
    var power = Math.pow(10, Math.floor(Math.log(value) / Math.LN10));
    var steps = [1, 2, 5, 10];
    for (var i = 0; i < steps.length; i += 1) {
      if (value <= steps[i] * power) {
        return steps[i] * power;
      }
    }
    return 10 * power;
  }

  // The fixed readout: always in the layout, so a selection moves no content.
  function readoutBox() {
    return el("p", { "class": "chart-readout", "aria-live": "polite" }, "Select a bar to read its values.");
  }

  function describe(bucket, series, index, unit) {
    if (bucket.gap) {
      return bucket.label + ": " + (bucket.gapText || "no data");
    }
    var parts = series.map(function (item) {
      var value = item.values[index];
      return item.label + " " + (value === null || value === undefined ? "no data" : value);
    });
    return bucket.label + ": " + parts.join(", ") + (unit ? " " + unit : "");
  }

  function stacks(options) {
    var buckets = options.buckets;
    var series = options.series;
    var count = Math.max(1, buckets.length);
    var totals = buckets.map(function (bucket, index) {
      return series.reduce(function (sum, item) {
        var value = item.values[index];
        return sum + (typeof value === "number" ? value : 0);
      }, 0);
    });
    var top = niceMax(Math.max.apply(null, totals.concat([0])));
    var plotW = WIDTH - LEFT;
    var plotH = HEIGHT - TOP - BOTTOM;
    var step = plotW / count;
    var barW = Math.max(1, step * 0.8);
    var readout = readoutBox();
    var selected = null;
    var chart = svg("svg", {
      "class": "chart", viewBox: "0 0 " + WIDTH + " " + HEIGHT, role: "group",
      "aria-label": options.label || "Chart", preserveAspectRatio: "xMidYMid meet",
    });
    // The hatch that marks a gap. It is its own pattern per chart, so ids never collide.
    counter += 1;
    var hatch = "chart-hatch-" + counter;
    chart.appendChild(svg("defs", null, svg("pattern", { id: hatch, width: 6, height: 6, patternUnits: "userSpaceOnUse" },
      svg("rect", { "class": "chart-hatch-ground", width: 6, height: 6 }),
      svg("path", { "class": "chart-hatch-line", d: "M0 6 L6 0" }))));
    chart.appendChild(svg("line", { "class": "chart-axis", x1: LEFT, y1: TOP + plotH, x2: WIDTH, y2: TOP + plotH }));
    chart.appendChild(svg("text", { "class": "chart-tick", x: LEFT - 4, y: TOP + 8, "text-anchor": "end" }, String(top)));
    chart.appendChild(svg("text", { "class": "chart-tick", x: LEFT - 4, y: TOP + plotH, "text-anchor": "end" }, "0"));
    var groups = buckets.map(function (bucket, index) {
      var x = LEFT + index * step + (step - barW) / 2;
      var group = svg("g", { "class": "chart-bucket", tabindex: index === 0 ? 0 : -1, role: "img",
        "aria-label": describe(bucket, series, index, options.unit) });
      group.appendChild(svg("rect", { "class": "chart-hit", x: LEFT + index * step, y: TOP, width: step, height: plotH }));
      if (bucket.gap) {
        group.appendChild(svg("rect", { "class": "chart-gap", fill: "url(#" + hatch + ")", x: x, y: TOP, width: barW, height: plotH }));
      } else {
        var base = TOP + plotH;
        series.forEach(function (item) {
          var value = item.values[index];
          if (typeof value !== "number" || value <= 0) {
            return;
          }
          var height = Math.max(1, value / top * plotH);
          base -= height;
          group.appendChild(svg("rect", { "class": "chart-bar " + item.className, x: x, y: base, width: barW, height: height }));
        });
      }
      function select() {
        if (selected !== null) {
          groups[selected].classList.remove("chart-selected");
        }
        selected = index;
        group.classList.add("chart-selected");
        D.replace(readout, describe(bucket, series, index, options.unit));
      }
      group.addEventListener("click", select);
      group.addEventListener("mouseenter", select);
      group.addEventListener("focus", select);
      group.addEventListener("keydown", function (event) {
        var next = event.key === "ArrowRight" ? index + 1 : event.key === "ArrowLeft" ? index - 1 : null;
        if (next !== null && next >= 0 && next < groups.length) {
          event.preventDefault();
          groups[index].setAttribute("tabindex", "-1");
          groups[next].setAttribute("tabindex", "0");
          groups[next].focus();
        }
      });
      chart.appendChild(group);
      return group;
    });
    if (buckets.length) {
      chart.appendChild(svg("text", { "class": "chart-tick", x: LEFT, y: HEIGHT - 6 }, buckets[0].label));
      chart.appendChild(svg("text", { "class": "chart-tick", x: WIDTH, y: HEIGHT - 6, "text-anchor": "end" },
        buckets[buckets.length - 1].label));
    }
    var legend = series.length > 1 ? el("ul", { "class": "chart-legend" }, series.map(function (item) {
      return el("li", null, el("span", { "class": "chart-key " + item.className, "aria-hidden": "true" }), item.label);
    })) : null;
    return { element: el("div", { "class": "chart-wrap" }, chart, readout, legend) };
  }

  function bars(options) {
    return stacks({
      buckets: options.buckets, unit: options.unit, label: options.label,
      series: [{ key: "value", label: options.seriesLabel || "Value", className: "series-1", values: options.values }],
    });
  }

  // The histogram of cycle or lead time: one bar per bin, and a vertical mark inside the bin
  // that holds the median and the p90. Marks are labelled in text, not only drawn.
  function histogram(options) {
    var bins = options.bins;
    var buckets = bins.map(function (bin) { return { label: bin.label, gap: false }; });
    var built = stacks({
      buckets: buckets, unit: options.unit, label: options.label,
      series: [{ key: "count", label: "Beads", className: "series-1", values: bins.map(function (bin) { return bin.count; }) }],
    });
    var chart = built.element.querySelector("svg");
    var step = (WIDTH - LEFT) / Math.max(1, bins.length);
    (options.marks || []).forEach(function (mark, order) {
      if (mark.index === null || mark.index === undefined) {
        return;
      }
      var x = LEFT + (mark.index + 0.5) * step;
      chart.appendChild(svg("line", { "class": "chart-mark chart-mark-" + (order + 1), x1: x, y1: TOP, x2: x, y2: HEIGHT - BOTTOM }));
      chart.appendChild(svg("text", { "class": "chart-mark-label", x: x + 3, y: TOP + 10 + order * 12 }, mark.label));
    });
    return built;
  }

  function rows(options) {
    var max = Math.max.apply(null, options.rows.map(function (row) { return row.value; }).concat([1]));
    var list = el("ul", { "class": "rows", "aria-label": options.label || "Rows" }, options.rows.map(function (row) {
      var label = row.href ? el("a", { href: row.href }, row.label) : el("span", null, row.label);
      var track = svg("svg", { "class": "rows-bar", viewBox: "0 0 100 8", preserveAspectRatio: "none", "aria-hidden": "true", focusable: "false" },
        svg("rect", { "class": "chart-bar series-1", x: 0, y: 0, width: Math.max(1, row.value / max * 100), height: 8 }));
      return el("li", null, el("span", { "class": "rows-label" }, label), track,
        el("span", { "class": "rows-value" }, row.value + (options.unit ? " " + options.unit : "")));
    }));
    return { element: list };
  }

  function table(options) {
    return el("table", { "class": "data-table" },
      options.caption ? el("caption", null, options.caption) : null,
      el("thead", null, el("tr", null, options.head.map(function (cell) { return el("th", { scope: "col" }, cell); }))),
      el("tbody", null, options.rows.map(function (row) {
        return el("tr", null, row.map(function (cell, index) {
          return index === 0 ? el("th", { scope: "row" }, cell) : el("td", null, cell);
        }));
      })));
  }

  // A chart with a Table button that shows the same numbers as a real table. The button keeps
  // focus, says which view is on, and the chart stays in the page so the toggle is instant.
  function tableToggle(chart, tableNode) {
    var showing = false;
    var holder = el("div", { "class": "chart-holder" }, chart.element || chart);
    var button = el("button", { type: "button", "class": "btn btn-quiet table-toggle", "aria-pressed": "false" }, "Table");
    button.addEventListener("click", function () {
      showing = !showing;
      button.setAttribute("aria-pressed", showing ? "true" : "false");
      D.replace(holder, showing ? tableNode : chart.element || chart);
    });
    return { element: el("div", { "class": "chart-block" }, el("div", { "class": "chart-tools" }, button), holder) };
  }

  window.noggingCharts = {
    stacks: stacks, bars: bars, histogram: histogram, rows: rows, table: table, tableToggle: tableToggle,
  };
}());
