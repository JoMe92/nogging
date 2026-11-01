// The start page, panels 1 to 6 (design Decisions 10 and 16): Beads by status, project age,
// closed over time, closed by change, cycle and lead time, and the activity timeline. Panels 7 to
// 11 belong to start-usage.js, which adds its own panels through window.noggingStart.
//
// The page reads /api/v1/summary?range=<r>. The server does the statistics; this file buckets
// closed Beads by day or week in the browser and draws. A missing period is a gap, a missing
// source reads "not available here", and nothing missing is ever drawn or written as a zero.
//
// window.noggingStart, for start-usage.js:
//   extras: functions called with {ctx, grid, fetch} after the six panels are placed.
//   sourceNote(envelope, names) -> text of the freshness of those sources.
//   show(panel, result, names, block, build, emptyText) maps a block and its source states to a panel state.
//   daily(...), group(...) bucketing helpers.
(function () {
  "use strict";
  var App = window.noggingApp;
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var C = window.noggingCharts;
  var el = D.el;

  var RANGES = [["7d", "7 days"], ["30d", "30 days"], ["90d", "90 days"], ["all", "All"]];
  var GROUPS = [["day", "Day"], ["week", "Week"]];
  var STATUS_ORDER = ["open", "in_progress", "blocked", "closed", "deferred"];
  var SOURCE_NAMES = { beads: "Beads", sessions: "Sessions", tests: "Tests", git: "Git", tokens: "Tokens" };
  var NOT_HERE = "Not available here.";
  var extras = [];
  var instance = null;

  /* ---------------------------------------------------------------- dates and buckets */

  function dayNumber(text) {
    var part = String(text).slice(0, 10).split("-");
    return Date.UTC(+part[0], +part[1] - 1, +part[2]) / 86400000;
  }

  function dayText(number) {
    return new Date(number * 86400000).toISOString().slice(0, 10);
  }

  function mondayOf(number) {
    return number - (new Date(number * 86400000).getUTCDay() + 6) % 7;
  }

  // One value per day from `first` to `last` (day numbers). A day before `floor` (a date text) or
  // with no source at all has the value null, a gap.
  function daily(counts, floor, first, last) {
    var from = floor ? dayNumber(floor) : null;
    var days = [];
    var values = [];
    for (var day = first; day <= last; day += 1) {
      days.push(day);
      values.push(from === null || day < from ? null : counts[dayText(day)] || 0);
    }
    return { days: days, values: values };
  }

  // Day or week buckets from daily values. A week is a gap only when no day of it has data; a
  // gap is never added into a sum.
  function group(days, values, unit, floor) {
    var gapText = floor ? "No data before " + String(floor).slice(0, 10) : "No data";
    var buckets = [];
    var out = [];
    if (unit === "week") {
      var byWeek = {};
      days.forEach(function (day, index) {
        var key = mondayOf(day);
        var slot = byWeek[key];
        if (!slot) {
          slot = byWeek[key] = { key: key, value: null };
          buckets.push(slot);
        }
        if (values[index] !== null) {
          slot.value = (slot.value || 0) + values[index];
        }
      });
      return {
        buckets: buckets.map(function (slot) {
          return { label: "Week of " + dayText(slot.key), gap: slot.value === null, gapText: gapText };
        }),
        values: buckets.map(function (slot) { return slot.value; }),
      };
    }
    days.forEach(function (day, index) {
      buckets.push({ label: dayText(day), gap: values[index] === null, gapText: gapText });
      out.push(values[index]);
    });
    return { buckets: buckets, values: out };
  }

  function duration(seconds) {
    if (typeof seconds !== "number") {
      return F.NOT_RECORDED;
    }
    if (seconds < 3600) {
      return Math.max(1, Math.round(seconds / 60)) + " min";
    }
    if (seconds < 86400) {
      return (Math.round(seconds / 360) / 10) + " h";
    }
    return (Math.round(seconds / 8640) / 10) + " d";
  }

  /* ---------------------------------------------------------------- panel states */

  function sourceNote(envelope, names) {
    if (!envelope) {
      return "";
    }
    return names.map(function (name) {
      var source = envelope.sources[name];
      var label = SOURCE_NAMES[name] || name;
      if (!source || source.state === "absent") {
        return label + ": not available here";
      }
      if (source.state === "stale") {
        return label + ": data may be stale, last update " + F.clock(source.as_of);
      }
      return source.as_of ? label + ": updated " + F.clock(source.as_of) : label + ": " + source.state;
    }).join(" · ");
  }

  // The state of a panel from its block and the states of the sources it reads.
  function show(panel, result, names, block, build, emptyText) {
    if (!result.ok) {
      if (result.status === 501) {
        panel.set("empty", "Not available yet.");
      } else {
        panel.set("error", {
          message: result.unreachable ? "Server not reachable." : "This panel could not load.",
          retry: function () { if (instance) { instance.load(true); } },
        });
      }
      return;
    }
    panel.setMeta(sourceNote(result.envelope, names));
    if (block.state === "absent") {
      var states = names.map(function (name) { return (result.envelope.sources[name] || { state: "absent" }).state; });
      if (states.indexOf("loading") >= 0 || states.indexOf("refreshing") >= 0) {
        panel.set("loading");
      } else if (states.indexOf("unavailable") >= 0) {
        panel.set("error", {
          message: "This source is unavailable. Showing nothing rather than zeros.",
          retry: function () { if (instance) { instance.load(true); } },
        });
      } else {
        panel.set("empty", NOT_HERE);
      }
    } else if (block.state === "empty") {
      panel.set("empty", emptyText || "No records yet.");
    } else {
      panel.set("ready", build(block));
    }
  }

  /* ---------------------------------------------------------------- the six panels */

  function statusPanel(p, ctx) {
    return function (block) {
      var tiles = el("ul", { "class": "tiles" }, STATUS_ORDER.map(function (name) {
        return el("li", null, el("a", { "class": "tile status-" + name, href: ctx.link("beads", { status: name }) },
          D.statusMark(name), el("span", { "class": "tile-count" }, String(block.counts[name])),
          el("span", { "class": "tile-label" }, F.status(name))));
      }));
      var notes = [block.total + (block.total === 1 ? " Bead, " : " Beads, ") + block.ready + " ready to work."];
      if (block.other) {
        notes.push(block.other + " with a status this page does not know are not in a tile.");
      }
      var tableNode = C.table({
        caption: "Beads by status", head: ["Status", "Beads"],
        rows: STATUS_ORDER.map(function (name) { return [F.status(name), String(block.counts[name])]; }),
      });
      var toggle = C.tableToggle(tiles, tableNode);
      return [toggle.element, el("p", { "class": "panel-note" }, notes.join(" "))];
    };
  }

  function projectPanel() {
    return function (block) {
      var rows = [
        ["Root commit", block.root_commit_at ? F.dateTime(block.root_commit_at) : "Not available here"],
        ["First Bead", block.first_bead_at ? F.dateTime(block.first_bead_at) : F.NOT_RECORDED],
        ["Age", block.age_days + " days" + (block.basis === "first_bead" ? ", counted from the first Bead" : "")],
      ];
      var list = el("dl", { "class": "facts" }, rows.map(function (row) {
        return [el("dt", null, row[0]), el("dd", null, row[1])];
      }));
      return C.tableToggle(list, C.table({ caption: "Project age", head: ["Item", "Value"], rows: rows })).element;
    };
  }

  function closedPanel(state, p, result) {
    var block = result.envelope.data.closed;
    show(p, result, ["beads"], block, function (data) {
      var floor = data.floor;
      var last = dayNumber(result.envelope.data.until);
      var first = data.since ? dayNumber(data.since) : floor ? dayNumber(floor) : last;
      var counts = {};
      data.events.forEach(function (event) {
        var key = event.at.slice(0, 10);
        counts[key] = (counts[key] || 0) + 1;
      });
      var spread = daily(counts, floor, first, last);
      var grouped = group(spread.days, spread.values, state.group, floor);
      if (grouped.values.every(function (value) { return value === null; })) {
        return el("div", { "class": "panel-state panel-gap" }, "No data before " + (floor ? floor.slice(0, 10) : "the first Bead"));
      }
      var chart = C.bars({ buckets: grouped.buckets, values: grouped.values, seriesLabel: "Closed", unit: "Beads",
        label: "Beads closed per " + state.group + " (UTC)" });
      var tableNode = C.table({
        caption: "Beads closed per " + state.group + " (UTC)", head: ["Period", "Closed"],
        rows: grouped.buckets.map(function (bucket, index) {
          return [bucket.label, grouped.values[index] === null ? bucket.gapText : String(grouped.values[index])];
        }),
      });
      var notes = ["Days are UTC. A Bead counts on the day of its latest close; the list keeps no reopen history."];
      if (data.without_time) {
        notes.push(data.without_time + " closed Beads have no close time and are not counted here.");
      }
      return [C.tableToggle(chart, tableNode).element, el("p", { "class": "panel-note" }, notes.join(" "))];
    }, "No Bead closed in this range.");
  }

  function byChangePanel(ctx) {
    return function (block) {
      var list = block.rows.map(function (row) {
        return {
          label: row.change === null ? "No change" : row.change, value: row.closed,
          href: row.change === null ? null : ctx.link("graph", { scope: "change", id: row.change }),
        };
      });
      if (block.other) {
        list.push({ label: "Other (" + block.other.changes + " changes)", value: block.other.closed, href: null });
      }
      var chart = C.rows({ rows: list, unit: "closed", label: "Closed Beads by change" });
      var tableNode = C.table({ caption: "Closed Beads by change", head: ["Change", "Closed"],
        rows: list.map(function (row) { return [row.label, String(row.value)]; }) });
      return C.tableToggle(chart, tableNode).element;
    };
  }

  function binOf(bins, seconds) {
    if (typeof seconds !== "number") {
      return null;
    }
    for (var i = 0; i < bins.length; i += 1) {
      if (bins[i].upper === null || seconds < bins[i].upper) {
        return i;
      }
    }
    return bins.length - 1;
  }

  function durationSection(title, hint, block) {
    var heading = el("h3", null, title);
    if (block.state === "empty") {
      var why = block.excluded.no_start
        ? "No closed Bead in this range has a start time (" + block.excluded.no_start + " left out)."
        : "No closed Bead in this range.";
      return el("section", { "class": "duration" }, heading, el("p", { "class": "panel-state panel-empty" }, why));
    }
    var summary = "Median " + duration(block.median_seconds) + ", p90 " + duration(block.p90_seconds) + " over " + block.count + (block.count === 1 ? " Bead." : " Beads.");
    var notes = [hint];
    if (block.excluded.no_start) {
      notes.push(block.excluded.no_start + " closed Beads have no start time and are left out.");
    }
    if (block.excluded.backwards) {
      notes.push(block.excluded.backwards + " have a close before the start and are left out.");
    }
    var chart = C.histogram({
      bins: block.bins, unit: "Beads", label: title,
      marks: [{ label: "median", index: binOf(block.bins, block.median_seconds) },
              { label: "p90", index: binOf(block.bins, block.p90_seconds) }],
    });
    var tableNode = C.table({ caption: title, head: ["Duration", "Beads"],
      rows: block.bins.map(function (bin) { return [bin.label, String(bin.count)]; }) });
    return el("section", { "class": "duration" }, heading, el("p", { "class": "duration-summary" }, summary),
      C.tableToggle(chart, tableNode).element, el("p", { "class": "panel-note" }, notes.join(" ")));
  }

  function cyclePanel(p, result) {
    var data = result.envelope.data;
    var block = data.cycle.state === "absent" ? data.cycle : { state: "ready" };
    show(p, result, ["beads"], block, function () {
      return [
        durationSection("Cycle time", "Started to closed. The list keeps the latest close only.", data.cycle),
        durationSection("Lead time", "Created to closed, so it includes the time a Bead waited.", data.lead),
      ];
    });
  }

  var SERIES = [["created", "Beads created", "series-1"], ["closed", "Beads closed", "series-2"],
                ["commits", "Commits", "series-3"], ["sessions", "Sessions started", "series-4"],
                ["tests", "Test runs", "series-5"]];

  function activityPanel(state, p, result) {
    var block = result.envelope.data.activity;
    show(p, result, ["beads", "git", "sessions", "tests"], block, function (data) {
      var days = data.days.map(dayNumber);
      var parts = SERIES.map(function (entry) {
        var series = data.series[entry[0]];
        var title = el("h3", null, entry[1]);
        if (series.state === "absent") {
          return el("section", { "class": "activity-row" }, title, el("p", { "class": "panel-state panel-empty" }, NOT_HERE));
        }
        if (series.state === "empty") {
          return el("section", { "class": "activity-row" }, title,
            el("p", { "class": "panel-state panel-empty" }, "The source exists but holds no records yet."));
        }
        var grouped = group(days, series.values, state.group, series.floor);
        var chart = C.stacks({ buckets: grouped.buckets, unit: "", label: entry[1] + " per " + state.group + " (UTC)",
          series: [{ key: entry[0], label: entry[1], className: entry[2], values: grouped.values }] });
        var tableNode = C.table({ caption: entry[1], head: ["Period", "Count"],
          rows: grouped.buckets.map(function (bucket, index) {
            return [bucket.label, grouped.values[index] === null ? bucket.gapText : String(grouped.values[index])];
          }) });
        return el("section", { "class": "activity-row" }, title,
          el("p", { "class": "panel-note" }, "Records from " + series.floor + "."), C.tableToggle(chart, tableNode).element);
      });
      return [parts, el("p", { "class": "panel-note" },
        "Each row starts at its own first record. Sessions are local to this host. Days are UTC.")];
    });
  }

  /* ---------------------------------------------------------------- the page */

  function parseState(ctx) {
    var range = ctx.params.get("range");
    var unit = ctx.params.get("group");
    return {
      range: RANGES.some(function (item) { return item[0] === range; }) ? range : "30d",
      group: unit === "week" ? "week" : "day",
    };
  }

  function choice(label, options, current, onPick) {
    return el("div", { "class": "choice", role: "group", "aria-label": label },
      el("span", { "class": "choice-label" }, label),
      options.map(function (item) {
        return el("button", {
          type: "button", "class": "btn btn-quiet choice-button", "aria-pressed": item[0] === current ? "true" : "false",
          on: { click: function () { onPick(item[0]); } },
        }, item[1]);
      }));
  }

  function mount(container, ctx) {
    var state = parseState(ctx);
    function go(change) {
      var next = { range: state.range, group: state.group };
      Object.keys(change).forEach(function (key) { next[key] = change[key]; });
      ctx.navigate("start", { range: next.range === "30d" ? null : next.range, group: next.group === "day" ? null : next.group });
    }
    var panels = {
      status: ctx.panel({ title: "Beads by status" }), project: ctx.panel({ title: "Project age" }),
      closed: ctx.panel({ title: "Closed over time" }), changes: ctx.panel({ title: "Closed by change" }),
      cycle: ctx.panel({ title: "Cycle and lead time" }), activity: ctx.panel({ title: "Activity" }),
    };
    var grid = el("div", { "class": "grid start-grid" },
      cell(panels.status, "col-12"), cell(panels.project, "col-4"), cell(panels.closed, "col-8"),
      cell(panels.changes, "col-4"), cell(panels.cycle, "col-8"), cell(panels.activity, "col-12"));
    function cell(controller, span) {
      controller.element.classList.add(span);
      return controller.element;
    }
    container.appendChild(el("div", { "class": "start" },
      el("div", { "class": "start-controls" },
        choice("Range", RANGES, state.range, function (value) { go({ range: value }); }),
        choice("Group by", GROUPS, state.group, function (value) { go({ group: value }); })),
      grid));
    Object.keys(panels).forEach(function (name) { panels[name].set("loading"); });

    var active = true;
    var self = {
      load: function (force) {
        return ctx.store.get("summary-" + state.range, "/api/v1/summary?range=" + state.range, { force: force }).then(function (result) {
          if (!active) {
            return;
          }
          if (result.ok) {
            var data = result.envelope.data;
            show(panels.status, result, ["beads"], data.status, statusPanel(panels.status, ctx), "No Beads yet.");
            show(panels.project, result, ["beads", "git"], data.project, projectPanel());
            closedPanel(state, panels.closed, result);
            show(panels.changes, result, ["beads"], data.by_change, byChangePanel(ctx), "No Bead closed in this range.");
            cyclePanel(panels.cycle, result);
            activityPanel(state, panels.activity, result);
          } else {
            Object.keys(panels).forEach(function (name) { show(panels[name], result, [], { state: "absent" }, null); });
          }
          extras.forEach(function (extra) { extra({ ctx: ctx, grid: grid, state: state, result: result }); });
        });
      },
      stop: function () { active = false; },
    };
    instance = self;
    self.load(false);
    return self;
  }

  var module = {
    // The returned function is the unmount the shell calls when the route changes.
    mount: function (container, ctx) {
      var running = mount(container, ctx);
      return function () {
        running.stop();
        if (instance === running) {
          instance = null;
        }
      };
    },
  };

  // A change in a source refetches the summary; the page is not rebuilt.
  App.store.subscribe(function (event) {
    if (instance && event && event.changed && event.changed.length) {
      instance.load(true);
    }
  });

  window.noggingStart = { extras: extras, sourceNote: sourceNote, show: show, daily: daily, group: group, duration: duration };
  App.registerView("start", module);
}());
