;;; cookiecutter.el --- Create projects from Cookiecutter templates -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Local configuration
;; Keywords: tools, project
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Interactive helpers for creating projects with the Cookiecutter command-line
;; program.  The built-in catalog contains a Python package template and a C++
;; project template.  Cookiecutter is installed into a managed virtual
;; environment on first use when it is not already available.

;;; Code:

(require 'subr-x)
(require 'comint)
(require 'seq)

(defvar-local cookiecutter-origin-window nil
  "Window that started the current Cookiecutter operation.")
(defvar-local cookiecutter-project-directory nil
  "Generated project root for project.el in the current buffer.")

(defgroup cookiecutter nil
  "Create projects from Cookiecutter templates."
  :group 'tools
  :prefix "cookiecutter-")

(defcustom cookiecutter-executable "cookiecutter"
  "Name or absolute path of the Cookiecutter executable."
  :type 'string
  :group 'cookiecutter)

(defcustom cookiecutter-python-executable "python3"
  "Python executable used to install Cookiecutter when it is unavailable."
  :type 'string
  :group 'cookiecutter)

(defcustom cookiecutter-venv-directory
  (expand-file-name "cookiecutter-venv" user-emacs-directory)
  "Directory for the virtual environment managed by this package."
  :type 'directory
  :group 'cookiecutter)

(defcustom cookiecutter-template-cache-directory
  (expand-file-name "~/.cookiecutters/")
  "Directory where Cookiecutter keeps downloaded templates."
  :type 'directory
  :group 'cookiecutter)

(defcustom cookiecutter-templates
  '(("Python package (audreyfeldroy)" . "gh:audreyfeldroy/cookiecutter-pypackage")
    ("C++ project (ssciwr)" . "gh:ssciwr/cookiecutter-cpp-project"))
  "Alist of descriptive names and Cookiecutter template locations.

Template locations use Cookiecutter's syntax, for example `gh:owner/repo'
or a local directory."
  :type '(alist :key-type string :value-type string)
  :group 'cookiecutter)

(defun cookiecutter--read-template ()
  "Read a template name from `cookiecutter-templates'."
  (let* ((names (mapcar #'car cookiecutter-templates))
         (choice (completing-read "Template: " names nil t)))
    (or (cdr (assoc choice cookiecutter-templates))
        (user-error "Unknown Cookiecutter template: %s" choice))))

(defun cookiecutter--read-output-directory ()
  "Read the directory where Cookiecutter creates a project.
The current directory is the default; a new path is created if needed."
  (let ((directory (read-file-name "Project location: "
                                   default-directory nil nil)))
    (setq directory (expand-file-name directory))
    (unless (file-directory-p directory)
      (make-directory directory t))
    (file-name-as-directory directory)))

(defun cookiecutter--managed-executable ()
  "Return the Cookiecutter executable inside `cookiecutter-venv-directory'."
  (expand-file-name
   (if (memq system-type '(windows-nt ms-dos))
       "Scripts/cookiecutter.exe"
     "bin/cookiecutter")
   cookiecutter-venv-directory))

(defun cookiecutter--cached-template (template)
  "Return TEMPLATE's cached directory if it is a valid Cookiecutter template."
  (let* ((repository (cond
                      ((string-match "\\`gh:[^/]+/\\([^/]+\\)\\(?:\\.git\\)?\\'"
                                     template)
                       (match-string 1 template))
                      ((and (string-match-p "\\`https?://" template)
                            (string-match "/\\([^/]+\\)\\(?:\\.git\\)?\\'"
                                          template))
                       (match-string 1 template))))
         (cached (and repository
                      (expand-file-name repository
                                       cookiecutter-template-cache-directory))))
    (when (and cached
               (file-directory-p cached)
               (file-readable-p (expand-file-name "cookiecutter.json" cached)))
      cached)))

(defun cookiecutter--new-project-directory (output-directory previous-entries)
  "Find the project directory created under OUTPUT-DIRECTORY.
PREVIOUS-ENTRIES is the list of names present before generation began."
  (let ((new-directories
         (seq-filter
          (lambda (path)
            (and (file-directory-p path)
                 (not (member (file-name-nondirectory
                               (directory-file-name path))
                              previous-entries))))
          (directory-files output-directory t directory-files-no-dot-files-regexp))))
    (when (= (length new-directories) 1)
      (file-name-as-directory (car new-directories)))))

(defun cookiecutter--remember-project (directory)
  "Register DIRECTORY with built-in project.el and Projectile when available."
  (require 'project)
  (project-remember-project
   (cons 'transient (file-name-as-directory directory)))
  (when (require 'projectile nil t)
    (funcall 'projectile-add-known-project directory)))

(defun cookiecutter--project-find (directory)
  "Return the generated project containing DIRECTORY, if any."
  (let ((root cookiecutter-project-directory))
    (when (and root
               (or (equal (file-name-as-directory (expand-file-name directory)) root)
                   (file-in-directory-p directory root)))
      (cons 'transient root))))

(defun cookiecutter--process-sentinel (process event)
  "Handle completion of Cookiecutter PROCESS and close its window."
  (let ((old-sentinel (process-get process 'cookiecutter-old-sentinel)))
    (when old-sentinel
      (funcall old-sentinel process event)))
  (when (and (memq (process-status process) '(exit signal))
             (not (process-get process 'cookiecutter-finalized)))
    (process-put process 'cookiecutter-finalized t)
    (if (and (eq (process-status process) 'exit)
             (= (process-exit-status process) 0))
        (let* ((buffer (process-buffer process))
               (directory
                (cookiecutter--new-project-directory
                 (process-get process 'cookiecutter-output-directory)
                 (process-get process 'cookiecutter-output-entries))))
          (if (and directory (buffer-live-p buffer))
              (with-current-buffer buffer
                (cookiecutter--remember-project directory)
                (let* ((window (process-get process 'cookiecutter-origin-window))
                       (project-buffer
                        (generate-new-buffer
                         (format "*Project: %s*" (abbreviate-file-name directory)))))
                  (with-current-buffer project-buffer
                    (setq default-directory directory
                          cookiecutter-project-directory directory)
                    (add-hook 'project-find-functions
                              #'cookiecutter--project-find nil t))
                  (quit-window)
                  (let ((window (if (window-live-p window)
                                    window
                                  (selected-window))))
                    (set-window-buffer window project-buffer)
                    (select-window window)))
                (message "Project created at %s." directory))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (quit-window)))
            (message "Cookiecutter finished; project directory could not be identified.")))
      (message "Cookiecutter exited with an error; see %s"
               (buffer-name (process-buffer process)))
      (when (buffer-live-p (process-buffer process))
        (with-current-buffer (process-buffer process) (quit-window))))))

(defun cookiecutter--run (executable template output-directory buffer)
  "Run EXECUTABLE with TEMPLATE and OUTPUT-DIRECTORY in BUFFER."
  (let* ((origin-window (buffer-local-value 'cookiecutter-origin-window buffer))
         (output-entries
          (directory-files output-directory nil
                           directory-files-no-dot-files-regexp))
         (process-connection-type t))
    (apply #'make-comint-in-buffer
           "cookiecutter" buffer executable nil
           (list "--output-dir" output-directory
                 (or (cookiecutter--cached-template template) template)))
    (let ((process (get-buffer-process buffer)))
      (set-process-query-on-exit-flag process nil)
      (process-put process 'cookiecutter-output-directory output-directory)
      (process-put process 'cookiecutter-output-entries output-entries)
      (process-put process 'cookiecutter-origin-window origin-window)
      (process-put process 'cookiecutter-old-sentinel (process-sentinel process))
      (set-process-sentinel process #'cookiecutter--process-sentinel)
      (pop-to-buffer buffer)
      (message "Cookiecutter is creating a project in %s" output-directory)
      process)))

(defun cookiecutter--install-and-run (template output-directory buffer)
  "Install Cookiecutter in the managed virtual environment, then run it."
  (unless (executable-find cookiecutter-python-executable)
    (user-error "Python executable not found: %s" cookiecutter-python-executable))
  (let* ((python-code
          (concat
           "import subprocess, sys, venv\n"
           "from pathlib import Path\n"
           "env = Path(sys.argv[1])\n"
           "venv.EnvBuilder(with_pip=True).create(env)\n"
           "python = env / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')\n"
           "subprocess.check_call([str(python), '-m', 'pip', 'install', '--upgrade', 'cookiecutter'])\n"))
         (process
          (make-process
           :name "cookiecutter-install"
           :buffer buffer
           :command (list cookiecutter-python-executable "-c" python-code
                          cookiecutter-venv-directory)
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (install-process _event)
             (when (memq (process-status install-process) '(exit signal))
               (if (and (eq (process-status install-process) 'exit)
                        (= (process-exit-status install-process) 0)
                        (file-executable-p (cookiecutter--managed-executable)))
                   (cookiecutter--run (cookiecutter--managed-executable)
                                      template output-directory buffer)
                 (message "Cookiecutter installation failed; see %s"
                          (buffer-name buffer))))))))
    (pop-to-buffer buffer)
    (message "Installing Cookiecutter into %s" cookiecutter-venv-directory)
    process))

;;;###autoload
(defun cookiecutter-create-project (&optional template output-directory)
  "Create a project from TEMPLATE in OUTPUT-DIRECTORY.

Interactively, select one of `cookiecutter-templates' and enter a project
location, defaulting to the current directory.  Cookiecutter prompts for
template variables in a dedicated process buffer.

When called from Lisp, TEMPLATE should be a Cookiecutter template location;
  OUTPUT-DIRECTORY defaults to `default-directory'."
  (interactive)
  (let* ((template (or template (cookiecutter--read-template)))
         (output-directory (or output-directory
                               (cookiecutter--read-output-directory)))
         (output-directory (file-name-as-directory
                            (expand-file-name output-directory)))
         (buffer (get-buffer-create "*Cookiecutter*"))
         (origin-window (selected-window))
         (executable (or (executable-find cookiecutter-executable)
                         (and (file-executable-p (cookiecutter--managed-executable))
                              (cookiecutter--managed-executable)))))
    (unless (file-directory-p output-directory)
      (make-directory output-directory t))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory output-directory
              cookiecutter-origin-window origin-window)))
    (if executable
        (cookiecutter--run executable template output-directory buffer)
      (cookiecutter--install-and-run template output-directory buffer))))

;;;###autoload
(defun cookiecutter-create-project-from-template (template)
  "Create a project from an arbitrary Cookiecutter TEMPLATE location."
  (interactive "sCookiecutter template (URL or directory): ")
  (cookiecutter-create-project template))

(provide 'cookiecutter)

;;; cookiecutter.el ends here
