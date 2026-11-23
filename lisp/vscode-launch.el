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
;; which dape cannot express.  Output keeps bounded scrollback and
;; abbreviates long lines; see `vscode-launch-output-max-line-length',
;; `vscode-launch-output-max-size' and `comint-buffer-maximum-size'.
;; Display updates are batched; during a flood only the newest pending
;; output is displayed, with a notice for discarded output.
;; Compiler error parsing runs on demand via `next-error', not on redisplay.
;; The same output bounds apply to Dape shell and REPL buffers, including
;; Dape's native REPL writer which bypasses comint preoutput hooks.
;; Like VS Code's `node-terminal', such a
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
(require 'comint)
(require 'ansi-color)
(require 'url-handlers)

(defvar dape-configs)
(defvar dape-adapter-dir)
(defvar dape-repl-echo-shell-output)
(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape--config-eval "dape" (key options &optional skip-functions))
(declare-function dape--repl-insert "dape" (string))


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

(defcustom vscode-launch-host-dape-adapters nil
  "Per-host overrides of `vscode-launch-dape-adapters'.
An alist (HOST-REGEXP . ALIST), where ALIST maps a launch.json `type' to a
key of `dape-configs' like `vscode-launch-dape-adapters' does.  HOST-REGEXP
is matched against the host of a remote workspace (for /rdev:HOST: or a
TRAMP name); the first matching entry that lists the type wins.  Local
workspaces use only `vscode-launch-dape-adapters'."
  :type '(alist :key-type regexp
                :value-type (alist :key-type string :value-type symbol)))

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

(defcustom vscode-launch-output-max-line-length 2048
  "Maximum characters of each output line displayed inline.
The rest of a longer line is folded: it is kept out of the buffer text,
as a text property on a one-character placeholder, so redisplay and comint
never scan it.  Press \\<vscode-launch-fold-map>\\[vscode-launch-expand-fold] on the placeholder to
expand it.  This also bounds lines that never end with a newline."
  :type 'natnum)

(defcustom vscode-launch-output-max-size (* 1024 1024)
  "Maximum characters of command output retained in a launch buffer.
Older output is discarded.  `comint-buffer-maximum-size' additionally
limits scrollback by line count.  Pending user input is preserved."
  :type 'natnum)

(defcustom vscode-launch-output-update-interval 0.2
  "Seconds between command output display updates.
Process output is drained into a bounded queue between updates, without
running comint or redisplay hooks for every process read.  The default
refreshes at most five times per second, including when the buffer is visible."
  :type 'number)

(defcustom vscode-launch-output-max-pending-size (* 2 1024 1024)
  "Maximum characters awaiting display in a command's output queue.
During a log flood, older pending output is discarded and a notice is
displayed.  This bounds the work done by each display update, independently
of the scrollback limit `vscode-launch-output-max-size'."
  :type 'natnum)

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

;;; Remote workspaces
;; A root such as /rdev:HOST:/home/me/proj (or a TRAMP name) is handled by
;; keeping every name Emacs itself touches (default-directory, files it
;; reads, plan :cwd) a full file name, while everything handed to a
;; process or debug adapter, which runs on the remote host, is a local name
;; from `file-local-name'.

(defun vscode-launch--expand (name root)
  "Expand NAME against ROOT like `expand-file-name', staying on ROOT's host.
An absolute NAME on ROOT's host (as ${workspaceFolder} produces for a
remote root) keeps ROOT's remote prefix."
  (let ((prefix (file-remote-p root)))
    (if (and prefix (file-name-absolute-p name) (not (file-remote-p name)))
        (expand-file-name (concat prefix name))
      (expand-file-name name root))))

(defun vscode-launch--local (name ctx)
  "Return NAME without a remote prefix if it is on the host of CTX's root."
  (if (equal (file-remote-p name) (file-remote-p (plist-get ctx :root)))
      (file-local-name name)
    name))

(defun vscode-launch--find-exe (command root)
  "Return the local name of COMMAND found on the host of ROOT, or nil."
  (let ((default-directory (file-name-as-directory root)))
    (executable-find command (and (file-remote-p root) t))))

(defun vscode-launch--exe-available-p (exe root)
  "Non-nil if the program EXE (a local name on ROOT's host) can be run."
  (if (file-name-absolute-p exe)
      (file-executable-p (concat (file-remote-p root) exe))
    (and (vscode-launch--find-exe exe root) t)))

(defun vscode-launch--remote-getenv (var root)
  "Return VAR from the environment of ROOT's host, or nil if unset."
  (if (not (file-remote-p root))
      (getenv var)
    (let ((default-directory (file-name-as-directory root)))
      (with-temp-buffer
        (when (zerop (process-file "printenv" nil t nil var))
          (string-remove-suffix "\n" (buffer-string)))))))

(defun vscode-launch--refresh-remote (root)
  "Forget cached file metadata of ROOT's host.
Programs we start there create files behind the file-name handler's back,
and a cached \"does not exist\" would otherwise outlive them."
  (when (and (file-remote-p root) (fboundp 'rdev-clear-cache))
    (when-let* ((host (file-remote-p root 'host)))
      (ignore-errors (rdev-clear-cache host)))))

(defun vscode-launch--cache-dir (root)
  "Return the directory for adapters installed on ROOT's host (a file name).
On a remote host that already has `dape-adapter-dir' (same path as here, for
instance from running dape there), reuse it; else use ~/.cache/vscode-launch."
  (let ((prefix (file-remote-p root))
        (dape-dir (and (boundp 'dape-adapter-dir) (expand-file-name dape-adapter-dir))))
    (cond ((not prefix) dape-dir)
          ((and dape-dir (file-directory-p (concat prefix dape-dir)))
           (concat prefix dape-dir))
          (t (expand-file-name (concat prefix "~/.cache/vscode-launch"))))))

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
  "Return a Python interpreter for the workspace ROOT, as a name on its host."
  (or (let ((venv (expand-file-name ".venv/bin/python" root)))
        (and (file-executable-p venv) (file-local-name venv)))
      (let ((v (and (not (file-remote-p root)) (getenv "VIRTUAL_ENV"))))
        (and v (file-executable-p (expand-file-name "bin/python" v))
             (expand-file-name "bin/python" v)))
      (vscode-launch--find-exe "python3" root)
      (vscode-launch--find-exe "python" root)
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
      ((or "workspaceFolder" "workspaceRoot" "cwd") (file-local-name root))
      ((rx bos "workspaceFolder:" (let folder (+ anything)) eos)
       (or (alist-get folder vscode-launch-workspace-folders nil nil #'equal)
           (user-error "Unknown workspace folder `%s'; see `vscode-launch-workspace-folders'"
                       folder)))
      ("workspaceFolderBasename" (file-name-nondirectory root))
      ("userHome" (if (file-remote-p root)
                      (file-local-name (expand-file-name (concat (file-remote-p root) "~")))
                    (expand-file-name "~")))
      ("pathSeparator" "/")
      ("file" (vscode-launch--local (vscode-launch--need-file name file) ctx))
      ("fileBasename" (file-name-nondirectory (vscode-launch--need-file name file)))
      ("fileBasenameNoExtension"
       (file-name-sans-extension (file-name-nondirectory (vscode-launch--need-file name file))))
      ("fileDirname"
       (vscode-launch--local
        (directory-file-name (file-name-directory (vscode-launch--need-file name file))) ctx))
      ("fileExtname"
       (let ((ext (file-name-extension (vscode-launch--need-file name file))))
         (if (and ext (not (string-empty-p ext))) (concat "." ext) "")))
      ("fileWorkspaceFolder" (vscode-launch--need-file name file) (file-local-name root))
      ("relativeFile" (file-relative-name (vscode-launch--need-file name file) root))
      ("relativeFileDirname"
       (directory-file-name
        (file-relative-name (file-name-directory (vscode-launch--need-file name file)) root)))
      ("lineNumber" (number-to-string (or (plist-get ctx :line) 1)))
      ("selectedText" (or (plist-get ctx :selected-text)
                          (user-error "Cannot resolve ${selectedText}: no active region")))
      ((rx bos "env:" (let var (+ anything)) eos)
       (or (vscode-launch--remote-getenv var root)
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
                       (vscode-launch--expand envfile (or root default-directory)))))
         (from-env (cl-loop for (k v) on (plist-get cfg :env) by #'cddr
                            collect (cons (substring (symbol-name k) 1)
                                          (vscode-launch--scalar-string v)))))
    (append from-env
            (cl-remove-if (lambda (kv) (assoc (car kv) from-env)) from-file))))

(defun vscode-launch--env-plist (env)
  "Convert the alist ENV to a plist with keyword keys, as dape expects."
  (cl-loop for (k . v) in env append (list (intern (concat ":" k)) (or v :null))))

(defun vscode-launch--exe (exe &optional root)
  "Return a usable form of EXE, for the host of ROOT (default: this one).
Absolute paths that no longer exist (stale fnm/nvm shims) fall back to
the bare command name, resolved through PATH."
  (let ((root (or root default-directory)))
    (if (and (file-name-absolute-p exe)
             (not (file-executable-p (concat (file-remote-p root) exe))))
        (let ((base (file-name-nondirectory exe)))
          (or (vscode-launch--find-exe base root) base))
      exe)))

(defun vscode-launch--fix-command-exe (command &optional root)
  "Apply `vscode-launch--exe' to the first word of the shell string COMMAND."
  (if (string-match "\\`\\(/[^ \t]+\\)\\(.*\\)\\'" command)
      (concat (vscode-launch--exe (match-string 1 command) root) (match-string 2 command))
    command))

(defun vscode-launch--cwd (cfg root)
  "Return the working directory of CFG relative to ROOT."
  (vscode-launch--expand (or (plist-get cfg :cwd) ".") root))

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

(defun vscode-launch--explicit-dape-key (type root)
  "Return the configured `dape-configs' key for TYPE on the host of ROOT, or nil.
`vscode-launch-host-dape-adapters' for a remote ROOT is consulted before
`vscode-launch-dape-adapters'."
  (or (when-let* ((host (and root (file-remote-p root 'host))))
        (cl-loop for (regexp . alist) in vscode-launch-host-dape-adapters
                 when (and (string-match-p regexp host)
                           (alist-get type alist nil nil #'equal))
                 return (alist-get type alist nil nil #'equal)))
      (alist-get type vscode-launch-dape-adapters nil nil #'equal)))

(defun vscode-launch--find-dape-key (type &optional default root)
  "Return the `dape-configs' key to use for the launch.json TYPE, or nil.
Order: `vscode-launch-host-dape-adapters' for the host of ROOT,
`vscode-launch-dape-adapters', DEFAULT, a unique `:type' match in
`dape-configs', else ask the user among several matches."
  (when (vscode-launch--dape-loaded-p)
    (let ((explicit (vscode-launch--explicit-dape-key type root)))
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

(defun vscode-launch-register-adapter (type dape-key &optional host-regexp)
  "Use the `dape-configs' entry DAPE-KEY for launch.json configurations of TYPE.
With HOST-REGEXP, only for remote workspaces whose host matches it, see
`vscode-launch-host-dape-adapters'."
  (if host-regexp
      (let ((entry (assoc host-regexp vscode-launch-host-dape-adapters)))
        (unless entry
          (setq entry (list host-regexp))
          (push entry vscode-launch-host-dape-adapters))
        (setf (alist-get type (cdr entry) nil nil #'equal) dape-key))
    (setf (alist-get type vscode-launch-dape-adapters nil nil #'equal) dape-key)))

(defun vscode-launch--js-debug-dir (&optional root)
  "Return the directory js-debug is (to be) installed in, or nil without dape.
For a remote ROOT this is on that host, and a full file name."
  (when-let* ((cache (vscode-launch--cache-dir (or root default-directory))))
    (expand-file-name "js-debug" cache)))

(defun vscode-launch--js-debug-installed-p (&optional root)
  "Non-nil if the js-debug adapter used by dape is installed for ROOT's host."
  (and (vscode-launch--dape-entry-p 'js-debug-node)
       (vscode-launch--js-debug-dir root)
       (file-exists-p (expand-file-name "src/dapDebugServer.js"
                                        (vscode-launch--js-debug-dir root)))))

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
(defun vscode-launch-install-js-debug (&optional version root)
  "Download and install the js-debug DAP server (VERSION, default
`vscode-launch-js-debug-version') for the host of ROOT (default: the
current workspace): into `dape-adapter-dir', or for a remote workspace
into ~/.cache/vscode-launch there.  The archive is downloaded by Emacs and
copied over, so the remote host needs no internet access, only `tar'.
Replaces an existing installation."
  (interactive)
  (unless (vscode-launch--dape-loaded-p)
    (user-error "dape is not available"))
  (let* ((root (or root (vscode-launch--root)))
         (remote (file-remote-p root))
         (default-directory (file-name-as-directory root))
         (version (or version (vscode-launch--js-debug-version)))
         (url (format "https://github.com/microsoft/vscode-js-debug/releases/download/%s/js-debug-dap-%s.tar.gz"
                      version version))
         (archive (make-temp-file "js-debug-dap" nil ".tar.gz"))
         (cache (file-name-as-directory (vscode-launch--cache-dir root)))
         (dest (vscode-launch--js-debug-dir root))
         (stage (and (not remote) (make-temp-file "js-debug-stage" t)))
         (remote-archive (and remote (expand-file-name ".js-debug-dap.tar.gz" cache))))
    (unless (vscode-launch--find-exe "tar" root)
      (user-error "Installing js-debug needs the `tar' program%s"
                  (if remote " on the remote host" "")))
    (unwind-protect
        (progn
          (message "vscode-launch: downloading js-debug %s..." version)
          (condition-case err
              (url-copy-file url archive t)
            (error (user-error "Cannot download %s: %s" url (error-message-string err))))
          (make-directory cache t)
          (let ((extract-to (if remote cache stage))
                (from (if remote
                          (progn (copy-file archive remote-archive t)
                                 (file-local-name remote-archive))
                        archive)))
            (when remote
              (when (file-exists-p dest) (delete-directory dest t)))
            (unless (zerop (call-process "tar" nil nil nil "-xzf" from "-C"
                                         (file-local-name extract-to)))
              (vscode-launch--refresh-remote root)
              (user-error "Cannot extract %s; is the version %s right?" url version))
            (vscode-launch--refresh-remote root)
            (unless (file-exists-p (expand-file-name "js-debug/src/dapDebugServer.js" extract-to))
              (user-error "Unexpected js-debug archive layout in %s" url))
            (unless remote
              (when (file-exists-p dest) (delete-directory dest t))
              (rename-file (expand-file-name "js-debug" stage) dest)))
          (message "vscode-launch: installed js-debug %s in %s" version dest))
      (ignore-errors (delete-file archive))
      (when remote-archive (ignore-errors (delete-file remote-archive)))
      (when stage (ignore-errors (delete-directory stage t))))
    dest))

(defun vscode-launch--js-debug-available-p (&optional root)
  "Non-nil if js-debug is installed for ROOT's host, or may be installed on demand."
  (and (vscode-launch--dape-entry-p 'js-debug-node)
       (or (vscode-launch--js-debug-installed-p root)
           (and vscode-launch-install-js-debug (vscode-launch--js-debug-dir root) t))))

(defun vscode-launch--ensure-js-debug (&optional root)
  "Install js-debug for ROOT's host if missing, as `vscode-launch-install-js-debug' allows."
  (unless (vscode-launch--js-debug-installed-p root)
    (if (or (eq vscode-launch-install-js-debug t)
            (and (eq vscode-launch-install-js-debug 'ask)
                 (y-or-n-p (format "js-debug is not installed%s; download it from GitHub? "
                                   (if (file-remote-p (or root default-directory))
                                       " on the remote host" "")))))
        (vscode-launch-install-js-debug nil root)
      (user-error "js-debug is not installed; run `vscode-launch-install-js-debug'"))))

(defun vscode-launch--debugpy-venv (&optional root)
  "Return the directory of the dedicated debugpy virtual environment for ROOT's host."
  (when-let* ((cache (vscode-launch--cache-dir (or root default-directory))))
    (expand-file-name "debugpy" cache)))

(defun vscode-launch--debugpy-python (&optional root)
  "Return the interpreter (a file name) of the dedicated debugpy environment, or nil."
  (when-let* ((venv (vscode-launch--debugpy-venv root)))
    (expand-file-name "bin/python" venv)))

(defun vscode-launch--has-debugpy-p (python &optional root)
  "Non-nil if the interpreter PYTHON, a name on ROOT's host, can import the debugpy adapter."
  (let* ((root (or root default-directory))
         (default-directory (file-name-as-directory root)))
    (and python (vscode-launch--exe-available-p python root)
         (zerop (process-file python nil nil nil "-c" "import debugpy.adapter")))))

(defun vscode-launch--call (program &rest args)
  "Run PROGRAM with ARGS; signal a `user-error' with its output on failure."
  (with-temp-buffer
    (unless (zerop (apply #'process-file program nil t nil args))
      (user-error "`%s %s' failed: %s" program (string-join args " ")
                  (string-trim (buffer-string))))))

;;;###autoload
(defun vscode-launch-install-debugpy (&optional root)
  "Create a virtual environment for debugpy for the host of ROOT.
Without a remote ROOT it goes under `dape-adapter-dir', otherwise into
~/.cache/vscode-launch on the remote host (which needs `python3' or `uv'
and access to a package index).  The environment is separate from any
project's: the debug adapter runs from it and launches the project's own
interpreter (the `python' launch property), which does not need debugpy.
Running this again upgrades debugpy."
  (interactive)
  (unless (vscode-launch--dape-loaded-p)
    (user-error "dape is not available"))
  (let* ((root (or root (vscode-launch--root)))
         (default-directory (file-name-as-directory root))
         (venv (vscode-launch--debugpy-venv root))
         (python (vscode-launch--debugpy-python root))
         (uv (vscode-launch--find-exe "uv" root))
         (base (or (vscode-launch--find-exe "python3" root)
                   (vscode-launch--find-exe "python" root))))
    (unless (or uv base)
      (user-error "Need `uv' or `python3' to create the debugpy environment"))
    (make-directory (file-name-directory venv) t)
    (message "vscode-launch: installing debugpy into %s..." venv)
    (unless (file-executable-p python)
      (if uv
          (vscode-launch--call uv "venv" (file-local-name venv))
        (vscode-launch--call base "-m" "venv" (file-local-name venv))))
    (if uv
        (vscode-launch--call uv "pip" "install" "--python" (file-local-name python)
                             "--upgrade" "debugpy")
      (vscode-launch--call (file-local-name python) "-m" "pip" "install" "--upgrade" "debugpy"))
    (vscode-launch--refresh-remote root)
    (unless (vscode-launch--has-debugpy-p (file-local-name python) root)
      (user-error "debugpy was installed but cannot be imported from %s" venv))
    (message "vscode-launch: installed debugpy in %s" venv)
    python))

(defun vscode-launch--debugpy-adapter (project-python &optional root)
  "Return (PYTHON . INSTALL-P): the interpreter that runs the debugpy adapter.
Order: the dedicated environment, PROJECT-PYTHON if it has debugpy, the
dedicated environment to be created, else PROJECT-PYTHON (dape then
reports the missing module).  PYTHON is a name on the host of ROOT."
  (let ((own (and (vscode-launch--debugpy-python root)
                  (file-local-name (vscode-launch--debugpy-python root)))))
    (cond
     ((and own (vscode-launch--has-debugpy-p own root)) (cons own nil))
     ((vscode-launch--has-debugpy-p project-python root) (cons project-python nil))
     ((and own vscode-launch-install-debugpy) (cons own t))
     (t (cons project-python nil)))))

(defun vscode-launch--ensure-debugpy (&optional root)
  "Create the debugpy venv on ROOT's host if missing, when `vscode-launch-install-debugpy' allows."
  (let ((own (vscode-launch--debugpy-python root)))
    (unless (vscode-launch--has-debugpy-p (and own (file-local-name own)) root)
      (if (or (eq vscode-launch-install-debugpy t)
              (and (eq vscode-launch-install-debugpy 'ask)
                   (y-or-n-p (format "debugpy is not installed%s; create a venv for it and install it? "
                                     (if (file-remote-p (or root default-directory))
                                         " on the remote host" "")))))
          (vscode-launch-install-debugpy root)
        (user-error "debugpy is not installed; run `vscode-launch-install-debugpy'")))))

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

(defun vscode-launch--remote-dape-options (key cwd)
  "Return the dape options that run the adapter KEY on the host of CWD.
CWD is a full file name; nil unless it is remote.  The adapter and the
debuggee run there, and paths the adapter reports map back to CWD's host."
  (when (file-remote-p cwd)
    (append (list 'command-cwd (file-name-as-directory cwd)
                  'prefix-local (file-remote-p cwd)
                  'prefix-remote "")
            (when (string-prefix-p "js-debug" (symbol-name key))
              (list 'ensure 'dape-ensure-command
                    'command-args
                    (list (file-local-name
                           (expand-file-name "src/dapDebugServer.js"
                                             (vscode-launch--js-debug-dir cwd)))
                          :autoport "127.0.0.1"))))))

(defun vscode-launch--dape-plan (key cfg root &optional extra-options extra-strip)
  "Build a :dape plan for entry KEY from CFG under ROOT."
  (let ((cwd (vscode-launch--cwd cfg root))
        (env (vscode-launch--env cfg root)))
    (list :dape :key key :cwd cwd
          :options (append extra-options
                           (vscode-launch--remote-dape-options key cwd)
                           (list :cwd (file-local-name cwd))
                           (vscode-launch--forwarded cfg extra-strip)
                           (when env (list :env (vscode-launch--env-plist env)))))))

(defun vscode-launch--plan-python (cfg root force-run)
  "Plan a Python CFG relative to ROOT; FORCE-RUN skips the debugger."
  (let* ((module (plist-get cfg :module))
         (program (plist-get cfg :program))
         (python (vscode-launch--exe (or (plist-get cfg :python)
                                         (vscode-launch--python root))
                                     root))
         (key (and (not force-run) vscode-launch-prefer-debugger
                   (vscode-launch--find-dape-key
                    (plist-get cfg :type) (if module 'debugpy-module 'debugpy) root))))
    (cond
     ((not (or module program))
      (list :unsupported :reason "python config has neither `program' nor `module'"))
     (key
      (let* ((adapter (vscode-launch--debugpy-adapter python root))
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
           (vscode-launch--js-debug-available-p root)
           (vscode-launch--find-dape-key (plist-get cfg :type) 'js-debug-node root))
      (vscode-launch--dape-plan
       (vscode-launch--find-dape-key (plist-get cfg :type) 'js-debug-node root) cfg root))
     ((not (or exe program))
      (list :unsupported :reason "node config has neither `runtimeExecutable' nor `program'"))
     (t
      (list :run :cwd (vscode-launch--cwd cfg root) :env (vscode-launch--env cfg root)
            :command (vscode-launch--shell-join
                      (append (list (if exe (vscode-launch--exe exe root) "node"))
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
       (list :run :command (vscode-launch--fix-command-exe command root)
             :cwd cwd
             :env (vscode-launch--env cfg root))
       (when (and (not force-run) vscode-launch-prefer-debugger
                  (vscode-launch--js-debug-available-p root)
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
    (append (vscode-launch--remote-dape-options vscode-launch-node-attach-key cwd)
            (list :cwd (file-local-name cwd) :restart t)
            given
            (unless (plist-member given :resolveSourceMapLocations)
              (list :resolveSourceMapLocations
                    (vector (concat (file-local-name root) "/**") "!**/node_modules/**")))
            (unless (plist-member given :skipFiles)
              (list :skipFiles (vector "<node_internals>/**"))))))

(defun vscode-launch--plan-dape-generic (cfg root force-run)
  "Plan CFG of any other type through the dape entry matching its type."
  (let* ((type (plist-get cfg :type))
         (key (and (not force-run) (vscode-launch--find-dape-key type nil root))))
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
         (cwd (vscode-launch--expand (or (plist-get opts :cwd) ".") root))
         (args (mapcar #'vscode-launch--task-arg (append (plist-get task :args) nil)))
         (background (eq (plist-get task :isBackground) t))
         (command
          (cond
           ((equal type "npm")
            (setq cwd (vscode-launch--expand (or (plist-get task :path) ".") root))
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
                          (progn (vscode-launch--refresh-remote (plist-get exec :cwd))
                                 (funcall done))
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

(defvar vscode-launch--display-process nil
  "Process whose queued output is being displayed, even after it exits.")

(defvar-local vscode-launch--output-line-length 0
  "Characters retained from the current output line, including truncation.
A value greater than `vscode-launch-output-max-line-length' means the
line's truncation marker has already been emitted.")

(cl-defstruct (vscode-launch--output (:constructor vscode-launch--make-output))
  "A process's bounded display queue and original comint handlers."
  chunks tail (size 0) (dropped 0) timer filter sentinel)

(defvar vscode-launch--inserting-dape-output nil
  "Non-nil while a queued batch is inserted through Dape's native REPL writer.")

(defun vscode-launch--output-buffer-p ()
  "Return non-nil in command and Dape output buffers managed by this library."
  (and (derived-mode-p 'comint-mode)
       (or (string-prefix-p "*vscode-launch: " (buffer-name))
           (derived-mode-p 'dape-repl-mode 'dape-shell-mode))))

(defun vscode-launch--queue-output (proc output)
  "Drain OUTPUT from PROC, deferring comint work to a bounded display update."
  (when-let* ((buf (process-buffer proc))
              ((buffer-live-p buf))
              (state (process-get proc 'vscode-launch-output)))
    (let ((node (list output))
          (limit vscode-launch-output-max-pending-size))
      (if (vscode-launch--output-tail state)
          (setcdr (vscode-launch--output-tail state) node)
        (setf (vscode-launch--output-chunks state) node))
      (setf (vscode-launch--output-tail state) node)
      (cl-incf (vscode-launch--output-size state) (length output))
      ;; Evict from the head in amortized constant time.  Never concatenate
      ;; the backlog in the process filter or retain arbitrarily large chunks.
      (while (> (vscode-launch--output-size state) limit)
        (let* ((head (vscode-launch--output-chunks state))
               (text (car head))
               (drop (min (length text)
                          (- (vscode-launch--output-size state) limit))))
          (cl-incf (vscode-launch--output-dropped state) drop)
          (cl-decf (vscode-launch--output-size state) drop)
          (if (= drop (length text))
              (setf (vscode-launch--output-chunks state) (cdr head))
            (setcar head (substring text drop)))))
      (unless (vscode-launch--output-timer state)
        (setf (vscode-launch--output-timer state)
              (run-at-time vscode-launch-output-update-interval
                           nil #'vscode-launch--flush-output proc))))))

(defun vscode-launch--cancel-output-timer (proc)
  "Cancel PROC's scheduled display update without discarding queued output."
  (when-let* ((state (process-get proc 'vscode-launch-output)))
    (when (timerp (vscode-launch--output-timer state))
      (cancel-timer (vscode-launch--output-timer state)))
    (setf (vscode-launch--output-timer state) nil)))

(defun vscode-launch--discard-output (proc)
  "Cancel PROC's pending display work when its buffer is killed or reused."
  (vscode-launch--cancel-output-timer proc)
  (when-let* ((state (process-get proc 'vscode-launch-output)))
    (setf (vscode-launch--output-chunks state) nil
          (vscode-launch--output-tail state) nil
          (vscode-launch--output-size state) 0
          (vscode-launch--output-dropped state) 0)))

(defun vscode-launch--display-output (proc filter output)
  "Insert OUTPUT using FILTER without repeatedly recentering visible windows.
Windows already following PROC keep showing the tail.  Windows scrolled
back into history keep their position.  Redisplay happens after the whole
batch and window positions have been updated."
  (let* ((buf (process-buffer proc))
         (following (cl-remove-if
                     (lambda (win) (< (window-point win) (process-mark proc)))
                     (get-buffer-window-list buf nil t)))
         (inhibit-redisplay t)
         (vscode-launch--display-process proc))
    (funcall filter proc output)
    (dolist (win following)
      (when (and (window-live-p win) (eq (window-buffer win) buf))
        (save-excursion
          (goto-char (window-point win))
          ;; Lines are not wrapped in launch buffers.  Avoid `recenter',
          ;; which asks redisplay to measure and scroll through output.
          (forward-line (- 1 (max 1 (window-body-height win))))
          (set-window-start win (point) t)
          (set-window-vscroll win 0))))))

(defun vscode-launch--flush-output (proc)
  "Display at most one bounded batch of PROC's queued output."
  (when-let* ((state (process-get proc 'vscode-launch-output)))
    (vscode-launch--cancel-output-timer proc)
    (let ((chunks (vscode-launch--output-chunks state))
          (dropped (vscode-launch--output-dropped state))
          (buf (process-buffer proc)))
      (vscode-launch--discard-output proc)
      (when (and chunks (buffer-live-p buf)
                 ;; A sentinel may flush after the process has exited, but
                 ;; an old process must never write into a newer run's buffer.
                 (memq (get-buffer-process buf) (list nil proc)))
        (with-current-buffer buf
          (let ((output (apply #'concat chunks)))
            (when (> dropped 0)
              ;; A gap may have lost a newline or an ANSI reset.
              (setq vscode-launch--output-line-length 0
                    ansi-color-context nil)
              (setq output
                    (concat (format "\n[vscode-launch: skipped %d output characters]\n"
                                    dropped)
                            output)))
            (vscode-launch--display-output
             proc (vscode-launch--output-filter state) output)))))))

(defun vscode-launch--handle-output-exit (proc event)
  "Flush PROC's last output before its original sentinel handles EVENT."
  (when-let* ((state (process-get proc 'vscode-launch-output)))
    (unwind-protect
        (when (memq (process-status proc) '(exit signal closed failed))
          (vscode-launch--flush-output proc))
      (when-let* ((sentinel (vscode-launch--output-sentinel state)))
        (funcall sentinel proc event)))))

(defvar vscode-launch-fold-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'vscode-launch-expand-fold)
    (define-key map [mouse-1] #'vscode-launch-expand-fold)
    map)
  "Keymap active on a folded part of a long output line.")

(defun vscode-launch--fold-segment (piece first)
  "Return a placeholder string hiding PIECE; FIRST says to show a label."
  (propertize " "
              'display (if first
                           (propertize " … [long line folded: RET to expand]"
                                       'face 'shadow)
                         "")
              'vscode-launch-fold piece
              'keymap vscode-launch-fold-map
              'mouse-face 'highlight
              'rear-nonsticky t))

(defun vscode-launch-expand-fold (&optional pos)
  "Expand the folded long-line tail at POS (default point) in place."
  (interactive (list (if (mouse-event-p last-nonmenu-event)
                         (posn-point (event-start last-nonmenu-event))
                       (point))))
  (let ((pos (or pos (point))))
    (unless (get-text-property pos 'vscode-launch-fold)
      (if (and (> pos (point-min)) (get-text-property (1- pos) 'vscode-launch-fold))
          (setq pos (1- pos))
        (user-error "No folded text here")))
    (let ((beg pos) (end pos) pieces
          (inhibit-read-only t))
      (while (and (> beg (point-min)) (get-text-property (1- beg) 'vscode-launch-fold))
        (setq beg (1- beg)))
      (while (and (< end (point-max)) (get-text-property end 'vscode-launch-fold))
        (push (get-text-property end 'vscode-launch-fold) pieces)
        (setq end (1+ end)))
      (save-excursion
        ;; Insert before the placeholders, then delete them: markers after
        ;; the fold (process mark, Dape's prompt) stay after the text.
        (goto-char beg)
        (insert (apply #'concat (nreverse pieces)))
        (delete-region (point) (+ (point) (- end beg)))))))

(defun vscode-launch--unfold-string (string)
  "Return STRING with folded long-line placeholders replaced by their text."
  (let ((pos 0) parts)
    (while (< pos (length string))
      (let ((next (next-single-property-change pos 'vscode-launch-fold string
                                               (length string))))
        (push (or (get-text-property pos 'vscode-launch-fold string)
                  (substring string pos next))
              parts)
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun vscode-launch--filter-buffer-substring (beg end &optional delete)
  "Like `buffer-substring--filter' for BEG, END, DELETE, but expand folds."
  (vscode-launch--unfold-string (buffer-substring--filter beg end delete)))

(defun vscode-launch-save-output (file)
  "Write this launch buffer's output, folded lines in full, to FILE.
Unlike `write-file', the buffer keeps its name and does not visit FILE, so
Dape still finds it and killing FILE's buffer never ends the session."
  (interactive
   (list (read-file-name
          "Save output to file: "
          ;; Dape may set `default-directory' without a trailing slash.
          (file-name-as-directory default-directory) nil nil
          (concat (replace-regexp-in-string
                   "[^[:alnum:]._-]+" "-"
                   (string-trim (buffer-name) "[ *]+" "[ *]+"))
                  ".log"))))
  (when (or (not (file-exists-p file))
            (yes-or-no-p (format "File %s exists; overwrite? " file)))
    (save-restriction
      (widen)
      (write-region (vscode-launch--unfold-string (buffer-string)) nil file))))

(defun vscode-launch-send-input ()
  "Send input like `comint-send-input', but never resend process output.
Right after a fold, expand it.  Elsewhere in process output, do nothing:
`comint-send-input' would copy the line to the prompt and send it."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (cond ((and (> (point) (point-min))
                (get-text-property (1- (point)) 'vscode-launch-fold))
           (vscode-launch-expand-fold))
          ((and proc (< (point) (process-mark proc))
                (eq (get-char-property (field-beginning) 'field) 'output)))
          (t (comint-send-input)))))

(define-minor-mode vscode-launch-output-mode
  "Keep launch output from being resent as input or attached to a file."
  :keymap `((,[remap comint-send-input] . vscode-launch-send-input)
            (,[remap write-file] . vscode-launch-save-output)
            (,[remap save-buffer] . vscode-launch-save-output)))

(defun vscode-launch--abbreviate-output (output)
  "Fold the tail of long lines in OUTPUT before comint inserts or scans them.
Keep state across process chunks, so an unterminated line stays bounded.
The process filter still receives the original output for debugger detection."
  ;; Decode ANSI on the incoming string, so no escape is split by a fold.
  (setq output (cond ((eq ansi-color-for-comint-mode 'filter)
                     (ansi-color-filter-apply output))
                    (ansi-color-for-comint-mode (ansi-color-apply output))
                    (t output)))
  (let ((start 0)
        (limit vscode-launch-output-max-line-length)
        parts)
    (while (< start (length output))
      (let* ((newline (string-match "[\n\r]" output start))
             (end (or newline (length output)))
             (keep (min (- end start)
                        (max 0 (- limit vscode-launch--output-line-length)))))
        (when (> keep 0)
          (push (substring output start (+ start keep)) parts)
          (cl-incf vscode-launch--output-line-length keep))
        (when (> (- end start) keep)
          (push (vscode-launch--fold-segment
                 (substring output (+ start keep) end)
                 (<= vscode-launch--output-line-length limit))
                parts)
          (setq vscode-launch--output-line-length (1+ limit)))
        (when newline
          (push (substring output newline (1+ newline)) parts)
          (setq vscode-launch--output-line-length 0))
        (setq start (if newline (1+ newline) end))))
    (apply #'concat (nreverse parts))))

(defun vscode-launch--truncate-output (_output)
  "Bound command scrollback by lines and characters, preserving user input."
  (save-restriction
    (widen)
    (when-let* ((proc (or (get-buffer-process (current-buffer))
                         vscode-launch--display-process)))
      (save-excursion
        (let ((inhibit-read-only t))
          ;; Unlike `comint-truncate-buffer', this also works while the exit
          ;; sentinel flushes output from a process no longer in the buffer.
          (goto-char (process-mark proc))
          (forward-line (- comint-buffer-maximum-size))
          (beginning-of-line)
          (delete-region (point-min) (point))
          (let ((end (marker-position (process-mark proc))))
            (when (> (- end (point-min)) vscode-launch-output-max-size)
              (goto-char (- end vscode-launch-output-max-size))
              ;; Prefer deleting whole lines, but never delete pending input.
              (forward-line 1)
              (delete-region (point-min) (min (point) end)))))))))

(defun vscode-launch--setup-output (proc)
  "Prepare PROC's launch buffer for sustained and long-line output.
Also runs on `recompile', which resets the buffer's local variables."
  (when-let* ((buf (process-buffer proc)))
    (with-current-buffer buf
      (when (vscode-launch--output-buffer-p)
        (setq-local vscode-launch--output-line-length 0)
        (setq-local ansi-color-context nil)
        (setq-local truncate-lines t)
        (setq-local filter-buffer-substring-function
                    #'vscode-launch--filter-buffer-substring)
        (vscode-launch-output-mode 1)
        ;; Keep point and viewport updates cheap when the GUI shows logs.
        (setq-local scroll-margin 0)
        (setq-local scroll-conservatively 101)
        (setq-local comint-move-point-for-output nil)
        (setq-local comint-scroll-show-maximum-output nil)
        (display-line-numbers-mode -1)
        ;; Runtime logs are not compiler diagnostics.  The compiler's broad
        ;; error regexps are expensive during redisplay (e.g. large JSON).
        ;; Explicit `next-error' still parses diagnostics on demand.
        (font-lock-remove-keywords nil '((compilation--ensure-parse)))
        ;; Process output must not accumulate in undo history after truncation.
        (buffer-disable-undo)
        ;; Expand inherited hooks before removing ANSI processing: a local
        ;; `remove-hook' alone still leaves the global hook reachable via t.
        ;; ANSI is already decoded by our preoutput filter.
        (setq-local comint-output-filter-functions
                    (cl-loop for hook in comint-output-filter-functions
                             append (if (eq hook t)
                                        (remq #'ansi-color-process-output
                                              (default-value 'comint-output-filter-functions))
                                      (unless (eq hook #'ansi-color-process-output)
                                        (list hook)))))
        ;; Dape's REPL writer inserts directly and bypasses comint's
        ;; preoutput hooks.  Its prompts still go through comint, so only
        ;; abbreviate REPL log output in our native-writer wrapper below.
        (unless (derived-mode-p 'dape-repl-mode)
          (add-hook 'comint-preoutput-filter-functions
                    #'vscode-launch--abbreviate-output nil t))
        (add-hook 'comint-output-filter-functions
                  #'vscode-launch--truncate-output t t)
        (unless (process-get proc 'vscode-launch-output)
          (process-put proc 'vscode-launch-output
                       (vscode-launch--make-output
                        :filter (cond ((derived-mode-p 'dape-repl-mode)
                                       #'vscode-launch--display-dape-repl-output)
                                      ((and (derived-mode-p 'dape-shell-mode)
                                            dape-repl-echo-shell-output)
                                       #'vscode-launch--display-dape-shell-output)
                                      (t (process-filter proc)))
                        :sentinel (process-sentinel proc)))
          (set-process-filter proc #'vscode-launch--queue-output)
          (set-process-sentinel proc #'vscode-launch--handle-output-exit)
          (let ((cleanup (lambda () (vscode-launch--discard-output proc))))
            (add-hook 'kill-buffer-hook cleanup nil t)
            (add-hook 'change-major-mode-hook cleanup nil t)))))))

(add-hook 'compilation-start-hook #'vscode-launch--setup-output)

(defun vscode-launch--display-dape-repl-output (_proc output)
  "Abbreviate OUTPUT before Dape inserts it, preserving prompts and user input."
  (let ((vscode-launch--inserting-dape-output t))
    (dape--repl-insert (vscode-launch--abbreviate-output output))))

(defun vscode-launch--display-dape-shell-output (proc output)
  "Display PROC's shell OUTPUT and echo it through the bounded Dape REPL queue.
Do not use Dape's saved buffer offsets for echoing: scrollback truncation
can invalidate those offsets while comint inserts the output."
  (comint-output-filter proc output)
  (dape--repl-insert output))

(defun vscode-launch--queue-dape-repl-output (insert string)
  "Queue Dape log STRING instead of inserting it synchronously with INSERT."
  (let* ((buf (get-buffer "*dape-repl*"))
         (proc (and buf (get-buffer-process buf))))
    (if (and (not vscode-launch--inserting-dape-output)
             (stringp string) proc
             (process-get proc 'vscode-launch-output))
        (vscode-launch--queue-output proc string)
      (funcall insert string))))

(defun vscode-launch--setup-current-dape-output ()
  "Set up the current Dape buffer once its comint process exists."
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (vscode-launch--setup-output proc)))

(defun vscode-launch--setup-dape-output-buffers ()
  "Apply output controls to Dape shell and REPL buffers that lack them."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'dape-repl-mode 'dape-shell-mode)
        (when-let* ((proc (get-buffer-process buf)))
          (unless (process-get proc 'vscode-launch-output)
            (vscode-launch--setup-output proc)))))))

(defun vscode-launch--dape-terminal-request (request conn command arguments)
  "Set up the shell Dape starts for REQUEST's runInTerminal COMMAND.
CONN and ARGUMENTS are passed through unchanged.  Dape creates the shell
process after `dape-shell-mode-hook' has run, so set it up afterwards."
  (prog1 (funcall request conn command arguments)
    (when (eq command 'runInTerminal)
      (vscode-launch--setup-dape-output-buffers))))

(with-eval-after-load 'dape
  (add-hook 'dape-repl-mode-hook #'vscode-launch--setup-current-dape-output)
  (advice-add 'dape--repl-insert :around #'vscode-launch--queue-dape-repl-output)
  (advice-add 'dape-handle-request :around #'vscode-launch--dape-terminal-request)
  (advice-add 'make-network-process :around #'vscode-launch--gate-connect))

(add-hook 'kill-emacs-hook #'vscode-launch--kill-tunnel)

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
           (if (not (string-match "Debugger listening on ws://\\(\\[?[^]/ ]+\\]?\\):\\([0-9]+\\)/"
                                  recent))
               ;; Search the whole chunk before keeping a bounded suffix:
               ;; pipe reads may include the announcement followed by a log burst.
               (setq recent (substring recent (max 0 (- (length recent) 4000))))
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

;;; SSH tunnel to a remote adapter
;; rdev (and TRAMP) do not forward ports, but dape connects to the adapter's
;; DAP port on localhost.  For a remote workspace the adapter therefore
;; listens on the remote loopback and an `ssh -L' forwards it.

(defvar vscode-launch--tunnel nil
  "The `ssh -L' process of the current remote debug session, if any.")

(defvar vscode-launch--tunnel-timer nil
  "Timer that stops the tunnel once the debug session it served is over.")

(defvar vscode-launch--gate nil
  "(LOCAL-PORT CWD . REMOTE-PORT) while dape must wait for the remote adapter.")

(defun vscode-launch--kill-tunnel (&rest _)
  "Stop the SSH tunnel of the last remote debug session."
  (when (timerp vscode-launch--tunnel-timer)
    (cancel-timer vscode-launch--tunnel-timer))
  (setq vscode-launch--tunnel-timer nil vscode-launch--gate nil)
  (when (process-live-p vscode-launch--tunnel)
    (let ((buf (process-buffer vscode-launch--tunnel)))
      (delete-process vscode-launch--tunnel)
      (when (buffer-live-p buf) (kill-buffer buf))))
  (setq vscode-launch--tunnel nil))

(defun vscode-launch--watch-tunnel ()
  "Stop the tunnel once dape has had a connection and no longer has one.
Give up after a minute without any connection."
  (let ((started (float-time)) (seen nil))
    (setq vscode-launch--tunnel-timer
          (run-with-timer
           2 2
           (lambda ()
             (let ((live (and (boundp 'dape--connections) dape--connections)))
               (cond (live (setq seen t))
                     ((or seen (> (- (float-time) started) 60))
                      (vscode-launch--kill-tunnel)))))))))

(defun vscode-launch--remote-listening-p (cwd port)
  "Non-nil if a TCP socket on the host of CWD is LISTENing on PORT.
Read from /proc, so that nothing connects to the adapter."
  (let ((default-directory (file-name-as-directory cwd))
        (python (vscode-launch--find-exe "python3" cwd)))
    (and python
         (zerop (process-file
                 python nil nil nil "-c"
                 (concat "import sys,os\n"
                         "p=':%04X'%int(sys.argv[1])\n"
                         "ok=False\n"
                         "for f in ('/proc/net/tcp','/proc/net/tcp6'):\n"
                         " if os.path.exists(f):\n"
                         "  ok=ok or any(l.split()[1].endswith(p) and l.split()[3]=='0A'"
                         " for l in open(f).readlines()[1:])\n"
                         "sys.exit(0 if ok else 1)")
                 (number-to-string port))))))

(defun vscode-launch--gate-connect (orig &rest args)
  "Around advice for `make-network-process': hold dape's connection to the tunnel.
An `ssh -L' accepts connections before the adapter listens and then drops
them, so wait until the remote port is LISTENING (at most 30s)."
  (let ((gate vscode-launch--gate))
    (when (and gate (eql (plist-get args :service) (car gate)))
      (setq vscode-launch--gate nil)
      (let ((deadline (+ (float-time) 30)))
        (while (and (< (float-time) deadline)
                    (process-live-p vscode-launch--tunnel)
                    (not (vscode-launch--remote-listening-p (cadr gate) (cddr gate))))
          (sleep-for 0.3)))))
  (apply orig args))

(defun vscode-launch--port-listening-p (port)
  "Non-nil if something on 127.0.0.1 already listens on PORT.
Probed by trying to listen on it ourselves, so that no stray connection
reaches the adapter."
  (let ((probe (ignore-errors
                 (make-network-process :name "vscode-launch-port-probe" :server t
                                       :host "127.0.0.1" :service port :noquery t))))
    (if probe (progn (delete-process probe) nil) t)))

(defun vscode-launch--remote-free-port (cwd)
  "Return a port that is free on the host of CWD, or nil if it cannot be asked."
  (let ((default-directory (file-name-as-directory cwd))
        (python (vscode-launch--find-exe "python3" cwd)))
    (when python
      (with-temp-buffer
        (when (zerop (process-file
                      python nil t nil "-c"
                      "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1])"))
          (let ((n (string-to-number (buffer-string))))
            (and (> n 0) n)))))))

(defun vscode-launch--open-tunnel (cwd port remote-port)
  "Forward local PORT to 127.0.0.1:REMOTE-PORT on the host of CWD over SSH."
  (vscode-launch--kill-tunnel)
  (let* ((host (file-remote-p cwd 'host))
         (user (file-remote-p cwd 'user))
         (spec (and (boundp 'rdev-hosts) (cdr (assoc host rdev-hosts))))
         (_ (when (eq (plist-get spec :transport) 'tcp)
              (user-error "Host %s uses the tcp transport; no SSH tunnel is possible" host)))
         (dest (or (plist-get spec :ssh-host) host))
         (target (if (and user (not (string-match-p "@" dest))) (concat user "@" dest) dest))
         (args (append (and (boundp 'rdev-ssh-args) rdev-ssh-args)
                       (list "-N" "-o" "ExitOnForwardFailure=yes"
                             "-L" (format "127.0.0.1:%d:127.0.0.1:%d" port remote-port)
                             "--" target)))
         (proc (make-process :name "vscode-launch-tunnel" :noquery t
                             :buffer (generate-new-buffer " *vscode-launch-tunnel*")
                             :command (cons "ssh" args)))
         (deadline (+ (float-time) 15)))
    (setq vscode-launch--tunnel proc)
    (while (and (process-live-p proc)
                (not (vscode-launch--port-listening-p port))
                (< (float-time) deadline))
      (accept-process-output proc 0.1))
    (unless (and (process-live-p proc) (vscode-launch--port-listening-p port))
      (let ((out (with-current-buffer (process-buffer proc) (string-trim (buffer-string)))))
        (vscode-launch--kill-tunnel)
        (user-error "Cannot open an SSH tunnel to %s for port %d%s" target port
                    (if (string-empty-p out) "" (concat ": " out)))))
    (setq vscode-launch--gate (cons port (cons cwd remote-port)))
    (vscode-launch--watch-tunnel)
    proc))

(defun vscode-launch--remote-config (config cwd)
  "Prepare the evaluated dape CONFIG to run its adapter on the host of CWD."
  (when (and (eq (plist-get config 'port) :autoport) (fboundp 'dape-config-autoport))
    (setq config (dape-config-autoport config)))
  ;; The adapter listens on a port that is free on the remote host (which
  ;; need not be the one that was free here), on its loopback only: just the
  ;; tunnel has to reach it.
  (let* ((port (plist-get config 'port))
         (remote-port (or (and (integerp port) (vscode-launch--remote-free-port cwd)) port))
         (from (and (integerp port) (number-to-string port)))
         (to (and (integerp remote-port) (number-to-string remote-port))))
    (when-let* ((args (plist-get config 'command-args)))
      (setq config
            (plist-put config 'command-args
                       (seq-map (lambda (a)
                                  (cond ((equal a "0.0.0.0") "127.0.0.1")
                                        ((and (stringp a) from (equal from a)) to)
                                        ((and (stringp a) from
                                              (string-match (concat "\\`\\(.*[:=]\\)" from "\\'") a))
                                         (concat (match-string 1 a) to))
                                        (t a)))
                                args))))
    (when (integerp port)
      (vscode-launch--open-tunnel cwd port remote-port)))
  config)

(defun vscode-launch--run-dape (plan)
  "Start a dape session from PLAN."
  (unless (and (vscode-launch--dape-loaded-p) (fboundp 'dape--config-eval))
    (user-error "dape is not available"))
  (let* ((cwd (plist-get plan :cwd))
         (default-directory (file-name-as-directory cwd))
         (config (dape--config-eval (plist-get plan :key) (plist-get plan :options))))
    (condition-case err
        (dape (if (file-remote-p cwd) (vscode-launch--remote-config config cwd) config))
      (error (vscode-launch--kill-tunnel)
             (signal (car err) (cdr err))))))

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
      (vscode-launch--ensure-debugpy root))
    (when (cl-some (lambda (p)
                     (let ((plan (cdr p)))
                       (or (and (eq (car plan) :dape)
                                (string-prefix-p "js-debug" (symbol-name (plist-get (cdr plan) :key))))
                           (and (eq (car plan) :run) (plist-get (cdr plan) :attach)))))
                   plans)
      (vscode-launch--ensure-js-debug root))
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
