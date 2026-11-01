# Architecture — parallel-path

## Overview

Two files. No coupling between them beyond a `require`.

```
parallel-path.el              — core, zero external dependencies
parallel-path-projectile.el  — optional projectile integration
test/parallel-path-test.el   — ERT tests (batch-safe, core only)
```

---

## parallel-path.el

### Data model: profiles  (`parallel-path-profiles`)

A profile is a plist with three keys:

```
:name               — keyword, e.g. :test or :views
:directory-mappings — alist of (A-FRAGMENT . B-FRAGMENT)
:name-patterns      — alist of (TEST-FMT . IMPL-FMT), or nil
```

The default ships one profile (:test) covering common test/impl conventions.
Users append further profiles (e.g. :views for Rails models↔views).

---

### Core: path arithmetic  (`parallel-path--strip-root`, `parallel-path--apply-root`)

```
strip-root(path, root):
  expand both
  if path starts with (root + "/") → return path[len(root+"/"):]
  else → nil

apply-root(path, source-root, target-root):
  rel = strip-root(path, source-root)
  if rel → expand-file-name(rel, target-root)
  else   → nil
```

Source and target roots are completely arbitrary; no common prefix is required.

---

### Core: profile toggle  (`parallel-path--toggle-with-profile`)

```
given path and profile:
  is-dir    = file-directory-p(path)
  dir       = directory part of path
  base-noext, ext = filename parts (if not dir)

  direction = cond
                is-dir AND any B-fragment in dir  → :b-to-a  (test-dir -> impl-dir)
                is-dir                            → :a-to-b  (impl-dir -> test-dir)
                name-patterns AND test-file-p(base-noext, patterns) → :b-to-a
                else                              → :a-to-b

  new-dir   = directory-transform(dir, mappings, direction)
  if not new-dir → nil

  if is-dir → new-dir
  else:
    new-base = if patterns → filename-transform(base-noext, ext, direction, patterns)
               else        → base (directory-only profile)
    → new-dir + "/" + new-base
```

---

### Directory transform  (`parallel-path--directory-transform`)

```
for each (A . B) in mappings:
  :a-to-b → if A appears in dir, replace first occurrence with B
  :b-to-a → if B appears in dir, replace first occurrence with A
  first match wins; remaining mappings not tried
return nil if no match
```

Ordering matters: put more-specific rules (e.g. "/lib/" → "/spec/lib/")
before less-specific ones ("/app/" → "/spec/") so the right rule wins.

---

### Filename transforms  (`parallel-path--fmt-to-regexp`, `parallel-path--test-file-p`, `parallel-path--filename-transform`)

```
fmt-to-regexp("%s_spec") → \`\(.*\)_spec\'   (dot/special chars in suffix are quoted)

test-file-p(base-noext, patterns):
  for each (test-fmt . impl-fmt):
    re = fmt-to-regexp(test-fmt)
    if base-noext matches re → return format(impl-fmt, captured-group)
  → nil

filename-transform(base-noext, ext, direction, patterns):
  :a-to-b → format(first-test-fmt, base-noext) + ext
  :b-to-a → test-file-p(base-noext) + ext  (nil if no match)
```

---

### Binding helper  (`parallel-path-bind`)

```
parallel-path-bind(fn, profile):
  if no profile → return fn unchanged
  sym = intern(fn-name + "-" + profile-name-without-colon)
  defalias sym → (lambda () (interactive) (funcall fn profile))
  return sym
```

Follows cabinet's `cabinet-make-toggle` pattern. Produces named symbols so
which-key shows `parallel-path-toggle-test` rather than an anonymous lambda.

---

## parallel-path-projectile.el

### Test toggle  (`parallel-path-projectile-toggle-test`)

```
if dired buffer:
  new-dir = (ignore-errors (projectile--test-to-impl-dir default-directory))
         OR (ignore-errors (projectile--impl-to-test-dir default-directory))
  → dired new-dir

if file buffer:
  counterpart = projectile-find-implementation-or-test(buffer-file-name)
  → find-file counterpart
```

The dired path is the new capability; the file-buffer path simply reuses
projectile's existing function unchanged.

### Worktree switch  (`parallel-path-projectile-switch-worktree`)

```
current-root = projectile-project-root()
all-worktrees = projectile-project-worktrees(current-root)
  → calls git worktree list --porcelain internally

candidates = filter out: prunable, current root

completing-read over candidates (path annotated with branch label)
  → user picks target-root

result = parallel-path--apply-root(current-path, current-root, target-root)
→ find-file or dired result
```

No additional configuration needed; projectile already knows all worktrees.

---

### Fix: dired toggle-back fails — asks for profile  (`parallel-path.el`)

`parallel-path--toggle-with-profile` always used direction `:a-to-b` for
directory paths (because `base-noext` is nil for dirs, defeating the filename
test).  From `/spec/lib/` the `:a-to-b` transform found `/lib/` inside the path
and replaced it with `/spec/lib/`, yielding `/spec/spec/lib/` — which doesn't
exist — so `parallel-path-toggle-auto` fell back to `completing-read`.

Fix: for `is-dir`, detect direction by checking whether the directory path
contains any B-side fragment from the profile's mappings.  If yes → `:b-to-a`,
else → `:a-to-b`.

```
direction(is-dir, dir, mappings):
  if any (cdr mapping) appears in dir → :b-to-a
  else                                → :a-to-b
```

### Fix: case-sensitive filename pattern matching  (`parallel-path.el`)
`parallel-path--test-file-p` binds `case-fold-search` to nil before calling
`string-match`, since filename conventions (_spec, _test, etc.) are case-sensitive
and Emacs sets `case-fold-search` to t by default.

### Fix: ERT macro quoting for list argument  (`test/parallel-path-test.el`)
`parallel-path-test--with-temp-tree` macro used `,dirs` which expanded the list
as a function call.  Fixed to `',dirs` so the directory list is quoted at expansion.

### Initial implementation  (`parallel-path.el`, `parallel-path-projectile.el`)

Added package headers, profiles defcustom, all internal pure functions,
and public commands: `parallel-path-to-root`, `parallel-path-toggle`,
`parallel-path-toggle-auto`, `parallel-path-bind` (+ other-window variants),
`parallel-path-projectile-toggle-test`, `parallel-path-projectile-switch-worktree`
(+ other-window variants).
