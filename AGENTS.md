# AGENTS.md

Guidance and context for working on this project. Read this before making changes.

## Project: journal-extract

An Emacs Lisp utility that moves tagged entries out of a single org-mode
"journal" file into one file per tag.

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
- **Implementation approach:** use org-element parsing/interpretation rather
  than regex manipulation of raw text.

### Status

- Extractor implemented; passes byte-compile diagnostics and an end-to-end
  test (run via `emacs --batch` against a temp copy): per-tag files are
  created with a top-level `* <tag>` heading, headings are outdented and
  tag-stripped, content order is preserved, and processed entries are tagged
  `:copied:`.
- Idempotent: a second run reports no changes.
- ERT test suite in `test/` (5 tests) passes; run with
  `emacs --batch -l test/journal-extract-tests.el -f ert-run-tests-batch-and-exit`.

### Environment notes

- Project root:
- Repository: `https://github.com/pwquint24/journal-extract.git`
- Emacs 31.1 available at `/opt/homebrew/bin/emacs`.
