// Trades the token, or a one-time pairing code, of the link for a session cookie. Both
// sit in the URL fragment, which no request, log or Referer carries, and the fragment
// leaves the address bar and the history entry before anything else runs.
// window.noggingAuth resolves to true once this browser has a session, and false after
// the denied panel is shown. Every message is a text node.
(function () {
  "use strict";
  var found = /^#(token|pair)=([A-Za-z0-9_-]+)$/.exec(window.location.hash);
  var headers = {};
  if (found) {
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
    headers.Authorization = (found[1] === "pair" ? "Pairing " : "Bearer ") + found[2];
  }

  var USED_ELSEWHERE = "This link was already used from another address. If that was not you, ask for the " +
    "token to be rotated (`nogg dashboard --rotate-token`), which signs every browser out.";
  var USED_HERE = "This link was already used from this address, perhaps by another app on this device. " +
    "Ask for a new link.";
  var EXPIRED = "This link has expired. Ask for a new one.";

  function used(data) {
    return data.same_peer === true ? USED_HERE : USED_ELSEWHERE;
  }

  function notice(text) {
    var node = document.getElementById("auth-notice");
    if (node) {
      node.textContent = text;
      node.hidden = false;
    }
  }

  function deny(text) {
    var panel = document.getElementById("auth-denied");
    if (panel) {
      panel.hidden = false;
    }
    if (text) {
      notice(text);
    }
    return false;
  }

  function dataOf(response) {
    return response.json().then(function (doc) {
      return (doc && typeof doc.data === "object" && doc.data) || {};
    }, function () {
      return {};
    });
  }

  window.noggingAuth = window.fetch("/api/v1/auth", {
    credentials: "same-origin",
    cache: "no-store",
    headers: headers,
  }).then(function (response) {
    return dataOf(response).then(function (data) {
      if (response.ok) {
        if (data.pairing === "used_elsewhere") {
          notice(used(data));       // signed in from before, and the new link lost a race
        }
        return true;
      }
      if (data.error === "pairing_used") {
        return deny(used(data));
      }
      return deny(data.error === "pairing_expired" ? EXPIRED : null);
    });
  }, function () {
    return deny(null);
  });
}());
