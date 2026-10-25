# Project Feedback — capture-agenda / ics-import (Corion)

**How to use:** read this file at the start of future sessions on this repo.
It contains corrections from the user, their stated preferences, and
lessons learned (mine and theirs), split into per-framework, general Perl,
and workflow findings. Last updated: 2026-10-25 session.

---

## Scope rules (user corrections — treat as standing orders)

- **`scripts/ics-import.pl` is an old prototype. Do not review or fix it.**
  Active code: `scripts/capture-agenda.pl` (Mojolicious::Lite webapp) and
  `lib/ZAI/Runner.pm`. The prototype's deps (Net::CalDAVTalk, DateTime) are
  still intentionally listed in the cpanfile.
- **Never treat an unavailable module as optional.** Do not design tests or
  code around a missing dependency — flag it, the user will install it
  ("I will install Text::JSCalendar for you."). Test against the real module.
- **`uploads/` contains real user data.** Never commit it, never write test
  files there. Tests isolate via `CAPTURE_AGENDA_UPLOAD_DIR` pointing at a
  temp dir.
- The user applies many fixes themselves between my turns. My role:
  review → propose → (on approval) implement TDD → verify → commit only when
  asked. Re-read files before acting; cached reads go stale (it happened).

## Per-framework findings

### Mojolicious (9.51) / Mojo

- **Route constraint regexes are spliced mid-pattern** (`Pattern::_compile`:
  `$part = _compile_req($c)` becomes `($constraint)` inside the route regex).
  NEVER use `^`/`$` anchors in `[placeholder => qr/.../]` — they cannot match
  mid-pattern and silently kill the route. Full-segment consumption is
  enforced separately (router rejects unconsumed path remainder), so
  unanchored `qr/[0-9a-f]{32}/` is exact.
- **Placeholder types:** `:name` = `[^/.]+` (no dots), `#name` = `[^/.]`→
  `[^/]+` relaxed, `*name` = anything. A trailing extension like `.ics` must
  be a literal in the pattern (`'/ics/<:id>.ics'`), not part of a constraint.
- **Implicit format extension:** the optional `format` regex group is only
  compiled when a `format` constraint exists (`_compile_format` returns ''
  unless `$format`). Extra suffixes like `/x.ics.json` are rejected by the
  leftover-path rule anyway.
- **Lite app under tests:** `app->start` no-ops under `HARNESS_ACTIVE`
  (`Mojolicious/Commands.pm` ~line 63). A Lite script can be `require`d by a
  test with no guard — but ONLY via prove; plain `perl t/foo.t` prints the
  command usage.
- **`__DATA__` templates are invisible when requiring a Lite app into a
  test:** the test file owns package `main`, so `main::DATA` is never
  populated, and `Mojo::Loader::_all` caches the empty result per class.
  Fix (see `t/extract-error.t`): write the app's `__DATA__` section to a
  real temp file, `open` it, assign `*main::DATA = $fh` BEFORE the `require`.
  A real filehandle is required (`_all` checks `fileno`; in-memory scalars
  fail).
- **`Mojo::File->slurp('UTF-8')` decodes, `->spew($chars, 'UTF-8')` encodes**
  (9.x). No manual `Encode` needed. I wrongly doubted this once — verified:
  returns flagged char string, `spew` round-trips byte-identically.
- **`Test::Mojo`:**
  - `Test::Mojo->new(app())` — needs parens on `app()`; bareword fails
    under strict subs (the sub isn't known at .t compile time).
  - `content_is` compares the **charset-decoded** text (`res->text`). For
    byte-exact file bodies assert on `$t->tx->res->body`.
  - Form uploads: `form => { images => { file => $path, 'Content-Type' =>
    'image/png' } }` — leftover hash keys become part headers
    (`UserAgent/Transactor::_parts`). Mojo does **not** sniff MIME from the
    file extension; without the header the app sees `undef` content type.
- **In-process fake servers:** `Mojo::Server::Daemon->new(app => $fake,
  listen => ['http://127.0.0.1'], silent => 1)->start`, then
  `$daemon->ports->[0]` for the ephemeral port. Give async work loop time
  with `Mojo::IOLoop->timer(0.05 => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;` slices between blocking requests. Do NOT mix
  blocking `$ua->post` with a non-blocking daemon in one process — it hangs.
- **`Mojolicious::Plugin::RenderFile`** (CPAN, not core): args
  `filepath/filename/content_type/content_disposition`; a missing/unreadable
  file only logs and returns — check `-f` yourself and `reply->not_found`.
- Wrong test plan or a die at END → exit 255 "Dubious". Use `done_testing()`.
- `perldoc` is not installed in this environment — read module sources
  straight from `@INC`; `B::Deparse` works for inspecting installed subs.

### JSON::PP

- **Always `->utf8` for HTTP JSON** (encode → UTF-8 byte string for the
  body, decode → character strings). Without it: encode returns flagged
  wide-char strings (wide-char warnings, char-vs-byte `Content-Length`
  mismatch) and decode results depend on the provider's serialization:
  raw-UTF-8 bodies + manual `decode('UTF-8', …)` accidentally works;
  `\uXXXX` escapes ≤ U+00FF become U+FFFD; escapes > U+00FF croak
  ("Cannot decode string with wide characters"). Boundary rule:
  **characters inside the app, bytes on the wire.**
- Assert on codepoints/UTF8 flags, not on terminal display (terminals
  mangle non-ASCII): `join '.', map { ord } split //, $s` and
  `utf8::is_utf8($s)`.

### Moo

- **Constructor defaults do NOT apply to explicitly passed `undef`.**
  `$class->new(model => undef)` leaves the attribute undef. Drop the pair
  instead.
- `use Moo` enables strict — undeclared variables are compile-time fatal.

### PerlX::Maybe (user's preferred idiom)

- Correct form is the **two-argument** `maybe key => $value` (drops the pair
  when value is undef; prototype `$$@`). `key => maybe $value` (one arg) is
  a compile error. The user uses it with aligned columns for optional
  constructor args (`maybe api_base => …`, `maybe model => …`).
- Watch for this class of bug: explicit-undef bypassing defaults applies to
  every optional attribute handed from a config hash.

### Text::JSCalendar (0.08)

- `vcalendarToEvents` accepts character strings directly (flagged strings
  fine, matches `slurp('UTF-8')` output).
- It **dies** on undef/empty/unparseable input — guard content presence and
  wrap in error handling before parsing (the `/extract` chain now does).

## General Perl programming findings

- `require` with an expression needs parentheses:
  `require( Cwd::abs_path($f) )`; bareword `require Foo::bar(...)` is a
  syntax error; relative paths resolve via `@INC`, not cwd — absolutize.
- A sub defined in the *calling script's* `main::` is not visible from a
  module's package (`verbose()` in `ZAI::Runner` was undefined there and
  crashed PDF handling). Modules must import/define what they call; also
  explicitly `use` modules you call as classes (`HTTP::Tiny`) — transitive
  loading is luck.
- `use 5.020` + `use experimental 'signatures'` ⇒ cpanfile must say
  `requires 'perl', '5.020'` (was 5.014 once).
- cpanfile completeness: every directly-used module, including dual-life
  core modules, non-core plugins (`Mojolicious::Plugin::RenderFile`), and
  the web framework itself; note external binaries (pdftoppm) in comments.
- `use lib 'lib'` is cwd-relative — fragile for repo-local modules.
  (Known unresolved backlog item in this repo; `PERL5LIB=lib` for now.)
- Cache keys derived from content (md5 of first image) must include ALL
  inputs (prompt, all images) — known backlog item.
- `File::Temp->newdir` object must stay alive; inlining
  `path(File::Temp->newdir->dirname)` GC's the object and silently deletes
  the directory (probe died on "Can't open file").
- Probe scripts beat `perl -e` one-liners: bash single quotes don't
  interpolate `\xNN`; escapes inside qq get mangled through the shell.
  Write a probe FILE when testing string/byte semantics.
- `$?` after a pipeline reports the last pipe element (`head`) — use
  `${PIPESTATUS[0]}` or no pipe when exit codes matter.
- Mojolicious apps log to stderr even under prove — read that output when
  diagnosing; it saved several debugging rounds here.

## Workflow findings & user preferences

- **Verification style:** empirical, codepoint-level evidence over claims.
  Deparse/inspect installed sources when docs are unavailable. When the
  user states a framework fact that contradicts my memory (slurp
  'UTF-8'), verify before objecting — they were right; I was wrong.
- **TDD is the standing expectation** for behavior changes: write test,
  watch it fail *for the right reason*, minimal implementation, watch it
  pass, run the whole suite (`prove -r t/`), `perl -c` everything touched.
  When the harness itself masks the RED (wrong upload content-type, missing
  `__DATA__`), fix the harness first and re-establish a crisp RED
  (e.g. failures reporting `'done'` where `'failed'` is expected) — don't
  rationalize timeouts.
- Real fixtures in `t/data/` (`.ics` files, UTF-8 + CRLF per RFC 5545,
  umlauts + astral chars). Verify fixture BYTES (od/python decode), not
  assumptions. Check codepoints against bytes — I labeled U+1F3AA a "circus
  tent" then "corrected" to top hat U+1F3A9; the fixture was right both
  times.
- Wrap `prove` runs in `timeout` (30–120s) — async tests can hang.
- **Comments: minimal.** The user trims explanatory comment blocks I add
  ("removed the superfluous comment"). Keep production code lean; put the
  lessons in tests, commit messages, or this file.
- **Commits:** only when asked; single commit per approved task; identity
  via `git -c user.name="Max Maischein" -c user.email="corion@corion.net"`
  (no git config exists in this repo); style = short imperative subject +
  body covering what/why/testing notes.
- The user co-edits the repo live during sessions. Before editing or
  committing, re-read current file state; before claiming a bug from a
  grep, re-check — I once mis-flagged a "one-argument maybe" that was
  already fixed on disk minutes earlier.
- Keep the review backlog visible and re-offer at natural completion
  points; the user works through it incrementally. Currently open:
  silent upload drop on unrecognized content-type; `/results` 500 on
  unknown request-ids; request-id cache key ignores prompt + other images;
  fence-stripping / arrayref `content` from the model; repo has no
  `use lib` for `lib/` (needs `PERL5LIB` or install).
- Environment (this box): Perl 5.42.3, Mojolicious 9.51, Moo 2.005005,
  JSON::PP 4.16, Text::JSCalendar 0.08, PerlX::Maybe 1.202,
  YAML::Tiny, Mojolicious::Plugin::RenderFile, prove at /usr/bin/prove.
  `Text::JSCalendar` and `PerlX::Maybe` were installed by the user on
  request — ask, don't work around.
