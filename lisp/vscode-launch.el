;;; vscode-launch.el --- Run VS Code launch.json configurations -*- lexical-binding: t; -*-

;; Author: Huy Pham
;; Keywords: tools, processes, convenience
;; Package-Requires: ((emacs "30.1") (dape "0.27"))

;;; Commentary:

;; Reads `.vscode/launch.json' from the current project and lets you run
;; its configurations from Emacs.
;;
;;   `vscode-launch'         Pick a configuration (or compound) and run it.
;;                           With a prefix argument, never start a debugger.
;;   `vscode-launch-rerun'   Run the last configuration used in this project.
;;   `vscode-launch-open-file'  Visit the launch.json.
;;
;; launch.json is a VS Code configuration language that ends up as DAP
;; launch arguments.  Debuggable configurations are therefore passed to
;; `dape' with every property forwarded as a keyword (VS Code-only
;; properties such as `name', `preLaunchTask' and `presentation' are
;; stripped), merged into the `dape-configs' entry that supplies the
;; adapter command.  The entry is chosen by `vscode-launch-dape-adapters',
;; else by a unique match of `:type' in `dape-configs'.
;;
;; Configurations that are plain commands (`node' with an npm/npx
;; `runtimeExecutable', `node-terminal') run in a comint `compile' buffer,
;; which dape cannot express.  Like VS Code's `node-terminal', such a
;; command is debugged by attaching to the node process it starts: when
;; its output announces "Debugger listening on ws://HOST:PORT" (what
;; `node --inspect' prints, also under nodemon), a dape attach session
;; (`vscode-launch-node-attach-key', with `restart' so that nodemon
;; restarts reconnect) is started.  A command that does not start node
;; with --inspect is not debugged.  Compounds run their members in order.
;; Attach requests and browser types are reported as unsupported.
;;
;; Pipeline: read JSONC -> pick -> platform override (linux/osx/windows)
;; -> substitute variables and inputs -> plan -> run.  Anything that
;; cannot be resolved is an error rather than being passed on literally.
;;
;; Variables: ${workspaceFolder}, ${workspaceFolder:NAME} (see
;; `vscode-launch-workspace-folders'), ${workspaceRoot},
;; ${workspaceFolderBasename}, ${cwd}, ${userHome}, ${pathSeparator},
;; ${file}, ${fileBasename}, ${fileBasenameNoExtension}, ${fileDirname},
;; ${fileExtname}, ${fileWorkspaceFolder}, ${relativeFile},
;; ${relativeFileDirname}, ${lineNumber}, ${selectedText}, ${env:NAME},
;; ${input:ID} (promptString, pickString, command) and ${command:NAME}
;; (see `vscode-launch-command-resolvers').  ${config:NAME} needs
;; `vscode-launch-config-variable-function'.
;;
;; `preLaunchTask' (of a configuration or a compound) is run from
;; `.vscode/tasks.json' before the configuration starts: `shell',
;; `process' and `npm' tasks, `dependsOn' with `dependsOrder', platform
;; overrides, `options' (cwd, env, shell) and background tasks.  A
;; background task counts as ready when its problem matcher's
;; `endsPattern' (or the built-in `$tsc-watch') matches its output, and a
;; background task still running from an earlier launch is reused.  A
;; failing task stops the launch.  `postDebugTask' only warns.
;;
;; Not supported: anything a VS Code debugger extension does in its own
;; resolveDebugConfiguration hooks.  `env' and `envFile' values are never
;; echoed or logged, since launch.json files often hold credentials.
;;
;; Lisp API: `vscode-launch-read', `vscode-launch-configurations',
;; `vscode-launch-find-configuration', `vscode-launch-make-context',
;; `vscode-launch-resolve', `vscode-launch-strip-client-properties',
;; `vscode-launch-to-dape', `vscode-launch-register-adapter' and
;; `vscode-launch-select'.  `vscode-launch-dape' is the debugger-only
;; variant of `vscode-launch'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'compile)
(require 'url-handlers)

(defvar dape-configs)
(defvar dape-adapter-dir)
(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape--config-eval "dape" (key options &optional skip-functions))


;;; ----------------------------------------------------------------------
;;; Customization
;;; ----------------------------------------------------------------------

(defgroup vscode-launch nil
  "Run VS Code launch.json configurations from Emacs."
  :group 'tools
  :prefix "vscode-launch-")

(defcustom vscode-launch-adapter-alist
  '(("python"        . vscode-launch--plan-python)
    ("debugpy"       . vscode-launch--plan-python)
    ("node"          . vscode-launch--plan-node)
    ("pwa-node"      . vscode-launch--plan-node)
    ("node-terminal" . vscode-launch--plan-node-terminal))
  "Map a launch.json `type' to a planner with special handling.
A planner is called with (CONFIG ROOT FORCE-RUN) and returns a plan, see
`vscode-launch--plan'.  Types not listed here use the generic dape planner."
  :type '(alist :key-type string :value-type function))

(defcustom vscode-launch-dape-adapters
  '(("dart"     . flutter)
    ("go"       . dlv)
    ("node"     . js-debug-node)
    ("pwa-node" . js-debug-node))
  "Explicit map from a launch.json `type' to a key of `dape-configs'.
Types not listed are matched against the `:type' of `dape-configs'
entries, and you are asked to choose when several match."
  :type '(alist :key-type string :value-type symbol))

(defcustom vscode-launch-command-resolvers
  '(("python.interpreterPath" . vscode-launch--resolve-python))
  "Functions for ${command:NAME} and `command' inputs, by command name.
Each is called with the context plist and returns a string."
  :type '(alist :key-type string :value-type function))

(defcustom vscode-launch-config-variable-function nil
  "Function of one argument returning the value of ${config:NAME}, or nil."
  :type '(choice (const nil) function))

(defcustom vscode-launch-workspace-folders nil
  "Alist (NAME . DIRECTORY) used for ${workspaceFolder:NAME}."
  :type '(alist :key-type string :value-type directory))

(defcustom vscode-launch-prefer-debugger t
  "When non-nil, start a debugger via dape when a configuration allows it.
A prefix argument to `vscode-launch' inverts this for one call."
  :type 'boolean)

(defconst vscode-launch--js-debug-fallback-version "v1.140.0"
  "Release used when the latest one cannot be looked up.")

(defcustom vscode-launch-js-debug-version 'latest
  "Release of vscode-js-debug that `vscode-launch-install-js-debug' installs.
`latest' asks GitHub for the newest release; a string such as \"v1.140.0\"
pins one."
  :type '(choice (const :tag "Latest release" latest) (string :tag "Tag")))

(defcustom vscode-launch-install-js-debug 'ask
  "What to do when a node configuration needs js-debug and it is missing.
`ask' offers to download it, t downloads it without asking, nil never
installs it (the configuration then runs as a plain command)."
  :type '(choice (const :tag "Ask first" ask) (const :tag "Always" t) (const :tag "Never" nil)))

(defcustom vscode-launch-install-debugpy 'ask
  "What to do when a Python configuration needs debugpy and none is found.
debugpy is installed into its own virtual environment under
`dape-adapter-dir', never into the project's.  `ask' offers to create it,
t creates it without asking, nil never does."
  :type '(choice (const :tag "Ask first" ask) (const :tag "Always" t) (const :tag "Never" nil)))

(defcustom vscode-launch-node-attach-key 'js-debug-node-attach
  "Key of the `dape-configs' entry used to attach to a node-terminal command."
  :type 'symbol)

(defcustom vscode-launch-client-properties
  '(:name :presentation :preLaunchTask :postDebugTask
    :internalConsoleOptions :serverReadyAction :windows :linux :osx)
  "Known VS Code-only properties, never sent to the debug adapter.
This list is not exhaustive: every property not listed here is treated
as an adapter argument and forwarded."
  :type '(repeat symbol))

(defconst vscode-launch--planner-keys '(:type :env :envFile :cwd)
  "Properties the planners consume themselves instead of forwarding as is.")

(defconst vscode-launch--top-level-keys '(:version :configurations :compounds :inputs)
  "The top-level launch.json fields VS Code defines.")

(defvar vscode-launch--require-dape nil
  "When non-nil, planning fails for configurations that cannot run under dape.")

(defvar vscode-launch--last (make-hash-table :test 'equal)
  "Project root -> name of the last configuration run.")


;;; ----------------------------------------------------------------------
;;; Locating and parsing launch.json
;;; ----------------------------------------------------------------------

(defun vscode-launch--root ()
  "Return the workspace root: nearest directory with .vscode/launch.json."
  (let ((dir (or (locate-dominating-file
                  default-directory
                  (lambda (d) (file-readable-p (expand-file-name ".vscode/launch.json" d))))
                 (and (project-current) (project-root (project-current)))
                 default-directory)))
    (directory-file-name (expand-file-name dir))))

(defun vscode-launch--file (root)
  "Return the launch.json path under ROOT, or signal a user error."
  (let ((file (expand-file-name ".vscode/launch.json" root)))
    (unless (file-readable-p file)
      (user-error "No .vscode/launch.json in %s" root))
    file))

(defun vscode-launch--strip-comments (s)
  "Return S without // and /* */ comments, leaving strings intact."
  (with-temp-buffer
    (let ((i 0) (n (length s)) (in-string nil))
      (while (< i n)
        (let ((c (aref s i))
              (next (and (< (1+ i) n) (aref s (1+ i)))))
          (cond
           (in-string
            (insert c)
            (cond ((and (eq c ?\\) next) (insert next) (cl-incf i 2))
                  (t (when (eq c ?\") (setq in-string nil))
                     (cl-incf i))))
           ((eq c ?\") (setq in-string t) (insert c) (cl-incf i))
           ((and (eq c ?/) (eq next ?/))
            (while (and (< i n) (not (eq (aref s i) ?\n))) (cl-incf i)))
           ((and (eq c ?/) (eq next ?*))
            (let ((end (string-search "*/" s (+ i 2))))
              (unless end (user-error "Unterminated /* comment in launch.json"))
              (insert ?\s)
              (setq i (+ end 2))))
           (t (insert c) (cl-incf i))))))
    (buffer-string)))

(defun vscode-launch--strip-trailing-commas (s)
  "Return S without commas that directly precede a closing } or ]."
  (with-temp-buffer
    (let ((i 0) (n (length s)) (in-string nil))
      (while (< i n)
        (let ((c (aref s i)))
          (cond
           (in-string
            (insert c)
            (cond ((and (eq c ?\\) (< (1+ i) n)) (insert (aref s (1+ i))) (cl-incf i 2))
                  (t (when (eq c ?\") (setq in-string nil))
                     (cl-incf i))))
           ((eq c ?\") (setq in-string t) (insert c) (cl-incf i))
           ((eq c ?,)
            (let ((j (1+ i)))
              (while (and (< j n) (memq (aref s j) '(?\s ?\t ?\n ?\r))) (cl-incf j))
              (unless (and (< j n) (memq (aref s j) '(?} ?\])))
                (insert c)))
            (cl-incf i))
           (t (insert c) (cl-incf i))))))
    (buffer-string)))

(defun vscode-launch--parse (string)
  "Parse JSONC STRING.
Objects become plists with keyword keys, arrays vectors, true t, false
:false and null :null, so absent, false and null stay distinguishable."
  (let* ((s (string-remove-prefix "\ufeff" string))
         (data (json-parse-string
                (vscode-launch--strip-trailing-commas (vscode-launch--strip-comments s))
                :object-type 'plist :array-type 'array
                :null-object :null :false-object :false)))
    (unless (and (consp data) (keywordp (car data)))
      (user-error "launch.json must contain a JSON object"))
    data))

(defun vscode-launch--validate (data)
  "Signal a user error unless DATA is a structurally valid launch.json.
Unknown top-level fields only produce a warning."
  (let ((configs (plist-get data :configurations)))
    (unless (vectorp configs)
      (user-error "launch.json has no `configurations' array"))
    (cl-loop for c across configs for i from 1
             do (unless (vscode-launch--plistp c)
                  (user-error "configurations[%d] is not an object" i))
             (unless (stringp (plist-get c :name))
               (user-error "configurations[%d] has no `name'" i))
             (unless (stringp (plist-get c :type))
               (user-error "Configuration `%s' has no `type'" (plist-get c :name)))
             (unless (stringp (plist-get c :request))
               (user-error "Configuration `%s' has no `request'" (plist-get c :name)))))
  (dolist (key '(:compounds :inputs))
    (when (and (plist-member data key) (not (vectorp (plist-get data key))))
      (user-error "launch.json `%s' must be an array" (substring (symbol-name key) 1))))
  (cl-loop for c across (or (plist-get data :compounds) [])
           do (unless (and (vscode-launch--plistp c) (stringp (plist-get c :name)))
                (user-error "A compound in launch.json has no `name'"))
           (unless (vectorp (plist-get c :configurations))
             (user-error "Compound `%s' has no `configurations' array" (plist-get c :name))))
  (cl-loop for (k _) on data by #'cddr
           unless (memq k vscode-launch--top-level-keys)
           do (display-warning 'vscode-launch
                               (format "Unknown top-level field `%s' in launch.json"
                                       (substring (symbol-name k) 1)))))

(defun vscode-launch-read (file)
  "Read and validate the launch.json FILE and return its parsed contents.
Objects are plists with keyword keys, arrays vectors, false is `:false'
and null is `:null'."
  (unless (file-readable-p file)
    (user-error "Cannot read %s" file))
  (let ((data (with-temp-buffer
                (insert-file-contents file)
                (condition-case err
                    (vscode-launch--parse (buffer-string))
                  (user-error (signal (car err) (cdr err)))
                  (error (user-error "Cannot parse launch.json: %s"
                                     (error-message-string err)))))))
    (let ((version (plist-get data :version)))
      (unless (equal version "0.2.0")
        (display-warning 'vscode-launch
                         (format "Unknown launch.json version: %S" version))))
    (vscode-launch--validate data)
    data))

(defun vscode-launch--read (root)
  "Return the parsed launch.json of ROOT."
  (vscode-launch-read (vscode-launch--file root)))

(defun vscode-launch-configurations (data)
  "Return the configurations of the launch.json DATA as an alist (NAME . CONFIG)."
  (let (out)
    (cl-loop for c across (or (plist-get data :configurations) [])
             for n = (plist-get c :name)
             do (cond ((not n)
                       (display-warning 'vscode-launch "Skipping configuration without a name"))
                      ((assoc n out)
                       (display-warning 'vscode-launch
                                        (format "Duplicate configuration name `%s' ignored" n)))
                      (t (push (cons n c) out))))
    (nreverse out)))

(defalias 'vscode-launch--configs #'vscode-launch-configurations)

(defun vscode-launch-find-configuration (data name)
  "Return the configuration called NAME in the launch.json DATA, or nil."
  (cdr (assoc name (vscode-launch-configurations data))))

(defun vscode-launch--compounds (data)
  "Return DATA's compounds as an alist (NAME . COMPOUND), COMPOUND being the plist."
  (cl-loop for c across (or (plist-get data :compounds) [])
           for n = (plist-get c :name)
           when n collect (cons n c)))

(defun vscode-launch--compound-members (compound)
  "Return the members of COMPOUND as a list of (NAME . FOLDER); FOLDER may be nil."
  (mapcar (lambda (m)
            (if (stringp m)
                (cons m nil)
              (cons (plist-get m :name) (plist-get m :folder))))
          (plist-get compound :configurations)))

(defun vscode-launch--hidden-p (obj)
  "Non-nil if the configuration or compound OBJ has `presentation.hidden'."
  (eq (plist-get (plist-get obj :presentation) :hidden) t))


;;; ----------------------------------------------------------------------
;;; Platform overrides
;;; ----------------------------------------------------------------------

(defun vscode-launch--plistp (x)
  "Non-nil if X is a non-empty plist with keyword keys."
  (and (consp x) (keywordp (car x))))

(defun vscode-launch--merge (base over)
  "Return BASE with plist OVER merged in recursively."
  (let ((out (copy-sequence base)))
    (cl-loop for (k v) on over by #'cddr
             do (let ((old (plist-get out k)))
                  (setq out (plist-put out k (if (and (vscode-launch--plistp old)
                                                      (vscode-launch--plistp v))
                                                 (vscode-launch--merge old v)
                                               v)))))
    out))

(defun vscode-launch--apply-platform (cfg platform)
  "Merge CFG's PLATFORM (:linux, :osx or :windows) block onto it, drop the blocks."
  (let ((over (plist-get cfg platform))
        (base (cl-loop for (k v) on cfg by #'cddr
                       unless (memq k '(:windows :osx :linux))
                       append (list k v))))
    (if (vscode-launch--plistp over) (vscode-launch--merge base over) base)))


;;; ----------------------------------------------------------------------
;;; Context, variables, inputs
;;; ----------------------------------------------------------------------

(defun vscode-launch-make-context (root data)
  "Return the resolution context for workspace ROOT and launch.json DATA.
File, line and region variables come from the current buffer."
  (list :root root
        :file (buffer-file-name)
        :line (line-number-at-pos)
        :selected-text (and (use-region-p)
                            (buffer-substring-no-properties (region-beginning) (region-end)))
        :platform (pcase system-type ('darwin :osx) ('windows-nt :windows) (_ :linux))
        :inputs (append (plist-get data :inputs) nil)
        :cache (make-hash-table :test 'equal)))

(defalias 'vscode-launch--context #'vscode-launch-make-context)

(defun vscode-launch-resolve (config context)
  "Return CONFIG with its platform override applied and variables substituted.
CONTEXT comes from `vscode-launch-make-context'.  Inputs are prompted for."
  (vscode-launch--subst
   (vscode-launch--apply-platform config (plist-get context :platform))
   context))

(defun vscode-launch--python (root)
  "Return a Python interpreter for the workspace ROOT."
  (or (let ((venv (expand-file-name ".venv/bin/python" root)))
        (and (file-executable-p venv) venv))
      (let ((v (getenv "VIRTUAL_ENV")))
        (and v (file-executable-p (expand-file-name "bin/python" v))
             (expand-file-name "bin/python" v)))
      (executable-find "python3")
      (executable-find "python")
      "python3"))

(defun vscode-launch--resolve-python (ctx)
  "Resolve ${command:python.interpreterPath} for CTX."
  (vscode-launch--python (plist-get ctx :root)))

(defun vscode-launch--command (name ctx)
  "Run the resolver registered for the VS Code command NAME with CTX."
  (let ((fn (alist-get name vscode-launch-command-resolvers nil nil #'equal)))
    (unless fn
      (user-error "No resolver for VS Code command `%s'; add one to `vscode-launch-command-resolvers'"
                  name))
    (funcall fn ctx)))

(defun vscode-launch--input (id ctx)
  "Return the value of the launch.json input ID, prompting once per run."
  (let* ((cache (plist-get ctx :cache))
         (hit (and cache (gethash id cache 'none))))
    (if (and hit (not (eq hit 'none)))
        hit
      (let* ((def (seq-find (lambda (i) (equal (plist-get i :id) id)) (plist-get ctx :inputs)))
             (_ (unless def (user-error "No input with id `%s' in launch.json" id)))
             (type (plist-get def :type))
             (prompt (format "%s: " (or (plist-get def :description) id)))
             (default (plist-get def :default))
             (value
              (pcase type
                ("promptString"
                 (if (eq (plist-get def :password) t)
                     (read-passwd prompt)
                   (read-string prompt (and (stringp default) default))))
                ("pickString"
                 (let* ((opts (mapcar (lambda (o)
                                        (if (stringp o)
                                            (cons o o)
                                          (cons (or (plist-get o :label) (plist-get o :value))
                                                (plist-get o :value))))
                                      (plist-get def :options)))
                        (dflt (car (rassoc default opts)))
                        (choice (completing-read prompt (mapcar #'car opts) nil t nil nil dflt)))
                   (cdr (assoc choice opts))))
                ("command" (vscode-launch--command (plist-get def :command) ctx))
                (_ (user-error "Unsupported input type `%s' for `%s'" type id)))))
        (when cache (puthash id value cache))
        value))))

(defun vscode-launch--need-file (name file)
  "Return FILE, or signal that ${NAME} cannot be resolved without one."
  (or file (user-error "Cannot resolve ${%s}: current buffer is not visiting a file" name)))

(defun vscode-launch--variable (name ctx)
  "Return the string value of variable NAME in context CTX, or signal an error."
  (let ((root (plist-get ctx :root))
        (file (plist-get ctx :file)))
    (pcase name
      ((or "workspaceFolder" "workspaceRoot" "cwd") root)
      ((rx bos "workspaceFolder:" (let folder (+ anything)) eos)
       (or (alist-get folder vscode-launch-workspace-folders nil nil #'equal)
           (user-error "Unknown workspace folder `%s'; see `vscode-launch-workspace-folders'"
                       folder)))
      ("workspaceFolderBasename" (file-name-nondirectory root))
      ("userHome" (expand-file-name "~"))
      ("pathSeparator" "/")
      ("file" (vscode-launch--need-file name file))
      ("fileBasename" (file-name-nondirectory (vscode-launch--need-file name file)))
      ("fileBasenameNoExtension"
       (file-name-sans-extension (file-name-nondirectory (vscode-launch--need-file name file))))
      ("fileDirname"
       (directory-file-name (file-name-directory (vscode-launch--need-file name file))))
      ("fileExtname"
       (let ((ext (file-name-extension (vscode-launch--need-file name file))))
         (if (and ext (not (string-empty-p ext))) (concat "." ext) "")))
      ("fileWorkspaceFolder" (vscode-launch--need-file name file) root)
      ("relativeFile" (file-relative-name (vscode-launch--need-file name file) root))
      ("relativeFileDirname"
       (directory-file-name
        (file-relative-name (file-name-directory (vscode-launch--need-file name file)) root)))
      ("lineNumber" (number-to-string (or (plist-get ctx :line) 1)))
      ("selectedText" (or (plist-get ctx :selected-text)
                          (user-error "Cannot resolve ${selectedText}: no active region")))
      ((rx bos "env:" (let var (+ anything)) eos)
       (or (getenv var)
           (progn (message "vscode-launch: environment variable %s is undefined" var) "")))
      ((rx bos "input:" (let id (+ anything)) eos) (vscode-launch--input id ctx))
      ((rx bos "command:" (let cmd (+ anything)) eos) (vscode-launch--command cmd ctx))
      ((rx bos "config:" (let key (+ anything)) eos)
       (or (and vscode-launch-config-variable-function
                (funcall vscode-launch-config-variable-function key))
           (user-error "Cannot resolve ${config:%s}; set `vscode-launch-config-variable-function'"
                       key)))
      (_ (user-error "Unsupported variable ${%s}" name)))))

(defun vscode-launch--subst-string (s ctx)
  "Substitute ${...} variables in S using CTX."
  (replace-regexp-in-string
   "\\${\\([^}]+\\)}"
   (lambda (m)
     (let ((name (match-string 1 m)))
       (save-match-data (vscode-launch--variable name ctx))))
   s t t))

(defun vscode-launch--subst (x ctx)
  "Recursively substitute variables in the parsed JSON value X."
  (cond ((stringp x) (vscode-launch--subst-string x ctx))
        ((vectorp x) (vconcat (mapcar (lambda (e) (vscode-launch--subst e ctx)) x)))
        ((vscode-launch--plistp x)
         (cl-loop for (k v) on x by #'cddr
                  append (list k (vscode-launch--subst v ctx))))
        (t x)))


;;; ----------------------------------------------------------------------
;;; Environment, executables, cwd
;;; ----------------------------------------------------------------------

(defun vscode-launch--read-env-file (file)
  "Return an alist (NAME . VALUE) from the dotenv-style FILE."
  (unless (file-readable-p file)
    (user-error "envFile %s not found" file))
  (let (out)
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-string) "\n" t))
        (setq line (string-trim line))
        (when (and (not (string-prefix-p "#" line))
                   (string-match "\\`\\(?:export[ \t]+\\)?\\([A-Za-z_][A-Za-z0-9_]*\\)=\\(.*\\)\\'" line))
          (let ((key (match-string 1 line))
                (val (string-trim (match-string 2 line))))
            (when (string-match "\\`\\([\"']\\)\\(.*\\)\\1\\'" val)
              (setq val (match-string 2 val)))
            (push (cons key val) out)))))
    (nreverse out)))

(defun vscode-launch--scalar-string (v)
  "Return the JSON scalar V as a string, or nil for null."
  (cond ((stringp v) v)
        ((eq v t) "true")
        ((eq v :false) "false")
        ((eq v :null) nil)
        (t (format "%s" v))))

(defun vscode-launch--env (cfg &optional root)
  "Return CFG's environment as an alist (NAME . VALUE); VALUE nil unsets NAME.
`env' wins over `envFile'; a relative envFile is resolved against ROOT."
  (let* ((envfile (plist-get cfg :envFile))
         (from-file (when envfile
                      (vscode-launch--read-env-file
                       (expand-file-name envfile (or root default-directory)))))
         (from-env (cl-loop for (k v) on (plist-get cfg :env) by #'cddr
                            collect (cons (substring (symbol-name k) 1)
                                          (vscode-launch--scalar-string v)))))
    (append from-env
            (cl-remove-if (lambda (kv) (assoc (car kv) from-env)) from-file))))

(defun vscode-launch--env-plist (env)
  "Convert the alist ENV to a plist with keyword keys, as dape expects."
  (cl-loop for (k . v) in env append (list (intern (concat ":" k)) (or v :null))))

(defun vscode-launch--exe (exe)
  "Return a usable form of EXE.
Absolute paths that no longer exist (stale fnm/nvm shims) fall back to
the bare command name, resolved through PATH."
  (if (and (file-name-absolute-p exe) (not (file-executable-p exe)))
      (let ((base (file-name-nondirectory exe)))
        (or (executable-find base) base))
    exe))

(defun vscode-launch--fix-command-exe (command)
  "Apply `vscode-launch--exe' to the first word of the shell string COMMAND."
  (if (string-match "\\`\\(/[^ \t]+\\)\\(.*\\)\\'" command)
      (concat (vscode-launch--exe (match-string 1 command)) (match-string 2 command))
    command))

(defun vscode-launch--cwd (cfg root)
  "Return the working directory of CFG relative to ROOT."
  (expand-file-name (or (plist-get cfg :cwd) ".") root))

(defun vscode-launch--arg-strings (args)
  "Return the vector ARGS as a list of strings."
  (delq nil (mapcar #'vscode-launch--scalar-string args)))

(defun vscode-launch--shell-join (words)
  "Quote and join WORDS into a shell command."
  (mapconcat (lambda (w)
               (if (string-match-p "\\`~?[A-Za-z0-9_@%+=:,./-]+\\'" w)
                   w
                 (shell-quote-argument w)))
             (delq nil words) " "))


;;; ----------------------------------------------------------------------
;;; Planning
;;; ----------------------------------------------------------------------
;; A plan is one of
;;   (:run :command STR :cwd DIR :env ALIST)
;;   (:dape :key SYMBOL :options PLIST :cwd DIR)
;;   (:unsupported :reason STR)
;; Planning starts nothing (it may prompt for inputs), so it can be tested
;; and smoke-checked against real files.

(defun vscode-launch--dape-loaded-p ()
  "Non-nil if dape is loaded or loadable."
  (or (featurep 'dape) (require 'dape nil t)))

(defun vscode-launch--dape-entry-p (key)
  "Non-nil if dape is available and `dape-configs' has KEY."
  (and (vscode-launch--dape-loaded-p) (assq key dape-configs) t))

(defun vscode-launch--find-dape-key (type &optional default)
  "Return the `dape-configs' key to use for the launch.json TYPE, or nil.
Order: `vscode-launch-dape-adapters', DEFAULT, a unique `:type' match
in `dape-configs', else ask the user among several matches."
  (when (vscode-launch--dape-loaded-p)
    (let ((explicit (alist-get type vscode-launch-dape-adapters nil nil #'equal)))
      (cond
       ((and explicit (assq explicit dape-configs)) explicit)
       ((and default (assq default dape-configs)) default)
       (t (let ((matches (cl-loop for (key . plist) in dape-configs
                                  when (equal (plist-get plist :type) type) collect key)))
            (pcase (length matches)
              (0 nil)
              (1 (car matches))
              (_ (display-warning
                  'vscode-launch
                  (format "Several dape configs match type `%s': %s"
                          type (mapconcat #'symbol-name matches ", ")))
                 (intern (completing-read
                          (format "Several dape configs match type `%s': " type)
                          (mapcar #'symbol-name matches) nil t))))))))))

(defun vscode-launch-register-adapter (type dape-key)
  "Use the `dape-configs' entry DAPE-KEY for launch.json configurations of TYPE."
  (setf (alist-get type vscode-launch-dape-adapters nil nil #'equal) dape-key))

(defun vscode-launch--js-debug-dir ()
  "Return the directory js-debug is (to be) installed in, or nil without dape."
  (and (boundp 'dape-adapter-dir)
       (expand-file-name "js-debug" dape-adapter-dir)))

(defun vscode-launch--js-debug-installed-p ()
  "Non-nil if the js-debug adapter used by dape is installed."
  (and (vscode-launch--dape-entry-p 'js-debug-node)
       (vscode-launch--js-debug-dir)
       (file-exists-p (expand-file-name "src/dapDebugServer.js"
                                        (vscode-launch--js-debug-dir)))))

(defun vscode-launch--js-debug-version ()
  "Return the js-debug release tag to install."
  (if (stringp vscode-launch-js-debug-version)
      vscode-launch-js-debug-version
    (condition-case err
        (let ((buf (url-retrieve-synchronously
                    "https://api.github.com/repos/microsoft/vscode-js-debug/releases/latest"
                    t nil 15)))
          (unless buf (error "no response"))
          (unwind-protect
              (with-current-buffer buf
                (goto-char (point-min))
                (re-search-forward "\r?\n\r?\n")
                (let ((tag (plist-get (json-parse-buffer :object-type 'plist) :tag_name)))
                  (unless (and (stringp tag) (string-match-p "\\`v[0-9][0-9.]*\\'" tag))
                    (error "unexpected tag %S" tag))
                  tag))
            (kill-buffer buf)))
      (error
       (display-warning 'vscode-launch
                        (format "Cannot look up the latest js-debug (%s); using %s"
                                (error-message-string err)
                                vscode-launch--js-debug-fallback-version))
       vscode-launch--js-debug-fallback-version))))

;;;###autoload
(defun vscode-launch-install-js-debug (&optional version)
  "Download and install the js-debug DAP server (VERSION, default
`vscode-launch-js-debug-version') into `dape-adapter-dir'.
Replaces an existing installation."
  (interactive)
  (unless (vscode-launch--dape-loaded-p)
    (user-error "dape is not available"))
  (unless (executable-find "tar")
    (user-error "Installing js-debug needs the `tar' program"))
  (let* ((version (or version (vscode-launch--js-debug-version)))
         (url (format "https://github.com/microsoft/vscode-js-debug/releases/download/%s/js-debug-dap-%s.tar.gz"
                      version version))
         (archive (make-temp-file "js-debug-dap" nil ".tar.gz"))
         (adapters (file-name-as-directory (expand-file-name dape-adapter-dir)))
         (stage (make-temp-file "js-debug-stage" t)))
    (unwind-protect
        (progn
          (message "vscode-launch: downloading js-debug %s..." version)
          (condition-case err
              (url-copy-file url archive t)
            (error (user-error "Cannot download %s: %s" url (error-message-string err))))
          (unless (zerop (call-process "tar" nil nil nil "-xzf" archive "-C" stage))
            (user-error "Cannot extract %s; is the version %s right?" url version))
          (unless (file-exists-p (expand-file-name "js-debug/src/dapDebugServer.js" stage))
            (user-error "Unexpected js-debug archive layout in %s" url))
          (make-directory adapters t)
          (when (file-exists-p (vscode-launch--js-debug-dir))
            (delete-directory (vscode-launch--js-debug-dir) t))
          (rename-file (expand-file-name "js-debug" stage) (vscode-launch--js-debug-dir))
          (message "vscode-launch: installed js-debug %s in %s" version (vscode-launch--js-debug-dir)))
      (ignore-errors (delete-file archive))
      (ignore-errors (delete-directory stage t)))
    (vscode-launch--js-debug-dir)))

(defun vscode-launch--js-debug-available-p ()
  "Non-nil if js-debug is installed, or may be installed on demand."
  (and (vscode-launch--dape-entry-p 'js-debug-node)
       (or (vscode-launch--js-debug-installed-p)
           (and vscode-launch-install-js-debug (vscode-launch--js-debug-dir) t))))

(defun vscode-launch--ensure-js-debug ()
  "Install js-debug if missing, as `vscode-launch-install-js-debug' allows."
  (unless (vscode-launch--js-debug-installed-p)
    (if (or (eq vscode-launch-install-js-debug t)
            (and (eq vscode-launch-install-js-debug 'ask)
                 (y-or-n-p "js-debug is not installed; download it from GitHub? ")))
        (vscode-launch-install-js-debug)
      (user-error "js-debug is not installed; run `vscode-launch-install-js-debug'"))))

(defun vscode-launch--debugpy-venv ()
  "Return the directory of the dedicated debugpy virtual environment."
  (and (boundp 'dape-adapter-dir)
       (expand-file-name "debugpy" dape-adapter-dir)))

(defun vscode-launch--debugpy-python ()
  "Return the interpreter of the dedicated debugpy environment, or nil."
  (when-let* ((venv (vscode-launch--debugpy-venv)))
    (expand-file-name "bin/python" venv)))

(defun vscode-launch--has-debugpy-p (python)
  "Non-nil if the interpreter PYTHON can import the debugpy adapter."
  (and python (executable-find python)
       (zerop (call-process python nil nil nil "-c" "import debugpy.adapter"))))

(defun vscode-launch--call (program &rest args)
  "Run PROGRAM with ARGS; signal a `user-error' with its output on failure."
  (with-temp-buffer
    (unless (zerop (apply #'call-process program nil t nil args))
      (user-error "`%s %s' failed: %s" program (string-join args " ")
                  (string-trim (buffer-string))))))

;;;###autoload
(defun vscode-launch-install-debugpy ()
  "Create a virtual environment for debugpy under `dape-adapter-dir'.
The environment is separate from any project's: the debug adapter runs
from it and launches the project's own interpreter (the `python'
launch property), which does not need debugpy.  Running this again
upgrades debugpy."
  (interactive)
  (unless (vscode-launch--dape-loaded-p)
    (user-error "dape is not available"))
  (let* ((venv (vscode-launch--debugpy-venv))
         (python (vscode-launch--debugpy-python))
         (uv (executable-find "uv"))
         (base (or (executable-find "python3") (executable-find "python"))))
    (unless (or uv base)
      (user-error "Need `uv' or `python3' to create the debugpy environment"))
    (make-directory (file-name-directory venv) t)
    (message "vscode-launch: installing debugpy into %s..." venv)
    (unless (file-executable-p python)
      (if uv
          (vscode-launch--call uv "venv" venv)
        (vscode-launch--call base "-m" "venv" venv)))
    (if uv
        (vscode-launch--call uv "pip" "install" "--python" python "--upgrade" "debugpy")
      (vscode-launch--call python "-m" "pip" "install" "--upgrade" "debugpy"))
    (unless (vscode-launch--has-debugpy-p python)
      (user-error "debugpy was installed but cannot be imported from %s" venv))
    (message "vscode-launch: installed debugpy in %s" venv)
    python))

(defun vscode-launch--debugpy-adapter (project-python)
  "Return (PYTHON . INSTALL-P): the interpreter that runs the debugpy adapter.
Order: the dedicated environment, PROJECT-PYTHON if it has debugpy, the
dedicated environment to be created, else PROJECT-PYTHON (dape then
reports the missing module)."
  (let ((own (vscode-launch--debugpy-python)))
    (cond
     ((and own (vscode-launch--has-debugpy-p own)) (cons own nil))
     ((vscode-launch--has-debugpy-p project-python) (cons project-python nil))
     ((and own vscode-launch-install-debugpy) (cons own t))
     (t (cons project-python nil)))))

(defun vscode-launch--ensure-debugpy ()
  "Create the debugpy venv if missing, when `vscode-launch-install-debugpy' allows."
  (unless (vscode-launch--has-debugpy-p (vscode-launch--debugpy-python))
    (if (or (eq vscode-launch-install-debugpy t)
            (and (eq vscode-launch-install-debugpy 'ask)
                 (y-or-n-p "debugpy is not installed; create a venv for it and install it? ")))
        (vscode-launch-install-debugpy)
      (user-error "debugpy is not installed; run `vscode-launch-install-debugpy'"))))

(defun vscode-launch--to-dape-value (v)
  "Convert the parsed JSON value V to what dape expects (false -> :json-false)."
  (cond ((eq v :false) :json-false)
        ((vectorp v) (vconcat (mapcar #'vscode-launch--to-dape-value v)))
        ((vscode-launch--plistp v)
         (cl-loop for (k x) on v by #'cddr append (list k (vscode-launch--to-dape-value x))))
        (t v)))

(defun vscode-launch-strip-client-properties (cfg)
  "Return plist CFG without the keys in `vscode-launch-client-properties'."
  (cl-loop for (k v) on cfg by #'cddr
           unless (memq k vscode-launch-client-properties)
           append (list k v)))

(defun vscode-launch--forwarded (cfg &optional extra-strip)
  "Return CFG's adapter properties as a dape plist.
Everything except `vscode-launch-client-properties', the keys the
planners handle themselves and EXTRA-STRIP is kept.  `:type' is dropped
so the dape entry's own `:type' stays in effect."
  (cl-loop for (k v) on (vscode-launch-strip-client-properties cfg) by #'cddr
           unless (or (memq k vscode-launch--planner-keys) (memq k extra-strip))
           append (list k (vscode-launch--to-dape-value v))))

(defun vscode-launch--dape-plan (key cfg root &optional extra-options extra-strip)
  "Build a :dape plan for entry KEY from CFG under ROOT."
  (let ((cwd (vscode-launch--cwd cfg root))
        (env (vscode-launch--env cfg root)))
    (list :dape :key key :cwd cwd
          :options (append extra-options
                           (list :cwd cwd)
                           (vscode-launch--forwarded cfg extra-strip)
                           (when env (list :env (vscode-launch--env-plist env)))))))

(defun vscode-launch--plan-python (cfg root force-run)
  "Plan a Python CFG relative to ROOT; FORCE-RUN skips the debugger."
  (let* ((module (plist-get cfg :module))
         (program (plist-get cfg :program))
         (python (vscode-launch--exe (or (plist-get cfg :python)
                                         (vscode-launch--python root))))
         (key (and (not force-run) vscode-launch-prefer-debugger
                   (vscode-launch--find-dape-key
                    (plist-get cfg :type) (if module 'debugpy-module 'debugpy)))))
    (cond
     ((not (or module program))
      (list :unsupported :reason "python config has neither `program' nor `module'"))
     (key
      (let* ((adapter (vscode-launch--debugpy-adapter python))
             (plan (vscode-launch--dape-plan
                    key cfg root (list 'command (car adapter) :python python) '(:python))))
        (if (cdr adapter) (append plan (list :ensure 'debugpy)) plan)))
     (t
      (list :run :cwd (vscode-launch--cwd cfg root) :env (vscode-launch--env cfg root)
            :command (vscode-launch--shell-join
                      (append (list python)
                              (if module (list "-m" module) (list program))
                              (vscode-launch--arg-strings (plist-get cfg :args)))))))))

(defun vscode-launch--plan-node (cfg root force-run)
  "Plan a node CFG relative to ROOT; FORCE-RUN skips the debugger."
  (let ((exe (plist-get cfg :runtimeExecutable))
        (program (plist-get cfg :program)))
    (cond
     ((and (not force-run) vscode-launch-prefer-debugger program
           (or (null exe) (equal (file-name-nondirectory exe) "node"))
           (vscode-launch--js-debug-available-p)
           (vscode-launch--find-dape-key (plist-get cfg :type) 'js-debug-node))
      (vscode-launch--dape-plan
       (vscode-launch--find-dape-key (plist-get cfg :type) 'js-debug-node) cfg root))
     ((not (or exe program))
      (list :unsupported :reason "node config has neither `runtimeExecutable' nor `program'"))
     (t
      (list :run :cwd (vscode-launch--cwd cfg root) :env (vscode-launch--env cfg root)
            :command (vscode-launch--shell-join
                      (append (list (if exe (vscode-launch--exe exe) "node"))
                              (vscode-launch--arg-strings (plist-get cfg :runtimeArgs))
                              (and program (list program))
                              (vscode-launch--arg-strings (plist-get cfg :args)))))))))

(defconst vscode-launch--attach-keys
  '(:skipFiles :outFiles :sourceMaps :resolveSourceMapLocations :sourceMapPathOverrides
    :smartStep :pauseForSourceMap)
  "launch.json properties forwarded to the attach session of a node-terminal command.")

(defun vscode-launch--plan-node-terminal (cfg root force-run)
  "Plan a node-terminal CFG relative to ROOT: run its `command' verbatim.
Unless FORCE-RUN, also plan attaching a debugger to the node it starts."
  (let ((command (plist-get cfg :command))
        (cwd (vscode-launch--cwd cfg root)))
    (if (not (stringp command))
        (list :unsupported :reason "node-terminal config has no `command'")
      (append
       (list :run :command (vscode-launch--fix-command-exe command)
             :cwd cwd
             :env (vscode-launch--env cfg root))
       (when (and (not force-run) vscode-launch-prefer-debugger
                  (vscode-launch--js-debug-available-p)
                  (vscode-launch--dape-entry-p vscode-launch-node-attach-key))
         (list :attach
               (list :key vscode-launch-node-attach-key
                     :options
                     (vscode-launch--attach-options cfg root cwd))))))))

(defun vscode-launch--attach-options (cfg root cwd)
  "Return the dape options for attaching to the node-terminal CFG.
The source-map and skipFiles defaults are what VS Code uses, where
${workspaceFolder} limits source maps to the workspace.  An attach session
has no workspace, so without them js-debug looks for the source maps of
every module in node_modules."
  (let ((given (cl-loop for (k v) on cfg by #'cddr
                        when (memq k vscode-launch--attach-keys)
                        append (list k (vscode-launch--to-dape-value v)))))
    (append (list :cwd cwd :restart t)
            given
            (unless (plist-member given :resolveSourceMapLocations)
              (list :resolveSourceMapLocations
                    (vector (concat root "/**") "!**/node_modules/**")))
            (unless (plist-member given :skipFiles)
              (list :skipFiles (vector "<node_internals>/**"))))))

(defun vscode-launch--plan-dape-generic (cfg root force-run)
  "Plan CFG of any other type through the dape entry matching its type."
  (let* ((type (plist-get cfg :type))
         (key (and (not force-run) (vscode-launch--find-dape-key type))))
    (cond (key (vscode-launch--dape-plan key cfg root))
          (force-run (list :unsupported
                           :reason (format "`%s' configs can only be debugged, not run as a command" type)))
          (t (list :unsupported
                   :reason (format "no dape config for type `%s'; map it in `vscode-launch-dape-adapters'"
                                   type))))))

(defun vscode-launch--plan (cfg root force-run)
  "Return the plan for the platform-merged, substituted configuration CFG."
  (let ((type (plist-get cfg :type))
        (request (plist-get cfg :request))
        (name (plist-get cfg :name)))
    (unless (stringp type) (user-error "Configuration `%s' has no `type'" name))
    (unless (stringp request) (user-error "Configuration `%s' has no `request'" name))
    (cond
     ((equal request "attach")
      (list :unsupported :reason "attach requests are not supported"))
     ((member type '("msedge" "chrome" "pwa-chrome" "pwa-msedge" "firefox"))
      (list :unsupported :reason "browser debugging is not supported"))
     (t (funcall (or (alist-get type vscode-launch-adapter-alist nil nil #'equal)
                     #'vscode-launch--plan-dape-generic)
                 cfg root force-run)))))


(defun vscode-launch-to-dape (config &optional root)
  "Convert the resolved launch.json CONFIG to a dape configuration.
ROOT is the workspace root and defaults to the current one.  Signal a
user error if CONFIG cannot be started under dape."
  (unless (and (vscode-launch--dape-loaded-p) (fboundp 'dape--config-eval))
    (user-error "dape is not available"))
  (let* ((vscode-launch-prefer-debugger t)
         (plan (vscode-launch--plan config (or root (vscode-launch--root)) nil)))
    (unless (eq (car plan) :dape)
      (user-error "%s cannot be started under dape: %s" (plist-get config :name)
                  (or (plist-get (cdr plan) :reason) "it runs as a plain command")))
    (dape--config-eval (plist-get (cdr plan) :key) (plist-get (cdr plan) :options))))


;;; ----------------------------------------------------------------------
;;; Tasks (preLaunchTask)
;;; ----------------------------------------------------------------------
;; A task plan is (:label L :exec EXEC :deps (TASKPLAN...) :order sequence|parallel)
;; where EXEC is nil or
;;   (:label L :command STR :cwd DIR :env ALIST :shell (EXE . SWITCH)
;;    :background BOOL :ready REGEXP)
;; Dependencies run first; then EXEC.  Planning starts nothing.

(defun vscode-launch--tasks-data (root ctx)
  "Return the parsed tasks.json of ROOT (cached in CTX), or nil without one."
  (let* ((cache (plist-get ctx :cache))
         (key (cons 'tasks root))
         (hit (and cache (gethash key cache 'none))))
    (if (and hit (not (eq hit 'none)))
        (if (eq hit :absent) nil hit)
      (let* ((file (expand-file-name ".vscode/tasks.json" root))
             (data (when (file-readable-p file)
                     (with-temp-buffer
                       (insert-file-contents file)
                       (condition-case err
                           (vscode-launch--parse (buffer-string))
                         (user-error (signal (car err) (cdr err)))
                         (error (user-error "Cannot parse tasks.json: %s"
                                            (error-message-string err))))))))
        (when cache (puthash key (or data :absent) cache))
        data))))

(defun vscode-launch--find-task (label data)
  "Return the task LABEL from the tasks.json DATA, or an implicit npm task, or nil."
  (or (cl-find-if (lambda (task)
                    (and (vscode-launch--plistp task)
                         (equal (or (plist-get task :label) (plist-get task :taskName)) label)))
                  (plist-get data :tasks))
      (when (string-match "\\`npm: \\([^ ]+\\)\\(?: - \\(.+\\)\\)?\\'" label)
        (list :label label :type "npm" :script (match-string 1 label)
              :path (match-string 2 label)))))

(defun vscode-launch--depends-on (task)
  "Return the labels in TASK's `dependsOn'."
  (let ((d (plist-get task :dependsOn)))
    (mapcar (lambda (x) (if (stringp x) x (plist-get x :task)))
            (cond ((stringp d) (list d))
                  ((vectorp d) (append d nil))
                  ((vscode-launch--plistp d) (list d))))))

(defun vscode-launch--task-ready-regexp (matcher)
  "Return the regexp that marks a background task as ready, from MATCHER, or nil."
  (let ((m (if (vectorp matcher) (and (> (length matcher) 0) (aref matcher 0)) matcher)))
    (cond ((equal m "$tsc-watch") "Watching for file changes")
          ((vscode-launch--plistp m)
           (let ((end (plist-get (plist-get m :background) :endsPattern)))
             (cond ((stringp end) end)
                   ((stringp (plist-get m :base))
                    (vscode-launch--task-ready-regexp (plist-get m :base)))))))))

(defun vscode-launch--task-arg (a)
  "Return the task argument A (a string or a {value} object) as a string."
  (if (stringp a) a (format "%s" (plist-get a :value))))

(defun vscode-launch--task-exec (task root)
  "Return the EXEC plist of the resolved TASK, or nil when it only has dependencies."
  (let* ((type (plist-get task :type))
         (opts (plist-get task :options))
         (label (plist-get task :label))
         (cwd (expand-file-name (or (plist-get opts :cwd) ".") root))
         (args (mapcar #'vscode-launch--task-arg (append (plist-get task :args) nil)))
         (background (eq (plist-get task :isBackground) t))
         (command
          (cond
           ((equal type "npm")
            (setq cwd (expand-file-name (or (plist-get task :path) ".") root))
            (vscode-launch--shell-join
             (list "npm" "run" (or (plist-get task :script)
                                   (user-error "npm task `%s' has no `script'" label)))))
           ((not (stringp (plist-get task :command))) nil)
           ((equal type "process")
            (vscode-launch--shell-join (cons (plist-get task :command) args)))
           (t (concat (plist-get task :command)
                      (mapconcat (lambda (a) (concat " " (vscode-launch--shell-join (list a))))
                                 args ""))))))
    (when command
      (let* ((shell (plist-get opts :shell))
             (exe (and (vscode-launch--plistp shell) (plist-get shell :executable)))
             (switch (and exe (car (append (plist-get shell :args) nil))))
             (ready (and background
                         (vscode-launch--task-ready-regexp (plist-get task :problemMatcher)))))
        (when (and background (not ready))
          (display-warning 'vscode-launch
                           (format "Cannot tell when background task `%s' is ready (no known \
`endsPattern'); continuing right after starting it" label)))
        (list :label label :command command :cwd cwd :env (vscode-launch--env opts root)
              :shell (and exe (cons exe (or switch "-c")))
              :background background :ready ready)))))

(defun vscode-launch--task-plan (label root ctx &optional stack)
  "Return the task plan for the task LABEL under ROOT.  STACK guards cycles."
  (when (member label stack)
    (user-error "Task `%s' depends on itself" label))
  (let* ((data (vscode-launch--tasks-data root ctx))
         (task (or (vscode-launch--find-task label data)
                   (user-error "Task `%s' not found in %s" label
                               (expand-file-name ".vscode/tasks.json" root))))
         (task (vscode-launch-resolve (if (plist-member task :label)
                                          task
                                        (plist-put (copy-sequence task) :label label))
                                      ctx)))
    (list :label label
          :order (if (equal (plist-get task :dependsOrder) "sequence") 'sequence 'parallel)
          :deps (mapcar (lambda (dep) (vscode-launch--task-plan dep root ctx (cons label stack)))
                        (vscode-launch--depends-on task))
          :exec (vscode-launch--task-exec task root))))

(defun vscode-launch--task-buffer-name (label)
  "Return the name of the buffer that runs the task LABEL."
  (format "*vscode-task: %s*" label))

(defun vscode-launch--exec-task (exec done)
  "Run EXEC, then call DONE with no arguments, unless it fails.
A background task is done once it is ready; one still running is reused."
  (let* ((label (plist-get exec :label))
         (bufname (vscode-launch--task-buffer-name label))
         (old (get-buffer-process bufname)))
    (cond
     ((and (plist-get exec :background) old (process-live-p old))
      (message "vscode-launch: task `%s' is already running" label)
      (funcall done))
     (t
      (unless (file-directory-p (plist-get exec :cwd))
        (user-error "Task `%s': working directory %s does not exist" label (plist-get exec :cwd)))
      (message "vscode-launch: running task `%s'..." label)
      (let* ((default-directory (file-name-as-directory (plist-get exec :cwd)))
             (shell (plist-get exec :shell))
             (shell-file-name (if shell (car shell) shell-file-name))
             (shell-command-switch (if shell (cdr shell) shell-command-switch))
             (compilation-ask-about-save nil)
             (compilation-scroll-output t)
             (compilation-environment
              (append (mapcar (lambda (kv) (if (cdr kv) (format "%s=%s" (car kv) (cdr kv)) (car kv)))
                              (plist-get exec :env))
                      compilation-environment))
             (display-buffer-overriding-action '(display-buffer-no-window (allow-no-window . t)))
             (buf (compilation-start (plist-get exec :command) nil (lambda (_mode) bufname)))
             (proc (get-buffer-process buf))
             (ready (plist-get exec :ready))
             (finished nil)
             (recent ""))
        (cl-flet ((finish (ok)
                    (unless finished
                      (setq finished t)
                      (if ok
                          (funcall done)
                        (message "vscode-launch: task `%s' failed, launch cancelled" label)
                        (display-buffer buf)))))
          (add-function :after (process-sentinel proc)
                        (lambda (p _event)
                          (when (memq (process-status p) '(exit signal))
                            (finish (and (eq (process-status p) 'exit)
                                         (zerop (process-exit-status p)))))))
          (when (plist-get exec :background)
            (if (not ready)
                (finish t)
              (add-function :after (process-filter proc)
                            (lambda (_p output)
                              (setq recent (concat recent (replace-regexp-in-string
                                                           "\e\\[[0-9;]*[A-Za-z]" "" output)))
                              (setq recent (substring recent (max 0 (- (length recent) 4000))))
                              (when (string-match-p ready recent)
                                (finish t))))))))))))

(defun vscode-launch--run-task-plan (plan done)
  "Run the task PLAN: its dependencies, then its own command; then call DONE."
  (let ((deps (plist-get plan :deps))
        (exec (plist-get plan :exec)))
    (let ((then (lambda ()
                  (if exec (vscode-launch--exec-task exec done) (funcall done)))))
      (if (eq (plist-get plan :order) 'sequence)
          (vscode-launch--run-tasks-in-sequence deps then)
        (vscode-launch--run-tasks-in-parallel deps then)))))

(defun vscode-launch--run-tasks-in-sequence (plans then)
  "Run the task PLANS one after the other, then call THEN."
  (if (null plans)
      (funcall then)
    (vscode-launch--run-task-plan
     (car plans) (lambda () (vscode-launch--run-tasks-in-sequence (cdr plans) then)))))

(defun vscode-launch--run-tasks-in-parallel (plans then)
  "Start all the task PLANS at once, call THEN when all are done."
  (if (null plans)
      (funcall then)
    (let ((left (length plans)))
      (dolist (p plans)
        (vscode-launch--run-task-plan
         p (lambda () (when (zerop (cl-decf left)) (funcall then))))))))


;;; ----------------------------------------------------------------------
;;; Execution
;;; ----------------------------------------------------------------------

(defun vscode-launch--run-command (name plan)
  "Run PLAN's command in a comint `compile' buffer named for NAME."
  (let* ((cwd (plist-get plan :cwd))
         (default-directory (file-name-as-directory cwd))
         (compilation-ask-about-save nil)
         (compilation-environment
          (append (mapcar (lambda (kv) (if (cdr kv) (format "%s=%s" (car kv) (cdr kv)) (car kv)))
                          (plist-get plan :env))
                  compilation-environment))
         (compilation-buffer-name-function
          (lambda (_mode) (format "*vscode-launch: %s*" name))))
    (unless (file-directory-p cwd)
      (user-error "Working directory %s does not exist" cwd))
    (let ((buf (compile (plist-get plan :command) t)))
      (when (plist-get plan :attach)
        (vscode-launch--attach-when-listening buf cwd (plist-get plan :attach)))
      buf)))

(defun vscode-launch--attach-when-listening (buf cwd attach)
  "Start the dape ATTACH session once the process of BUF announces its inspector.
ATTACH is (:key KEY :options PLIST).  Only the first announcement counts: node
restarts (nodemon) are followed by the session's `restart' option."
  (when-let* ((proc (get-buffer-process buf)))
    (let ((recent "") (attached nil))
      (add-function
       :after (process-filter proc)
       (lambda (_p output)
         (unless attached
           (setq recent (concat recent (replace-regexp-in-string "\e\\[[0-9;]*[A-Za-z]" "" output)))
           (setq recent (substring recent (max 0 (- (length recent) 4000))))
           (when (string-match "Debugger listening on ws://\\(\\[?[^]/ ]+\\]?\\):\\([0-9]+\\)/"
                               recent)
             (let ((host (match-string 1 recent))
                   (port (string-to-number (match-string 2 recent))))
               (setq attached t)
               (run-at-time
                0 nil
                (lambda ()
                  (condition-case err
                      (vscode-launch--run-dape
                       (list :key (plist-get attach :key) :cwd cwd
                             :options (append (list :address host :port port)
                                              (plist-get attach :options))))
                    (error (message "vscode-launch: cannot attach the debugger: %s"
                                    (error-message-string err))))))))))))))

(defun vscode-launch--run-dape (plan)
  "Start a dape session from PLAN."
  (unless (and (vscode-launch--dape-loaded-p) (fboundp 'dape--config-eval))
    (user-error "dape is not available"))
  (let ((default-directory (file-name-as-directory (plist-get plan :cwd))))
    (dape (dape--config-eval (plist-get plan :key) (plist-get plan :options)))))

(defun vscode-launch--run-plan (name plan)
  "Execute PLAN for the configuration called NAME."
  (pcase (car plan)
    (:run (vscode-launch--run-command name (cdr plan)))
    (:dape (vscode-launch--run-dape (cdr plan)))
    (_ (user-error "%s: %s" name (plist-get (cdr plan) :reason)))))

(defun vscode-launch--warn-unsupported (obj kind name)
  "Warn about ignored client features in OBJ, the KIND (string) called NAME."
  (dolist (key '(:postDebugTask))
    (when (stringp (plist-get obj key))
      (display-warning 'vscode-launch
                       (format "%s `%s' of %s `%s' is not supported; run it yourself"
                               (substring (symbol-name key) 1) (plist-get obj key) kind name))))
  (when (eq (plist-get obj :stopAll) t)
    (display-warning 'vscode-launch
                     (format "stopAll of %s `%s' is not supported" kind name))))

(defun vscode-launch--member-plans (member folder compound data root ctx force-run seen)
  "Return the plans for MEMBER of COMPOUND.
A member with a workspace FOLDER is looked up in that folder's launch.json."
  (if (null folder)
      (progn
        (unless (or (assoc member (vscode-launch-configurations data))
                    (assoc member (vscode-launch--compounds data)))
          (user-error "Compound `%s' references unknown configuration `%s'" compound member))
        (vscode-launch--plans member data root ctx force-run seen))
    (let* ((dir (or (alist-get folder vscode-launch-workspace-folders nil nil #'equal)
                    (user-error "Compound `%s' uses unknown workspace folder `%s'; see `vscode-launch-workspace-folders'"
                                compound folder)))
           (root2 (directory-file-name (expand-file-name dir)))
           (data2 (vscode-launch--read root2)))
      (vscode-launch--member-plans member nil compound data2 root2
                                   (vscode-launch-make-context root2 data2)
                                   force-run seen))))

(defun vscode-launch--pre-plans (obj root ctx)
  "Return the (NAME . (:pre :task PLAN)) step for OBJ's `preLaunchTask', as a list."
  (let ((label (plist-get obj :preLaunchTask)))
    (when (stringp label)
      (list (cons label (list :pre :task (vscode-launch--task-plan label root ctx)))))))

(defun vscode-launch--plans (name data root ctx force-run &optional seen)
  "Return a list of (NAME . PLAN) for the config or compound NAME of DATA.
Everything is resolved and planned before anything starts, so a compound
with a bad member fails without starting the earlier ones.  SEEN guards
against compounds that contain themselves."
  (let ((configs (vscode-launch-configurations data))
        (compounds (vscode-launch--compounds data))
        (id (cons root name)))
    (cond
     ((assoc name configs)
      (let* ((cfg (vscode-launch-resolve (cdr (assoc name configs)) ctx))
             (plan (vscode-launch--plan cfg root force-run)))
        (vscode-launch--warn-unsupported cfg "configuration" name)
        (when (eq (car plan) :unsupported)
          (user-error "%s: %s" name (plist-get (cdr plan) :reason)))
        (when (and vscode-launch--require-dape (not (eq (car plan) :dape)))
          (user-error "%s cannot be started under dape: it runs as a plain command" name))
        (append (vscode-launch--pre-plans cfg root ctx)
                (list (cons name plan)))))
     ((assoc name compounds)
      (when (member id seen)
        (user-error "Compound `%s' contains itself" name))
      (let ((compound (cdr (assoc name compounds))))
        (vscode-launch--warn-unsupported compound "compound" name)
        (append (vscode-launch--pre-plans compound root ctx)
                (cl-loop for (member . folder) in (vscode-launch--compound-members compound)
                         append (vscode-launch--member-plans
                                 member folder name data root ctx force-run (cons id seen))))))
     (t (user-error "No configuration named `%s'" name)))))

(defun vscode-launch--run-name (name data root ctx force-run)
  "Run the configuration or compound NAME from DATA."
  (let ((plans (vscode-launch--plans name data root ctx force-run)))
    (when (> (cl-count :dape plans :key (lambda (p) (car (cdr p)))) 1)
      (user-error "`%s' would start several debug sessions; dape supports one at a time" name))
    (when (cl-some (lambda (p) (eq (plist-get (cdr (cdr p)) :ensure) 'debugpy)) plans)
      (vscode-launch--ensure-debugpy))
    (when (cl-some (lambda (p)
                     (let ((plan (cdr p)))
                       (or (and (eq (car plan) :dape)
                                (string-prefix-p "js-debug" (symbol-name (plist-get (cdr plan) :key))))
                           (and (eq (car plan) :run) (plist-get (cdr plan) :attach)))))
                   plans)
      (vscode-launch--ensure-js-debug))
    (vscode-launch--run-steps plans)))

(defun vscode-launch--run-steps (steps)
  "Run STEPS, a list of (NAME . PLAN), in order.
A `:pre' step is a task that has to finish before the rest continues, which
can happen later, from a process sentinel or filter."
  (when steps
    (let ((name (car (car steps)))
          (plan (cdr (car steps)))
          (rest (cdr steps)))
      (if (eq (car plan) :pre)
          (vscode-launch--run-task-plan
           (plist-get (cdr plan) :task)
           (lambda ()
             (condition-case err
                 (vscode-launch--run-steps rest)
               (error (message "vscode-launch: %s" (error-message-string err))))))
        (vscode-launch--run-plan name plan)
        (vscode-launch--run-steps rest)))))


;;; ----------------------------------------------------------------------
;;; Commands
;;; ----------------------------------------------------------------------

(defun vscode-launch--candidates (data)
  "Return (NAME . ANNOTATION) pairs for the configs and compounds of DATA."
  (append
   (mapcar (lambda (c)
             (cons (car c) (format "%s %s" (or (plist-get (cdr c) :type) "?")
                                   (or (plist-get (cdr c) :request) "?"))))
           (cl-remove-if (lambda (c) (vscode-launch--hidden-p (cdr c)))
                         (vscode-launch-configurations data)))
   (mapcar (lambda (c)
             (cons (car c) (format "compound: %s"
                                   (mapconcat #'car (vscode-launch--compound-members (cdr c))
                                              ", "))))
           (cl-remove-if (lambda (c) (vscode-launch--hidden-p (cdr c)))
                         (vscode-launch--compounds data)))))

(defun vscode-launch--read-name (data root)
  "Prompt for a configuration name from DATA, defaulting to the last run in ROOT."
  (let* ((cands (vscode-launch--candidates data))
         (width (apply #'max 0 (mapcar (lambda (c) (length (car c))) cands)))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (n) (when-let* ((a (cdr (assoc n cands))))
                           (concat (make-string (- (1+ width) (length n)) ?\s) a))))))
    (unless cands (user-error "launch.json has no configurations"))
    (completing-read "Launch: " (mapcar #'car cands) nil t nil nil
                     (gethash root vscode-launch--last))))

(defun vscode-launch-select (data &optional root)
  "Prompt for a configuration or compound of the launch.json DATA; return its name.
ROOT defaults to the current workspace root."
  (vscode-launch--read-name data (or root (vscode-launch--root))))

;;;###autoload
(defun vscode-launch (&optional force-run)
  "Pick a configuration from the project's launch.json and run it.
With prefix argument FORCE-RUN, run it as a plain command instead of
starting a debugger."
  (interactive "P")
  (let* ((root (vscode-launch--root))
         (data (vscode-launch--read root))
         (name (vscode-launch--read-name data root)))
    (puthash root name vscode-launch--last)
    (vscode-launch--run-name name data root (vscode-launch--context root data) force-run)))

;;;###autoload
(defun vscode-launch-dape ()
  "Pick a configuration from launch.json and start it under dape.
Unlike `vscode-launch', a configuration that is a plain command is an error."
  (interactive)
  (let ((vscode-launch-prefer-debugger t)
        (vscode-launch--require-dape t))
    (vscode-launch nil)))

;;;###autoload
(defun vscode-launch-rerun (&optional force-run)
  "Run the last configuration used in this project again.
FORCE-RUN as in `vscode-launch'."
  (interactive "P")
  (let* ((root (vscode-launch--root))
         (name (gethash root vscode-launch--last)))
    (if (not name)
        (vscode-launch force-run)
      (let ((data (vscode-launch--read root)))
        (vscode-launch--run-name name data root (vscode-launch--context root data)
                                 force-run)))))

;;;###autoload
(defun vscode-launch-open-file ()
  "Visit the project's launch.json."
  (interactive)
  (find-file (vscode-launch--file (vscode-launch--root))))

(provide 'vscode-launch)
;;; vscode-launch.el ends here
