;;; post-init.el --- Init -*- lexical-binding: t; -*-

;;; ----------------------------------------------------------------------
;;; Core
;;; ----------------------------------------------------------------------
(setq auth-sources '("~/.authinfo.gpg" "~/.authinfo"))
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(load-theme 'modus-operandi-tinted t)

;; macOS: Command is Meta, Option is Super.
(when (eq system-type 'darwin)
  (setq mac-command-modifier 'meta
        mac-option-modifier 'super))

;; Font: keep the default when JetBrains Mono is unavailable.
(when (and (display-graphic-p)
           (find-font (font-spec :family "JetBrains Mono")))
  (set-face-attribute 'default nil
                      :family "JetBrains Mono"
                      :height 140))

;; Automatically reload buffers when files change on disk.
(global-auto-revert-mode 1)

;; Track recently opened files (feeds `consult-recent-file' on C-x C-r).
(recentf-mode 1)

;; Remember point position when reopening files.
(save-place-mode 1)

;; Emacs 30.2's project file reader fails when a project has no files.
(defun my-project-read-file-name (prompt files &optional predicate hist mb-default)
  "Read a project file, allowing a first file in an empty project."
  (if files
      (project--read-file-cpd-relative prompt files predicate hist mb-default)
    (read-file-name (concat prompt ": ") default-directory nil nil nil predicate)))

(with-eval-after-load 'project
  (setq project-read-file-name-function #'my-project-read-file-name))

;; Copy from line above
(global-set-key (kbd "C-M-=") #'copy-from-above-command)

(use-package async
  :ensure t
  :commands async-start)

(use-package exec-path-from-shell
  :ensure t
  :demand t
  :if (memq system-type '(darwin gnu/linux))
  :init
  (defvar my/shell-path-cache
    (expand-file-name "var/shell-path" user-emacs-directory)
    "File containing the cached shell PATH.")

  (defun my/apply-shell-path (path)
    "Update PATH and executable lookup directories."
    (setenv "PATH" path)
    (setq exec-path
          (append (parse-colon-path path)
                  (list exec-directory))))

  ;; Load the previous PATH immediately, without starting a shell.
  (when (file-readable-p my/shell-path-cache)
    (let ((path (with-temp-buffer
                  (insert-file-contents my/shell-path-cache)
                  (buffer-string))))
      (when (> (length path) 0)
        (my/apply-shell-path path))))

  :config
  ;; Refresh PATH in a separate Emacs process.
  (async-start
   `(lambda ()
      (load ,(locate-library "exec-path-from-shell") nil t)
      (setq exec-path-from-shell-variables '("PATH"))
      (exec-path-from-shell-initialize)
      (getenv "PATH"))
   (lambda (path)
     (when (and (stringp path) (> (length path) 0))
       (my/apply-shell-path path)
       (make-directory
        (file-name-directory my/shell-path-cache) t)
       (with-temp-buffer
         (insert path)
         (write-region (point-min) (point-max)
                       my/shell-path-cache nil 'silent))))))

(use-package drag-stuff
  :ensure t
  ;; Vertical only: `drag-stuff-define-keys' would also take M-<left>/M-<right>
  ;; (Cmd-left/right) for sideways dragging.
  :bind
  (("M-<up>"   . drag-stuff-up)
   ("M-<down>" . drag-stuff-down)))

;; Enable delete-selection-mode
(delete-selection-mode 1)

;;; ----------------------------------------------------------------------
;;; Tab Line (VS Code-style buffer tabs)
;;; ----------------------------------------------------------------------

(use-package tab-line
  :ensure nil
  :init
  (global-tab-line-mode 1)
  :custom
  (tab-line-tabs-function #'tab-line-tabs-fixed-window-buffers)
  (tab-line-tab-name-function #'tab-line-tab-name-truncated-buffer)
  (tab-line-tab-name-truncated-max 30)
  (tab-line-new-button-show nil)
  (tab-line-close-button-show t)
  (tab-line-close-tab-function 'kill-buffer)
  (tab-line-exclude-buffers '(derived-mode . dired-sidebar-mode))

  :bind
  (("C-<prior>" . tab-line-switch-to-prev-tab)
   ("C-<next>"  . tab-line-switch-to-next-tab)))

;;; ----------------------------------------------------------------------
;;; Line numbers
;;; ----------------------------------------------------------------------
(setq-default display-line-numbers-width nil   ; auto-size to the buffer
              display-line-numbers-widen nil)  ; numbers follow narrowing
(global-display-line-numbers-mode 1)
(defun my/disable-line-numbers ()
  "Turn off line numbers in the current buffer."
  (display-line-numbers-mode -1))
(dolist (hook '(dired-mode-hook
                dired-sidebar-mode-hook
                term-mode-hook
                shell-mode-hook
                eshell-mode-hook
                vterm-mode-hook
                help-mode-hook
                completion-list-mode-hook
                compilation-mode-hook
                org-mode-hook
                pdf-view-mode-hook))
  (add-hook hook #'my/disable-line-numbers))

;;; ----------------------------------------------------------------------
;;; Undo (undo-fu + persistent session history)
;;; ----------------------------------------------------------------------

(use-package undo-fu
  :ensure t
  :bind
  (("C-/" . undo-fu-only-undo)
   ("C-_" . undo-fu-only-undo)          ; what C-/ sends in a terminal
   ("C-?" . undo-fu-only-redo)
   ("M-_" . undo-fu-only-redo)))        ; C-? can't be typed in a terminal

(use-package undo-fu-session
  :ensure t
  :init
  (undo-fu-session-global-mode 1))

;;; ----------------------------------------------------------------------
;;; Which Key
;;; ----------------------------------------------------------------------

(use-package which-key
  :ensure nil                           ; built in since Emacs 30
  :init
  (which-key-mode 1))


;;; ----------------------------------------------------------------------
;;; Yasnippet
;;; ----------------------------------------------------------------------

(use-package yasnippet
  :ensure t
  :hook
  (prog-mode . yas-minor-mode)
  :custom
  (yas-snippet-dirs
   (list (expand-file-name "snippets" user-emacs-directory)))
  :config
  (yas-reload-all))

(use-package yasnippet-snippets
  :ensure t
  :after yasnippet)

(use-package yasnippet-capf
  :ensure t
  :after yasnippet)


;;; ----------------------------------------------------------------------
;;; Minibuffer Completion
;;; Vertico + Orderless + Marginalia + Consult + Embark
;;; ----------------------------------------------------------------------

;; Persist minibuffer history.
(use-package savehist
  :ensure nil
  :init
  (savehist-mode 1))


;; Vertical minibuffer completion.
(use-package vertico
  :ensure t
  :custom
  (vertico-resize t)
  :init
  (vertico-mode 1))


;; Flexible matching.
(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides
   '((file (styles partial-completion)))))


;; Candidate annotations.
(use-package marginalia
  :ensure t
  :init
  (marginalia-mode 1))


;; Search/navigation.
(use-package consult
  :ensure t
  :bind
  (("C-s"     . consult-line)
   ("C-x b"   . consult-buffer)
   ("C-x C-r" . consult-recent-file)
   ("M-y"     . consult-yank-pop)

   ("M-g g"   . consult-goto-line)
   ("M-g i"   . consult-imenu)

   ("M-s r"   . consult-ripgrep)
   ("M-s g"   . consult-grep)
   ("M-s f"   . consult-find))

  :hook
  (completion-list-mode . consult-preview-at-point-mode)

  :init
  ;; Consult register preview.
  (advice-add #'register-preview
              :override
              #'consult-register-window)

  ;; Consult for xref.
  (setq xref-show-xrefs-function
        #'consult-xref

        xref-show-definitions-function
        #'consult-xref))


;;; ----------------------------------------------------------------------
;;; Corfu
;;; ----------------------------------------------------------------------

(use-package corfu
  :ensure t
  :custom
  ;; Show completion automatically.
  (corfu-auto t)

  ;; Wait slightly before showing popup.
  (corfu-auto-delay 0.15)

  ;; Start after two characters.
  (corfu-auto-prefix 2)

  ;; Cycle around candidate list.
  (corfu-cycle t)

  ;; Minimum popup width in characters.
  (corfu-min-width 25)

  ;; Keep popup reasonably sized.
  (corfu-count 12)

  ;; Preselect the first candidate.
  (corfu-preselect 'first)

  :bind
  (:map corfu-map
        ;; TAB accepts completion
        ("TAB" . corfu-insert)
        ([tab] . corfu-insert)

        ;; ENTER inserts newline instead of accepting completion
        ("RET" . newline)
        ([return] . newline))

  :init
  (global-corfu-mode 1))


;;; ----------------------------------------------------------------------
;;; Cape
;;; ----------------------------------------------------------------------

(use-package cape
  ;; Wait, so `cape-capf-super' exists before startup files run
  ;; `prog-mode-hook' (otherwise void-function on first run / updates).
  :ensure (:wait t)
  :after corfu)


;;; ----------------------------------------------------------------------
;;; Normal programming-mode completion
;;;
;;; For non-Eglot buffers:
;;;
;;;   Yasnippet
;;;   + dabbrev
;;;
;;; are combined into ONE Corfu popup.
;;;
;;; File completion stays separate because file CAPFs commonly use
;;; different completion boundaries.
;;; ----------------------------------------------------------------------

(defun my/prog-capf-setup ()
  "Configure completion sources for normal programming buffers."
  ;; Append rather than replace, so the major mode's own CAPF
  ;; (e.g. `elisp-completion-at-point') keeps priority.
  (add-hook 'completion-at-point-functions
            (cape-capf-super #'yasnippet-capf #'cape-dabbrev) 50 t)
  (add-hook 'completion-at-point-functions #'cape-file 60 t))

(add-hook 'prog-mode-hook #'my/prog-capf-setup)


;;; ----------------------------------------------------------------------
;;; Eglot
;;; ----------------------------------------------------------------------

(use-package eglot
  :ensure nil
  :hook
  (prog-mode . my/eglot-ensure-maybe)
  :init
  (defun my/eglot-server-available-p ()
    "Non-nil if `eglot-server-programs' has an installed server for this mode.
Function contacts (e.g. `eglot-alternatives') are assumed available."
    (require 'eglot)
    (seq-some
     (lambda (entry)
       (and (seq-some (lambda (m)
                        (and (symbolp m) (not (keywordp m))
                             (provided-mode-derived-p major-mode m)))
                      (flatten-tree (car entry)))
            (let ((contact (cdr entry)))
              (or (functionp contact)
                  (not (stringp (car-safe contact)))
                  (executable-find (car contact))))))
     eglot-server-programs))

  (defun my/eglot-ensure-maybe ()
    "Start Eglot only when a language server is available, to avoid
\"Couldn't guess LSP server\" warnings in other buffers."
    (when (my/eglot-server-available-p)
      (eglot-ensure)))
  :bind
  (:map eglot-mode-map
        ("C-c l a" . eglot-code-actions)
        ("C-c l e" . consult-flymake)
        ("C-c l r" . eglot-rename)
        ("C-c l f" . eglot-format-buffer)
        ("C-c l d" . eldoc-doc-buffer)
        ("C-c l s" . consult-eglot-symbols))

  :custom

  ;; Disable LSP inlay hints.
  ;; Disable on-type formatting
  (eglot-ignored-server-capabilities
   '(:inlayHintProvider :documentOnTypeFormattingProvider))

  ;; Show code-action hints in the fringe only.  The default also includes
  ;; `eldoc-hint', which makes eldoc-box pop up with just the action hint
  ;; even when there is no documentation at point.
  (eglot-code-action-indications '(left-fringe))

  ;; Shut the server down when its last buffer is killed.
  (eglot-autoshutdown t)

  ;; Don't log every JSON-RPC message; large logs slow Eglot down.
  (eglot-events-buffer-config '(:size 0 :format full))

  :config

  ;; Explicit Flutter/Dart language server.
  (add-to-list
   'eglot-server-programs

   ;; Resolved on `exec-path' at connect time rather than hardcoded, so
   ;; this works wherever the Flutter SDK happens to be installed.
   '(dart-mode
     . ("dart"
        "language-server"
        "--protocol=lsp"))))


;;; ----------------------------------------------------------------------
;;; Eglot + Corfu completion
;;;
;;; In Eglot buffers Corfu gets one combined table of Eglot/LSP and
;;; Yasnippet candidates.  The `my/prog-capf-setup' sources (snippets +
;;; dabbrev, then cape-file) stay behind it as fallbacks.
;;; ----------------------------------------------------------------------

(defvar-local my/eglot-capf nil
  "Combined Eglot CAPF installed in the current buffer.")

(defun my/eglot-capf-setup ()
  "Put Eglot and snippets into one Corfu list; undo when Eglot stops."
  (when my/eglot-capf
    (remove-hook 'completion-at-point-functions my/eglot-capf t)
    (setq my/eglot-capf nil))
  (when (eglot-managed-p)
    (setq my/eglot-capf
          (cape-capf-super #'eglot-completion-at-point #'yasnippet-capf))
    ;; Replace Eglot's own plain CAPF with the combined one.
    (remove-hook 'completion-at-point-functions #'eglot-completion-at-point t)
    (add-hook 'completion-at-point-functions my/eglot-capf -10 t)))

(add-hook 'eglot-managed-mode-hook #'my/eglot-capf-setup)


;;; ----------------------------------------------------------------------
;;; Embark
;;; ----------------------------------------------------------------------

(use-package embark
  :ensure t

  :bind
  (("C-."   . embark-act)
   ("C-;"   . embark-dwim)
   ("C-h B" . embark-bindings))

  :init
  (setq prefix-help-command
        #'embark-prefix-help-command))


(use-package embark-consult
  :ensure t
  :after (embark consult)

  :hook
  (embark-collect-mode
   . consult-preview-at-point-mode))


;;; ----------------------------------------------------------------------
;;; Code folding
;;; ----------------------------------------------------------------------

(use-package hideshow
  :ensure nil
  :commands hs-minor-mode
  :init
  (defun my/enable-hideshow ()
    "Enable Hideshow when the programming mode provides comment syntax."
    (when (and (bound-and-true-p comment-start)
               (bound-and-true-p comment-end))
      (hs-minor-mode 1)))
  :hook
  (prog-mode . my/enable-hideshow)
  :bind
  (:map hs-minor-mode-map
        ("C-c f f" . hs-toggle-hiding)
        ("C-c f h" . hs-hide-block)
        ("C-c f s" . hs-show-block)
        ("C-c f H" . hs-hide-all)
        ("C-c f S" . hs-show-all)
        ("C-c f l" . hs-hide-level))
  :custom
  (hs-hide-comments-when-hiding-all nil)
  (hs-show-indicators t)
  ;; Keep fold arrows out of the left fringe, where dape draws breakpoints.
  (hs-indicator-type 'margin)
  (hs-display-lines-hidden t)
  :config
  ;; Fold Dart classes and methods delimited by braces.
  (add-to-list 'hs-special-modes-alist
               '(dart-mode "{" "}" "/[*/]" nil nil)))


;;; ----------------------------------------------------------------------
;;; Dart / Flutter
;;; ----------------------------------------------------------------------

(use-package dart-mode
  :ensure t

  ;; Eglot starts via the `prog-mode' hook in the Eglot section.
  :mode
  "\\.dart\\'")

;; Dart formatting is handled by Apheleia (see the Formatting section below).


;;; ----------------------------------------------------------------------
;;; Org
;;; ----------------------------------------------------------------------

(use-package org
  :defer
  :ensure (org :repo "https://code.tecosaur.net/tec/org-mode.git/"
                :branch "dev")
  :custom
  (org-startup-truncated nil)
  (org-preview-latex-default-process 'dvisvgm)
  (org-agenda-files
   '("~/Dropbox/Documents/org-roam/20250805110520-backlog.org")))

(use-package org-fragtog
  :ensure t
  :hook
  (org-mode . org-fragtog-mode))

(use-package org-modern
  :ensure t
  :hook
  (org-mode . org-modern-mode))

(use-package org-modern-indent
  :ensure (org-modern-indent :repo "https://github.com/jdtsmith/org-modern-indent.git"
                    :branch "main")
  :hook
  (org-mode . org-modern-indent-mode))

(with-eval-after-load 'org
  (setq org-startup-indented t) ; Enable `org-indent-mode' by default
  (add-hook 'org-mode-hook #'visual-line-mode))

(defun my/org-regenerate-all-latex-previews ()
  "Clear and regenerate all LaTeX previews in the current Org buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command only works in Org mode"))
  ;; Triple prefix: clear all previews.
  (org-latex-preview '(64))
  ;; Double prefix: generate all previews.
  (org-latex-preview '(16)))

(defun my/org-increase-latex-preview-size ()
  "Increase LaTeX preview size by 0.1 and regenerate all previews."
  (interactive)
  (my/org-set-latex-preview-size
   (/ (round (* 10 (+ (or (plist-get org-format-latex-options :scale) 1.0)
                      0.1)))
      10.0)))

(defun my/org-decrease-latex-preview-size ()
  "Decrease LaTeX preview size by 0.1 and regenerate all previews."
  (interactive)
  (my/org-set-latex-preview-size
   (max 0.1
        (/ (round (* 10 (- (or (plist-get org-format-latex-options :scale) 1.0)
                           0.1)))
           10.0))))

(defun my/org-set-latex-preview-size (scale)
  "Set LaTeX preview SCALE for the current buffer and regenerate previews."
  (interactive
   (list
    (read-number
     "LaTeX preview scale: "
     (or (plist-get org-format-latex-options :scale) 1.0))))
  (unless (derived-mode-p 'org-mode)
    (user-error "This command only works in Org mode"))
  (unless (> scale 0)
    (user-error "Scale must be greater than zero"))

  ;; Make the setting local to this Org buffer.
  (unless (local-variable-p 'org-format-latex-options)
    (setq-local org-format-latex-options
                (copy-tree org-format-latex-options)))

  (setq org-format-latex-options
        (plist-put org-format-latex-options :scale scale))

  (my/org-regenerate-all-latex-previews)
  (message "LaTeX preview scale: %.2f" scale))

(defvar-local my/org-font-remap-cookie nil
  "Face-remapping cookie for the current Org buffer.")

(defvar-local my/org-font-family nil
  "Selected font family for the current Org buffer.")

(defvar-local my/org-font-size 16
  "Selected font size for the current Org buffer.")

(defun my/org-change-font (font size)
  "Interactively change FONT and SIZE in the current Org buffer."
  (interactive
   (let* ((fonts (sort (delete-dups (font-family-list))
                       #'string-lessp))
          (current-font
           (or my/org-font-family
               (face-attribute 'variable-pitch
                               :family nil 'default)))
          (font
           (completing-read
            "Org font: "
            fonts nil t nil nil current-font))
          (size
           (read-number
            "Org font size: "
            my/org-font-size)))
     (list font size)))

  (unless (derived-mode-p 'org-mode)
    (user-error "This command only works in Org mode"))

  (unless (> size 0)
    (user-error "Font size must be greater than zero"))

  ;; Remove the previous buffer-local font setting.
  (when my/org-font-remap-cookie
    (face-remap-remove-relative my/org-font-remap-cookie))

  (setq-local my/org-font-family font)
  (setq-local my/org-font-size size)

  ;; Face height uses tenths of a point: 16 pt = 160.
  (setq my/org-font-remap-cookie
        (face-remap-add-relative
         'default
         `(:family ,font :height ,(round (* size 10)))))

  (font-lock-flush)
  (message "Org font: %s, %.1f pt" font size))


;;; ----------------------------------------------------------------------
;;; Org Roam
;;; ----------------------------------------------------------------------

(use-package org-roam
  :ensure t

  :custom
  (org-roam-directory
   (file-truename
    "~/Dropbox/Documents/org-roam"))

  :bind
  (("C-c n l" . org-roam-buffer-toggle)
   ("C-c n f" . org-roam-node-find)
   ("C-c n g" . org-roam-graph)
   ("C-c n i" . org-roam-node-insert)
   ("C-c n c" . org-roam-capture)

   ;; Dailies
   ("C-c n j" . org-roam-dailies-capture-today)))


(use-package org-roam-ask
  :ensure nil

  :commands
  (org-roam-ask
   org-roam-ask-search
   org-roam-ask-index-build
   org-roam-ask-index-note
   org-roam-ask-index-rebuild
   org-roam-ask-index-status)

  :custom
  (org-roam-ask-embedding-model "nomic-embed-text")

  ;; Reindex on save is opt-in: super-save writes often, and every write
  ;; would otherwise fire an embedding request. Enable with
  ;; `org-roam-ask-mode' once the index is built.
  (org-roam-ask-auto-index nil)

  :bind
  (("C-c n a" . org-roam-ask)
   ("C-c n s" . org-roam-ask-search)
   ("C-c n u" . org-roam-ask-index-build)))


;;; ----------------------------------------------------------------------
;;; Eldoc Box
;;; ----------------------------------------------------------------------

(use-package eldoc-box
  :ensure t

  :hook
  (eglot-managed-mode . eldoc-box-hover-at-point-mode)

  :custom
  (eldoc-box-mouse-mode-idle-delay 1)
  (eldoc-box-max-pixel-width 500)
  (eldoc-box-max-pixel-height 200))


;;; ----------------------------------------------------------------------
;;; Python Virtualenv
;;; ----------------------------------------------------------------------

(use-package pyvenv
  :ensure t
  :hook
  (python-base-mode . pyvenv-mode)
  (python-base-mode . pyvenv-tracking-mode))


;;; ----------------------------------------------------------------------
;;; Expand Region
;;; ----------------------------------------------------------------------

(use-package expand-region
  :ensure t

  :bind
  ("C-=" . er/expand-region))


(use-package super-save
  :ensure t
  :custom
  (super-save-auto-save-when-idle t)
  (super-save-idle-duration 10)
  (super-save-remote-files nil)
  :config
  ;; Don't run Apheleia on idle autosaves, which would reformat half-typed
  ;; code.  Explicit saves (C-x C-s) still format.
  (defvar my/super-save-idle-in-progress nil
    "Non-nil while super-save's idle timer is saving buffers.")

  (defun my/super-save-mark-idle (fn &rest args)
    "Call FN with ARGS while flagging the save as an idle autosave."
    (let ((my/super-save-idle-in-progress t))
      (apply fn args)))

  (advice-add 'super-save-command-idle :around #'my/super-save-mark-idle)

  (defun my/super-save-idle-p ()
    "Non-nil during an idle autosave; used by `apheleia-skip-functions'."
    my/super-save-idle-in-progress)

  (with-eval-after-load 'apheleia
    (add-hook 'apheleia-skip-functions #'my/super-save-idle-p))

  (super-save-mode 1))

;; Sidebar
(use-package dired-subtree
  :ensure t
  :commands (dired-subtree-toggle dired-subtree-cycle)
  :config
  (setq dired-subtree-line-prefix " ")
  (setq dired-subtree-use-backgrounds nil))

;; Icon set required by `dired-sidebar-theme' `vscode'.
(use-package vscode-icon
  :ensure t
  :defer t)

(use-package dired-sidebar
  :bind (("C-x C-n" . dired-sidebar-toggle-sidebar))
  :ensure t
  :commands (dired-sidebar-toggle-sidebar)
  :init
  (add-hook 'dired-sidebar-mode-hook
            (lambda ()
              (unless (file-remote-p default-directory)
                (auto-revert-mode))))
  :config
  (push 'toggle-window-split dired-sidebar-toggle-hidden-commands)
  (push 'rotate-windows dired-sidebar-toggle-hidden-commands)

  (setq dired-sidebar-subtree-line-prefix "__")
  (setq dired-sidebar-theme 'vscode)
  (setq dired-sidebar-use-term-integration t)
  (setq dired-sidebar-use-custom-font t))

(use-package transient
  :ensure t
  :defer t)

(use-package gptel
  :ensure t
  ;; Defer so gptel (and its llm/plz dependencies) does not load at startup.
  :defer t
  :config
  (gptel-make-ollama
         "Ollama"
         :host "localhost:11434"
         :stream t
         :models
         '((qwen3.5:2b
            :description "Qwen3.5 2B local"
            :capabilities (tool-use))))
  
  (gptel-make-openai "OpenRouter"
    :host "openrouter.ai"
    :endpoint "/api/v1/chat/completions"
    :stream t
    :key #'gptel-api-key-from-auth-source
    :models '(inclusionai/ling-3.0-flash))

  ;; Use DeepSeek by default.  Store its key in ~/.authinfo.gpg as:
  ;; machine api.deepseek.com login apikey password YOUR_API_KEY
  (setq gptel-model 'deepseek-chat
        gptel-backend
        (gptel-make-deepseek "DeepSeek"
          :stream t
          :key #'gptel-api-key-from-auth-source))

  (setq gptel-default-mode 'org-mode))

(with-eval-after-load 'gptel-context
  (set-face-attribute 'gptel-context-highlight-face nil
                      :background 'unspecified
                      :foreground 'unspecified
                      :extend nil
                      :inherit nil))

(use-package gptel-agent
  :ensure t
  :defer t
  :after gptel
  :config
  (gptel-agent-update))

(use-package ghostel
  :ensure t
  :defer t)

(use-package markdown-mode
  :ensure t
  ;; `.md' files open via the autoloaded major mode.
  :defer t)

(use-package smart-hungry-delete
  :ensure t

  :bind
  (([remap backward-delete-char-untabify]
    . smart-hungry-delete-backward-char)
   ([remap delete-backward-char]
    . smart-hungry-delete-backward-char)
   ([remap delete-char]
    . smart-hungry-delete-forward-char)
   ([remap c-electric-backspace]
    . smart-hungry-delete-backward-char)
   ([remap cperl-electric-backspace]
    . smart-hungry-delete-backward-char)
   ([remap python-indent-dedent-line-backspace]
    . smart-hungry-delete-backward-char)
   ([remap c-electric-delete-forward]
    . smart-hungry-delete-forward-char))

  :init
  (smart-hungry-delete-add-default-hooks)

  :config
  ;; Dedent one level when DEL is pressed inside the indentation.
  ;; Self-contained, so it does not depend on cc-mode's electric commands
  ;; (which are hungry-delete and only delete one char with a numeric prefix).
  (defun my/indent-step ()
    "Return the indentation step of the current major mode.
Not `tab-width': `python-mode' sets that to 8 while indenting by 4."
    (let ((step (cond ((derived-mode-p 'python-base-mode) python-indent-offset)
                      ((derived-mode-p 'c-ts-base-mode) c-ts-mode-indent-offset)
                      ((derived-mode-p 'java-ts-mode) java-ts-mode-indent-offset)
                      ((derived-mode-p 'cperl-mode) cperl-indent-level)
                      ;; cc-mode modes don't derive from `c-mode-common'.
                      ((bound-and-true-p c-buffer-is-cc-mode) c-basic-offset))))
      (if (and (integerp step) (> step 0)) step tab-width)))

  (defun my/dedent-line-backspace ()
    "Dedent the current line by one indentation level; else delete one char.
Snaps to the previous multiple of the step, so uneven indentation
lines up again."
    (interactive)
    (let ((indent (current-indentation)))
      ;; At column 0, delete the newline (join lines) as usual.
      (if (and (> indent 0) (not (bolp)))
          (let ((step (my/indent-step)))
            (indent-line-to (* step (/ (1- indent) step))))
        (delete-backward-char 1))))

  (dolist (mode '(c-mode c++-mode java-mode objc-mode awk-mode idl-mode pike-mode
                  python-mode cperl-mode
                  c-ts-mode c++-ts-mode java-ts-mode python-ts-mode))
    (setf (alist-get mode smart-hungry-delete-major-mode-dedent-function-alist)
          #'my/dedent-line-backspace)))

(use-package quickrun
  :ensure t
  :defer t
  :bind
  (("C-c r" . quickrun)                 ; compile + run the current file
   ("C-c R" . quickrun-shell))          ; same, in a shell (for stdin input)
  :config
  ;; macOS has no `python' on the default PATH, only `python3'.
  (quickrun-add-command "python" '((:command . "python3")) :override t))

;; Project builds.  `compilation-scroll-output' and ANSI colors are already
;; set up by init.el.
(use-package compile
  :ensure nil
  :bind
  (("C-c c" . compile)
   ("C-c C" . recompile)))

(use-package elec-pair
    :ensure nil
    :hook (prog-mode . electric-pair-local-mode))


(use-package surround
  :ensure t
  :bind-keymap ("M-'" . surround-keymap))
;;; ----------------------------------------------------------------------
;;; Git: Magit + diff-hl
;;; ----------------------------------------------------------------------

(use-package magit
  :ensure t
  :defer t
  :bind ("C-x g" . magit-status)
  :custom
  (magit-display-buffer-function
   #'magit-display-buffer-same-window-except-diff-v1))

(use-package diff-hl
  :ensure t
  :init
  (global-diff-hl-mode 1)
  :config
  (diff-hl-flydiff-mode 1))


;;; ----------------------------------------------------------------------
;;; Formatting: Apheleia (format-on-save)
;;; ----------------------------------------------------------------------

(use-package apheleia
  :ensure t
  :init
  ;; Dart uses Apheleia's built-in `dart-format' (dart format).
  (apheleia-global-mode 1))


;;; ----------------------------------------------------------------------
;;; Ligatures (gear: JetBrains Mono)
;;; ----------------------------------------------------------------------

(use-package ligature
  :ensure t
  :config
  (ligature-set-ligatures
   'prog-mode
   '("->" "=>" "==" "!=" ">=" "<=" "&&" "||" "::" "..." "<-" "-->" "<=>" "www"))
  (global-ligature-mode t))


;;; ----------------------------------------------------------------------
;;; Editing helpers
;;; ----------------------------------------------------------------------

(use-package ws-butler
  :ensure t
  :hook (prog-mode . ws-butler-mode))

(use-package avy
  :ensure t
  :defer t
  :bind ("C-:" . avy-goto-char-timer))

(use-package symbol-overlay
  :ensure t
  :defer t
  :bind (("C-c s p" . symbol-overlay-put)
         ("C-c s n" . symbol-overlay-jump-next)
         ("C-c s P" . symbol-overlay-jump-prev)))

(use-package multiple-cursors
  :ensure t
  :defer t
  :bind (("C-c m l" . mc/edit-lines)
         ("C-c m d" . mc/mark-next-like-this)))

(use-package helpful
  :ensure t
  :defer t
  :bind (([remap describe-function] . helpful-callable)
         ([remap describe-variable] . helpful-variable)
         ([remap describe-key] . helpful-key)))

(use-package consult-eglot
  ;; Bound to C-c l s in `eglot-mode-map' (see the Eglot section).
  :ensure t
  :defer t)

;;; ----------------------------------------------------------------------
;;; Org extras
;;; ----------------------------------------------------------------------

(use-package org-appear
  :ensure t
  :hook (org-mode . org-appear-mode)
  :custom
  (org-appear-autolinks t)
  (org-appear-autoemphasis t))

(use-package org-download
  :ensure t
  ;; No `:after org': `org-download-enable' is autoloaded, and waiting for
  ;; Org skipped dired buffers opened before Org loaded.
  :hook (dired-mode . org-download-enable)
  :custom
  ;; Temporary location: the OS may clear it, so don't keep images here.
  (org-download-image-dir
   (expand-file-name "org-download/" temporary-file-directory)))

(use-package org-roam-ui
  :ensure t
  :defer t
  :after org-roam
  :bind ("C-c n U" . org-roam-ui-mode)
  :custom
  (org-roam-ui-sync-theme t)
  (org-roam-ui-follow t)
  (org-roam-ui-update-on-save t))


;;; ----------------------------------------------------------------------
;;; Icons and UI polish
;;; ----------------------------------------------------------------------

(use-package nerd-icons
  :ensure t
  :defer t)

(use-package nerd-icons-completion
  :ensure t
  :after marginalia
  :hook
  (marginalia-mode . nerd-icons-completion-marginalia-setup)
  :config
  (nerd-icons-completion-mode 1)
  ;; `marginalia-mode' is usually on already, so run the setup now too.
  (nerd-icons-completion-marginalia-setup))

(use-package nerd-icons-dired
  :ensure t
  :hook (dired-mode . nerd-icons-dired-mode))

;; `minions' folds all minor modes into one mode-line menu (no diminish needed).
(use-package minions
  :ensure t
  :config
  (minions-mode 1))

(use-package popper
  :ensure t
  :init
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*gptel.*"
          help-mode
          compilation-mode))
  (popper-mode 1)
  (popper-echo-mode 1)
  :bind (("C-`" . popper-toggle)
         ;; Not C-<tab>: Org and Magit bind it locally.
         ("C-M-`" . popper-cycle)))


;;; ----------------------------------------------------------------------
;;; Debugging (DAP) and terminal
;;; ----------------------------------------------------------------------

;; dape only autoloads `dape' itself, so its `C-x C-a' keys and the
;; breakpoint commands do not exist until it has loaded.  Bind the ones
;; needed before the first session so breakpoints can be set up front.
(use-package dape
  :ensure t
  :defer t
  :commands (dape dape-breakpoint-toggle dape-breakpoint-log
             dape-breakpoint-expression dape-breakpoint-remove-all)
  :bind
  (("C-c d b" . dape-breakpoint-toggle)
   ("C-c d B" . dape-breakpoint-expression))
  ;; Highlight the line the debugger is stopped on (empty by default).
  ;; Add `:underline t' for an underline as well.
  :custom-face
  (dape-source-line-face ((t :inherit highlight :extend t)))
  :config
  ;; Launch a C/C++ executable built with debug symbols (for example, -g).
  (setf (alist-get 'lldb-dap dape-configs)
        '(modes (c-mode c-ts-mode c++-mode c++-ts-mode
                 rust-mode rust-ts-mode rustic-mode)
          ensure dape-ensure-command
          command "lldb-dap"
          command-cwd dape-command-cwd
          :type "lldb-dap"
          :request "launch"
          :cwd dape-cwd
          :program (lambda ()
                     (read-file-name "Executable to debug: " (dape-cwd)
                                     nil t))
          :args [])))

;; Run .vscode/launch.json configs: debuggable ones go through dape,
;; plain commands (npm/npx, node-terminal) through compile.
(use-package vscode-launch
  :ensure nil
  :commands (vscode-launch vscode-launch-dape vscode-launch-install-js-debug vscode-launch-install-debugpy vscode-launch-rerun vscode-launch-open-file)
  :bind
  (("C-c d l" . vscode-launch)
   ("C-c d r" . vscode-launch-rerun)
   ("C-c d o" . vscode-launch-open-file)))

(provide 'post-init)

;;; post-init.el ends here
