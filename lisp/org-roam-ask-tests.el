;;; org-roam-ask-tests.el --- Tests for org-roam-ask -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the parts of org-roam-ask that do not need a live Ollama:
;; the chunker, the vector maths, the index format, and the incremental
;; reindexing plan.
;;
;; Run with:
;;   emacs -Q --batch -L lisp -l ert -l lisp/org-roam-ask-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-roam-ask)


;;; ----------------------------------------------------------------------
;;; Helpers
;;; ----------------------------------------------------------------------

(defmacro org-roam-ask-tests--with-notes (spec &rest body)
  "Create the notes described by SPEC in a temp dir and run BODY.
SPEC is a list of (FILENAME . CONTENTS).  The directory is bound to
`dir' and used as `org-roam-ask-directory'."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "org-roam-ask-test" t))
          (org-roam-ask-directory dir)
          (org-roam-ask-index-file (expand-file-name "index.eld" dir))
          (org-roam-ask--index nil))
     (unwind-protect
         (progn
           (dolist (note ,spec)
             (let ((file (expand-file-name (car note) dir)))
               (with-temp-file file (insert (cdr note)))))
           ,@body)
       (delete-directory dir t))))

(defun org-roam-ask-tests--note (id title body)
  "Return the text of a note with ID, TITLE and BODY."
  (format ":PROPERTIES:\n:ID:       %s\n:END:\n#+title: %s\n\n%s" id title body))

(defun org-roam-ask-tests--vec (&rest values)
  "Return VALUES as a float vector."
  (vconcat (mapcar #'float values)))


;;; ----------------------------------------------------------------------
;;; Vector maths
;;; ----------------------------------------------------------------------

(ert-deftest org-roam-ask-test-normalize ()
  "Normalising yields a unit vector."
  (let ((v (org-roam-ask--normalize (org-roam-ask-tests--vec 3 4))))
    (should (< (abs (- (aref v 0) 0.6)) 1e-6))
    (should (< (abs (- (aref v 1) 0.8)) 1e-6))
    (should (< (abs (- (org-roam-ask--dot v v) 1.0)) 1e-6))))

(ert-deftest org-roam-ask-test-normalize-zero ()
  "A zero vector survives normalisation without dividing by zero."
  (let ((v (org-roam-ask--normalize (org-roam-ask-tests--vec 0 0))))
    (should (= (aref v 0) 0.0))))

(ert-deftest org-roam-ask-test-dot-orthogonal ()
  "Orthogonal unit vectors have a cosine of zero."
  (should (< (abs (org-roam-ask--dot (org-roam-ask-tests--vec 1 0)
                                     (org-roam-ask-tests--vec 0 1)))
             1e-6)))

(ert-deftest org-roam-ask-test-quantize-roundtrip ()
  "Quantising to int8 and back preserves cosine to within 1e-2."
  (let ((v (org-roam-ask--normalize
            (vconcat (cl-loop for i below 768
                              collect (sin (* 0.1 i)))))))
    (pcase-let* ((`(,scale . ,b64) (org-roam-ask--quantize v))
                 (back (org-roam-ask--dequantize b64 scale)))
      (should (= (length back) 768))
      (should (> (org-roam-ask--dot v back) 0.99)))))

(ert-deftest org-roam-ask-test-rank-orders-by-score ()
  "Ranking returns the closest chunks first and honours the limit."
  (let* ((mk (lambda (name vec)
               (org-roam-ask--chunk-make :hash name :title name :text name
                                         :vec (org-roam-ask--normalize vec))))
         (near (funcall mk "near" (org-roam-ask-tests--vec 1 0.1)))
         (mid (funcall mk "mid" (org-roam-ask-tests--vec 1 1)))
         (far (funcall mk "far" (org-roam-ask-tests--vec 0 1)))
         (query (org-roam-ask--normalize (org-roam-ask-tests--vec 1 0)))
         (ranked (org-roam-ask--rank query (list far mid near) 2)))
    (should (equal (mapcar (lambda (r) (org-roam-ask-chunk-title (car r))) ranked)
                   '("near" "mid")))
    (should (> (cdr (nth 0 ranked)) (cdr (nth 1 ranked))))))

(ert-deftest org-roam-ask-test-rank-skips-unembedded ()
  "Chunks without a vector are never returned."
  (let ((bare (org-roam-ask--chunk-make :hash "bare" :title "bare" :vec nil)))
    (should (null (org-roam-ask--rank (org-roam-ask-tests--vec 1 0) (list bare) 5)))))


;;; ----------------------------------------------------------------------
;;; Cleaning and chunking
;;; ----------------------------------------------------------------------

(ert-deftest org-roam-ask-test-clean-text ()
  "Drawers and export keywords are stripped, prose is kept."
  (let ((cleaned (org-roam-ask--clean-text
                  (concat ":PROPERTIES:\n:ID: abc\n:END:\n"
                          "#+LATEX_HEADER: \\usepackage{tcolorbox}\n"
                          "#+OPTIONS: toc:nil\n"
                          "Real prose here.\n"))))
    (should (equal cleaned "Real prose here."))))

(ert-deftest org-roam-ask-test-clean-text-unterminated-drawer ()
  "An unterminated drawer does not swallow the parser."
  (should (equal (org-roam-ask--clean-text ":PROPERTIES:\n:ID: abc\n") "")))

(ert-deftest org-roam-ask-test-pack-merges-small-sections ()
  "Many tiny sections collapse into one chunk rather than many.
This is the case that dominates the real corpus, where the median
section is under 100 characters."
  (let* ((org-roam-ask-chunk-size 1500)
         (org-roam-ask-chunk-min 250)
         (org-roam-ask-chunk-max 3000)
         (sections (cl-loop for i below 20
                            collect (list :olp (list "Root" (format "H%d" i))
                                          :pos (* 10 i)
                                          :text (format "Tiny body %d." i))))
         (packed (org-roam-ask--pack-sections sections)))
    (should (= (length packed) 1))
    (should (string-match-p "Tiny body 0\\." (plist-get (car packed) :text)))
    (should (string-match-p "Tiny body 19\\." (plist-get (car packed) :text)))))

(ert-deftest org-roam-ask-test-pack-splits-large-section ()
  "A section far over the cap is split into several chunks."
  (let* ((org-roam-ask-chunk-size 500)
         (org-roam-ask-chunk-max 800)
         (org-roam-ask-chunk-overlap 50)
         (body (mapconcat (lambda (i) (format "Paragraph number %d. %s" i (make-string 200 ?x)))
                          (number-sequence 1 10)
                          "\n\n"))
         (packed (org-roam-ask--pack-sections
                  (list (list :olp '("Big") :pos 1 :text body)))))
    (should (> (length packed) 3))
    (dolist (unit packed)
      (should (equal (plist-get unit :olp) '("Big"))))))

(ert-deftest org-roam-ask-test-pack-does-not-merge-across-roots ()
  "Sections under different top-level headings never share a chunk."
  (let* ((org-roam-ask-chunk-size 100000)
         (org-roam-ask-chunk-min 1)
         (packed (org-roam-ask--pack-sections
                  (list (list :olp '("Alpha") :pos 1 :text "alpha body")
                        (list :olp '("Beta") :pos 2 :text "beta body")))))
    (should (= (length packed) 2))
    (should (equal (plist-get (nth 0 packed) :olp) '("Alpha")))
    (should (equal (plist-get (nth 1 packed) :olp) '("Beta")))))

(ert-deftest org-roam-ask-test-pack-skips-empty-sections ()
  "Headings with no body contribute nothing on their own."
  (should (null (org-roam-ask--pack-sections
                 (list (list :olp '("Empty") :pos 1 :text ""))))))

(ert-deftest org-roam-ask-test-chunk-file-metadata ()
  "Chunks carry the file title, the file-level ID and the outline path."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (org-roam-ask-tests--note
                   "AAAA-BBBB" "Linear Algebra"
                   "* Vector Spaces\nA vector space is a set with addition.\n")))
    (let* ((file (expand-file-name "note.org" dir))
           (chunks (let ((org-roam-ask-chunk-min 1))
                     (org-roam-ask--chunk-file file))))
      (should (= (length chunks) 1))
      (let ((chunk (car chunks)))
        (should (equal (org-roam-ask-chunk-node-id chunk) "AAAA-BBBB"))
        (should (equal (org-roam-ask-chunk-title chunk) "Linear Algebra"))
        (should (equal (org-roam-ask-chunk-olp chunk) '("Vector Spaces")))
        ;; The embedded text leads with a breadcrumb so the vector carries
        ;; document context, not just the bare sentence.
        (should (string-prefix-p "Linear Algebra > Vector Spaces"
                                 (org-roam-ask-chunk-text chunk)))
        (should (string-match-p "set with addition" (org-roam-ask-chunk-text chunk)))
        (should (equal (org-roam-ask-chunk-hash chunk)
                       (secure-hash 'sha1 (org-roam-ask-chunk-text chunk))))))))

(ert-deftest org-roam-ask-test-chunk-file-ignores-heading-ids ()
  "A heading ID is never mistaken for the file's node ID."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (concat ":PROPERTIES:\n:ID:       FILE-ID\n:END:\n"
                          "#+title: T\n\n"
                          "* Heading\n:PROPERTIES:\n:ID:       HEADING-ID\n:END:\n"
                          "Body text that is long enough to matter.\n")))
    (let ((chunks (let ((org-roam-ask-chunk-min 1))
                    (org-roam-ask--chunk-file (expand-file-name "note.org" dir)))))
      (should (cl-every (lambda (c) (equal (org-roam-ask-chunk-node-id c) "FILE-ID"))
                        chunks)))))

(ert-deftest org-roam-ask-test-chunk-file-without-id-is-skipped ()
  "A note with no ID is skipped rather than indexed without a link target."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org" "#+title: No ID\n\n* Heading\nBody.\n"))
    (let ((warning-minimum-log-level :emergency))
      (should (null (org-roam-ask--chunk-file (expand-file-name "note.org" dir)))))))

(ert-deftest org-roam-ask-test-chunk-file-drops-keyword-only-preamble ()
  "A note whose preamble is only keywords yields no preamble chunk.
Without this, every note in the collection would contribute a junk chunk
containing nothing but its own title line."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (concat ":PROPERTIES:\n:ID:       ID1\n:END:\n"
                          "#+title: Only A Title\n"
                          "#+LATEX_HEADER: \\usepackage{amsmath}\n\n"
                          "* Heading\nReal body text.\n")))
    (let ((chunks (let ((org-roam-ask-chunk-min 1))
                    (org-roam-ask--chunk-file (expand-file-name "note.org" dir)))))
      (should (= (length chunks) 1))
      (should (equal (org-roam-ask-chunk-olp (car chunks)) '("Heading"))))))

(ert-deftest org-roam-ask-test-chunk-file-keeps-src-blocks ()
  "Block delimiters survive keyword stripping."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (org-roam-ask-tests--note
                   "ID1" "Code"
                   "* Snippet\n#+begin_src emacs-lisp\n(message \"hi\")\n#+end_src\n")))
    (let ((chunks (let ((org-roam-ask-chunk-min 1))
                    (org-roam-ask--chunk-file (expand-file-name "note.org" dir)))))
      (should (string-match-p "begin_src" (org-roam-ask-chunk-text (car chunks))))
      (should (string-match-p "message" (org-roam-ask-chunk-text (car chunks)))))))

(ert-deftest org-roam-ask-test-chunk-file-preamble ()
  "Text before the first heading is indexed too."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (org-roam-ask-tests--note
                   "ID1" "Preamble Note"
                   "Standalone thought with no heading at all.\n")))
    (let ((chunks (let ((org-roam-ask-chunk-min 1))
                    (org-roam-ask--chunk-file (expand-file-name "note.org" dir)))))
      (should (= (length chunks) 1))
      (should (null (org-roam-ask-chunk-olp (car chunks))))
      (should (string-match-p "Standalone thought"
                              (org-roam-ask-chunk-text (car chunks)))))))


;;; ----------------------------------------------------------------------
;;; Index serialisation
;;; ----------------------------------------------------------------------

(ert-deftest org-roam-ask-test-index-roundtrip ()
  "Saving and loading an index preserves chunks and their vectors."
  (org-roam-ask-tests--with-notes nil
    (let* ((vec (org-roam-ask--normalize (org-roam-ask-tests--vec 1 2 3 4)))
           (chunk (org-roam-ask--chunk-make
                   :hash "h1" :file "/tmp/a.org" :node-id "ID1" :title "A"
                   :olp '("H") :pos 42 :text "text" :vec vec))
           (index (plist-put (org-roam-ask--empty-index) :chunks (list chunk))))
      (org-roam-ask--index-save index)
      (setq org-roam-ask--index nil)
      (let* ((loaded (org-roam-ask--index-load))
             (back (car (plist-get loaded :chunks))))
        (should (equal (org-roam-ask-chunk-hash back) "h1"))
        (should (equal (org-roam-ask-chunk-olp back) '("H")))
        (should (equal (org-roam-ask-chunk-pos back) 42))
        (should (> (org-roam-ask--dot vec (org-roam-ask-chunk-vec back)) 0.99))))))

(ert-deftest org-roam-ask-test-index-invalidated-on-model-change ()
  "An index built with another embedding model is discarded, not trusted."
  (org-roam-ask-tests--with-notes nil
    (let ((chunk (org-roam-ask--chunk-make :hash "h" :text "t" :vec (org-roam-ask-tests--vec 1))))
      (let ((org-roam-ask-embedding-model "model-a"))
        (org-roam-ask--index-save
         (plist-put (org-roam-ask--empty-index) :chunks (list chunk))))
      (setq org-roam-ask--index nil)
      (let ((org-roam-ask-embedding-model "model-b"))
        (should (null (plist-get (org-roam-ask--index-load) :chunks)))))))

(ert-deftest org-roam-ask-test-index-load-survives-corruption ()
  "A corrupt index file yields an empty index instead of an error."
  (org-roam-ask-tests--with-notes nil
    (with-temp-file org-roam-ask-index-file (insert "(:version 1 :chunks ("))
    (setq org-roam-ask--index nil)
    (let ((warning-minimum-log-level :emergency))
      (should (null (plist-get (org-roam-ask--index-load) :chunks))))))


;;; ----------------------------------------------------------------------
;;; Incremental reindexing
;;; ----------------------------------------------------------------------

(ert-deftest org-roam-ask-test-index-plan-classifies-files ()
  "New, changed, unchanged and removed files each land in the right bucket."
  (org-roam-ask-tests--with-notes
      (list (cons "stable.org" (org-roam-ask-tests--note "ID1" "Stable" "* H\nBody.\n"))
            (cons "edited.org" (org-roam-ask-tests--note "ID2" "Edited" "* H\nBefore.\n")))
    (let* ((stable (expand-file-name "stable.org" dir))
           (edited (expand-file-name "edited.org" dir))
           (gone (expand-file-name "gone.org" dir))
           ;; An index that knows all three files as they stand now.
           (index (plist-put (org-roam-ask--empty-index)
                             :files
                             (list (cons stable (cons (org-roam-ask--file-hash stable)
                                                      (org-roam-ask--file-stat stable)))
                                   (cons edited (cons (org-roam-ask--file-hash edited)
                                                      (org-roam-ask--file-stat edited)))
                                   (cons gone (cons "deadbeef" (list 0.0 0)))))))
      ;; Change one file and introduce another.
      (with-temp-file edited
        (insert (org-roam-ask-tests--note "ID2" "Edited" "* H\nAfter, quite different.\n")))
      (let* ((fresh (expand-file-name "fresh.org" dir))
             (_ (with-temp-file fresh
                  (insert (org-roam-ask-tests--note "ID3" "Fresh" "* H\nNew.\n"))))
             (plan (org-roam-ask--index-plan index (list stable edited fresh))))
        (should (equal (plist-get plan :new) (list fresh)))
        (should (equal (plist-get plan :changed) (list edited)))
        (should (equal (plist-get plan :unchanged) (list stable)))
        (should (equal (plist-get plan :removed) (list gone)))))))

(ert-deftest org-roam-ask-test-index-plan-ignores-touch ()
  "Touching a file without editing it does not mark it changed.
This is what keeps Dropbox's mtime rewrites from forcing a full re-embed."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org" (org-roam-ask-tests--note "ID1" "T" "* H\nBody.\n")))
    (let* ((file (expand-file-name "note.org" dir))
           (index (plist-put (org-roam-ask--empty-index)
                             :files
                             (list (cons file (cons (org-roam-ask--file-hash file)
                                                    ;; Stale mtime: the prefilter
                                                    ;; misses, so the hash decides.
                                                    (list 0.0 0)))))))
      (let ((plan (org-roam-ask--index-plan index (list file))))
        (should (equal (plist-get plan :unchanged) (list file)))
        (should (null (plist-get plan :changed)))))))

(ert-deftest org-roam-ask-test-vector-map-enables-reuse ()
  "The reuse map is keyed on content hash across every file in the index."
  (let* ((vec (org-roam-ask--normalize (org-roam-ask-tests--vec 1 1)))
         (index (plist-put (org-roam-ask--empty-index)
                           :chunks
                           (list (org-roam-ask--chunk-make
                                  :hash "shared" :file "/tmp/old.org" :vec vec)
                                 (org-roam-ask--chunk-make
                                  :hash "unembedded" :file "/tmp/old.org" :vec nil))))
         (map (org-roam-ask--vector-map index)))
    ;; A chunk that moved to a different file still finds its vector.
    (should (gethash "shared" map))
    (should (> (org-roam-ask--dot vec (gethash "shared" map)) 0.99))
    ;; Chunks that were never embedded are not offered for reuse.
    (should (null (gethash "unembedded" map)))))

(ert-deftest org-roam-ask-test-edit-reuses-untouched-chunks ()
  "Editing one section leaves the other sections' vectors in place.
This is the property that makes reindexing cheap: only the edited chunk
should be missing a vector and therefore queued for embedding."
  (org-roam-ask-tests--with-notes
      (list (cons "note.org"
                  (org-roam-ask-tests--note
                   "ID1" "T"
                   (concat "* Alpha\n" (make-string 400 ?a) "\n\n"
                           "* Beta\n" (make-string 400 ?b) "\n"))))
    (let* ((file (expand-file-name "note.org" dir))
           (org-roam-ask-chunk-size 300)
           (org-roam-ask-chunk-min 1)
           (before (org-roam-ask--chunk-file file)))
      (should (= (length before) 2))
      ;; Pretend the first pass embedded both chunks.
      (dolist (chunk before)
        (setf (org-roam-ask-chunk-vec chunk)
              (org-roam-ask--normalize (org-roam-ask-tests--vec 1 0))))
      ;; Edit only the Beta section.
      (with-temp-file file
        (insert (org-roam-ask-tests--note
                 "ID1" "T"
                 (concat "* Alpha\n" (make-string 400 ?a) "\n\n"
                         "* Beta\n" (make-string 400 ?c) "\n"))))
      (let* ((index (plist-put (org-roam-ask--empty-index) :chunks before))
             (reuse (org-roam-ask--vector-map index))
             (after (org-roam-ask--chunk-file file))
             (hits 0)
             (misses 0))
        (dolist (chunk after)
          (if (gethash (org-roam-ask-chunk-hash chunk) reuse)
              (cl-incf hits)
            (cl-incf misses)))
        (should (= hits 1))
        (should (= misses 1))))))


;;; ----------------------------------------------------------------------
;;; Presentation helpers
;;; ----------------------------------------------------------------------

(ert-deftest org-roam-ask-test-label ()
  "Labels read as a breadcrumb from the note title down to the heading."
  (should (equal (org-roam-ask--label
                  (org-roam-ask--chunk-make :title "Notes" :olp '("A" "B")))
                 "Notes > A > B"))
  (should (equal (org-roam-ask--label
                  (org-roam-ask--chunk-make :title "Notes" :olp nil))
                 "Notes")))

(ert-deftest org-roam-ask-test-snippet-drops-breadcrumb ()
  "Snippets show the body, flattened, not the breadcrumb line."
  (let ((chunk (org-roam-ask--chunk-make
                :title "T" :text "T > H\n\nFirst line.\nSecond   line.")))
    (should (equal (org-roam-ask--snippet chunk 40) "First line. Second line."))))

(ert-deftest org-roam-ask-test-select-context-honours-budget ()
  "Context selection stops once the character budget is spent."
  (let* ((org-roam-ask-context-chunks 8)
         (org-roam-ask-context-max-chars 1000)
         (mk (lambda (n) (cons (org-roam-ask--chunk-make
                                :title n :text (make-string 400 ?x))
                               0.9)))
         (results (list (funcall mk "a") (funcall mk "b") (funcall mk "c"))))
    ;; Two 400-char excerpts fit in 1000; a third would overrun it.
    (should (= (length (org-roam-ask--select-context results)) 2))))

(ert-deftest org-roam-ask-test-select-context-respects-chunk-count ()
  "The chunk-count cap binds even when the character budget is generous."
  (let* ((org-roam-ask-context-chunks 2)
         (org-roam-ask-context-max-chars 100000)
         (results (cl-loop for i below 5
                           collect (cons (org-roam-ask--chunk-make
                                          :title (number-to-string i) :text "short")
                                         0.9))))
    (should (= (length (org-roam-ask--select-context results)) 2))))

(ert-deftest org-roam-ask-test-select-context-keeps-one-oversized ()
  "A single excerpt larger than the budget is still used rather than dropped."
  (let* ((org-roam-ask-context-max-chars 100)
         (results (list (cons (org-roam-ask--chunk-make
                               :title "big" :text (make-string 5000 ?x))
                              0.9))))
    (should (= (length (org-roam-ask--select-context results)) 1))))

(ert-deftest org-roam-ask-test-source-link-is-precise ()
  "A source link carries the file, the position and the full outline path."
  (let* ((org-roam-ask-source-link-style 'precise)
         (chunk (org-roam-ask--chunk-make
                 :node-id "UUID-1" :file "/tmp/notes/algebra.org" :pos 42
                 :title "Algebra" :olp '("Vector Spaces" "Subspaces")))
         (link (org-roam-ask--source-link chunk)))
    (should (string-match "\\`\\[\\[org-roam-ask:\\([^]]+\\)\\]\\[\\(.*\\)\\]\\]\\'" link))
    (let* ((path (match-string 1 link))
           (label (match-string 2 link))
           (parts (mapcar #'url-unhex-string (split-string path "/" t))))
      (should (equal label "Algebra > Vector Spaces > Subspaces"))
      (should (equal (nth 0 parts) "/tmp/notes/algebra.org"))
      (should (equal (nth 1 parts) "42"))
      (should (equal (cddr parts) '("Vector Spaces" "Subspaces"))))))

(ert-deftest org-roam-ask-test-link-path-survives-awkward-headings ()
  "Slashes, brackets and quotes in a heading cannot break the link."
  (let* ((chunk (org-roam-ask--chunk-make
                 :file "/tmp/a b.org" :pos 7
                 :olp '("a/b" "See [1]" "``quoted''")))
         (parts (mapcar #'url-unhex-string
                        (split-string (org-roam-ask--link-path chunk) "/" t))))
    (should (equal (cddr parts) '("a/b" "See [1]" "``quoted''")))
    ;; Nothing that would terminate an Org link survives encoding.
    (should-not (string-match-p "[][]" (org-roam-ask--link-path chunk)))))

(ert-deftest org-roam-ask-test-source-link-id-style ()
  "The id style still produces an org-roam id link when asked for."
  (let* ((org-roam-ask-source-link-style 'id)
         (chunk (org-roam-ask--chunk-make
                 :node-id "UUID-1" :file "/tmp/a.org" :title "Note" :olp '("H"))))
    (should (equal (org-roam-ask--source-link chunk)
                   "[[id:UUID-1][Note > H]]"))))

(ert-deftest org-roam-ask-test-find-olp-handles-link-headings ()
  "A heading written as an Org link is still found.
`org-get-outline-path' reports the link description while the buffer holds
the raw link, which is why `org-find-olp' fails here."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "* [[https://example.com][Ten Lessons]]\nbody\n")
    (let ((hit (org-roam-ask--find-olp '("Ten Lessons"))))
      (should hit)
      (should (equal (save-excursion (goto-char hit) (org-get-outline-path t))
                     '("Ten Lessons"))))
    ;; Document why the custom search exists.
    (should-not (ignore-errors (org-find-olp '("Ten Lessons") t)))))

(ert-deftest org-roam-ask-test-find-olp-disambiguates-by-full-path ()
  "Repeated leaf headings are told apart by their complete outline path.
Templated notes repeat headings like \"1. Basic Info\" under every entry."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "* Paper A\n** 1. Basic Info\naaa\n* Paper B\n** 1. Basic Info\nbbb\n")
    (let ((a (org-roam-ask--find-olp '("Paper A" "1. Basic Info")))
          (b (org-roam-ask--find-olp '("Paper B" "1. Basic Info"))))
      (should a) (should b) (should (< a b))
      (should (equal (save-excursion (goto-char a) (org-get-outline-path t))
                     '("Paper A" "1. Basic Info")))
      (should (equal (save-excursion (goto-char b) (org-get-outline-path t))
                     '("Paper B" "1. Basic Info"))))
    ;; Here org-find-olp copes too: the parent scopes the child search.
    (should (ignore-errors (org-find-olp '("Paper A" "1. Basic Info") t)))))

(ert-deftest org-roam-ask-test-find-olp-handles-identical-siblings ()
  "Two siblings sharing a name resolve, where `org-find-olp' gives up."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "* A\n** X\nfirst\n** X\nsecond\n")
    (should (org-roam-ask--find-olp '("A" "X")))
    ;; "Heading not unique on level 2: X"
    (should-not (ignore-errors (org-find-olp '("A" "X") t)))))

(ert-deftest org-roam-ask-test-find-olp-breaks-ties-with-position ()
  "When a whole outline path repeats, the occurrence nearest POS wins."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "* A\n** X\nfirst\n* A\n** X\nsecond\n")
    (let* ((second (save-excursion
                     (goto-char (point-max))
                     (re-search-backward "^\\*\\* X" nil t)
                     (line-beginning-position)))
           (near-first (org-roam-ask--find-olp '("A" "X") 1))
           (near-second (org-roam-ask--find-olp '("A" "X") second)))
      (should (= near-second second))
      (should (< near-first second)))))

(ert-deftest org-roam-ask-test-find-olp-missing-path ()
  "An outline path that no longer exists yields nil rather than an error."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert "* Only\nbody\n")
    (should-not (org-roam-ask--find-olp '("Gone")))))

(ert-deftest org-roam-ask-test-sources-numbering-matches-citations ()
  "Sources stay one-to-one with the prompt's [1], [2] markers.
Two excerpts from the same heading must both be listed, or the model's
citation numbers would point at the wrong entries."
  (let* ((org-roam-ask-source-link-style 'heading)
         (mk (lambda () (org-roam-ask--chunk-make
                         :node-id "U" :file "/tmp/a.org" :title "A" :olp '("H"))))
         (rendered (org-roam-ask--sources
                    (list (cons (funcall mk) 0.9)
                          (cons (funcall mk) 0.8)
                          (cons (funcall mk) 0.7)))))
    (should (string-match-p "^1\\. " rendered))
    (should (string-match-p "\n2\\. " rendered))
    (should (string-match-p "\n3\\. " rendered))
    (should (string-match-p "0\\.900" rendered))))

(ert-deftest org-roam-ask-test-prompt-numbers-excerpts ()
  "Excerpts are numbered so the model can cite them."
  (let ((prompt (org-roam-ask--build-prompt
                 "What is a vector space?"
                 (list (cons (org-roam-ask--chunk-make :title "A" :text "body a") 0.9)
                       (cons (org-roam-ask--chunk-make :title "B" :text "body b") 0.8)))))
    (should (string-match-p "\\[1\\] A" prompt))
    (should (string-match-p "\\[2\\] B" prompt))
    (should (string-match-p "Question: What is a vector space\\?" prompt))))

(ert-deftest org-roam-ask-test-normalize-demotes-headings ()
  "A line-initial asterisk is demoted so it cannot split the answer entry.
An answer containing \"* Subspace\" at column zero would otherwise become a
sibling of the question heading."
  (with-temp-buffer
    (insert "* Subspace Definition\nBody.\n")
    (org-roam-ask--normalize-markup (point-min) (point-max))
    (should (equal (buffer-string) "*** Subspace Definition\nBody.\n"))))

(ert-deftest org-roam-ask-test-normalize-markdown-headings ()
  "Markdown headings become nested Org headings."
  (with-temp-buffer
    (insert "## Conditions\ntext\n")
    (org-roam-ask--normalize-markup (point-min) (point-max))
    (should (equal (buffer-string) "*** Conditions\ntext\n"))))

(ert-deftest org-roam-ask-test-normalize-citations-and-emphasis ()
  "Bracketed citations stay plain and Markdown bold becomes Org bold."
  (with-temp-buffer
    (insert "A **subspace** is closed [[1]] and bounded [[12]].")
    (org-roam-ask--normalize-markup (point-min) (point-max))
    (should (equal (buffer-string)
                   "A *subspace* is closed [1] and bounded [12]."))))

(ert-deftest org-roam-ask-test-normalize-leaves-good-org-alone ()
  "Well-formed Org markup passes through untouched."
  (let ((text "Already *bold* and /italic/ with [1] and [2].\n- a list item\n"))
    (with-temp-buffer
      (insert text)
      (org-roam-ask--normalize-markup (point-min) (point-max))
      (should (equal (buffer-string) text)))))

(ert-deftest org-roam-ask-test-request-params-raise-context ()
  "The default request parameters guard against Ollama's 4096-token window.
The context budget must fit well inside num_ctx, or the model reasons
until the window is full and returns nothing."
  (let ((ctx (plist-get (plist-get org-roam-ask-request-params :options) :num_ctx)))
    (should (integerp ctx))
    ;; Roughly three characters per token, plus room for the answer.
    (should (> ctx (/ org-roam-ask-context-max-chars 3)))))

(provide 'org-roam-ask-tests)

;;; org-roam-ask-tests.el ends here
