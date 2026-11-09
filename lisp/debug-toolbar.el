;;; debug-toolbar.el --- VS Code-style debug controls for dape -*- lexical-binding: t; -*-

;; Author: Huy Pham
;; Keywords: tools, processes, convenience
;; Package-Requires: ((emacs "30.1") (dape "0.27"))

;;; Commentary:

;; VS Code shows a floating bar with continue/pause, step over, step into,
;; step out, restart and stop while a launch configuration runs.  This
;; shows the same buttons at the start of the mode line (so it is never truncated) during a session, and binds VS Code's keys:
;;
;;   F5          continue (or start/rerun the last launch when idle)
;;   F6          pause
;;   F10         step over        F11  step into        S-F11  step out
;;   C-S-F5      restart          S-F5 stop
;;
;; The bar is visible while a dape session is active or a
;; `vscode-launch' process is still running.  Stop ends both the debug
;; session and the launched process; Restart stops them and reruns the
;; last `vscode-launch' configuration of the project, preLaunchTask
;; included.  Without a `vscode-launch' run, Restart is `dape-restart'.

;;; Code:

(require 'cl-lib)

(declare-function dape-continue "dape")
(declare-function dape-pause "dape")
(declare-function dape-next "dape")
(declare-function dape-step-in "dape")
(declare-function dape-step-out "dape")
(declare-function dape-restart "dape")
(declare-function dape-quit "dape")
(declare-function dape--live-connection "dape")
(declare-function vscode-launch "vscode-launch")
(declare-function vscode-launch-rerun "vscode-launch")
(defvar dape-active-mode)
(defvar debug-toolbar-mode)
(defvar dape--connections)
(defvar vscode-launch--last)
(declare-function vscode-launch--root "vscode-launch")

(defgroup debug-toolbar nil
  "VS Code-style debug controls."
  :group 'tools)

(defcustom debug-toolbar-restart-timeout 8
  "Seconds to wait for a stopped session to go away before restarting."
  :type 'number)

;;;; State

(defun debug-toolbar--launch-buffers ()
  "Live `vscode-launch' process buffers."
  (cl-remove-if-not
   (lambda (b)
     (and (string-prefix-p "*vscode-launch: " (buffer-name b))
          (process-live-p (get-buffer-process b))))
   (buffer-list)))

(defun debug-toolbar--dape-p ()
  "Non-nil while a dape session exists."
  (and (featurep 'dape) (bound-and-true-p dape-active-mode)))

(defun debug-toolbar--active-p ()
  "Non-nil when the bar should be shown."
  (or (debug-toolbar--dape-p) (debug-toolbar--launch-buffers)))

(defun debug-toolbar--stopped-p ()
  "Non-nil when the debuggee is stopped at a breakpoint or step."
  (and (debug-toolbar--dape-p)
       (dape--live-connection 'stopped t)))

;;;; Commands

(defun debug-toolbar--need-stopped ()
  (unless (debug-toolbar--stopped-p)
    (user-error "Debuggee is not stopped")))

;;;###autoload
(defun debug-toolbar-continue ()
  "Continue when stopped; start or rerun the last launch when idle."
  (interactive)
  (cond ((debug-toolbar--stopped-p) (dape-continue (dape--live-connection 'stopped)))
        ((debug-toolbar--active-p) (user-error "Already running; use pause (F6)"))
        (t (call-interactively #'vscode-launch-rerun))))

(defun debug-toolbar-pause ()
  "Pause the running debuggee."
  (interactive)
  (unless (debug-toolbar--dape-p) (user-error "No debug session"))
  (call-interactively #'dape-pause))

(defun debug-toolbar-next ()
  "Step over."
  (interactive)
  (debug-toolbar--need-stopped)
  (call-interactively #'dape-next))

(defun debug-toolbar-step-in ()
  "Step into."
  (interactive)
  (debug-toolbar--need-stopped)
  (call-interactively #'dape-step-in))

(defun debug-toolbar-step-out ()
  "Step out."
  (interactive)
  (debug-toolbar--need-stopped)
  (call-interactively #'dape-step-out))

(defun debug-toolbar--kill-launch-processes ()
  "Kill the processes started by `vscode-launch'."
  (dolist (b (debug-toolbar--launch-buffers))
    (when-let* ((p (get-buffer-process b)))
      (set-process-query-on-exit-flag p nil)
      (interrupt-process p)
      (run-at-time 2 nil (lambda () (when (process-live-p p) (kill-process p)))))))

;;;###autoload
(defun debug-toolbar-stop ()
  "Stop the debug session and the process `vscode-launch' started."
  (interactive)
  (unless (debug-toolbar--active-p) (user-error "Nothing to stop"))
  (when (debug-toolbar--dape-p) (dape-quit))
  (debug-toolbar--kill-launch-processes)
  (message "Debug session stopped"))

(defun debug-toolbar--when-idle (fn)
  "Call FN once the session and launched processes are gone, or time out."
  (let ((deadline (+ (float-time) debug-toolbar-restart-timeout)))
    (cl-labels
        ((poll ()
           (cond ((not (or (debug-toolbar--launch-buffers)
                           (and (featurep 'dape) dape--connections)))
                  (funcall fn))
                 ((> (float-time) deadline)
                  (message "debug-toolbar: session did not stop within %ss; restart aborted"
                           debug-toolbar-restart-timeout))
                 (t (run-at-time 0.2 nil #'poll)))))
      (poll))))

;;;###autoload
(defun debug-toolbar-restart ()
  "Restart: rerun the last `vscode-launch' configuration, else `dape-restart'."
  (interactive)
  (let ((relaunch (and (featurep 'vscode-launch)
                       (ignore-errors
                         (gethash (vscode-launch--root) vscode-launch--last)))))
    (cond
     (relaunch
      (let ((default-directory default-directory))
        (when (debug-toolbar--active-p) (debug-toolbar-stop))
        (debug-toolbar--when-idle
         (lambda () (let ((default-directory default-directory))
                      (vscode-launch-rerun))))))
     ((debug-toolbar--dape-p) (call-interactively #'dape-restart))
     (t (user-error "Nothing to restart")))))

;;;; Mode line

(defvar debug-toolbar--buttons
  ;; (GLYPH LABEL COMMAND HELP ENABLED-P)
  '(("▶" "Continue" debug-toolbar-continue "Continue (F5)"
     (lambda () (debug-toolbar--stopped-p)))
    ("⏸" "Pause" debug-toolbar-pause "Pause (F6)"
     (lambda () (debug-toolbar--dape-p)))
    ("⤼" "Over" debug-toolbar-next "Step over (F10)"
     (lambda () (debug-toolbar--stopped-p)))
    ("⤓" "Into" debug-toolbar-step-in "Step into (F11)"
     (lambda () (debug-toolbar--stopped-p)))
    ("⤒" "Out" debug-toolbar-step-out "Step out (S-F11)"
     (lambda () (debug-toolbar--stopped-p)))
    ("⟳" "Restart" debug-toolbar-restart "Restart (C-S-F5)"
     (lambda () t))
    ("■" "Stop" debug-toolbar-stop "Stop (S-F5)"
     (lambda () t)))
  "Toolbar buttons.")

(defun debug-toolbar--visible-buttons ()
  "Buttons to show now: continue when stopped, else pause (like VS Code)."
  (let ((stopped (debug-toolbar--stopped-p))
        (dape (debug-toolbar--dape-p)))
    (cl-remove-if
     (lambda (s)
       (pcase (nth 2 s)
         ('debug-toolbar-pause (or stopped (not dape)))
         ('debug-toolbar-continue (and dape (not stopped)))))
     debug-toolbar--buttons)))

(defun debug-toolbar--face (cmd on)
  (cond ((not on) 'shadow)
        ((eq cmd 'debug-toolbar-stop) '(:foreground "red3" :weight bold))
        ((memq cmd '(debug-toolbar-restart debug-toolbar-continue))
         '(:foreground "green4" :weight bold))
        (t '(:foreground "dodger blue" :weight bold))))

(defun debug-toolbar--button (spec)
  "Propertized mode-line text for button SPEC."
  (pcase-let* ((`(,glyph ,_label ,cmd ,help ,enabled) spec)
               (on (funcall enabled))
               (map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] cmd)
    (propertize (concat " " glyph " ")
                'face (debug-toolbar--face cmd on)
                'mouse-face 'mode-line-highlight
                'help-echo (if on help (concat help " — not available now"))
                'keymap map)))

(defun debug-toolbar--lowest-window ()
  "The window with the lowest mode line on the selected frame.
Among windows sharing the bottom edge, the leftmost one."
  (let (best)
    (dolist (w (window-list (selected-frame) 'no-minibuf))
      (let ((e (window-edges w)))
        (when (or (null best)
                  (> (nth 3 e) (nth 3 (car best)))
                  (and (= (nth 3 e) (nth 3 (car best)))
                       (< (nth 0 e) (nth 0 (car best)))))
          (setq best (cons e w)))))
    (cdr best)))

(defun debug-toolbar--format ()
  "Mode-line text with the debug buttons, or nil when no session runs."
  ;; Every window has its own mode line; draw the buttons in one only.
  ;; Mode lines are evaluated with their window's buffer current.
  (when (and (debug-toolbar--active-p)
             (eq (current-buffer) (window-buffer (debug-toolbar--lowest-window))))
    (concat "["
            (mapconcat #'debug-toolbar--button (debug-toolbar--visible-buttons) "")
            "] ")))

(defvar debug-toolbar--mode-line '(:eval (debug-toolbar--format)))
(put 'debug-toolbar--mode-line 'risky-local-variable t)

(defvar debug-toolbar--saved-front-space nil
  "Original `mode-line-front-space' while the segment is installed.")

(defun debug-toolbar--install ()
  "Put the buttons first in the mode line, before everything that can be cut off."
  (unless debug-toolbar--saved-front-space
    (setq debug-toolbar--saved-front-space (list mode-line-front-space))
    (setq mode-line-front-space
          ;; The leading "" matters: a list starting with a symbol is read
          ;; as the conditional (SYMBOL THEN ELSE).
          (list "" 'debug-toolbar--mode-line
                (car debug-toolbar--saved-front-space))))
  (force-mode-line-update t))

(defun debug-toolbar--uninstall ()
  (when debug-toolbar--saved-front-space
    (setq mode-line-front-space (car debug-toolbar--saved-front-space)
          debug-toolbar--saved-front-space nil))
  (force-mode-line-update t))

(defun debug-toolbar--sync (&rest _)
  "Redraw the mode line after a session or launch process changes."
  (force-mode-line-update t))

(defun debug-toolbar--watch-launch (proc)
  "Redraw when PROC, a `vscode-launch' process, ends."
  (when (and (processp proc) (process-buffer proc)
             (string-prefix-p "*vscode-launch: " (buffer-name (process-buffer proc))))
    (add-function :after (process-sentinel proc)
                  (lambda (&rest _) (run-at-time 0.1 nil #'debug-toolbar--sync)))
    (run-at-time 0.1 nil #'debug-toolbar--sync)))

(defvar debug-toolbar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<f5>") #'debug-toolbar-continue)
    (define-key map (kbd "<f6>") #'debug-toolbar-pause)
    (define-key map (kbd "<f10>") #'debug-toolbar-next)
    (define-key map (kbd "<f11>") #'debug-toolbar-step-in)
    (define-key map (kbd "S-<f11>") #'debug-toolbar-step-out)
    (define-key map (kbd "S-<f5>") #'debug-toolbar-stop)
    (define-key map (kbd "C-S-<f5>") #'debug-toolbar-restart)
    map))

;;;###autoload
(define-minor-mode debug-toolbar-mode
  "Show VS Code-style debug buttons at the start of the mode line.
The buttons appear only while a debug session or launch is running.
Also binds the VS Code debug F-keys."
  :global t
  :keymap debug-toolbar-mode-map
  (cond
   (debug-toolbar-mode
    (add-hook 'compilation-start-hook #'debug-toolbar--watch-launch)
    (with-eval-after-load 'dape
      (add-hook 'dape-active-mode-hook #'debug-toolbar--sync))
    (debug-toolbar--install))
   (t
    (remove-hook 'compilation-start-hook #'debug-toolbar--watch-launch)
    (remove-hook 'dape-active-mode-hook #'debug-toolbar--sync)
    (debug-toolbar--uninstall))))

(provide 'debug-toolbar)
;;; debug-toolbar.el ends here
