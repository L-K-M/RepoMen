# Changelog

## Unreleased

- Move the update checker to the shared Updraft package. RepoMen still never
  downloads an update: the Download button opens the release page. Version
  parsing is now stricter, pre-release ordering follows the SemVer rules, a
  retagged release no longer re-prompts a skipped version, and clicking Check
  for Updates while a check is running now reports that check instead of
  doing nothing. An unparseable version shows a "Couldn't compare versions"
  alert naming the release tag or the installed version, and the release page
  opened is always this repository's GitHub page.
- Detect Codex/ChatGPT Crashpad reports in current and legacy locations, with
  running-app warnings and report-bucket-only reclaim boundaries.
