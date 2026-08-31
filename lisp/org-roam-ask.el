;;; org-roam-ask.el --- Semantic search and Q&A over org-roam notes -*- lexical-binding: t; -*-

;; Author: Huy Pham
;; Keywords: outlines, convenience, tools
;; Package-Requires: ((emacs "29.1") (org "9.6"))

;;; Commentary:

;; Semantic search and retrieval-augmented question answering over an
;; org-roam note collection, backed entirely by local models served by
;; Ollama.
;;
;; Two entry points:
;;
;;   `org-roam-ask-search'  Type a query, get notes ranked by meaning
;;                          rather than keywords.
;;   `org-roam-ask'         Ask a question, get an answer generated from
;;                          your notes with links back to the sources.
;;
;; Both need an index, built by `org-roam-ask-index-build'.  Indexing is
;; incremental: unchanged files are skipped, and unchanged sections of
;; changed files keep their existing vectors, so ordinary editing
;; re-embeds a chunk or two rather than the whole collection.
;;
;; The .org files on disk are the source of truth.  The org-roam SQLite
;; database is deliberately not consulted, so this works whether or not
;; `org-roam-db-autosync-mode' is enabled.
;;
;; Setup, once:
;;
;;   ollama pull nomic-embed-text
;;   M-x org-roam-ask-index-build

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'org)
(require 'subr-x)
(require 'url)
(require 'url-util)
(require 'json)

(defvar org-roam-directory)
(declare-function gptel-request "gptel" (&rest args))
(defvar gptel-backend)
(defvar gptel-include-reasoning)
(defvar gptel--request-params)


;;; ----------------------------------------------------------------------
;;; Customization
;;; ----------------------------------------------------------------------

(defgroup org-roam-ask nil
  "Semantic search and Q&A over org-roam notes using local models."
  :group 'org
  :prefix "org-roam-ask-")

(defcustom org-roam-ask-directory nil
  "Directory holding the notes to index.
When nil, `org-roam-directory' is used."
  :type '(choice (const :tag "Use `org-roam-directory'" nil) directory))

(defcustom org-roam-ask-ollama-host "http://localhost:11434"
  "Base URL of the Ollama server."
  :type 'string)

(defcustom org-roam-ask-embedding-model "nomic-embed-text"
  "Ollama model used to embed notes and queries.
Changing this invalidates the index; rebuild it with
`org-roam-ask-index-rebuild'."
  :type 'string)

(defcustom org-roam-ask-index-file
  (expand-file-name "org-roam-ask-index.eld" user-emacs-directory)
  "File in which the embedding index is stored."
  :type 'file)

(defcustom org-roam-ask-chunk-size 1500
  "Target size, in characters, of an indexed chunk."
  :type 'integer)

(defcustom org-roam-ask-chunk-min 250
  "Minimum size, in characters, of a trailing chunk worth keeping."
  :type 'integer)

(defcustom org-roam-ask-chunk-max 3000
  "Size, in characters, above which a single section is split."
  :type 'integer)

(defcustom org-roam-ask-chunk-overlap 200
  "Characters of overlap carried between the pieces of a split section."
  :type 'integer)

(defcustom org-roam-ask-embed-batch-size 16
  "Number of texts sent to Ollama per embedding request."
  :type 'integer)

(defcustom org-roam-ask-search-results 20
  "Number of results offered by `org-roam-ask-search'."
  :type 'integer)

(defcustom org-roam-ask-context-chunks 8
  "Maximum number of note excerpts passed to the LLM by `org-roam-ask'."
  :type 'integer)

(defcustom org-roam-ask-context-max-chars 12000
  "Maximum total size, in characters, of the excerpts passed to the LLM."
  :type 'integer)

(defcustom org-roam-ask-show-reasoning nil
  "When non-nil, keep the model's reasoning in a drawer under the answer."
  :type 'boolean)

(defcustom org-roam-ask-auto-index nil
  "When non-nil, `org-roam-ask-mode' reindexes notes as they are saved."
  :type 'boolean)

(defcustom org-roam-ask-auto-index-idle 5
  "Seconds of idle time before a saved note is reindexed."
  :type 'number)

(defcustom org-roam-ask-exclude-regexp nil
  "Regexp matched against absolute file names to exclude from the index."
  :type '(choice (const :tag "Exclude nothing" nil) regexp))

(defcustom org-roam-ask-buffer-name "*org-roam-ask*"
  "Name of the buffer in which answers are rendered."
  :type 'string)

(defcustom org-roam-ask-source-link-style 'precise
  "How the Sources section links back to a note.

`precise' uses an \"org-roam-ask:\" link carrying the full outline path,
followed with `org-find-olp'.  This is the default because it is the only
option that reliably lands on the passage that was actually quoted.
Matching on heading text alone is not enough: in a typical collection a
third of headings repeat inside their own file, and a nested heading can
share its name with an ancestor.

`id' uses an org-roam \"id:\" link.  Portable and survives a rename, but
notes normally carry only a file-level ID, so every citation lands at the
top of the file rather than at the passage.  Such links also resolve only
once org-roam is loaded, and only for notes already in its database."
  :type '(choice (const :tag "Link to the exact passage" precise)
                 (const :tag "Link to the org-roam node by ID" id)))

(defcustom org-roam-ask-request-params
  '(:think :json-false :options (:num_ctx 8192))
  "Extra parameters merged into the Ollama generation request.

Two settings matter here, and the defaults are not cosmetic.

`:num_ctx' raises the context window.  Ollama defaults to 4096 tokens,
which a retrieval prompt overruns: the model then spends the whole window
reasoning and returns an empty answer.  Keep this comfortably above
`org-roam-ask-context-max-chars' divided by three.

`:think' turned off stops reasoning models from thinking their way
through the window before answering.  On a local 4B model this was the
difference between 108 seconds for a truncated answer and 11 seconds for
a complete one.  Set it to t if you would rather have the reasoning, or
clear this option entirely if your model rejects the parameter."
  :type '(plist :key-type symbol :value-type sexp))

(defcustom org-roam-ask-system-message
  "You are answering questions using excerpts from the user's personal \
Org-mode notes.

Rules:
- Answer only from the excerpts provided. Do not use outside knowledge.
- Cite the excerpts supporting each claim inline as [1], [2], and so on.
  Write citations as plain square brackets, never as links.
- If the excerpts do not contain the answer, say so plainly instead of
  guessing. It is better to say the notes do not cover it.
- Be concise.
- Write Org markup: *bold*, /italic/, and \"- \" for list items. Do not use
  Markdown, and do not start any line with an asterisk or a # heading."
  "System message sent to the LLM by `org-roam-ask'."
  :type 'string)


;;; ----------------------------------------------------------------------
;;; Chunks
;;; ----------------------------------------------------------------------

(cl-defstruct (org-roam-ask-chunk (:constructor org-roam-ask--chunk-make)
                                  (:copier nil))
  hash                                  ; sha1 of TEXT, the reuse key
  file                                  ; absolute path
  node-id                               ; file-level org-roam ID
  title                                 ; #+title:
  olp                                   ; outline path, outermost first
  pos                                   ; heading position, for navigation
  text                                  ; the embedded text
  vec)                                  ; normalised float vector, or nil

(defvar org-roam-ask--index nil
  "Cached index plist, or nil when not yet loaded.")

(defvar org-roam-ask--indexing-p nil
  "Non-nil while an indexing pass is in flight.")

(defun org-roam-ask--notes-directory ()
  "Return the directory holding the notes to index.
Falls back to `org-roam-directory', loading org-roam if it has not been
loaded yet.  Deferring that load until it is actually needed is what lets
this package's commands and keys work from startup without dragging
org-roam in first."
  (let ((dir (or org-roam-ask-directory
                 (progn
                   (unless (boundp 'org-roam-directory)
                     (require 'org-roam nil t))
                   (and (boundp 'org-roam-directory) org-roam-directory)))))
    (unless dir
      (user-error "org-roam-ask: set `org-roam-ask-directory' or `org-roam-directory'"))
    (unless (file-directory-p dir)
      (user-error "org-roam-ask: %s is not a directory" dir))
    (file-truename dir)))

(defun org-roam-ask--files ()
  "Return the absolute names of the .org files to index."
  (let ((files (directory-files-recursively (org-roam-ask--notes-directory) "\\.org\\'")))
    (sort (if org-roam-ask-exclude-regexp
              (seq-remove (lambda (f) (string-match-p org-roam-ask-exclude-regexp f))
                          files)
            files)
          #'string<)))


;;; ----------------------------------------------------------------------
;;; Parsing notes into chunks
;;; ----------------------------------------------------------------------

(defun org-roam-ask--file-node-id ()
  "Return the file-level ID of the current Org buffer, or nil.
Only the property drawer preceding the first heading is considered, so a
heading ID is never mistaken for the file's node ID."
  (or (org-entry-get (point-min) "ID")
      (save-excursion
        (goto-char (point-min))
        (let ((limit (save-excursion
                       (if (re-search-forward "^\\*+[ \t]" nil t)
                           (match-beginning 0)
                         (point-max)))))
          (when (re-search-forward "^[ \t]*:ID:[ \t]*\\(\\S-+\\)" limit t)
            (match-string-no-properties 1))))))

(defun org-roam-ask--clean-text (text)
  "Strip Org bookkeeping from TEXT, leaving prose worth embedding."
  (with-temp-buffer
    (insert text)
    ;; Property and logbook drawers.
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*:\\(?:PROPERTIES\\|LOGBOOK\\):[ \t]*$" nil t)
      (let ((start (match-beginning 0)))
        (if (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
            (delete-region start (min (point-max) (1+ (point))))
          (delete-region start (point-max)))))
    ;; Keyword lines (#+title:, #+LATEX_HEADER:, #+OPTIONS: ...) are metadata.
    ;; Block delimiters such as #+begin_src carry no colon and are kept.
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*#\\+[A-Za-z_][A-Za-z0-9_-]*:.*$" nil t)
      (delete-region (match-beginning 0) (min (point-max) (1+ (point)))))
    ;; Collapse the blank lines left behind.
    (goto-char (point-min))
    (while (re-search-forward "\n\\{3,\\}" nil t)
      (replace-match "\n\n"))
    (string-trim (buffer-string))))

(defun org-roam-ask--olp-label (olp)
  "Return a breadcrumb string for outline path OLP."
  (if olp (string-join olp " > ") ""))

(defun org-roam-ask--file-sections (file)
  "Return (TITLE NODE-ID SECTIONS) for FILE.
Each section is a plist with :olp, :pos and :text.  Returns nil when the
file has no discoverable node ID."
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (org-mode))
    (let ((title (or (cadr (assoc "TITLE" (org-collect-keywords '("TITLE"))))
                     (file-name-base file)))
          (node-id (org-roam-ask--file-node-id))
          (sections nil))
      (when node-id
        ;; Content before the first heading.
        (let* ((first (save-excursion
                        (goto-char (point-min))
                        (if (re-search-forward "^\\*+[ \t]" nil t)
                            (match-beginning 0)
                          (point-max))))
               (pre (org-roam-ask--clean-text
                     (buffer-substring-no-properties (point-min) first))))
          (unless (string-empty-p pre)
            (push (list :olp nil :pos (point-min) :text pre) sections)))
        ;; One section per heading, excluding its children.
        (org-map-entries
         (lambda ()
           (let* ((pos (point))
                  (olp (org-get-outline-path t))
                  (end (save-excursion
                         (goto-char pos)
                         (if (outline-next-heading) (point) (point-max))))
                  (beg (save-excursion
                         (goto-char pos)
                         (org-end-of-meta-data t)
                         (point)))
                  (body (org-roam-ask--clean-text
                         (buffer-substring-no-properties (min beg end) end))))
             (push (list :olp olp :pos pos :text body) sections))))
        (list title node-id (nreverse sections))))))

(defun org-roam-ask--split-long (text)
  "Split TEXT into pieces of roughly `org-roam-ask-chunk-size' characters.
Splits on paragraph boundaries, carrying `org-roam-ask-chunk-overlap'
characters of context between consecutive pieces."
  (let ((paragraphs nil)
        (pieces nil)
        (current ""))
    ;; A single paragraph may itself be enormous; break those up first.
    (dolist (p (split-string text "\n[ \t]*\n" t))
      (if (<= (length p) org-roam-ask-chunk-max)
          (push p paragraphs)
        (let ((start 0))
          (while (< start (length p))
            (let ((end (min (length p) (+ start org-roam-ask-chunk-size))))
              (push (substring p start end) paragraphs)
              (setq start end))))))
    (setq paragraphs (nreverse paragraphs))
    (dolist (p paragraphs)
      (if (and (not (string-empty-p current))
               (> (+ (length current) (length p)) org-roam-ask-chunk-size))
          (progn
            (push current pieces)
            (setq current
                  (concat (let ((n (min org-roam-ask-chunk-overlap (length current))))
                            (substring current (- (length current) n)))
                          "\n\n" p)))
        (setq current (if (string-empty-p current) p (concat current "\n\n" p)))))
    (unless (string-empty-p (string-trim current))
      (push current pieces))
    (nreverse pieces)))

(defun org-roam-ask--pack-sections (sections)
  "Group SECTIONS into chunk-sized units.
Small consecutive sections are merged and oversized ones are split, which
is what turns a corpus of mostly tiny headings into useful chunks.
Returns a list of plists with :olp, :pos and :text."
  (let ((out nil)
        (acc nil)                       ; accumulated section texts
        (acc-len 0)
        (acc-olp nil)
        (acc-pos nil)
        (acc-root nil))
    (cl-labels
        ((flush ()
           (when acc
             (push (list :olp acc-olp :pos acc-pos
                         :text (string-join (nreverse acc) "\n\n"))
                   out)
             (setq acc nil acc-len 0 acc-olp nil acc-pos nil acc-root nil))))
      (dolist (sec sections)
        (let* ((text (plist-get sec :text))
               (olp (plist-get sec :olp))
               (pos (plist-get sec :pos))
               (root (car olp))
               (labelled (if olp
                             (concat (org-roam-ask--olp-label olp) "\n" text)
                           text)))
          (unless (string-empty-p text)
            (cond
             ;; Oversized: stands alone, split into pieces.
             ((> (length labelled) org-roam-ask-chunk-max)
              (flush)
              (dolist (piece (org-roam-ask--split-long labelled))
                (push (list :olp olp :pos pos :text piece) out)))
             (t
              ;; Never merge across unrelated top-level headings.
              (when (and acc (not (equal root acc-root)))
                (flush))
              (unless acc
                (setq acc-olp olp acc-pos pos acc-root root))
              (push labelled acc)
              (setq acc-len (+ acc-len (length labelled) 2))
              (when (>= acc-len org-roam-ask-chunk-size)
                (flush)))))))
      ;; Keep the tail only if it carries enough substance, or is all we have.
      (when (and acc (or (>= acc-len org-roam-ask-chunk-min) (null out)))
        (flush)))
    (nreverse out)))

(defun org-roam-ask--chunk-file (file)
  "Return the list of chunks for FILE, with vectors unset."
  (pcase (org-roam-ask--file-sections file)
    (`(,title ,node-id ,sections)
     (mapcar
      (lambda (unit)
        (let* ((olp (plist-get unit :olp))
               (breadcrumb (string-join
                            (seq-remove #'string-empty-p
                                        (list (or title "")
                                              (org-roam-ask--olp-label olp)))
                            " > "))
               (text (concat breadcrumb "\n\n" (plist-get unit :text))))
          (org-roam-ask--chunk-make
           :hash (secure-hash 'sha1 text)
           :file file
           :node-id node-id
           :title title
           :olp olp
           :pos (plist-get unit :pos)
           :text text
           :vec nil)))
      (org-roam-ask--pack-sections sections)))
    (_
     (display-warning 'org-roam-ask
                      (format "Skipping %s: no file-level :ID: found" file)
                      :warning)
     nil)))


;;; ----------------------------------------------------------------------
;;; Vectors
;;; ----------------------------------------------------------------------

(defun org-roam-ask--normalize (vec)
  "Scale VEC to unit length, in place, and return it."
  (let ((sum 0.0)
        (len (length vec)))
    (dotimes (i len)
      (setq sum (+ sum (* (aref vec i) (aref vec i)))))
    (setq sum (sqrt sum))
    (when (> sum 0.0)
      (dotimes (i len)
        (aset vec i (/ (aref vec i) sum))))
    vec))

(defun org-roam-ask--dot (a b)
  "Return the dot product of unit vectors A and B, i.e. their cosine."
  (let ((sum 0.0)
        (len (min (length a) (length b)))
        (i 0))
    (while (< i len)
      (setq sum (+ sum (* (aref a i) (aref b i))))
      (setq i (1+ i)))
    sum))

(defun org-roam-ask--quantize (vec)
  "Return (SCALE . BASE64) holding VEC as int8 values.
Storing vectors this way keeps the index around fifteen times smaller
than printed floats and makes loading it essentially free.  The
precision lost is irrelevant to cosine ranking."
  (let* ((len (length vec))
         (scale 0.0)
         (bytes (make-string len 0)))
    (dotimes (i len)
      (setq scale (max scale (abs (aref vec i)))))
    (when (= scale 0.0) (setq scale 1.0))
    (dotimes (i len)
      (aset bytes i (+ 127 (max -127 (min 127 (round (* 127.0 (/ (aref vec i) scale))))))))
    (cons scale (base64-encode-string bytes t))))

(defun org-roam-ask--dequantize (base64 scale)
  "Rebuild a normalised float vector from BASE64 and SCALE."
  (let* ((bytes (base64-decode-string base64))
         (len (length bytes))
         (vec (make-vector len 0.0)))
    (dotimes (i len)
      (aset vec i (* scale (/ (float (- (aref bytes i) 127)) 127.0))))
    (org-roam-ask--normalize vec)))

(defun org-roam-ask--rank (query chunks limit)
  "Return the LIMIT chunks in CHUNKS closest to QUERY, as (CHUNK . SCORE)."
  (let ((scored nil))
    (dolist (chunk chunks)
      (when (org-roam-ask-chunk-vec chunk)
        (push (cons chunk (org-roam-ask--dot query (org-roam-ask-chunk-vec chunk)))
              scored)))
    (seq-take (sort scored (lambda (a b) (> (cdr a) (cdr b)))) limit)))


;;; ----------------------------------------------------------------------
;;; Talking to Ollama
;;; ----------------------------------------------------------------------

(defun org-roam-ask--url (path)
  "Return the Ollama endpoint for PATH."
  (concat (string-remove-suffix "/" org-roam-ask-ollama-host) path))

(defun org-roam-ask--pull-hint ()
  "Return the command the user needs to run to install the embedding model."
  (format "run: ollama pull %s" org-roam-ask-embedding-model))

(defun org-roam-ask--read-response (status)
  "Parse an Ollama JSON response in the current buffer.
Returns (DATA . ERROR); exactly one of the two is non-nil.  STATUS is the
plist `url-retrieve' hands to its callback.

The body is read before STATUS is consulted.  Ollama reports a missing
model as HTTP 400, which `url-retrieve' surfaces as a transport error, and
blaming the connection would send the reader off debugging the wrong
thing.  Whatever the server said wins; the connection message is only for
the case where nothing came back at all."
  (let ((body (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "\n\n" nil t)
                  (condition-case nil
                      (json-parse-buffer :object-type 'plist :array-type 'list)
                    (error nil))))))
    (cond
     ((and body (plist-get body :error)) (cons nil (plist-get body :error)))
     (body (cons body nil))
     ((plist-get status :error)
      (cons nil (format "cannot reach Ollama at %s -- is `ollama serve' running?"
                        org-roam-ask-ollama-host)))
     (t (cons nil "malformed response from Ollama")))))

(defun org-roam-ask--embed (inputs callback)
  "Embed INPUTS, a list of strings, then call CALLBACK with (VECTORS ERROR)."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data
         (encode-coding-string
          (json-serialize (list :model org-roam-ask-embedding-model
                                :input (vconcat inputs)))
          'utf-8)))
    (url-retrieve
     (org-roam-ask--url "/api/embed")
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (pcase-let ((`(,json . ,err) (org-roam-ask--read-response status)))
               (cond
                (err (funcall callback nil
                              (if (string-match-p "not found" err)
                                  (format "%s -- %s" err (org-roam-ask--pull-hint))
                                err)))
                (t
                 (let ((vectors (mapcar (lambda (row)
                                          (org-roam-ask--normalize
                                           (vconcat (mapcar #'float row))))
                                        (plist-get json :embeddings))))
                   (if (null vectors)
                       (funcall callback nil "Ollama returned no embeddings")
                     (funcall callback vectors nil))))))
           (kill-buffer buffer))))
     nil t t)))

(defun org-roam-ask--preflight (callback)
  "Check that Ollama is up and the embedding model is present.
Calls CALLBACK with an error string, or nil when everything is ready."
  (url-retrieve
   (org-roam-ask--url "/api/tags")
   (lambda (status)
     (let ((buffer (current-buffer)))
       (unwind-protect
           (pcase-let ((`(,json . ,err) (org-roam-ask--read-response status)))
             (if err
                 (funcall callback err)
               (let ((models (mapcar (lambda (m) (plist-get m :model))
                                     (plist-get json :models))))
                 (if (seq-find (lambda (m)
                                 (or (equal m org-roam-ask-embedding-model)
                                     (equal m (concat org-roam-ask-embedding-model ":latest"))))
                               models)
                     (funcall callback nil)
                   (funcall callback
                            (format "embedding model %s is not installed -- %s"
                                    org-roam-ask-embedding-model
                                    (org-roam-ask--pull-hint)))))))
         (kill-buffer buffer))))
   nil t t))

(defun org-roam-ask--embed-queue (pending done)
  "Embed the chunks in PENDING in batches, then call DONE with an error or nil.
Batches are chained through their callbacks so Emacs is never blocked."
  (if (null pending)
      (funcall done nil)
    (let* ((total (length pending))
           (reporter (make-progress-reporter
                      (format "org-roam-ask: embedding %d chunks" total) 0 total))
           (finished 0))
      (cl-labels
          ((step (rest)
             (if (null rest)
                 (progn (progress-reporter-done reporter) (funcall done nil))
               (let ((batch (seq-take rest org-roam-ask-embed-batch-size))
                     (tail (seq-drop rest org-roam-ask-embed-batch-size)))
                 (org-roam-ask--embed
                  (mapcar #'org-roam-ask-chunk-text batch)
                  (lambda (vectors err)
                    (cond
                     (err (funcall done err))
                     ((/= (length vectors) (length batch))
                      (funcall done "Ollama returned a mismatched number of embeddings"))
                     (t
                      (cl-loop for chunk in batch
                               for vec in vectors
                               do (setf (org-roam-ask-chunk-vec chunk) vec))
                      (setq finished (+ finished (length batch)))
                      (progress-reporter-update reporter finished)
                      (step tail)))))))))
        (step pending)))))


;;; ----------------------------------------------------------------------
;;; Index storage
;;; ----------------------------------------------------------------------

(defun org-roam-ask--empty-index ()
  "Return a fresh, empty index plist."
  (list :version 1 :model org-roam-ask-embedding-model :dim nil
        :files nil :chunks nil))

(defun org-roam-ask--chunk-to-sexp (chunk)
  "Return CHUNK as a serialisable plist."
  (pcase-let ((`(,scale . ,base64)
               (if (org-roam-ask-chunk-vec chunk)
                   (org-roam-ask--quantize (org-roam-ask-chunk-vec chunk))
                 (cons nil nil))))
    (list :hash (org-roam-ask-chunk-hash chunk)
          :file (org-roam-ask-chunk-file chunk)
          :node-id (org-roam-ask-chunk-node-id chunk)
          :title (org-roam-ask-chunk-title chunk)
          :olp (org-roam-ask-chunk-olp chunk)
          :pos (org-roam-ask-chunk-pos chunk)
          :text (org-roam-ask-chunk-text chunk)
          :scale scale
          :vec base64)))

(defun org-roam-ask--chunk-from-sexp (plist)
  "Rebuild a chunk struct from PLIST."
  (org-roam-ask--chunk-make
   :hash (plist-get plist :hash)
   :file (plist-get plist :file)
   :node-id (plist-get plist :node-id)
   :title (plist-get plist :title)
   :olp (plist-get plist :olp)
   :pos (plist-get plist :pos)
   :text (plist-get plist :text)
   :vec (when (plist-get plist :vec)
          (org-roam-ask--dequantize (plist-get plist :vec)
                                    (plist-get plist :scale)))))

(defun org-roam-ask--index-save (index)
  "Write INDEX to `org-roam-ask-index-file' atomically."
  (let* ((file org-roam-ask-index-file)
         (temp (make-temp-name (concat file ".tmp")))
         (serialised (plist-put (copy-sequence index)
                                :chunks
                                (mapcar #'org-roam-ask--chunk-to-sexp
                                        (plist-get index :chunks)))))
    (make-directory (file-name-directory file) t)
    (with-temp-file temp
      (let ((print-length nil)
            (print-level nil))
        (prin1 serialised (current-buffer))))
    (rename-file temp file t)
    (setq org-roam-ask--index index)))

(defun org-roam-ask--index-load ()
  "Load and return the index, or an empty one when it is missing or stale.
An index built with a different embedding model is discarded, since its
vectors are meaningless under the current one."
  (or org-roam-ask--index
      (setq org-roam-ask--index
            (let ((file org-roam-ask-index-file))
              (if (not (file-readable-p file))
                  (org-roam-ask--empty-index)
                (condition-case nil
                    (let ((raw (with-temp-buffer
                                 (insert-file-contents file)
                                 (goto-char (point-min))
                                 (read (current-buffer)))))
                      (if (not (equal (plist-get raw :model) org-roam-ask-embedding-model))
                          (org-roam-ask--empty-index)
                        (plist-put raw :chunks
                                   (mapcar #'org-roam-ask--chunk-from-sexp
                                           (plist-get raw :chunks)))))
                  (error
                   (display-warning 'org-roam-ask
                                    "Index file is unreadable; starting a new one"
                                    :warning)
                   (org-roam-ask--empty-index))))))))

(defun org-roam-ask--ensure-index ()
  "Return the indexed chunks, or signal a helpful error when there are none."
  (let* ((index (org-roam-ask--index-load))
         (chunks (plist-get index :chunks)))
    (unless chunks
      (user-error "org-roam-ask: the index is empty -- run M-x org-roam-ask-index-build"))
    chunks))


;;; ----------------------------------------------------------------------
;;; Incremental reindexing
;;; ----------------------------------------------------------------------

(defun org-roam-ask--file-stat (file)
  "Return (MTIME SIZE) for FILE, used as a cheap change prefilter."
  (let ((attrs (file-attributes file)))
    (list (float-time (file-attribute-modification-time attrs))
          (file-attribute-size attrs))))

(defun org-roam-ask--file-hash (file)
  "Return the SHA-1 of FILE's contents.
Content hashing rather than mtime comparison matters here: these notes
live in Dropbox, which rewrites mtimes on sync and would otherwise force
a full re-embed every time."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha1 (current-buffer))))

(defun org-roam-ask--index-plan (index files)
  "Compare FILES against INDEX and return what a build would do.
The result is a plist with :new, :changed, :unchanged and :removed lists
of file names, plus the refreshed :files metadata.  Pure apart from
reading the files themselves, so it is both the dry-run used by
`org-roam-ask-index-status' and the planning step of a real build."
  (let ((known (plist-get index :files))
        (new nil) (changed nil) (unchanged nil) (removed nil) (meta nil))
    (dolist (file files)
      (let ((entry (assoc file known))
            (stat (org-roam-ask--file-stat file)))
        (cond
         ((null entry)
          (push file new)
          (push (cons file (cons (org-roam-ask--file-hash file) stat)) meta))
         ;; Cheap path: mtime and size both unchanged, so the contents are too.
         ((equal (cddr entry) stat)
          (push file unchanged)
          (push entry meta))
         (t
          ;; Touched. Hash it to find out whether anything actually changed.
          (let ((hash (org-roam-ask--file-hash file)))
            (if (equal hash (cadr entry))
                (push file unchanged)
              (push file changed))
            (push (cons file (cons hash stat)) meta))))))
    (dolist (entry known)
      (unless (member (car entry) files)
        (push (car entry) removed)))
    (list :new (nreverse new)
          :changed (nreverse changed)
          :unchanged (nreverse unchanged)
          :removed (nreverse removed)
          :files (nreverse meta))))

(defun org-roam-ask--vector-map (index)
  "Return a hash table mapping chunk hash to vector for every chunk in INDEX.
The map spans all files, so a section moved between notes, or a renamed
file, reuses its vector instead of being embedded again."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (chunk (plist-get index :chunks))
      (when (org-roam-ask-chunk-vec chunk)
        (puthash (org-roam-ask-chunk-hash chunk) (org-roam-ask-chunk-vec chunk) table)))
    table))

(defun org-roam-ask--build (index plan on-done)
  "Apply PLAN to INDEX, embedding only what is genuinely new.
Calls ON-DONE with (ERROR STATS) once every batch has been embedded."
  (let* ((stale (append (plist-get plan :new) (plist-get plan :changed)))
         (dropped (append stale (plist-get plan :removed)))
         (kept (seq-remove (lambda (chunk)
                             (member (org-roam-ask-chunk-file chunk) dropped))
                           (plist-get index :chunks)))
         (fresh (mapcan #'org-roam-ask--chunk-file stale))
         (reuse (org-roam-ask--vector-map index))
         (pending nil)
         (reused 0))
    ;; Chunk-level reuse: an untouched section of an edited file keeps its vector.
    (dolist (chunk fresh)
      (let ((vec (gethash (org-roam-ask-chunk-hash chunk) reuse)))
        (if vec
            (progn (setf (org-roam-ask-chunk-vec chunk) vec)
                   (setq reused (1+ reused)))
          (push chunk pending))))
    (setq pending (nreverse pending))
    (org-roam-ask--embed-queue
     pending
     (lambda (err)
       ;; Whatever was embedded before a failure is still worth keeping, so the
       ;; next run resumes rather than starting over.
       (let* ((embedded (seq-filter #'org-roam-ask-chunk-vec fresh))
              (chunks (append kept embedded))
              ;; A file counts as indexed once every chunk it produced has a
              ;; vector.  Stub notes that yield no chunks at all qualify too,
              ;; otherwise they would look new on every subsequent build and the
              ;; "up to date" short circuit would never fire.
              (complete (seq-filter
                         (lambda (file)
                           (seq-every-p
                            #'org-roam-ask-chunk-vec
                            (seq-filter (lambda (chunk)
                                          (equal (org-roam-ask-chunk-file chunk) file))
                                        fresh)))
                         stale))
              (files (seq-filter
                      (lambda (entry)
                        (or (member (car entry) (plist-get plan :unchanged))
                            (member (car entry) complete)))
                      (plist-get plan :files)))
              (updated (plist-put (plist-put (plist-put (copy-sequence index)
                                                        :chunks chunks)
                                             :files files)
                                  :dim (when-let* ((c (car chunks))
                                                   (v (org-roam-ask-chunk-vec c)))
                                         (length v)))))
         (org-roam-ask--index-save updated)
         (funcall on-done err (list :total (length chunks)
                                    :embedded (length pending)
                                    :reused reused
                                    :removed (length (plist-get plan :removed)))))))))

;;;###autoload
(defun org-roam-ask-index-build (&optional force)
  "Update the embedding index, re-embedding as little as possible.
With a prefix argument, or when FORCE is non-nil, rebuild from scratch."
  (interactive "P")
  (when org-roam-ask--indexing-p
    (user-error "org-roam-ask: an indexing pass is already running"))
  (let* ((index (if force (org-roam-ask--empty-index) (org-roam-ask--index-load)))
         (files (org-roam-ask--files))
         (plan (org-roam-ask--index-plan index files))
         (start (float-time)))
    (if (and (null (plist-get plan :new))
             (null (plist-get plan :changed))
             (null (plist-get plan :removed)))
        (message "org-roam-ask: index is up to date (%d chunks)"
                 (length (plist-get index :chunks)))
      (setq org-roam-ask--indexing-p t)
      (org-roam-ask--preflight
       (lambda (err)
         (if err
             (progn (setq org-roam-ask--indexing-p nil)
                    (message "org-roam-ask: %s" err))
           (org-roam-ask--build
            index plan
            (lambda (build-err stats)
              (setq org-roam-ask--indexing-p nil)
              (if build-err
                  (message "org-roam-ask: %s (kept %d chunks embedded so far)"
                           build-err (plist-get stats :total))
                (message "org-roam-ask: %d chunks -- %d embedded, %d reused, %d removed (%.1fs)"
                         (plist-get stats :total)
                         (plist-get stats :embedded)
                         (plist-get stats :reused)
                         (plist-get stats :removed)
                         (- (float-time) start)))))))))))

;;;###autoload
(defun org-roam-ask-index-rebuild ()
  "Discard the index and embed every note again.
Needed after switching `org-roam-ask-embedding-model'."
  (interactive)
  (when (yes-or-no-p "Re-embed every note from scratch? ")
    (setq org-roam-ask--index nil)
    (org-roam-ask-index-build t)))

;;;###autoload
(defun org-roam-ask-index-note (file)
  "Reindex FILE alone, leaving the rest of the index untouched.
Interactively, reindex the note in the current buffer."
  (interactive (list (or buffer-file-name
                         (user-error "org-roam-ask: this buffer is not visiting a file"))))
  (when org-roam-ask--indexing-p
    (user-error "org-roam-ask: an indexing pass is already running"))
  (let ((file (file-truename file)))
    (unless (string-prefix-p (org-roam-ask--notes-directory) file)
      (user-error "org-roam-ask: %s is not in the notes directory" file))
    (let* ((index (org-roam-ask--index-load))
           (plan (org-roam-ask--index-plan index (list file))))
      ;; Confine the plan to this file: everything else is left alone.
      (setq plan (plist-put plan :removed nil))
      (setq plan (plist-put plan :files
                            (append (seq-remove (lambda (e) (equal (car e) file))
                                                (plist-get index :files))
                                    (plist-get plan :files))))
      (setq plan (plist-put plan :unchanged
                            (append (plist-get plan :unchanged)
                                    (delete file (mapcar #'car (plist-get index :files))))))
      (if (and (null (plist-get plan :new)) (null (plist-get plan :changed)))
          (message "org-roam-ask: %s is unchanged" (file-name-nondirectory file))
        (setq org-roam-ask--indexing-p t)
        (org-roam-ask--build
         index plan
         (lambda (err stats)
           (setq org-roam-ask--indexing-p nil)
           (if err
               (message "org-roam-ask: %s" err)
             (message "org-roam-ask: %s reindexed -- %d embedded, %d reused (%d chunks total)"
                      (file-name-nondirectory file)
                      (plist-get stats :embedded)
                      (plist-get stats :reused)
                      (plist-get stats :total)))))))))

;;;###autoload
(defun org-roam-ask-index-status ()
  "Report what the index holds and what a build would do."
  (interactive)
  (let* ((index (org-roam-ask--index-load))
         (chunks (plist-get index :chunks))
         (plan (org-roam-ask--index-plan index (org-roam-ask--files))))
    (message "org-roam-ask: %d chunks over %d files, model %s, dim %s%s -- pending: %d new, %d changed, %d removed"
             (length chunks)
             (length (plist-get index :files))
             (plist-get index :model)
             (or (plist-get index :dim) "?")
             (if (file-readable-p org-roam-ask-index-file)
                 (format ", index %s"
                         (format-time-string
                          "%Y-%m-%d %H:%M"
                          (file-attribute-modification-time
                           (file-attributes org-roam-ask-index-file))))
               ", never written")
             (length (plist-get plan :new))
             (length (plist-get plan :changed))
             (length (plist-get plan :removed)))))


;;; ----------------------------------------------------------------------
;;; Reindexing on save
;;; ----------------------------------------------------------------------

(defvar org-roam-ask--pending-files nil
  "Files saved but not yet reindexed.")

(defvar org-roam-ask--auto-timer nil
  "Idle timer that drains `org-roam-ask--pending-files'.")

(defun org-roam-ask--auto-flush ()
  "Reindex one pending file, rescheduling if more remain."
  (setq org-roam-ask--auto-timer nil)
  (unless org-roam-ask--indexing-p
    (when-let* ((file (pop org-roam-ask--pending-files)))
      (when (file-readable-p file)
        (ignore-errors (org-roam-ask-index-note file)))))
  (when org-roam-ask--pending-files
    (org-roam-ask--auto-schedule)))

(defun org-roam-ask--auto-schedule ()
  "Arm the idle timer that reindexes saved notes."
  (unless org-roam-ask--auto-timer
    (setq org-roam-ask--auto-timer
          (run-with-idle-timer org-roam-ask-auto-index-idle nil
                               #'org-roam-ask--auto-flush))))

(defun org-roam-ask--maybe-queue ()
  "Queue the current buffer's file for reindexing, if it is a note.
Work is deferred to an idle timer because `super-save' saves often, and
every save should not fire an embedding request."
  (when (and org-roam-ask-auto-index
             buffer-file-name
             (string-suffix-p ".org" buffer-file-name)
             (ignore-errors
               (string-prefix-p (org-roam-ask--notes-directory)
                                (file-truename buffer-file-name))))
    (cl-pushnew (file-truename buffer-file-name)
                org-roam-ask--pending-files :test #'equal)
    (org-roam-ask--auto-schedule)))

;;;###autoload
(define-minor-mode org-roam-ask-mode
  "Keep the org-roam-ask index current as notes are saved."
  :global t
  :group 'org-roam-ask
  (if org-roam-ask-mode
      (add-hook 'after-save-hook #'org-roam-ask--maybe-queue)
    (remove-hook 'after-save-hook #'org-roam-ask--maybe-queue)))


;;; ----------------------------------------------------------------------
;;; Semantic search
;;; ----------------------------------------------------------------------

(defun org-roam-ask--label (chunk)
  "Return a one-line breadcrumb describing CHUNK."
  (let ((olp (org-roam-ask-chunk-olp chunk)))
    (if olp
        (format "%s > %s" (org-roam-ask-chunk-title chunk)
                (org-roam-ask--olp-label olp))
      (org-roam-ask-chunk-title chunk))))

(defun org-roam-ask--snippet (chunk &optional width)
  "Return a single-line excerpt of CHUNK, at most WIDTH characters."
  (let* ((text (org-roam-ask-chunk-text chunk))
         ;; Drop the breadcrumb line the chunker prepended.
         (body (if (string-match "\n\n" text)
                   (substring text (match-end 0))
                 text))
         (flat (string-trim (replace-regexp-in-string "[ \t\n]+" " " body))))
    (truncate-string-to-width flat (or width 70) nil nil t)))

(defun org-roam-ask--find-olp (olp &optional pos)
  "Return the position of the heading whose outline path is OLP, or nil.

`org-find-olp' cannot be used for this.  It matches `regexp-quote'd
heading text against the raw buffer, whereas `org-get-outline-path'
reports a heading written as an Org link by its description only, so the
two never meet: that accounts for 28 of the 298 paths in the collection
this was built against.  It also refuses, with \"Heading not unique\", when
two siblings share a name.

Paths are instead compared with `org-get-outline-path', the very function
that recorded them, so both sides normalise identically.  When a path
genuinely repeats, the occurrence nearest POS wins."
  (let ((best nil)
        (closest nil))
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward org-outline-regexp-bol nil t)
       (when (equal (org-get-outline-path t) olp)
         (let* ((here (line-beginning-position))
                (distance (if pos (abs (- here pos)) 0)))
           (when (or (null closest) (< distance closest))
             (setq best here closest distance))))))
    best))

(defun org-roam-ask--goto (file olp &optional pos)
  "Open FILE and move point to the heading at OLP.
OLP is matched as a complete outline path, which is what distinguishes
repeated heading names from one another.  POS breaks ties and is the
fallback for a note edited since it was indexed; the top of the file is
the last resort."
  (find-file file)
  (widen)
  (goto-char (or (and olp (org-roam-ask--find-olp olp pos))
                 (and pos (<= pos (point-max)) pos)
                 (point-min)))
  (when (derived-mode-p 'org-mode)
    (org-fold-show-context 'link-search))
  (recenter))

(defun org-roam-ask--link-path (chunk)
  "Encode CHUNK's file, position and outline path as an Org link path.
Each component is percent-encoded, so headings containing slashes,
brackets or quotes cannot break the link.  The position rides along to
tell two identical outline paths apart."
  (mapconcat #'url-hexify-string
             (append (list (org-roam-ask-chunk-file chunk)
                           (number-to-string (or (org-roam-ask-chunk-pos chunk) 0)))
                     (org-roam-ask-chunk-olp chunk))
             "/"))

(defun org-roam-ask-open (path &optional _arg)
  "Follow an \"org-roam-ask:\" link with PATH, jumping to the quoted passage."
  (let* ((parts (mapcar #'url-unhex-string (split-string path "/" t)))
         (file (car parts))
         (pos (string-to-number (or (cadr parts) "0")))
         (olp (cddr parts)))
    (unless (and file (file-readable-p file))
      (user-error "org-roam-ask: cannot open %s" (or file "<empty link>")))
    (org-roam-ask--goto file olp (and (> pos 0) pos))))

(org-link-set-parameters "org-roam-ask" :follow #'org-roam-ask-open)

(defun org-roam-ask--visit (chunk)
  "Open CHUNK's note and move point to the heading it came from."
  (org-roam-ask--goto (org-roam-ask-chunk-file chunk)
                      (org-roam-ask-chunk-olp chunk)
                      (org-roam-ask-chunk-pos chunk)))

(defun org-roam-ask--choose (results)
  "Offer RESULTS, a list of (CHUNK . SCORE), and visit the one chosen."
  (let ((table (make-hash-table :test #'equal))
        (candidates nil)
        (rank 0))
    (dolist (result results)
      ;; The rank prefix keeps candidates unique when two chunks share a label.
      (let ((label (format "%2d  %s" (cl-incf rank) (org-roam-ask--label (car result)))))
        (puthash label result table)
        (push label candidates)))
    (setq candidates (nreverse candidates))
    (let* ((completion-extra-properties
            (list :annotation-function
                  (lambda (candidate)
                    (when-let* ((hit (gethash candidate table)))
                      (concat (propertize (format "  %.3f  " (cdr hit))
                                          'face 'font-lock-constant-face)
                              (propertize (org-roam-ask--snippet (car hit))
                                          'face 'font-lock-comment-face))))))
           (choice (completing-read
                    "Note: "
                    (lambda (string predicate action)
                      (if (eq action 'metadata)
                          ;; Keep the ranking order; alphabetical would be useless.
                          '(metadata (category . org-roam-ask-chunk)
                                     (display-sort-function . identity)
                                     (cycle-sort-function . identity))
                        (complete-with-action action candidates string predicate)))
                    nil t)))
      (when-let* ((hit (gethash choice table)))
        (org-roam-ask--visit (car hit))))))

;;;###autoload
(defun org-roam-ask-search (query)
  "Search the notes for QUERY by meaning rather than by keyword."
  (interactive (list (read-string "Semantic search: ")))
  (when (string-blank-p query)
    (user-error "org-roam-ask: empty query"))
  (let ((chunks (org-roam-ask--ensure-index)))
    (message "org-roam-ask: searching...")
    (org-roam-ask--embed
     (list query)
     (lambda (vectors err)
       (cond
        (err (message "org-roam-ask: %s" err))
        (t
         (let ((results (org-roam-ask--rank (car vectors) chunks
                                            org-roam-ask-search-results)))
           (if (null results)
               (message "org-roam-ask: nothing found")
             ;; Hand back to the command loop: prompting from inside a process
             ;; callback is asking for trouble.
             (run-at-time 0 nil #'org-roam-ask--choose results)))))))))


;;; ----------------------------------------------------------------------
;;; Answering questions
;;; ----------------------------------------------------------------------

(defun org-roam-ask--select-context (results)
  "Return the prefix of RESULTS that fits the configured context budget."
  (let ((budget org-roam-ask-context-max-chars)
        (kept nil))
    (catch 'done
      (dolist (result (seq-take results org-roam-ask-context-chunks))
        (let ((size (length (org-roam-ask-chunk-text (car result)))))
          (when (and kept (> size budget))
            (throw 'done nil))
          (push result kept)
          (setq budget (- budget size)))))
    (nreverse kept)))

(defun org-roam-ask--build-prompt (question context)
  "Return the user prompt posing QUESTION over the excerpts in CONTEXT."
  (let ((n 0))
    (concat
     "Here are excerpts from my notes.\n\n"
     (mapconcat
      (lambda (result)
        (format "[%d] %s\n%s\n"
                (cl-incf n)
                (org-roam-ask--label (car result))
                (org-roam-ask-chunk-text (car result))))
      context
      "\n")
     "\nQuestion: " question)))

(defun org-roam-ask--source-link (chunk)
  "Return an Org link to the passage CHUNK was taken from.
See `org-roam-ask-source-link-style'."
  (let ((label (org-roam-ask--label chunk)))
    (if (eq org-roam-ask-source-link-style 'id)
        (format "[[id:%s][%s]]" (org-roam-ask-chunk-node-id chunk) label)
      (format "[[org-roam-ask:%s][%s]]" (org-roam-ask--link-path chunk) label))))

(defun org-roam-ask--sources (context)
  "Return an Org source list for the excerpts in CONTEXT.
The entries stay in one-to-one correspondence with the [1], [2] markers in
the prompt, so repeated headings are listed more than once on purpose:
renumbering them would misalign the model's citations."
  (when (eq org-roam-ask-source-link-style 'id)
    ;; org-roam advises `org-id-find' to consult its database.  Without
    ;; org-roam loaded, org-id falls back to `org-id-locations' and an
    ;; "id:" link fails with "Cannot find entry with ID".
    (require 'org-roam nil t))
  (let ((n 0))
    (concat
     "\n\n** Sources\n"
     (mapconcat
      (lambda (result)
        (format "%d. %s /(%.3f)/"
                (cl-incf n)
                (org-roam-ask--source-link (car result))
                (cdr result)))
      context
      "\n")
     "\n")))

(defun org-roam-ask--normalize-markup (start end)
  "Repair Markdown leaking into the Org answer between START and END.
Small models drift from the requested markup no matter how the prompt is
worded.  A stray asterisk at the start of a line is the one that actually
matters: it would become a sibling heading and split the answer out of
its own entry, so headings are demoted to level three instead."
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      ;; Markdown headings, then any line-initial asterisk, demoted so they
      ;; stay nested under the question.
      (goto-char (point-min))
      (while (re-search-forward "^#+[ \t]+" nil t)
        (replace-match "*** "))
      (goto-char (point-min))
      (while (re-search-forward "^\\*+[ \t]+" nil t)
        (replace-match "*** "))
      ;; Citations the model turned into Org links.
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\([0-9]+\\)\\]\\]" nil t)
        (replace-match "[\\1]"))
      ;; Markdown emphasis.
      (goto-char (point-min))
      (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" nil t)
        (replace-match "*\\1*")))))


(defun org-roam-ask--answer (question context)
  "Ask the LLM QUESTION over CONTEXT and stream the answer into a buffer."
  (unless (require 'gptel nil t)
    (user-error "org-roam-ask: gptel is not installed"))
  (unless (bound-and-true-p gptel-backend)
    (user-error "org-roam-ask: gptel has no backend configured"))
  (let ((buffer (get-buffer-create org-roam-ask-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (goto-char (point-max))
      (unless (bobp) (insert "\n"))
      (insert "* " question "\n\n")
      (let ((start (copy-marker (point) nil))
            (answer (copy-marker (point) t))
            (reasoning nil))
        (display-buffer buffer)
        (let ((gptel-include-reasoning (and org-roam-ask-show-reasoning t))
              (gptel--request-params org-roam-ask-request-params))
          (gptel-request
           (org-roam-ask--build-prompt question context)
           :system org-roam-ask-system-message
           :stream t
           :callback
           (lambda (response info)
             (cond
              ;; A chunk of the answer.
              ((stringp response)
               (with-current-buffer buffer
                 (save-excursion (goto-char answer) (insert response))))
              ;; A chunk of the model's thinking.
              ((and (consp response) (eq (car response) 'reasoning))
               (when (and org-roam-ask-show-reasoning (stringp (cdr response)))
                 (push (cdr response) reasoning)))
              ;; Finished.
              ((eq response t)
               (with-current-buffer buffer
                 (org-roam-ask--normalize-markup start answer)
                 (save-excursion
                   (goto-char answer)
                   (when reasoning
                     (insert "\n:REASONING:\n"
                             (string-join (nreverse reasoning))
                             "\n:END:\n"))
                   (insert (org-roam-ask--sources context)))
                 (when (fboundp 'org-fold-hide-drawer-all)
                   (ignore-errors (org-fold-hide-drawer-all)))))
              ;; Failed.
              (t
               (message "org-roam-ask: request failed -- %s"
                        (plist-get info :status)))))))))))

;;;###autoload
(defun org-roam-ask (question)
  "Answer QUESTION from the notes, using the LLM configured in gptel."
  (interactive (list (read-string "Ask your notes: ")))
  (when (string-blank-p question)
    (user-error "org-roam-ask: empty question"))
  (let ((chunks (org-roam-ask--ensure-index)))
    (message "org-roam-ask: retrieving...")
    (org-roam-ask--embed
     (list question)
     (lambda (vectors err)
       (cond
        (err (message "org-roam-ask: %s" err))
        (t
         (let* ((results (org-roam-ask--rank (car vectors) chunks
                                             org-roam-ask-context-chunks))
                (context (org-roam-ask--select-context results)))
           (if (null context)
               (message "org-roam-ask: nothing relevant found")
             (run-at-time 0 nil #'org-roam-ask--answer question context)))))))))


(provide 'org-roam-ask)

;;; org-roam-ask.el ends here
