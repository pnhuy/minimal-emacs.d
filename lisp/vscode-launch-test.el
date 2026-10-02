;;; vscode-launch-test.el --- Tests for vscode-launch -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'vscode-launch)

(defun vscode-launch-test--ctx (&rest extra)
  "Return a resolution context, with EXTRA plist entries added."
  (append extra (list :root "/ws/proj" :file "/ws/proj/src/app.py" :line 7
                      :platform :osx :cache (make-hash-table :test 'equal))))

(defun vscode-launch-test--plan (json &optional force-run)
  "Plan the single configuration in JSON text, the way a real run would."
  (let* ((cfg (vscode-launch--parse json))
         (ctx (vscode-launch-test--ctx)))
    (vscode-launch--plan
     (vscode-launch--subst (vscode-launch--apply-platform cfg :osx) ctx)
     "/ws/proj" force-run)))

(ert-deftest vscode-launch-test-jsonc ()
  (let ((d (vscode-launch--parse
            "{ // c1\n \"a\": \"http://x/y\", /* c2 */ \"b\": [1, 2,],\n \"c\": \"q\\\" // not\",\n}")))
    (should (equal (plist-get d :a) "http://x/y"))
    (should (equal (plist-get d :b) [1 2]))
    (should (equal (plist-get d :c) "q\" // not"))))

(ert-deftest vscode-launch-test-json-scalars ()
  (let ((d (vscode-launch--parse "{\"t\": true, \"f\": false, \"n\": null, \"e\": {}, \"l\": []}")))
    (should (eq (plist-get d :t) t))
    (should (eq (plist-get d :f) :false))
    (should (eq (plist-get d :n) :null))
    (should (equal (plist-get d :l) []))))

(ert-deftest vscode-launch-test-subst ()
  (let ((ctx (vscode-launch-test--ctx)))
    (should (equal (vscode-launch--subst
                    '(:cwd "${workspaceFolder}/x" :args ["${fileBasename}" "${workspaceRoot}" "${lineNumber}"])
                    ctx)
                   '(:cwd "/ws/proj/x" :args ["app.py" "/ws/proj" "7"])))
    (let ((process-environment (cons "VL_T=1" process-environment)))
      (should (equal (vscode-launch--subst-string "${env:VL_T}" ctx) "1")))))

(ert-deftest vscode-launch-test-subst-unknown-is-error ()
  (let ((ctx (vscode-launch-test--ctx)))
    (should-error (vscode-launch--subst-string "${nonsense}" ctx) :type 'user-error)
    (should-error (vscode-launch--subst-string "${input:missing}" ctx) :type 'user-error)
    (should-error (vscode-launch--subst-string "${config:x}" ctx) :type 'user-error)
    (should-error (vscode-launch--subst-string "${file}" '(:root "/ws")) :type 'user-error)))

(ert-deftest vscode-launch-test-inputs ()
  (let ((ctx (vscode-launch-test--ctx
              :inputs (list '(:id "port" :type "promptString" :description "Port")
                            '(:id "mode" :type "pickString" :options ["dev" "prod"])))))
    (let ((calls 0))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (cl-incf calls) "8080")))
        (should (equal (vscode-launch--subst-string "${input:port}:${input:port}" ctx)
                       "8080:8080"))
        (should (= calls 1))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "prod")))
      (should (equal (vscode-launch--subst-string "${input:mode}" ctx) "prod")))))

(ert-deftest vscode-launch-test-env-file ()
  (let ((f (make-temp-file "vl" nil ".env" "# c\nA=1\nexport B=\"two\"\nC='3'\n")))
    (unwind-protect
        (should (equal (vscode-launch--read-env-file f)
                       '(("A" . "1") ("B" . "two") ("C" . "3"))))
      (delete-file f))))

(ert-deftest vscode-launch-test-env-precedence-and-scalars ()
  (let ((f (make-temp-file "vl" nil ".env" "A=file\nB=file\n")))
    (unwind-protect
        (let ((env (vscode-launch--env
                    (list :envFile f :env '(:A "env" :N 5 :T t :F :false :U :null)))))
          (should (equal (alist-get "A" env nil nil #'equal) "env"))
          (should (equal (alist-get "B" env nil nil #'equal) "file"))
          (should (equal (alist-get "N" env nil nil #'equal) "5"))
          (should (equal (alist-get "T" env nil nil #'equal) "true"))
          (should (equal (alist-get "F" env nil nil #'equal) "false"))
          (should (assoc "U" env))
          (should-not (cdr (assoc "U" env))))
      (delete-file f))))

(ert-deftest vscode-launch-test-platform-override ()
  (let* ((cfg (vscode-launch--parse
               "{\"name\":\"x\",\"env\":{\"A\":\"1\",\"B\":\"2\"},\"osx\":{\"env\":{\"A\":\"mac\"},\"args\":[\"m\"]},\"linux\":{\"args\":[\"l\"]}}"))
         (mac (vscode-launch--apply-platform cfg :osx))
         (lin (vscode-launch--apply-platform cfg :linux)))
    (should (equal (plist-get (plist-get mac :env) :A) "mac"))
    (should (equal (plist-get (plist-get mac :env) :B) "2"))
    (should (equal (plist-get mac :args) ["m"]))
    (should (equal (plist-get lin :args) ["l"]))
    (should-not (plist-member mac :osx))
    (should-not (plist-member mac :linux))))

(ert-deftest vscode-launch-test-stale-exe ()
  (should (equal (vscode-launch--exe "/no/such/dir/bin/sh-nonexistent-xyz")
                 "sh-nonexistent-xyz"))
  (should (equal (vscode-launch--exe "npm") "npm")))

(ert-deftest vscode-launch-test-plan-node-run ()
  (let ((plan (vscode-launch-test--plan
               "{\"name\":\"n\",\"type\":\"node\",\"request\":\"launch\",\"runtimeExecutable\":\"npm\",\"runtimeArgs\":[\"run\",\"dev\"],\"cwd\":\"${workspaceFolder}/app\"}")))
    (should (eq (car plan) :run))
    (should (equal (plist-get (cdr plan) :command) "npm run dev"))
    (should (equal (plist-get (cdr plan) :cwd) "/ws/proj/app"))))

(ert-deftest vscode-launch-test-plan-python-run ()
  (let* ((vscode-launch-prefer-debugger nil)
         (plan (vscode-launch-test--plan
                "{\"name\":\"p\",\"type\":\"debugpy\",\"request\":\"launch\",\"module\":\"uvicorn\",\"python\":\"python3\",\"args\":[\"app.main:app\",\"--port\",\"5001\"]}")))
    (should (eq (car plan) :run))
    (should (string-match-p "-m uvicorn app.main:app --port 5001\\'"
                            (plist-get (cdr plan) :command)))))

(ert-deftest vscode-launch-test-dape-forwards-adapter-keys ()
  "Unknown properties reach dape; client-only ones do not; false stays false."
  (skip-unless (require 'dape nil t))
  (let* ((vscode-launch-prefer-debugger t)
         (plan (vscode-launch-test--plan
                (concat "{\"name\":\"p\",\"type\":\"debugpy\",\"request\":\"launch\","
                        "\"module\":\"uvicorn\",\"justMyCode\":false,\"console\":\"integratedTerminal\","
                        "\"subProcess\":true,\"presentation\":{\"order\":1},\"preLaunchTask\":\"b\","
                        "\"env\":{\"X\":\"1\"}}"))))
    (should (eq (car plan) :dape))
    (let ((o (plist-get (cdr plan) :options)))
      (should (eq (plist-get o :justMyCode) :json-false))
      (should (equal (plist-get o :console) "integratedTerminal"))
      (should (eq (plist-get o :subProcess) t))
      (should (equal (plist-get o :module) "uvicorn"))
      (should (equal (plist-get (plist-get o :env) :X) "1"))
      (should-not (plist-member o :presentation))
      (should-not (plist-member o :preLaunchTask))
      (should-not (plist-member o :name))
      (should-not (plist-member o :type)))))

(ert-deftest vscode-launch-test-plan-unsupported ()
  (dolist (json '("{\"name\":\"a\",\"type\":\"msedge\",\"request\":\"attach\"}"
                  "{\"name\":\"b\",\"type\":\"python\",\"request\":\"attach\"}"
                  "{\"name\":\"c\",\"type\":\"weird\",\"request\":\"launch\"}"))
    (should (eq (car (vscode-launch-test--plan json)) :unsupported))))

(ert-deftest vscode-launch-test-node-terminal ()
  (let ((plan (vscode-launch-test--plan
               "{\"name\":\"t\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"npm run start:dev\"}")))
    (should (equal (plist-get (cdr plan) :command) "npm run start:dev"))))

(ert-deftest vscode-launch-test-compound-fails-before-starting ()
  (let* ((data (vscode-launch--parse
                (concat "{\"configurations\":["
                        "{\"name\":\"ok\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"true\"},"
                        "{\"name\":\"bad\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"${nonsense}\"}],"
                        "\"compounds\":[{\"name\":\"both\",\"configurations\":[\"ok\",\"bad\"]},"
                        "{\"name\":\"loop\",\"configurations\":[\"loop\"]}]}")))
         (ctx (vscode-launch-test--ctx))
         (started nil))
    (cl-letf (((symbol-function 'vscode-launch--run-plan) (lambda (&rest _) (setq started t))))
      (should-error (vscode-launch--run-name "both" data "/ws/proj" ctx nil) :type 'user-error)
      (should-error (vscode-launch--run-name "loop" data "/ws/proj" ctx nil) :type 'user-error)
      (should-not started))))

(defun vscode-launch-test--data (json)
  "Parse and validate the launch.json text JSON."
  (let ((d (vscode-launch--parse json)))
    (vscode-launch--validate d)
    d))

(ert-deftest vscode-launch-test-validation ()
  (dolist (json '("{\"configurations\":null}"
                  "{}"
                  "{\"configurations\":[{\"type\":\"node\",\"request\":\"launch\"}]}"
                  "{\"configurations\":[],\"compounds\":{}}"
                  "{\"configurations\":[],\"inputs\":3}"
                  "{\"configurations\":[],\"compounds\":[{\"configurations\":[]}]}"))
    (should-error (vscode-launch-test--data json) :type 'user-error))
  (should (vscode-launch-test--data "{\"configurations\":[]}")))

(ert-deftest vscode-launch-test-unknown-top-level-warns ()
  (let (warned)
    (cl-letf (((symbol-function 'display-warning) (lambda (&rest a) (push a warned))))
      (vscode-launch-test--data "{\"configurations\":[],\"bogus\":1}"))
    (should warned)))

(ert-deftest vscode-launch-test-read-and-find ()
  (let ((f (make-temp-file "vl" nil ".json"
                           "{\"version\":\"0.2.0\",\"configurations\":[{\"name\":\"a\",\"type\":\"node\",\"request\":\"launch\"}]}")))
    (unwind-protect
        (let ((data (vscode-launch-read f)))
          (should (equal (mapcar #'car (vscode-launch-configurations data)) '("a")))
          (should (vscode-launch-find-configuration data "a"))
          (should-not (vscode-launch-find-configuration data "zz")))
      (delete-file f))
    (should-error (vscode-launch-read "/no/such/launch.json") :type 'user-error)))

(ert-deftest vscode-launch-test-compound-warnings-and-hidden ()
  (let* ((data (vscode-launch-test--data
                (concat "{\"configurations\":["
                        "{\"name\":\"a\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"true\"},"
                        "{\"name\":\"h\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"true\",\"presentation\":{\"hidden\":true}}],"
                        "\"compounds\":[{\"name\":\"c\",\"configurations\":[\"a\"],\"preLaunchTask\":\"build\",\"stopAll\":true}]}")))
         warnings)
    (should (equal (mapcar #'car (vscode-launch--candidates data)) '("a" "c")))
    (cl-letf (((symbol-function 'display-warning) (lambda (_ msg &rest _) (push msg warnings))))
      (vscode-launch--plans "c" data "/ws/proj" (vscode-launch-test--ctx) nil))
    (should (cl-some (lambda (w) (string-match-p "preLaunchTask" w)) warnings))
    (should (cl-some (lambda (w) (string-match-p "stopAll" w)) warnings))))

(ert-deftest vscode-launch-test-compound-folder-member ()
  (let* ((dir (make-temp-file "vlws" t))
         (data (vscode-launch-test--data
                "{\"configurations\":[],\"compounds\":[{\"name\":\"c\",\"configurations\":[{\"name\":\"r\",\"folder\":\"other\"}]}]}")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".vscode" dir))
          (with-temp-file (expand-file-name ".vscode/launch.json" dir)
            (insert "{\"configurations\":[{\"name\":\"r\",\"type\":\"node-terminal\",\"request\":\"launch\",\"command\":\"echo hi\"}]}"))
          (let ((vscode-launch-workspace-folders `(("other" . ,dir))))
            (let ((plans (vscode-launch--plans "c" data "/ws/proj" (vscode-launch-test--ctx) nil)))
              (should (equal (mapcar #'car plans) '("r")))
              (should (equal (plist-get (cdr (cdar plans)) :command) "echo hi"))))
          (let ((vscode-launch-workspace-folders nil))
            (should-error (vscode-launch--plans "c" data "/ws/proj" (vscode-launch-test--ctx) nil)
                          :type 'user-error)))
      (delete-directory dir t))))

(ert-deftest vscode-launch-test-client-properties-customizable ()
  (let ((vscode-launch-client-properties (cons :mine vscode-launch-client-properties)))
    (should-not (plist-member (vscode-launch-strip-client-properties '(:mine 1 :keep 2)) :mine))
    (should (equal (plist-get (vscode-launch-strip-client-properties '(:mine 1 :keep 2)) :keep) 2))))

(ert-deftest vscode-launch-test-to-dape ()
  (skip-unless (require 'dape nil t))
  (let ((cfg (vscode-launch--parse
              "{\"name\":\"p\",\"type\":\"debugpy\",\"request\":\"launch\",\"module\":\"uvicorn\"}")))
    (should (vscode-launch-to-dape cfg "/ws/proj"))
    (should-error (vscode-launch-to-dape
                   (vscode-launch--parse "{\"name\":\"a\",\"type\":\"weird\",\"request\":\"launch\"}")
                   "/ws/proj"))))

(ert-deftest vscode-launch-test-register-adapter ()
  (let ((vscode-launch-dape-adapters nil))
    (vscode-launch-register-adapter "foo" 'bar)
    (should (eq (alist-get "foo" vscode-launch-dape-adapters nil nil #'equal) 'bar))))

(ert-deftest vscode-launch-test-ambiguous-adapter-warns ()
  (skip-unless (require 'dape nil t))
  (let ((dape-configs '((a1 :type "zzz") (a2 :type "zzz")))
        (vscode-launch-dape-adapters nil)
        warned)
    (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warned t)))
              ((symbol-function 'completing-read) (lambda (&rest _) "a2")))
      (should (eq (vscode-launch--find-dape-key "zzz") 'a2))
      (should warned))))

(ert-deftest vscode-launch-test-install-js-debug ()
  "Install from a fake archive into a temp adapter dir; no network."
  (skip-unless (and (require 'dape nil t) (executable-find "tar")))
  (let* ((src (make-temp-file "vlsrc" t))
         (dest (make-temp-file "vladapters" t))
         (archive (expand-file-name "a.tar.gz" src))
         (dape-adapter-dir dest)
         (vscode-launch-install-js-debug t)
         (vscode-launch-js-debug-version "v0.0.0"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "js-debug/src" src) t)
          (with-temp-file (expand-file-name "js-debug/src/dapDebugServer.js" src) (insert "//"))
          (call-process "tar" nil nil nil "-czf" archive "-C" src "js-debug")
          (should-not (vscode-launch--js-debug-installed-p))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (_url file &rest _) (copy-file archive file t))))
            (vscode-launch--ensure-js-debug))
          (should (vscode-launch--js-debug-installed-p))
          ;; failure surfaces as a user-error
          (delete-directory (expand-file-name "js-debug" dest) t)
          (cl-letf (((symbol-function 'url-copy-file) (lambda (&rest _) (error "offline"))))
            (should-error (vscode-launch--ensure-js-debug) :type 'user-error))
          (let ((vscode-launch-install-js-debug nil))
            (should-error (vscode-launch--ensure-js-debug) :type 'user-error)))
      (delete-directory src t)
      (delete-directory dest t))))

(ert-deftest vscode-launch-test-debugpy-adapter-selection ()
  (skip-unless (require 'dape nil t))
  (let* ((dape-adapter-dir (make-temp-file "vlad" t))
         (own (vscode-launch--debugpy-python))
         (vscode-launch-install-debugpy t))
    (unwind-protect
        (cl-letf (((symbol-function 'vscode-launch--has-debugpy-p)
                   (lambda (py) (member py has))))
          (defvar has)
          (let ((has (list "/proj/py")))
            ;; project python has debugpy: use it, nothing to install
            (should (equal (vscode-launch--debugpy-adapter "/proj/py") '("/proj/py"))))
          (let ((has (list own "/proj/py")))
            (should (equal (vscode-launch--debugpy-adapter "/proj/py") (list own))))
          (let ((has nil))
            ;; nothing has it: dedicated env, to be installed
            (should (equal (vscode-launch--debugpy-adapter "/proj/py") (cons own t)))
            (let ((vscode-launch-install-debugpy nil))
              (should (equal (vscode-launch--debugpy-adapter "/proj/py") '("/proj/py"))))))
      (delete-directory dape-adapter-dir t))))

(ert-deftest vscode-launch-test-debugpy-plan-splits-interpreters ()
  "The adapter runs from one python; the debuggee uses the project's."
  (skip-unless (require 'dape nil t))
  (let ((vscode-launch-prefer-debugger t))
    (cl-letf (((symbol-function 'vscode-launch--debugpy-adapter)
               (lambda (_) '("/adapter/py"))))
      (let* ((plan (vscode-launch-test--plan
                    "{\"name\":\"p\",\"type\":\"debugpy\",\"request\":\"launch\",\"module\":\"m\",\"python\":\"python3\"}"))
             (o (plist-get (cdr plan) :options)))
        (should (eq (car plan) :dape))
        (should (equal (plist-get o 'command) "/adapter/py"))
        (should (equal (plist-get o :python) "python3"))))))

(provide 'vscode-launch-test)
;;; vscode-launch-test.el ends here
