// Fills in the newest stable desktop release from GitHub and highlights the
// visitor's platform. Without this script, or offline, every link still opens
// the GitHub releases page.
(function () {
  'use strict';

  var REPO = 'rennerdo30/sim-bridge';
  var API = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  var DOWNLOAD_PREFIX = 'https://github.com/' + REPO + '/releases/download/';
  // Release asset names, with or without a version: Sim-Bridge[-<version>]-<platform>.<ext>
  var PATTERNS = {
    macos: /^Sim-Bridge-(?:[0-9][0-9A-Za-z.+-]*-)?macos-arm64\.(?:zip|dmg)$/i,
    windows: /^Sim-Bridge-(?:[0-9][0-9A-Za-z.+-]*-)?windows-x64-setup\.exe$/i,
    windowsPortable: /^Sim-Bridge-(?:[0-9][0-9A-Za-z.+-]*-)?windows-x64\.zip$/i,
    linux: /^Sim-Bridge-(?:[0-9][0-9A-Za-z.+-]*-)?linux-x64\.(?:zip|tar\.gz)$/i
  };
  var LABELS = { macos: 'Download for macOS', windows: 'Download for Windows', linux: 'Download for Linux' };

  function platform() {
    var ua = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.userAgent || '';
    if (/android|iphone|ipad|ipod/i.test(navigator.userAgent || '')) return null;
    if (/mac/i.test(ua)) return 'macos';
    if (/win/i.test(ua)) return 'windows';
    if (/linux|x11/i.test(ua)) return 'linux';
    return null;
  }

  function assetFor(release, key) {
    var assets = release.assets || [];
    for (var i = 0; i < assets.length; i++) {
      var url = assets[i].browser_download_url || '';
      // Only follow links into this repository's own release downloads.
      if (PATTERNS[key].test(assets[i].name) && url.indexOf(DOWNLOAD_PREFIX) === 0) return url;
    }
    return null;
  }

  function apply(release) {
    var mine = platform();
    Object.keys(PATTERNS).forEach(function (key) {
      var url = release ? assetFor(release, key) : null;
      document.querySelectorAll('[data-platform="' + key + '"]').forEach(function (el) {
        if (url) el.href = url;
        if (key === mine) el.classList.add('recommended');
      });
    });
    var recommended = document.querySelector('[data-download="recommended"]');
    if (recommended && mine) {
      var url = release ? assetFor(release, mine) : null;
      if (url) recommended.href = url;
      var label = recommended.querySelector('[data-download-label]');
      if (label) label.textContent = LABELS[mine];
    }
    if (release && release.tag_name) {
      var note = document.querySelector('[data-release="note"]');
      var version = document.querySelector('[data-release="version"]');
      var date = document.querySelector('[data-release="date"]');
      if (version) version.textContent = release.tag_name.replace(/^v/, '');
      if (date && release.published_at) {
        date.textContent = new Date(release.published_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
      }
      if (note) note.hidden = false;
    }
  }

  function start() {
    apply(null);
    if (!window.fetch) return;
    fetch(API, { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (release) { if (release && !release.draft && !release.prerelease) apply(release); })
      .catch(function () { /* Keep the releases-page links. */ });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
