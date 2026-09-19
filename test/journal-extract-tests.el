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

(provide 'journal-extract-tests)
;;; journal-extract-tests.el ends here
