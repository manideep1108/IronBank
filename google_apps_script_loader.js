// ====================================================================
//              🏦 IRONBANK BOOTSTRAP LOADER (AUTO-UPDATER)
// ====================================================================
// Paste this file ONCE into your Google Apps Script editor (script.new).
// On every request it fetches google_apps_script.js (the IronBank brain)
// from GitHub raw and runs it, so deployments always execute whatever is
// on the pinned branch — no re-pasting after backend updates.
//
// It exposes SIX entry points — all of them are required:
//   doGet / doPost / setupWebhook          (Web App + Telegram webhook)
//   pollSplitwise / installPollTrigger /   (the 15-min Splitwise↔Notion
//   removePollTriggers                      sync — run installPollTrigger
//                                           once from this editor)
//
// Resilience: the fetched code is cached for 10 minutes (CacheService,
// chunked — a single cache value caps at 100KB) AND persisted as a
// last-good copy in Script Properties, so a GitHub outage longer than
// the cache TTL cannot take the deployment down.
// ====================================================================

// Change this URL if you fork the repository.
var GITHUB_RAW_URL = "https://raw.githubusercontent.com/manideep1108/IronBank/main/google_apps_script.js";
var CACHE_EXPIRATION_SECONDS = 600; // 10 minutes

// ---- chunked CacheService cache (a single value caps at 100KB) -------------
var CACHE_KEY = "ironbank_code";
var CACHE_CHUNK = 90000;

function getCachedCode_(cache) {
  var n = cache.get(CACHE_KEY + "_n");
  if (!n) return null;
  n = parseInt(n, 10);
  var keys = [];
  for (var i = 0; i < n; i++) keys.push(CACHE_KEY + "_" + i);
  var got = cache.getAll(keys);
  var out = "";
  for (var j = 0; j < n; j++) {
    var part = got[CACHE_KEY + "_" + j];
    if (part == null) return null; // a chunk expired/evicted — treat the whole thing as a miss
    out += part;
  }
  return out;
}

function putCachedCode_(cache, code) {
  var n = Math.ceil(code.length / CACHE_CHUNK);
  var props = {};
  for (var i = 0; i < n; i++) props[CACHE_KEY + "_" + i] = code.substring(i * CACHE_CHUNK, (i + 1) * CACHE_CHUNK);
  props[CACHE_KEY + "_n"] = String(n);
  cache.putAll(props, CACHE_EXPIRATION_SECONDS);
}

// ---- last-good copy in Script Properties (survives cache expiry) -----------
// A Script Property value caps at ~9KB, so the code is chunked here too.
var LKG_KEY = "ironbank_lkg";
var LKG_CHUNK = 8500;

function getLastGoodCode_() {
  try {
    var props = PropertiesService.getScriptProperties();
    var n = props.getProperty(LKG_KEY + "_n");
    if (!n) return null;
    n = parseInt(n, 10);
    var out = "";
    for (var i = 0; i < n; i++) {
      var part = props.getProperty(LKG_KEY + "_" + i);
      if (part == null) return null;
      out += part;
    }
    return out;
  } catch (e) { return null; }
}

function putLastGoodCode_(code) {
  try {
    var props = PropertiesService.getScriptProperties();
    // Skip the ~20 writes when the code hasn't changed (cheap length+head/tail check).
    var prevN = props.getProperty(LKG_KEY + "_n");
    if (prevN) {
      var prev0 = props.getProperty(LKG_KEY + "_0") || "";
      if (parseInt(prevN, 10) === Math.ceil(code.length / LKG_CHUNK) && code.substring(0, 200) === prev0.substring(0, 200)) {
        var last = props.getProperty(LKG_KEY + "_" + (parseInt(prevN, 10) - 1)) || "";
        if (code.substring(code.length - 200) === last.substring(Math.max(0, last.length - 200))) return;
      }
    }
    var n = Math.ceil(code.length / LKG_CHUNK);
    for (var i = 0; i < n; i++) props.setProperty(LKG_KEY + "_" + i, code.substring(i * LKG_CHUNK, (i + 1) * LKG_CHUNK));
    props.setProperty(LKG_KEY + "_n", String(n));
  } catch (e) { Logger.log("last-good save skipped (" + e + ")"); }
}

// Optional: set GITHUB_TOKEN in Script Properties if your fork is private.
function getGithubToken_() {
  try {
    var token = PropertiesService.getScriptProperties().getProperty("GITHUB_TOKEN");
    if (token) return token.trim();
  } catch (e) {}
  return null;
}

function getCode() {
  var cache = CacheService.getScriptCache();
  var cachedCode = getCachedCode_(cache);
  if (cachedCode) return cachedCode;

  try {
    var headers = { "Cache-Control": "no-cache" };
    var token = getGithubToken_();
    if (token) headers["Authorization"] = "token " + token;

    var response = UrlFetchApp.fetch(GITHUB_RAW_URL, {
      muteHttpExceptions: true,
      headers: headers
    });

    if (response.getResponseCode() === 200) {
      var code = response.getContentText();
      try { putCachedCode_(cache, code); } catch (ce) { Logger.log("cache skipped (" + ce + ")"); }
      putLastGoodCode_(code);
      return code;
    }
    throw new Error("HTTP " + response.getResponseCode());
  } catch (e) {
    Logger.log("⚠️ Error fetching IronBank code from GitHub: " + e.toString());
    var fallback = getCachedCode_(cache) || getLastGoodCode_();
    if (fallback) return fallback;
    throw new Error("Unable to fetch the IronBank backend from GitHub (and no last-good copy yet): " + e.toString());
  }
}

function runRemote(fnName, args) {
  var code = getCode();

  // Indirect eval executes in the global context, binding all top-level variables and functions.
  (1, eval)(code);

  var globalScope = typeof globalThis !== "undefined" ? globalThis : this;
  if (typeof globalScope[fnName] === "function") {
    return globalScope[fnName].apply(globalScope, args);
  }
  throw new Error("Function '" + fnName + "' not found in the IronBank code.");
}

// ── Web App entry points ─────────────────────────────────────────────────────
function doGet(e) {
  return runRemote("doGet", [e]);
}

function doPost(e) {
  return runRemote("doPost", [e]);
}

// Run ONCE from the editor after deploying the Web App (or let onboarding.sh
// trigger it by setting WEBAPP_URL): registers the Telegram webhook.
function setupWebhook() {
  return runRemote("setupWebhook", []);
}

// ── Splitwise ↔ Notion sync (time-driven trigger) ────────────────────────────
// The trigger's target must be a top-level function in THIS loader, so it
// delegates to the remotely-fetched pollSplitwise() in google_apps_script.js.
function pollSplitwise() {
  return runRemote("pollSplitwise", []);
}

// Installs the sync trigger (onboarding.sh normally does this for you through the Web App's
// installTrigger action — run this manually only as a fallback). Cadence comes from the
// POLL_INTERVAL_MIN Script Property (1/5/10/15/30; default 15).
// Idempotent: clears any existing pollSplitwise triggers first so re-running won't stack them.
function installPollTrigger() {
  removePollTriggers();
  var mins = 15;
  try {
    var v = parseInt(PropertiesService.getScriptProperties().getProperty("POLL_INTERVAL_MIN") || "15", 10);
    if ([1, 5, 10, 15, 30].indexOf(v) >= 0) mins = v;
  } catch (e) {}
  ScriptApp.newTrigger("pollSplitwise").timeBased().everyMinutes(mins).create();
  Logger.log("Installed pollSplitwise trigger (every " + mins + " minutes).");
}

function removePollTriggers() {
  var triggers = ScriptApp.getProjectTriggers();
  var removed = 0;
  for (var i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === "pollSplitwise") {
      ScriptApp.deleteTrigger(triggers[i]);
      removed++;
    }
  }
  Logger.log("Removed " + removed + " existing pollSplitwise trigger(s).");
}
