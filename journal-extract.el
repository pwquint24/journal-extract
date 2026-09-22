;;; journal-extract.el --- Extract tagged journal entries into per-tag org files -*- lexical-binding: t; -*-

;;; Commentary:

;; Scans an org-mode "journal" file and moves tagged date entries out
;; into one file per tag.
;;
;; Structure of the input file:
;;
;;   * Journal                          ; level 1, ignored
;;   ** 2026-09-18 Fri 16:50            ; level 2 = a "date entry"
;;   *** Some note ...        :ArtHist: ; content, tags live here
;;   **** A deeper note ...
;;
;; For each date entry (a level-2 heading whose title starts with a
;; digit):
;;
;;   1. Skip it if it already carries an ignored tag (`:copied:` by
;;      default).
;;   2. Collect every tag found in the entry's subtree (the date
;;      heading itself plus all descendant headlines and items),
;;      excluding ignored tags.
;;   3. For each collected tag, append the whole block (everything
;;      under the date heading, minus the date heading itself) to
;;      <TAG>.org in the target directory.  New files start with a
;;      top-level `* TAG' heading.
;;   4. Outdent the moved headings by one level, since the `**` date
;;      heading has been removed (`***` -> `**`, `****` -> `***`), and
;;      strip their tags (the file's `* TAG' heading conveys the
;;      category).
;;   5. Tag the date heading `:copied:` so later runs skip it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)

(defgroup journal-extract nil
  "Extract tagged journal entries into per-tag org files."
  :group 'org)

(defcustom journal-extract-input-file nil
  "Default input org file for `journal-extract'.
When nil, `journal-extract' prompts for the file interactively, or the
file must be supplied as an argument."
  :type '(choice (const :tag "Prompt each time" nil)
                 (file :tag "Input file")))

(defcustom journal-extract-target-directory nil
  "Default output directory for the per-tag org files.
When nil, the directory containing the input file is used."
  :type '(choice (const :tag "Input file's directory" nil)
                 (directory :tag "Output directory")))

(defcustom journal-extract-entry-level 2
  "Heading level at which date entries live."
  :type 'integer)

(defcustom journal-extract-ignored-tags '("copied")
  "List of tags to ignore.
A date entry is skipped if it already carries one of these tags, and
these tags are never exported to their own file."
  :type '(repeat string))

(defcustom journal-extract-tag-file-map nil
  "Alist mapping tags to the file base name they are written to.

Each entry is (TAG . FILE-NAME).  When a collected tag matches TAG, its
content is written to FILE-NAME.org -- with a top-level `* FILE-NAME'
heading -- instead of TAG.org.  This lets several tags share one output
file, or renames a tag's output file."
  :type '(alist :key-type string :value-type string))

(defcustom journal-extract-preserve-date nil
  "When non-nil, add the source date header to exported content.

Each heading directly under the date entry gets a :DATE: property
drawer holding the entry's full date header (for example
`2026-09-18 Fri 16:50').  Direct text with no heading is left
unchanged."
  :type 'boolean)

(defcustom journal-extract-dry-run nil
  "When non-nil, `journal-extract' reports without writing anything.
Useful for previewing the extraction before making changes."
  :type 'boolean)

(defun journal-extract--ignored-tag-p (tag)
  "Return non-nil if TAG is in `journal-extract-ignored-tags'."
  (member tag journal-extract-ignored-tags))

(defun journal-extract--ignored-p (tags)
  "Return non-nil if TAGS contains an ignored tag."
  (cl-some #'journal-extract--ignored-tag-p tags))

(defun journal-extract--entry-date-string (headline)
  "Return HEADLINE's leading YYYY-MM-DD date as a string, or nil."
  (let ((raw (org-element-property :raw-value headline)))
    (when (string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"
                        raw)
      (match-string 1 raw))))

(defun journal-extract--collect-tags (headline)
  "Collect distinct tags in HEADLINE's subtree.
Includes HEADLINE's own tags and all descendant headlines and items,
excluding any tag in `journal-extract-ignored-tags'."
  (let (result)
    (cl-labels ((collect (tags)
                  (dolist (tag tags)
                    (unless (or (member tag result)
                                (journal-extract--ignored-tag-p tag))
                      (push tag result))))
                (walk (el)
                  (when (memq (org-element-type el) '(headline item))
                    (collect (org-element-property :tags el)))
                  (dolist (child (org-element-contents el))
                    (walk child))))
      (collect (org-element-property :tags headline))
      (dolist (child (org-element-contents headline))
        (walk child)))
    (nreverse result)))

(defun journal-extract--prepare-headlines (data)
  "Prepare headlines in DATA for export.
For every headline: reduce its level by one (never below 1) and clear
its tags.  DATA is an org-element parse-tree node, or a list of them."
  (cond
   ((null data) nil)
   ((stringp data) data)
   ((eq (org-element-type data) 'headline)
    (org-element-put-property data :level
                              (max 1 (1- (org-element-property :level data))))
    (org-element-put-property data :tags nil)
    (dolist (child (org-element-contents data))
      (journal-extract--prepare-headlines child))
    data)
   ((org-element-type data)
    (dolist (child (org-element-contents data))
      (journal-extract--prepare-headlines child))
    data)
   (t
    (dolist (el data)
      (journal-extract--prepare-headlines el))
    data)))

(defun journal-extract--extract-block (headline)
  "Return HEADLINE's contents, excluding the headline line.
Rebuilds the block from the org-element parse tree: each heading is
outdented one level and has its tags removed.  When
`journal-extract-preserve-date' is non-nil, each direct child heading
also gets the entry's full date header as a :DATE: property."
  (let ((children (org-element-contents headline)))
    (if (null children)
        ""
      (journal-extract--prepare-headlines children)
      (when journal-extract-preserve-date
        (journal-extract--preserve-dates headline children))
      (substring-no-properties
       (string-trim (org-element-interpret-data children))))))

(defun journal-extract--add-date-property (headline timestamp)
  "Insert a :DATE: property drawer holding TIMESTAMP into HEADLINE."
  (let* ((section (car (org-element-contents headline)))
         (node (org-element-create 'node-property
                                   (list :key "DATE" :value timestamp)))
         (drawer (org-element-create 'property-drawer nil node)))
    (when (eq (org-element-type section) 'section)
      (org-element-set-contents section
                                (cons drawer (org-element-contents section))))
    headline))

(defun journal-extract--preserve-dates (date-headline children)
  "Add DATE-HEADLINE's full header timestamp to each child in CHILDREN."
  (let ((timestamp (org-element-property :raw-value date-headline)))
    (when (and timestamp (not (string-empty-p timestamp)))
      (dolist (child children)
        (when (eq (org-element-type child) 'headline)
          (journal-extract--add-date-property child timestamp))))))

(defun journal-extract--entry-text (headline preserve-p)
  "Return the text to copy for date entry HEADLINE.

When PRESERVE-P is nil, drop the date headline, outdent child headings,
and strip their tags (used when exporting to per-tag topic files).
When non-nil, return the entry verbatim, keeping its date header and
tags (used when backing up)."
  (if preserve-p
      (string-trim
       (buffer-substring-no-properties
        (org-element-property :begin headline)
        (org-element-property :end headline)))
    (journal-extract--extract-block headline)))

(defun journal-extract--append-to-file (file heading text)
  "Append TEXT to FILE.
Creates FILE with a top-level `* HEADING' heading when it does not
exist.  Appends to existing content otherwise."
  (let* ((exists (file-exists-p file))
         (existing (when exists
                     (with-temp-buffer
                       (insert-file-contents file)
                       (string-trim-right (buffer-string)))))
         (new (if (and exists (not (string-empty-p existing)))
                  (concat existing "\n\n" text "\n")
                (concat "* " heading "\n\n" text "\n"))))
    (with-temp-file file
      (insert new))))

(defun journal-extract--tag-destination (tag)
  "Return the file base name TAG should be written to.
Uses `journal-extract-tag-file-map'; defaults to TAG itself."
  (or (cdr (assoc tag journal-extract-tag-file-map)) tag))

(defun journal-extract--copy-to-tag-files (dir headline tags)
  "Copy HEADLINE to one file per tag destination in TAGS.

For each tag, the destination file is DIR/<name>.org where <name> is
the tag's `journal-extract-tag-file-map' mapping, or the tag itself.
The date headline is dropped and tags are stripped from the copied
content.  The stripped text is computed once, and tags that map to the
same destination receive a single copy."
  (let ((text (journal-extract--entry-text headline nil)))
    (unless (string-empty-p text)
      (dolist (dest (delete-dups
                     (mapcar #'journal-extract--tag-destination tags)))
        (journal-extract--append-to-file
         (expand-file-name (concat dest ".org") dir) dest text)))))

(defun journal-extract--mark-copied (pos)
  "Add the `:copied:' tag to the headline at POS.
Return non-nil if the tag was actually added."
  (save-excursion
    (goto-char pos)
    (let ((tags (org-get-tags nil t)))
      (unless (member "copied" tags)
        (org-set-tags (append tags '("copied")))
        t))))

(defun journal-extract--date-entry-p (headline)
  "Return non-nil if HEADLINE is a date entry.
A date entry is a `journal-extract-entry-level' headline whose title
starts with a digit."
  (and (= (org-element-property :level headline)
          journal-extract-entry-level)
       (string-match-p "\\`[0-9]"
                       (org-element-property :raw-value headline))))

(defun journal-extract--copied-p (headline)
  "Return non-nil if HEADLINE carries the `copied' tag."
  (member "copied" (org-element-property :tags headline)))

(defun journal-extract--copied-entries (tree)
  "Return `copied' date entries in TREE, in document order."
  (let (entries)
    (org-element-map tree 'headline
      (lambda (h)
        (when (and (journal-extract--date-entry-p h)
                   (journal-extract--copied-p h))
          (push h entries))
        nil))
    (sort entries
          (lambda (a b)
            (< (org-element-property :begin a)
               (org-element-property :begin b))))))

(defun journal-extract--delete-entries (entries)
  "Delete each headline in ENTRIES from the current buffer.
ENTRIES must be sorted in ascending `:begin' order.  Deletion runs
bottom-to-top so earlier buffer positions stay valid."
  (dolist (h (nreverse (copy-sequence entries)))
    (delete-region (org-element-property :begin h)
                   (org-element-property :end h))))

(defun journal-extract--normalize-blank-lines ()
  "Tidy up the current buffer after deletions.
Collapses runs of blank lines and leaves a single trailing newline."
  (goto-char (point-min))
  (while (re-search-forward "\n\n\n+" nil t)
    (replace-match "\n\n"))
  (goto-char (point-max))
  (skip-chars-backward "\n")
  (delete-region (point) (point-max))
  (insert "\n"))

(defun journal-extract--root-title (tree)
  "Return the title of the top-level heading in TREE.
Falls back to \"Journal\" when TREE has no level-1 heading."
  (let ((root
         (org-element-map tree 'headline
           (lambda (h)
             (when (= 1 (org-element-property :level h)) h))
           nil t)))
    (if (and root (org-element-property :raw-value root))
        (org-element-property :raw-value root)
      "Journal")))

(defun journal-extract--backup-file-name (input-file)
  "Return the default backup file name for INPUT-FILE.
Inserts `-backup' before the extension: journals.org becomes
journals-backup.org."
  (let ((dir (file-name-directory input-file))
        (base (file-name-base input-file))
        (ext (file-name-extension input-file)))
    (expand-file-name
     (if ext
         (concat base "-backup." ext)
       (concat base "-backup"))
     dir)))

(defun journal-extract--copy-to-backup (file root-title headline)
  "Copy HEADLINE verbatim to FILE, creating it with `* ROOT-TITLE'.
Keeps the date header and tags."
  (let ((text (journal-extract--entry-text headline t)))
    (unless (string-empty-p text)
      (journal-extract--append-to-file file root-title text))))

(defun journal-extract--entry-date (headline)
  "Return HEADLINE's leading YYYY-MM-DD date as a time value.
Returns nil when the title does not start with a parseable date."
  (let ((date (journal-extract--entry-date-string headline)))
    (and date (date-to-time date))))

(defun journal-extract--old-entries (tree weeks)
  "Return date entries in TREE older than WEEKS weeks, in document order.
Entries without a parseable leading date are left untouched."
  (let* ((today (time-to-days (current-time)))
         (cutoff (- today (* weeks 7)))
         (entries nil))
    (org-element-map tree 'headline
      (lambda (h)
        (when (journal-extract--date-entry-p h)
          (let ((date (journal-extract--entry-date h)))
            (when (and date (< (time-to-days date) cutoff))
              (push h entries))))
        nil))
    (sort entries
          (lambda (a b)
            (< (org-element-property :begin a)
               (org-element-property :begin b))))))

(defun journal-extract--warn-untagged (plan)
  "Warn about untagged date entries in PLAN.
PLAN is a list of alists with `title' and `tags' keys."
  (dolist (entry plan)
    (unless (cdr (assq 'tags entry))
      (lwarn 'journal-extract :warning
             "Untagged date entry (not exported): %s"
             (cdr (assq 'title entry))))))

(defun journal-extract--dry-run-report (input-file target-directory plan)
  "Return a human-readable dry-run report for PLAN.

INPUT-FILE and TARGET-DIRECTORY are shown at the top of the report."
  (let ((tagged (cl-remove-if-not (lambda (e) (cdr (assq 'tags e))) plan))
        (untagged (cl-remove-if (lambda (e) (cdr (assq 'tags e))) plan)))
    (with-temp-buffer
      (insert "journal-extract dry run\n")
      (insert (format "Input:  %s\n" input-file))
      (insert (format "Target: %s\n\n" target-directory))
      (if tagged
          (progn
            (insert (format "%d tagged %s would be exported:\n"
                            (length tagged)
                            (if (= (length tagged) 1) "entry" "entries")))
            (dolist (e tagged)
              (insert (format "  %s\n" (cdr (assq 'title e))))
              (insert (format "    tags: %s\n"
                              (string-join (cdr (assq 'tags e)) ", ")))
              (insert (format "    -> %s\n"
                              (string-join
                               (mapcar (lambda (d) (concat d ".org"))
                                       (cdr (assq 'destinations e)))
                               ", ")))))
        (insert "No tagged entries to export.\n"))
      (when untagged
        (insert (format "\n%d untagged %s (no tags to export):\n"
                        (length untagged)
                        (if (= (length untagged) 1) "entry" "entries")))
        (dolist (e untagged)
          (insert (format "  %s\n" (cdr (assq 'title e))))))
      (buffer-string))))

(defun journal-extract--show-report (report)
  "Display REPORT.
In batch mode print to standard output; otherwise show it in a buffer."
  (if noninteractive
      (princ (concat report "\n"))
    (with-output-to-temp-buffer "*journal-extract*"
      (princ report))))

;;;###autoload
(defun journal-extract (&optional input-file target-directory dry-run)
  "Extract tagged date entries from INPUT-FILE into per-tag org files.

INPUT-FILE defaults to `journal-extract-input-file' (or is prompted for
interactively when nil).  TARGET-DIRECTORY defaults to
`journal-extract-target-directory', or the directory containing
INPUT-FILE.

When DRY-RUN is non-nil (or `journal-extract-dry-run' is non-nil), no
files are written and no entries are marked; a report of what would
happen is shown instead.

Date entries are `journal-extract-entry-level' headlines whose title
starts with a digit.  Entries already carrying an
`journal-extract-ignored-tags' tag are skipped.  For each remaining
entry, tags in its subtree are collected (excluding ignored tags) and
the entry's content -- minus its heading, outdented one level, with
tags removed -- is appended to one <TAG>.org file per tag.  New files
start with a top-level `* TAG' heading.  Processed entries are tagged
`:copied:'."
  (interactive
   (list (or journal-extract-input-file
             (read-file-name "Input org file: "))
         (or journal-extract-target-directory
             (read-directory-name "Target directory: "))))
  (let* ((input-file (expand-file-name
                      (or input-file journal-extract-input-file)))
         (target-directory
          (expand-file-name
           (or target-directory
               journal-extract-target-directory
               (file-name-directory input-file))))
         (dry-run (or dry-run journal-extract-dry-run))
         (entries nil)
         (modified nil)
         (plan nil))
    (unless (file-readable-p input-file)
      (user-error "Input file is not readable: %s" input-file))
    (unless (or dry-run (file-directory-p target-directory))
      (make-directory target-directory t))
    (with-temp-buffer
      (insert-file-contents input-file)
      (org-mode)
      (let ((tree (org-element-parse-buffer)))
        (org-element-map tree 'headline
          (lambda (h)
            (when (and (journal-extract--date-entry-p h)
                       (not (journal-extract--ignored-p
                             (org-element-property :tags h))))
              (push h entries)))))
      ;; Keep entries in document order so exported content preserves
      ;; the original ordering.
      (setq entries
            (sort entries
                  (lambda (a b)
                    (< (org-element-property :begin a)
                       (org-element-property :begin b)))))
      (let (to-mark)
        (dolist (h entries)
          (let* ((tags (journal-extract--collect-tags h))
                 (dests (and tags
                             (delete-dups
                              (mapcar #'journal-extract--tag-destination
                                      tags)))))
            (push (list (cons 'title (org-element-property :raw-value h))
                        (cons 'tags tags)
                        (cons 'destinations dests))
                  plan)
            (unless (or dry-run (null tags))
              (journal-extract--copy-to-tag-files target-directory h tags)
              (push h to-mark))))
        (setq plan (nreverse plan))
        (unless dry-run
          ;; Tag processed entries `:copied:', bottom-to-top, so that
          ;; editing a later entry does not shift the recorded
          ;; positions of earlier entries.
          (dolist (h to-mark)
            (when (journal-extract--mark-copied
                   (org-element-property :begin h))
              (setq modified t)))))
      (unless dry-run
        (when modified
          (write-region (point-min) (point-max) input-file))))
    (if dry-run
        (journal-extract--show-report
         (journal-extract--dry-run-report input-file target-directory plan))
      (journal-extract--warn-untagged plan))
    (message "journal-extract: %s %d entries%s"
             (if dry-run "would process" "processed")
             (length entries)
             (if dry-run "" (if modified "" " (no changes)")))))

;;;###autoload
(defun journal-extract-dry-run (&optional input-file target-directory)
  "Preview what `journal-extract' would do, without writing anything.

INPUT-FILE and TARGET-DIRECTORY default the same way as in
`journal-extract'.  Shows a report of which entries would be exported,
to which files, and which entries have no tags."
  (interactive
   (list (or journal-extract-input-file
             (read-file-name "Input org file: "))
         (or journal-extract-target-directory
             (read-directory-name "Target directory: "))))
  (journal-extract input-file target-directory t))

;;;###autoload
(defun journal-extract-remove-copied (&optional input-file)
  "Remove all `copied' date entries from INPUT-FILE.

INPUT-FILE defaults to `journal-extract-input-file' (or is prompted for
interactively when nil).  Removes each date entry whose heading carries
the `copied' tag, together with its subtree."
  (interactive
   (list (or journal-extract-input-file
             (read-file-name "Input org file: "))))
  (let* ((input-file (expand-file-name
                      (or input-file journal-extract-input-file)))
         (removed 0))
    (unless (file-readable-p input-file)
      (user-error "Input file is not readable: %s" input-file))
    (with-temp-buffer
      (insert-file-contents input-file)
      (org-mode)
      (let* ((tree (org-element-parse-buffer))
             (entries (journal-extract--copied-entries tree)))
        (setq removed (length entries))
        (when entries
          (journal-extract--delete-entries entries)
          (journal-extract--normalize-blank-lines)
          (write-region (point-min) (point-max) input-file))))
    (message "journal-extract: removed %d copied %s"
             removed (if (= removed 1) "entry" "entries"))
    removed))

;;;###autoload
(defun journal-extract-archive-copied (&optional input-file backup-file)
  "Back up `copied' date entries from INPUT-FILE, then remove them.

Copies every `copied' date entry -- including its date header and
subtree -- to BACKUP-FILE, then removes those entries from INPUT-FILE.
BACKUP-FILE defaults to INPUT-FILE with `-backup' inserted before the
extension (for example journals.org becomes journals-backup.org)."
  (interactive
   (list (or journal-extract-input-file
             (read-file-name "Input org file: "))))
  (let* ((input-file (expand-file-name
                      (or input-file journal-extract-input-file)))
         (backup-file
          (expand-file-name
           (or backup-file
               (journal-extract--backup-file-name input-file))))
         (archived 0))
    (unless (file-readable-p input-file)
      (user-error "Input file is not readable: %s" input-file))
    (with-temp-buffer
      (insert-file-contents input-file)
      (org-mode)
      (let* ((tree (org-element-parse-buffer))
             (entries (journal-extract--copied-entries tree))
             (root (journal-extract--root-title tree)))
        (setq archived (length entries))
        (dolist (h entries)
          (journal-extract--copy-to-backup backup-file root h))))
    (journal-extract-remove-copied input-file)
    (message "journal-extract: archived %d copied %s to %s"
             archived (if (= archived 1) "entry" "entries") backup-file)
    archived))

;;;###autoload
(defun journal-extract-prune-backup (weeks &optional backup-file)
  "Remove date entries older than WEEKS weeks from BACKUP-FILE.

BACKUP-FILE defaults to the `-backup' file derived from
`journal-extract-input-file'.  An entry is removed when its date header
is more than WEEKS weeks in the past; entries without a parseable date
are left untouched."
  (interactive
   (let* ((input (or journal-extract-input-file
                     (read-file-name "Input org file: "))))
     (list (string-to-number
            (read-string "Prune entries older than (weeks): " "52"))
           (journal-extract--backup-file-name input))))
  (let* ((backup-file
          (expand-file-name
           (or backup-file
               (journal-extract--backup-file-name
                (or journal-extract-input-file
                    (user-error "Cannot derive backup file: journal-extract-input-file is nil; pass BACKUP-FILE"))))))
         (weeks (max 0 (truncate weeks)))
         (removed 0))
    (unless (file-readable-p backup-file)
      (user-error "Backup file is not readable: %s" backup-file))
    (with-temp-buffer
      (insert-file-contents backup-file)
      (org-mode)
      (let* ((tree (org-element-parse-buffer))
             (entries (journal-extract--old-entries tree weeks)))
        (setq removed (length entries))
        (when entries
          (journal-extract--delete-entries entries)
          (journal-extract--normalize-blank-lines)
          (write-region (point-min) (point-max) backup-file))))
    (message "journal-extract: pruned %d %s from %s"
             removed (if (= removed 1) "entry" "entries") backup-file)
    removed))

(provide 'journal-extract)
;;; journal-extract.el ends here
