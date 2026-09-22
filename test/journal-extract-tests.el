;;; journal-extract-tests.el --- Tests for journal-extract  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT test suite for journal-extract.
;;
;; Run from the journal-extract/ directory:
;;
;;   emacs --batch -l test/journal-extract-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(defconst journal-extract-tests--dir
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name))))

(defconst journal-extract-tests--package-file
  (expand-file-name "../journal-extract.el" journal-extract-tests--dir))

(defconst journal-extract-tests--fixture
  (expand-file-name "test-data/journals.org" journal-extract-tests--dir))

(load-file journal-extract-tests--package-file)

(defun journal-extract-tests--blocks (text)
  "Parse TEXT and return a (TITLE TAGS BLOCK) list per date entry.
Results are in document order."
  (let (result)
    (with-temp-buffer
      (insert text)
      (org-mode)
      (let* ((tree (org-element-parse-buffer))
             (entries
              (delq nil
                    (org-element-map
                        tree 'headline
                      (lambda (h)
                        (when (and (= (org-element-property :level h)
                                      journal-extract-entry-level)
                                   (string-match-p "\\`[0-9]"
                                                   (org-element-property
                                                    :raw-value h))
                                   (not (journal-extract--ignored-p
                                         (org-element-property :tags h))))
                          h))))))
        (dolist (h entries)
          (push (list (org-element-property :raw-value h)
                      (journal-extract--collect-tags h)
                      (journal-extract--extract-block h))
                result))))
    (nreverse result)))

(defun journal-extract-tests--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun journal-extract-tests--count (regexp string)
  "Return the number of occurrences of REGEXP in STRING."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward regexp nil t)
        (setq n (1+ n)))
      n)))

(ert-deftest journal-extract-collect-tags ()
  "Tags are collected (and deduplicated) from the entry subtree."
  (let ((blocks
         (journal-extract-tests--blocks
          (concat "* Journal\n\n"
                  "** 2024-01-01 Mon 09:00\n\n"
                  "*** One :alpha:\n\n"
                  "*** Two :alpha:beta:\n\n"
                  "*** Three :beta:\n"))))
    (should (= (length blocks) 1))
    (should (equal (nth 1 (nth 0 blocks)) '("alpha" "beta")))))

(ert-deftest journal-extract-ignored-tags ()
  "Ignored tags are neither collected nor exported."
  (let ((journal-extract-ignored-tags '("copied" "private")))
    ;; A tag in the ignore list is excluded from collection.
    (let ((blocks
           (journal-extract-tests--blocks
            (concat "* Journal\n\n"
                    "** 2024-01-01 Mon 09:00\n\n"
                    "*** One :alpha:\n\n"
                    "*** Two :private:\n"))))
      (should (equal (nth 1 (nth 0 blocks)) '("alpha"))))
    ;; A date heading that itself carries an ignored tag is skipped.
    (let ((blocks
           (journal-extract-tests--blocks
            (concat "* Journal\n\n"
                    "** 2024-01-01 Mon 09:00 :private:\n\n"
                    "*** One :alpha:\n\n"
                    "** 2024-01-02 Tue 10:00\n\n"
                    "*** Two :beta:\n"))))
      (should (= (length blocks) 1))
      (should (equal (nth 1 (nth 0 blocks)) '("beta"))))))

(ert-deftest journal-extract-outdents-and-strips-tags ()
  "Moved headings are outdented one level and have their tags removed."
  (let ((blocks
         (journal-extract-tests--blocks
          (concat "* Journal\n\n"
                  "** 2024-01-01 Mon 09:00\n\n"
                  "*** Heading :alpha:\n"
                  "body text\n\n"
                  "**** Sub :beta:\n"))))
    (should (= (length blocks) 1))
    (let ((block (nth 2 (nth 0 blocks))))
      (should (string-prefix-p "** Heading\n" block))
      (should (string-match-p "\n\\*\\*\\* Sub" block))
      (should-not (string-match-p ":alpha:\\|:beta:" block)))))

(ert-deftest journal-extract-tagged-date-heading-direct-text ()
  "A tag on the date heading itself, with direct body text, is exported."
  (let ((blocks
         (journal-extract-tests--blocks
          (concat "* Journal\n\n"
                  "** 2024-01-03 Wed 09:15 :alpha:\n"
                  "Some text directly under the date heading.\n"))))
    (should (= (length blocks) 1))
    (should (equal (nth 0 (nth 0 blocks)) "2024-01-03 Wed 09:15"))
    (should (equal (nth 1 (nth 0 blocks)) '("alpha")))
    ;; The date heading is dropped and the direct text becomes the block.
    (should (string= (nth 2 (nth 0 blocks))
                     "Some text directly under the date heading."))))

(ert-deftest journal-extract-subheading-text-outdented ()
  "Outdented subheadings keep the text attached to them."
  (let ((blocks
         (journal-extract-tests--blocks
          (concat "* Journal\n\n"
                  "** 2024-01-04 Thu 10:00\n\n"
                  "*** SubHeading :beta:\n"
                  "text attached to the subheading\n\n"
                  "**** Deeper\n"
                  "deeper text\n"))))
    (should (= (length blocks) 1))
    (should (equal (nth 1 (nth 0 blocks)) '("beta")))
    (let ((block (nth 2 (nth 0 blocks))))
      ;; Text stays immediately under its (outdented) heading.
      (should (string-match-p
               "\\*\\* SubHeading\ntext attached to the subheading" block))
      (should (string-match-p
               "\\*\\*\\* Deeper\ndeeper text" block))
      (should-not (string-match-p ":beta:" block)))))

(ert-deftest journal-extract-preserve-date ()
  "When enabled, exported headings get a :DATE: property with the full header."
  (let ((journal-extract-preserve-date t))
    (let ((blocks
           (journal-extract-tests--blocks
            (concat "* Journal\n\n"
                    "** 2024-01-03 Wed 09:15\n\n"
                    "*** Note one :alpha:\n"
                    "text one\n\n"
                    "*** Note two :beta:\n"
                    "text two\n"))))
      (should (= (length blocks) 1))
      (let ((block (nth 2 (nth 0 blocks))))
        (should (string-match-p ":DATE:.*2024-01-03 Wed 09:15" block))
        ;; Both direct child headings carry the date.
        (should (= (journal-extract-tests--count ":DATE:" block) 2))))))

(ert-deftest journal-extract-tag-file-map ()
  "Tags can be mapped to a renamed or shared output file."
  (let* ((dir (make-temp-file "journal-extract-map-" t))
         (input (expand-file-name "journals.org" dir))
         (journal-extract-tag-file-map '(("alpha" . "Art") ("beta" . "Art"))))
    (unwind-protect
        (progn
          (with-temp-file input
            (insert "* Journal\n\n"
                    "** 2024-01-03 Wed 09:15\n\n"
                    "*** Note one :alpha:\n"
                    "text one\n\n"
                    "*** Note two :beta:\n"
                    "text two\n"))
          (journal-extract input dir)
          (let ((art (expand-file-name "Art.org" dir)))
            (should (file-exists-p art))
            (should-not (file-exists-p (expand-file-name "alpha.org" dir)))
            (should-not (file-exists-p (expand-file-name "beta.org" dir)))
            (let ((content (journal-extract-tests--file-string art)))
              (should (string-prefix-p "* Art\n" content))
              (should (string-match-p "\\*\\* Note one" content))
              (should (string-match-p "\\*\\* Note two" content))
              ;; Both tags map to the same file, so each note appears once.
              (should (= (journal-extract-tests--count "text one" content) 1))
              (should (= (journal-extract-tests--count "text two" content) 1)))))
      (delete-directory dir t))))

(ert-deftest journal-extract-end-to-end ()
  "The full command produces correct per-tag files and marks entries copied."
  (let* ((dir (make-temp-file "journal-extract-e2e-" t))
         (input (expand-file-name "journals.org" dir)))
    (unwind-protect
        (progn
          (copy-file journal-extract-tests--fixture input)
          (journal-extract input dir)
          (let ((alpha-file (expand-file-name "alpha.org" dir))
                (beta-file (expand-file-name "beta.org" dir)))
            (should (file-exists-p alpha-file))
            (should (file-exists-p beta-file))
            (should-not (file-exists-p (expand-file-name "copied.org" dir)))
            (let ((alpha (journal-extract-tests--file-string alpha-file))
                  (beta (journal-extract-tests--file-string beta-file))
                  (input-str (journal-extract-tests--file-string input)))
              ;; Each file starts with a top-level heading named after its tag.
              (should (string-prefix-p "* alpha\n" alpha))
              (should (string-prefix-p "* beta\n" beta))
              ;; Moved content has no tags left on its headings.
              (should-not (string-match-p ":alpha:\\|:beta:" alpha))
              (should-not (string-match-p ":alpha:\\|:beta:" beta))
              ;; Content is present and outdented.
              (should (string-match-p "\\*\\* Vestibulum ante ipsum" alpha))
              (should (string-match-p "\\*\\*\\* Ut enim ad minim" alpha))
              (should (string-match-p "\\*\\* Excepteur sint occaecat" beta))
              ;; The multi-tag entry is copied to both files.
              (should (string-match-p "\\*\\* Sed ut perspiciatis" alpha))
              (should (string-match-p "\\*\\* Sed ut perspiciatis" beta))
              ;; Entries keep document order.
              (let ((p1 (string-match "Vestibulum ante ipsum" alpha))
                    (p3 (string-match "Sed ut perspiciatis" alpha)))
                (should (and p1 p3 (< p1 p3))))
              ;; Exactly three entries were marked copied.
              (should (= (journal-extract-tests--count ":copied:" input-str) 3))
              ;; The untagged entry remains and is not marked copied.
              (should (string-match-p "At vero eos et accusamus" input-str)))))
      (delete-directory dir t))))

(ert-deftest journal-extract-idempotent ()
  "A second run makes no changes."
  (let* ((dir (make-temp-file "journal-extract-idem-" t))
         (input (expand-file-name "journals.org" dir)))
    (unwind-protect
        (progn
          (copy-file journal-extract-tests--fixture input)
          (journal-extract input dir)
          (let ((alpha-before (journal-extract-tests--file-string
                               (expand-file-name "alpha.org" dir)))
                (beta-before (journal-extract-tests--file-string
                              (expand-file-name "beta.org" dir)))
                (input-before (journal-extract-tests--file-string input)))
            (journal-extract input dir)
            (should (string= alpha-before
                             (journal-extract-tests--file-string
                              (expand-file-name "alpha.org" dir))))
            (should (string= beta-before
                             (journal-extract-tests--file-string
                              (expand-file-name "beta.org" dir))))
            (should (string= input-before
                             (journal-extract-tests--file-string input)))))
      (delete-directory dir t))))

(ert-deftest journal-extract-remove-copied ()
  "Copied date entries are removed; other entries remain."
  (let* ((dir (make-temp-file "journal-extract-rm-" t))
         (input (expand-file-name "journals.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file input
            (insert "* Journal\n\n"
                    "** 2024-01-03 Wed 09:15 :copied:\n\n"
                    "*** A note :alpha:\n"
                    "text\n\n"
                    "** 2024-01-05 Fri 14:30\n\n"
                    "*** B note :beta:\n"
                    "text2\n"))
          (should (= (journal-extract-remove-copied input) 1))
          (let ((s (journal-extract-tests--file-string input)))
            (should (string-prefix-p "* Journal\n" s))
            (should-not (string-match-p "2024-01-03" s))
            (should-not (string-match-p ":copied:" s))
            (should-not (string-match-p "A note" s))
            (should (string-match-p "2024-01-05" s))
            (should (string-match-p "B note" s)))
          ;; A second run has nothing left to remove.
          (should (= (journal-extract-remove-copied input) 0)))
      (delete-directory dir t))))

(ert-deftest journal-extract-archive-copied ()
  "Copied entries are backed up with date headers, then removed."
  (let* ((dir (make-temp-file "journal-extract-arch-" t))
         (input (expand-file-name "journals.org" dir))
         (backup (expand-file-name "journals-backup.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file input
            (insert "* Journal\n\n"
                    "** 2024-01-03 Wed 09:15 :copied:\n\n"
                    "*** A note :alpha:\n"
                    "text\n\n"
                    "** 2024-01-05 Fri 14:30 :copied:\n\n"
                    "*** B note :beta:\n"
                    "text2\n\n"
                    "** 2024-01-08 Mon 10:00\n\n"
                    "*** C note :gamma:\n"
                    "text3\n"))
          (should (= (journal-extract-archive-copied input) 2))
          (should (file-exists-p backup))
          (let ((bs (journal-extract-tests--file-string backup))
                (is (journal-extract-tests--file-string input)))
            ;; Backup starts with the source root heading.
            (should (string-prefix-p "* Journal\n" bs))
            ;; Both copied entries, with date headers, are in the backup.
            (should (string-match-p "\\*\\* 2024-01-03 Wed 09:15" bs))
            (should (string-match-p "\\*\\* 2024-01-05 Fri 14:30" bs))
            (should (string-match-p "A note" bs))
            (should (string-match-p "B note" bs))
            ;; The unmarked entry is not backed up.
            (should-not (string-match-p "2024-01-08" bs))
            (should-not (string-match-p "C note" bs))
            ;; The input keeps only the unmarked entry.
            (should-not (string-match-p "2024-01-03" is))
            (should-not (string-match-p "2024-01-05" is))
            (should-not (string-match-p ":copied:" is))
            (should (string-match-p "2024-01-08" is))
            (should (string-match-p "C note" is))))
      (delete-directory dir t))))

(ert-deftest journal-extract-prune-backup ()
  "Backup entries older than the given number of weeks are removed."
  (let* ((dir (make-temp-file "journal-extract-prune-" t))
         (backup (expand-file-name "journals-backup.org" dir))
         (old-date (format-time-string
                    "%Y-%m-%d %a %H:%M"
                    (time-subtract (current-time) (days-to-time (* 10 7)))))
         (recent-date (format-time-string
                       "%Y-%m-%d %a %H:%M"
                       (time-subtract (current-time) (days-to-time (* 2 7))))))
    (unwind-protect
        (progn
          (with-temp-file backup
            (insert "* Journal\n\n"
                    (format "** %s\n\n*** Old note :alpha:\nold text\n\n"
                            old-date)
                    (format "** %s\n\n*** Recent note :beta:\nrecent text\n\n"
                            recent-date)
                    "** 123 notes about something\n\n*** No parseable date\n\n"))
          (should (= (journal-extract-prune-backup 4 backup) 1))
          (let ((s (journal-extract-tests--file-string backup)))
            (should-not (string-match-p "Old note" s))
            (should-not (string-match-p "old text" s))
            (should (string-match-p "Recent note" s))
            (should (string-match-p "recent text" s))
            ;; An entry whose title starts with a digit but has no
            ;; parseable date is left untouched.
            (should (string-match-p "123 notes about something" s))
            (should (string-match-p "No parseable date" s))))
      (delete-directory dir t))))

(ert-deftest journal-extract-dry-run ()
  "Dry run reports without writing files or marking entries."
  (let* ((dir (make-temp-file "journal-extract-dry-" t))
         (input (expand-file-name "journals.org" dir))
         (before nil))
    (unwind-protect
        (progn
          (with-temp-file input
            (insert "* Journal\n\n"
                    "** 2024-01-03 Wed 09:15\n\n"
                    "*** Note one :alpha:\n"
                    "text one\n\n"
                    "** 2024-01-04 Thu 10:00\n\n"
                    "*** Untagged note\n"
                    "plain text\n"))
          (setq before (journal-extract-tests--file-string input))
          (journal-extract input dir t)
          (should-not (file-exists-p (expand-file-name "alpha.org" dir)))
          (should (string= before (journal-extract-tests--file-string input))))
      (delete-directory dir t))))

(ert-deftest journal-extract-dry-run-report ()
  "The dry-run report lists tagged and untagged entries."
  (let* ((plan
          (list
           (list (cons 'title "2024-01-03 Wed 09:15")
                 (cons 'tags '("alpha"))
                 (cons 'destinations '("alpha")))
           (list (cons 'title "2024-01-04 Thu 10:00")
                 (cons 'tags nil)
                 (cons 'destinations nil))))
         (report (journal-extract--dry-run-report "/in/journals.org" "/out" plan)))
    (should (string-match-p "1 tagged entry would be exported" report))
    (should (string-match-p "alpha\\.org" report))
    (should (string-match-p "1 untagged entry" report))
    (should (string-match-p "2024-01-04 Thu 10:00" report))))

(ert-deftest journal-extract-warn-untagged ()
  "Untagged entries produce a warning; tagged entries do not."
  (let (warnings)
    (cl-letf (((symbol-function 'lwarn)
               (lambda (_type _level msg &rest args)
                 (push (apply #'format msg args) warnings))))
      (journal-extract--warn-untagged
       (list (list (cons 'title "2024-01-04 Thu 10:00") (cons 'tags nil))
             (list (cons 'title "2024-01-05 Fri 14:30")
                   (cons 'tags '("alpha"))))))
    (should (= (length warnings) 1))
    (should (string-match-p "2024-01-04 Thu 10:00" (car warnings)))))

(provide 'journal-extract-tests)
;;; journal-extract-tests.el ends here
