// Display formatting shared by every view. Pure functions, no DOM. Times arrive as UTC ISO
// strings and are shown in the browser's local time; chart buckets stay UTC days.
(function () {
  "use strict";
  var NOT_RECORDED = "Not recorded";
  var AGENT_NAMES = { antigravity: "agy" };
  var STATUS_NAMES = {
    open: "Open", ready: "Ready", in_progress: "In progress",
    blocked: "Blocked", deferred: "Deferred", closed: "Closed",
  };

  function parse(iso) {
    if (typeof iso !== "string") {
      return null;
    }
    var time = Date.parse(iso);
    return isNaN(time) ? null : new Date(time);
  }

  function pad(number) {
    return (number < 10 ? "0" : "") + number;
  }

  function clock(iso) {
    var date = parse(iso);
    return date ? pad(date.getHours()) + ":" + pad(date.getMinutes()) : NOT_RECORDED;
  }

  function dateTime(iso) {
    var date = parse(iso);
    if (!date) {
      return NOT_RECORDED;
    }
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + clock(iso);
  }

  function utcDay(iso) {
    var date = parse(iso);
    return date ? date.toISOString().slice(0, 10) : NOT_RECORDED;
  }

  // "3 min", "2 h", "5 d": the age of a time against `now` (a Date or a millisecond number).
  function age(iso, now) {
    var date = parse(iso);
    if (!date) {
      return NOT_RECORDED;
    }
    var seconds = Math.max(0, Math.round(((now === undefined ? Date.now() : +now) - date.getTime()) / 1000));
    if (seconds < 60) {
      return seconds + " s";
    }
    if (seconds < 3600) {
      return Math.floor(seconds / 60) + " min";
    }
    if (seconds < 86400) {
      return Math.floor(seconds / 3600) + " h";
    }
    return Math.floor(seconds / 86400) + " d";
  }

  function agent(name) {
    if (!name) {
      return "Unknown";
    }
    return AGENT_NAMES[name] || name.charAt(0).toUpperCase() + name.slice(1);
  }

  // `agy` is the display name of the stored `antigravity`; the class tokens use the display key.
  function agentKey(name) {
    var shown = AGENT_NAMES[name] || name;
    return ["claude", "codex", "pi", "agy"].indexOf(shown) >= 0 ? shown : "unknown";
  }

  function status(name) {
    return STATUS_NAMES[name] || NOT_RECORDED;
  }

  function priority(value) {
    return typeof value === "number" && value >= 0 && value <= 4 ? "P" + value : NOT_RECORDED;
  }

  // The "TASK-XXX-001: [tier] " prefix is removed for display only.
  function title(text) {
    if (typeof text !== "string" || !text) {
      return NOT_RECORDED;
    }
    return text.replace(/^TASK-[A-Z0-9]+-\d+:\s*(?:\[[^\]]*\]\s*)*/, "") || text;
  }

  function orNotRecorded(value) {
    return value === null || value === undefined || value === "" ? NOT_RECORDED : String(value);
  }

  window.noggingFormat = {
    NOT_RECORDED: NOT_RECORDED, clock: clock, dateTime: dateTime, utcDay: utcDay, age: age,
    agent: agent, agentKey: agentKey, status: status, priority: priority, title: title,
    orNotRecorded: orNotRecorded,
  };
}());
