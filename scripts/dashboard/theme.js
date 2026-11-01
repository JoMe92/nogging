// The theme choice: System, Light or Dark, kept under `nogging-theme` in localStorage.
// System leaves the root element bare so prefers-color-scheme decides; Light and Dark set
// data-theme, which tokens.css reads. This file is external because the policy forbids the
// docs site's inline head script. Storage may be blocked or full, so every access is guarded
// and the page still renders with the system choice.
(function () {
  "use strict";
  var KEY = "nogging-theme";
  var CHOICES = ["system", "light", "dark"];

  function stored() {
    try {
      var value = window.localStorage.getItem(KEY);
      return CHOICES.indexOf(value) >= 0 ? value : "system";
    } catch (ignored) {
      return "system";
    }
  }

  function apply(choice) {
    var root = document.documentElement;
    if (choice === "light" || choice === "dark") {
      root.setAttribute("data-theme", choice);
    } else {
      root.removeAttribute("data-theme");
    }
  }

  function set(choice) {
    if (CHOICES.indexOf(choice) < 0) {
      choice = "system";
    }
    apply(choice);
    try {
      if (choice === "system") {
        window.localStorage.removeItem(KEY);
      } else {
        window.localStorage.setItem(KEY, choice);
      }
    } catch (ignored) {
      // The choice still applies for this page.
    }
    return choice;
  }

  apply(stored());
  window.noggingTheme = { choices: CHOICES.slice(), get: stored, set: set };
}());
