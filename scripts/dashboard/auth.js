// Trades the token of the link for a session cookie. The token sits in the URL
// fragment, which no request, log or Referer carries, and it leaves the address bar
// and the history entry before anything else runs. window.noggingAuth resolves to
// true once this browser has a session, and false after the denied panel is shown.
(function () {
  "use strict";
  var found = /^#token=([A-Za-z0-9_-]+)$/.exec(window.location.hash);
  var headers = {};
  if (found) {
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
    headers.Authorization = "Bearer " + found[1];
  }

  function deny() {
    var panel = document.getElementById("auth-denied");
    if (panel) {
      panel.hidden = false;
    }
    return false;
  }

  window.noggingAuth = window.fetch("/api/v1/auth", {
    credentials: "same-origin",
    cache: "no-store",
    headers: headers,
  }).then(function (response) {
    return response.ok || deny();
  }, deny);
}());
