// The start page, panels 7 to 11 (design Decisions 10 and 16): agent-hours, agents with models and
// tiers, token usage, commits and changed lines, and test cost. It adds its panels through
// window.noggingStart.extras, so start.js stays the owner of the page and its range and group.
//
// The server did the statistics. This file only draws, and it follows the same rules as the first
// six panels: a period with no data is a hatched gap and never a zero bar, an absent source reads
// "Not available here", and a sum that misses something says so ("+?", "Partial data").
// Tokens read "Known: …" and carry no cost and no quota share.
(function () {
  "use strict";
  var Start = window.noggingStart;
  if (!Start) {
    return;
  }
  var D = window.noggingDom;
  var F = window.noggingFormat;
  var C = window.noggingCharts;
  var el = D.el;

  var NOT_HERE = "Not available here.";
  var panelsOf = typeof WeakMap === "function" ? new WeakMap() : null;
  var STAGES = [["changed", "Changed", "series-1"], ["commit", "Commit", "series-2"],
                ["bead", "Bead", "series-3"], ["full", "Full", "series-5"]];

  /* ---------------------------------------------------------------- helpers */

  function dayNumber(text) {
    var part = String(text).slice(0, 10).split("-");
    return Date.UTC(+part[0], +part[1] - 1, +part[2]) / 86400000;
  }

  // A whole number with thin separators; null reads as not recorded.
  function count(value) {
    return typeof value === "number" ? String(Math.round(value)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") : F.NOT_RECORDED;
  }

  function hours(value) {
    return typeof value === "number" ? (Math.round(value * 10) / 10) + " h" : F.NOT_RECORDED;
  }

  function seconds(value) {
    if (typeof value !== "number") {
      return F.NOT_RECORDED;
    }
    return value >= 3600 ? (Math.round(value / 360) / 10) + " h" : value >= 120 ? (Math.round(value / 6) / 10) + " min"
      : (Math.round(value * 10) / 10) + " s";
  }

  // Buckets of one daily series. `suffix` marks a bucket whose sum misses a counter.
  function series(days, values, state, floor, flagged) {
    var grouped = Start.group(days.map(dayNumber), values, state.group, floor);
    if (flagged && flagged.length) {
      var marked = {};
      flagged.forEach(function (day) { marked[day] = true; });
      var source = days.map(function (day) { return !!marked[day]; });
      grouped.buckets.forEach(function (bucket, index) {
        var covered = state.group === "week" ? weekDays(days.map(dayNumber), index) : [index];
        if (covered.some(function (position) { return source[position]; })) {
          bucket.label += " (unknown counters)";
        }
      });
    }
    return grouped;
  }

  // The day positions of the week bucket `index`, in the order Start.group builds them.
  function weekDays(numbers, index) {
    var keys = [];
    var positions = {};
    numbers.forEach(function (day, position) {
      var monday = day - (new Date(day * 86400000).getUTCDay() + 6) % 7;
      if (positions[monday] === undefined) {
        positions[monday] = [];
        keys.push(monday);
      }
      positions[monday].push(position);
    });
    return positions[keys[index]] || [];
  }

  function allGap(values) {
    return values.every(function (value) { return value === null; });
  }

  function gapNote(floor, what) {
    return el("div", { "class": "panel-state panel-gap" }, "No " + what + " data before " + (floor ? String(floor).slice(0, 10) : "the first record"));
  }

  function chartBlock(options, tableHead, tableRows) {
    var chart = C.stacks(options);
    return C.tableToggle(chart, C.table({ caption: options.label, head: tableHead, rows: tableRows })).element;
  }

  function note(text) {
    return el("p", { "class": "panel-note" }, text);
  }

  function section(title, children) {
    return el("section", { "class": "usage-section" }, el("h3", null, title), children);
  }

  /* ---------------------------------------------------------------- panel 7: agent-hours */

  function agentHoursPanel(state) {
    return function (block) {
      var running = block.running + " running";
      var facts = [
        ["Agent-hours", hours(block.hours) + " over " + block.sessions + (block.sessions === 1 ? " finished session" : " finished sessions")],
        ["Running", running + (block.running ? ", not in the hours" : "")],
        ["Planning sessions", count(block.planning_sessions) + ", in the hours but in no Bead's detail"],
        ["Orchestrator", hours(block.orchestrator.hours) + " over " + block.orchestrator.sessions + " sessions, "
          + block.orchestrator.running + " running, kept apart from the headline"],
      ];
      var list = el("dl", { "class": "facts" }, facts.map(function (row) { return [el("dt", null, row[0]), el("dd", null, row[1])]; }));
      var parts = [list];
      if (block.days.length && allGap(block.values)) {
        parts.push(gapNote(block.floor, "session"));
      } else if (block.days.length) {
        var grouped = series(block.days, block.values, state, block.floor);
        parts.push(chartBlock({
          buckets: grouped.buckets, unit: "h", label: "Agent-hours per " + state.group + " (UTC, by start day)",
          series: [{ key: "hours", label: "Agent-hours", className: "series-1", values: grouped.values }],
        }, ["Period", "Agent-hours"], grouped.buckets.map(function (bucket, index) {
          return [bucket.label, grouped.values[index] === null ? bucket.gapText : String(grouped.values[index])];
        })));
      }
      var notes = ["Parallel sessions add up, so this is not elapsed time. A session counts on the UTC day it started.",
        "Session records are local to this host" + (block.floor ? ", kept from " + block.floor + "." : ".")];
      if (block.excluded.untimed || block.excluded.backwards) {
        notes.push((block.excluded.untimed + block.excluded.backwards) + " sessions with no start or an end before the start are left out.");
      }
      parts.push(note(notes.join(" ")));
      return parts;
    };
  }

  /* ---------------------------------------------------------------- panel 8: agents */

  function labelled(items, key) {
    return items.map(function (item) {
      var name = item[key] === null ? "Not recorded" : String(item[key]);
      return name + " (" + item.sessions + ")";
    }).join(", ");
  }

  function agentsPanel() {
    return function (block) {
      var parts = [];
      var requested = block.requested;
      if (requested.state === "absent") {
        parts.push(section("Requested at launch", el("p", { "class": "panel-state panel-empty" }, NOT_HERE)));
      } else if (requested.state === "empty") {
        parts.push(section("Requested at launch", el("p", { "class": "panel-state panel-empty" }, "No session started in this range.")));
      } else {
        var rows = requested.rows.map(function (row) {
          return [F.agent(row.agent), String(row.sessions), String(row.running), hours(row.hours),
            labelled(row.models, "model"), labelled(row.tiers, "tier")];
        });
        parts.push(section("Requested at launch", [
          note("Model and tier come from the session records: what was asked for, not what ran."),
          C.table({ caption: "Agents, requested models and tiers", head: ["Agent", "Sessions", "Running", "Hours", "Requested models", "Tiers"], rows: rows }),
        ]));
      }
      var observed = block.observed;
      if (observed.state === "absent") {
        parts.push(section("Observed in usage", el("p", { "class": "panel-state panel-empty" }, NOT_HERE)));
      } else if (observed.state === "empty") {
        parts.push(section("Observed in usage", el("p", { "class": "panel-state panel-empty" }, "The usage store holds no model yet.")));
      } else {
        var seen = observed.rows.map(function (row) { return [row.model, "Known: " + count(row.known) + (row.unknown ? "+?" : "")]; });
        if (observed.other) {
          seen.push(["Other (" + observed.other.models + " models)", count(observed.other.known)]);
        }
        parts.push(section("Observed in usage", [
          note("Models the usage records saw, for the whole history. Not the same list as above."),
          C.table({ caption: "Observed models and their known tokens", head: ["Model", "Known tokens"], rows: seen }),
        ]));
      }
      return parts;
    };
  }

  /* ---------------------------------------------------------------- panel 9: tokens */

  function tokensPanel(state) {
    return function (block) {
      if (block.state === "empty") {
        return el("p", { "class": "panel-state panel-empty" }, "The usage store holds no timed record yet.");
      }
      var head = block.headline;
      var known = head.known === null ? "No token record in this range" : "Known: " + count(head.known) + (head.unknown ? "+?" : "");
      var parts = [el("p", { "class": "headline" }, known),
        el("p", { "class": "panel-note" }, "Fresh input plus output, as far as the records prove. Not a cost and not a share of a quota."
          + (head.unknown ? " “+?” marks a sum with a counter nobody could prove." : ""))];
      var stacksSeries = block.runtimes.map(function (row) {
        var grouped = series(block.days, row.values, state, row.floor, row.unknown_days);
        return { row: row, grouped: grouped };
      });
      var first = stacksSeries[0];
      if (!first || stacksSeries.every(function (item) { return allGap(item.row.values); })) {
        parts.push(gapNote(block.floor, "token"));
      } else {
        parts.push(chartBlock({
          buckets: first.grouped.buckets.map(function (bucket, index) {
            return { label: bucket.label, gap: stacksSeries.every(function (item) { return item.grouped.buckets[index].gap; }),
              gapText: "No data before " + (block.floor || "").slice(0, 10) };
          }),
          unit: "known tokens", label: "Known tokens per " + state.group + " and runtime (UTC)",
          series: stacksSeries.map(function (item) {
            return { key: item.row.runtime, label: F.agent(item.row.runtime), className: "agent-" + F.agentKey(item.row.runtime),
              values: item.grouped.values };
          }),
        }, ["Runtime", "Known tokens", "Fresh input", "Output", "Records from"], block.runtimes.map(function (row) {
          return [F.agent(row.runtime) + (row.partial ? " (partial)" : ""), row.known === null ? "No data in this range"
            : count(row.known) + (row.unknown ? "+?" : ""), count(row.fresh_input), count(row.output), row.floor || F.NOT_RECORDED];
        })));
      }
      var notes = ["Each runtime starts at its own first record: " + block.runtimes.map(function (row) {
        return F.agent(row.runtime) + " " + (row.floor || "no dated record");
      }).join(", ") + "."];
      if (block.partial.length) {
        notes.push("Partial data for " + block.partial.map(F.agent).join(", ") + ": their sums may miss usage.");
      }
      if (block.pending_batches) {
        notes.push(block.pending_batches + " usage batches wait to be imported and are not in these numbers.");
      }
      parts.push(note(notes.join(" ")));
      return parts;
    };
  }

  /* ---------------------------------------------------------------- panel 10: commits */

  function commitsPanel(state) {
    return function (block) {
      if (block.state === "empty") {
        return [el("p", { "class": "panel-state panel-empty" }, "No commit carries a Bead token yet."),
          note(count(block.tokenless_commits) + " commits carry no Bead token.")];
      }
      var totals = block.totals;
      var list = el("dl", { "class": "facts" }, [
        ["Commits", count(totals.commits)], ["Production lines", count(totals.production_lines)],
        ["Test lines", count(totals.test_lines)],
      ].map(function (row) { return [el("dt", null, row[0]), el("dd", null, row[1])]; }));
      var parts = [list];
      if (allGap(block.commits)) {
        parts.push(gapNote(block.floor, "commit"));
      } else {
        var production = series(block.days, block.production, state, block.floor);
        var tests = series(block.days, block.test, state, block.floor);
        var commits = series(block.days, block.commits, state, block.floor);
        parts.push(chartBlock({
          buckets: production.buckets, unit: "lines", label: "Changed lines per " + state.group + " (UTC)",
          series: [{ key: "production", label: "Production lines", className: "series-1", values: production.values },
                   { key: "test", label: "Test lines", className: "series-2", values: tests.values }],
        }, ["Period", "Commits", "Production lines", "Test lines"], production.buckets.map(function (bucket, index) {
          return production.values[index] === null ? [bucket.label, bucket.gapText, bucket.gapText, bucket.gapText]
            : [bucket.label, String(commits.values[index]), String(production.values[index]), String(tests.values[index])];
        })));
      }
      var notes = [count(block.tokenless_commits) + " commits in the whole history carry no Bead token and are not in the panel.",
        "Commits include unmerged work. A rebased copy counts once. Records start with the first Bead-token commit, " + (block.floor || "") + "."];
      if (totals.lines_unknown) {
        notes.push(totals.lines_unknown + " commits have no line count and add no lines.");
      }
      parts.push(note(notes.join(" ")));
      return parts;
    };
  }

  /* ---------------------------------------------------------------- panel 11: test cost */

  function testCostPanel(state) {
    return function (block) {
      if (block.state === "empty") {
        return el("p", { "class": "panel-state panel-empty" }, "No test run is on record yet.");
      }
      var rows = block.stages.map(function (stage) {
        return [stage.stage, stage.runs ? String(stage.runs) : "No run", stage.failed ? String(stage.failed) : (stage.runs ? "0" : F.NOT_RECORDED),
          stage.runs ? seconds(stage.seconds) : F.NOT_RECORDED, stage.runs ? seconds(stage.median_seconds) : F.NOT_RECORDED];
      });
      var parts = [C.table({ caption: "Test cost per stage", head: ["Stage", "Runs", "Failed", "Total time", "Median run"], rows: rows })];
      var days = block.days;
      var seriesList = STAGES.map(function (entry) {
        var stage = block.stages.filter(function (item) { return item.stage === entry[0]; })[0];
        return { entry: entry, grouped: series(days, stage.values, state, block.floor) };
      });
      if (days.length && !seriesList.every(function (item) { return allGap(item.grouped.values); })) {
        var base = seriesList[0].grouped;
        parts.push(chartBlock({
          buckets: base.buckets, unit: "s", label: "Test seconds per " + state.group + " and stage (UTC)",
          series: seriesList.map(function (item) {
            return { key: item.entry[0], label: item.entry[1], className: item.entry[2], values: item.grouped.values };
          }),
        }, ["Period"].concat(STAGES.map(function (entry) { return entry[1] + " (s)"; })), base.buckets.map(function (bucket, index) {
          return [bucket.label].concat(seriesList.map(function (item) {
            return item.grouped.values[index] === null ? bucket.gapText : String(item.grouped.values[index]);
          }));
        })));
      }
      var notes = ["Records kept from " + (block.floor || "…") + ": older records rotate away, so earlier runs are missing, not free."];
      if (block.excluded.not_run || block.excluded.untimed) {
        notes.push((block.excluded.not_run + block.excluded.untimed) + " records without a run time are left out.");
      }
      parts.push(note(notes.join(" ")));
      return parts;
    };
  }

  /* ---------------------------------------------------------------- placement */

  function panelsFor(grid, ctx) {
    var known = panelsOf && panelsOf.get(grid);
    if (known) {
      return known;
    }
    var made = {
      hours: ctx.panel({ title: "Agent-hours" }), agents: ctx.panel({ title: "Agents, models and tiers" }),
      tokens: ctx.panel({ title: "Token usage" }), commits: ctx.panel({ title: "Commits and changed lines" }),
      tests: ctx.panel({ title: "Test cost" }),
    };
    var spans = { hours: "col-6", agents: "col-6", tokens: "col-12", commits: "col-6", tests: "col-6" };
    Object.keys(made).forEach(function (name) {
      made[name].element.classList.add(spans[name]);
      made[name].set("loading");
      grid.appendChild(made[name].element);
    });
    if (panelsOf) {
      panelsOf.set(grid, made);
    }
    return made;
  }

  Start.extras.push(function (context) {
    var panels = panelsFor(context.grid, context.ctx);
    var result = context.result;
    var state = context.state;
    var data = result.ok ? result.envelope.data : {};
    Start.show(panels.hours, result, ["sessions"], data.agent_hours || { state: "absent" }, agentHoursPanel(state), "No session on record.");
    Start.show(panels.agents, result, ["sessions", "tokens"], data.agents || { state: "absent" }, agentsPanel());
    Start.show(panels.tokens, result, ["tokens"], data.tokens || { state: "absent" }, tokensPanel(state));
    Start.show(panels.commits, result, ["git"], data.commits || { state: "absent" }, commitsPanel(state));
    Start.show(panels.tests, result, ["tests"], data.test_cost || { state: "absent" }, testCostPanel(state));
  });
}());
