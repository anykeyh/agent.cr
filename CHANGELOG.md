# Changelog

## [Unreleased]

### Fixed

- **Critical: Duplicate tool results in auto-resolve loop** (#1). Tool-result
  messages were being appended to history twice, causing malformed API requests.
- **Critical: Raising tool callbacks kill the agent fiber** (#2). A tool callback
  that raised an exception would silently terminate the background fiber,
  blocking all future `#ask` calls. Callback errors are now captured and returned
  as tool-result messages.
- **Critical: `#reset` races with in-flight requests** (#3). `#reset` now routes
  through the request channel, serializing with any pending request and waiting
  for it to complete before clearing history.
- String-prefix error detection replaced with structured error types (#4/#5).
  Added `Agent::Error`, `Agent::ConnectionError`, `Agent::ApiError`,
  `Agent::ToolError` exception classes and `Response#error?` / `Response#error`.
- SSE parser now handles `data:` (without trailing space) per the SSE spec (#24).
- `ToolCallDelta.id` and `name` use assignment (`=`) instead of `+=` (#17).
- `max_history` trimming now correctly counts user/assistant roles, avoiding
  orphaned tool messages in agentic flows (#7).

### Changed

- Removed misleading `tags: "remote"` from all spec tests (#35). Tests use a
  local mock server and don't require a remote API.

### Added

- Tests for the auto-resolve tool loop, raising callbacks, `register_tool`
  without auto_execute, `max_history` trimming, and structured error responses
  (#32, #33, #34).
- `CHANGELOG.md` (#39).
- Updated `shard.yml` author (#38).

## [0.1.0] - Initial release