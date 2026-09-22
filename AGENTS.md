# AGENTS.md

Guidance and context for working on this project. Read this before making changes.

## Project: journal-extract

An Emacs Lisp utility that moves tagged entries out of a single org-mode
"journal" file into one file per tag, and can archive processed (`:copied:`)
entries to a backup file that can later be pruned by age.

### Key locations

- Package: `journal-extract.el`
- README: `README.org`
- License: `LICENSE` (GPL-3.0)
- Test suite: `test/journal-extract-tests.el`
- Test fixture: `test/test-data/journals.org` (fake lorem-ipsum data)
- Real journal: `journals.org` (personal data; gitignored, not committed)
- Per-tag output files: created in the target directory (default: this
  directory), e.g. `MyToipicA.org' also gitignored.

### Input structure

```
* Journal                              ; level 1, file root — never processed
** <date> <day> <time>                 ; level 2, a "date header" = one entry
*** ...  :SomeTag:                     ; level 3+, content; tags live here
**** ...
```

### Transformation rules

1. Parse the input file into the org-element AST with `org-element-parse-buffer`.
2. A "date entry" is a `journal-extract-entry-level` headline whose title
   starts with a digit.
3. Skip any entry already carrying an ignored tag.
4. Collect every tag in the entry's subtree (the heading itself plus all
   descendant headlines and items), excluding ignored tags.
5. For each collected tag, append the whole block (everything under the date
   heading, minus the date heading itself) to `<tag>.org` in the target
   directory.  New files start with a top-level `* TAG` heading.
6. Outdent the moved headings by one level (because the `**` parent is
   removed) and strip their tags: decrement each headline's `:level` in the
   AST and clear `:tags`, then re-serialize with `org-element-interpret-data`.
7. Keep blocks in document order within each tag file.
8. Tag the processed date heading `:copied:` via `org-set-tags`.

### Configuration

- `journal-extract-input-file` — default input file (also accepted as the
  first argument to `journal-extract`; interactive prompt when nil).
- `journal-extract-target-directory` — output directory (also the second
  argument; defaults to the input file's directory).
- `journal-extract-entry-level` — heading level of date entries (default 2).
- `journal-extract-ignored-tags` — tags to skip/never export (default
  `("copied")`).
- `journal-extract-tag-file-map` — alist mapping tags to output file base
  names; several tags may share one file (default nil).
- `journal-extract-preserve-date` — when non-nil, add a `:DATE:` property
  (full date header) to each exported heading directly under the date entry
  (default nil).
- `journal-extract-dry-run` — when non-nil, `journal-extract` reports without
  writing (default nil); `journal-extract-dry-run` is a one-off command.

### Clarified decisions

- **Multi-tag entries:** unlikely, but if present, copy the whole block to
  every tag's file (whole-block-to-each, no splitting).
- **Date check:** rudimentary — heading title starts with a digit.
- **Tag source:** collected from descendant `headline` and `item` elements.
- **Tag files:** each is created with a top-level `* <tag>` heading; moved
  headings have their tags stripped (the file's top heading conveys the
  category).
- **Marking `:copied:`:** only mark an entry that has at least one tag to
  export, so untagged entries stay available for later re-processing.
- **Backup & cleanup:** `journal-extract-archive-copied` copies every
  `:copied:` date entry — date header and tags preserved — to
  `<name>-backup.org` (created with the source's top-level heading, then
  appended to on later runs), and then removes those entries from the input.
  `journal-extract-prune-backup` removes backup entries older than N weeks by
  parsing the leading `YYYY-MM-DD` of each date header; entries without a
  parseable date are kept.
- **Shared copy path:** tag-file export and backup both write through one
  `journal-extract--append-to-file` helper; `journal-extract--entry-text`
  toggles between stripping the date header/tags (export) and preserving them
  (backup) via a `preserve-p` flag.
- **Tag → file mapping:** `journal-extract-tag-file-map` renames tag output
  files or merges several tags into one; duplicate destinations from a single
  entry are deduplicated so content is written once.
- **Date provenance:** when `journal-extract-preserve-date` is non-nil, each
  direct child heading in an exported block gets a `:DATE:` property drawer
  holding the full date header (e.g. `2026-09-18 Fri 16:50`); heading-less
  direct text is left unchanged.
- **Dry run & untagged warnings:** `journal-extract` accepts a `dry-run`
  argument (and there is a `journal-extract-dry-run` command) that reports
  tagged and untagged entries without writing.  A normal run warns about
  untagged date entries.
- **Implementation approach:** use org-element parsing/interpretation rather
  than regex manipulation of raw text.

### Status

- Extractor implemented; passes byte-compile diagnostics and an end-to-end
  test (run via `emacs --batch` against a temp copy): per-tag files are
  created with a top-level `* <tag>` heading, headings are outdented and
  tag-stripped, content order is preserved, and processed entries are tagged
  `:copied:`.
- Idempotent: a second run reports no changes.
- Backup & cleanup commands implemented: `journal-extract-remove-copied`,
  `journal-extract-archive-copied`, and `journal-extract-prune-backup`.
- Tag → file mapping (`journal-extract-tag-file-map`) and date provenance
  (`journal-extract-preserve-date`) implemented.
- Dry-run reporting (`journal-extract-dry-run`) and untagged-entry warnings
  implemented.
- ERT test suite in `test/` (15 tests) passes; run with
  `emacs --batch -l test/journal-extract-tests.el -f ert-run-tests-batch-and-exit`.

### Environment notes

- Project root:
- Repository: `https://github.com/pwquint24/journal-extract.git`
- Emacs 31.1 available at `/opt/homebrew/bin/emacs`.
