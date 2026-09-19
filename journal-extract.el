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

(defun journal-extract--ignored-tag-p (tag)
  "Return non-nil if TAG is in `journal-extract-ignored-tags'."
  (member tag journal-extract-ignored-tags))

(defun journal-extract--ignored-p (tags)
  "Return non-nil if TAGS contains an ignored tag."
  (cl-some #'journal-extract--ignored-tag-p tags))

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
outdented one level and has its tags removed."
  (let ((children (org-element-contents headline)))
    (if (null children)
        ""
      (journal-extract--prepare-headlines children)
      (substring-no-properties
       (string-trim (org-element-interpret-data children))))))

(defun journal-extract--append-to-tag-file (dir tag text)
  "Append TEXT to the file DIR/TAG.org.
Creates the file if needed, starting it with a top-level `* TAG'
heading.  Appends to existing content otherwise."
  (let* ((file (expand-file-name (concat tag ".org") dir))
         (exists (file-exists-p file))
         (existing (when exists
                     (with-temp-buffer
                       (insert-file-contents file)
                       (string-trim-right (buffer-string)))))
         (new (if (and exists (not (string-empty-p existing)))
                  (concat existing "\n\n" text "\n")
                (concat "* " tag "\n\n" text "\n"))))
    (with-temp-file file
      (insert new))))

(defun journal-extract--mark-copied (pos)
  "Add the `:copied:' tag to the headline at POS.
Return non-nil if the tag was actually added."
  (save-excursion
    (goto-char pos)
    (let ((tags (org-get-tags nil t)))
      (unless (member "copied" tags)
        (org-set-tags (append tags '("copied")))
        t))))

;;;###autoload
(defun journal-extract (&optional input-file target-directory)
  "Extract tagged date entries from INPUT-FILE into per-tag org files.

INPUT-FILE defaults to `journal-extract-input-file' (or is prompted for
interactively when nil).  TARGET-DIRECTORY defaults to
`journal-extract-target-directory', or the directory containing
INPUT-FILE.

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
         (entries nil)
         (modified nil))
    (unless (file-readable-p input-file)
      (user-error "Input file is not readable: %s" input-file))
    (unless (file-directory-p target-directory)
      (make-directory target-directory t))
    (with-temp-buffer
      (insert-file-contents input-file)
      (org-mode)
      (let ((tree (org-element-parse-buffer)))
        (org-element-map tree 'headline
          (lambda (h)
            (when (and (= (org-element-property :level h)
                          journal-extract-entry-level)
                       (string-match-p "\\`[0-9]"
                                       (org-element-property :raw-value h))
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
        ;; Phase 1: write each tagged block to its tag file(s), in
        ;; document order.
        (dolist (h entries)
          (let ((tags (journal-extract--collect-tags h)))
            (unless (null tags)
              (let ((block (journal-extract--extract-block h)))
                (unless (string-empty-p block)
                  (dolist (tag tags)
                    (journal-extract--append-to-tag-file
                     target-directory tag block))))
              (push h to-mark))))
        ;; Phase 2: tag processed entries `:copied:', bottom-to-top, so
        ;; that editing a later entry does not shift the recorded
        ;; positions of earlier entries.
        (dolist (h to-mark)
          (when (journal-extract--mark-copied
                 (org-element-property :begin h))
            (setq modified t))))
      (when modified
        (write-region (point-min) (point-max) input-file)))
    (message "journal-extract: processed %d entries%s"
             (length entries)
             (if modified "" " (no changes)"))))

(provide 'journal-extract)
;;; journal-extract.el ends here
