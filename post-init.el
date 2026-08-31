;;; post-init.el --- Init -*- lexical-binding: t; -*-

;;; ----------------------------------------------------------------------
;;; Core
;;; ----------------------------------------------------------------------

(setq package-install-upgrade-built-in t)

(load-theme 'modus-operandi-tinted t)

;; Font
(set-face-attribute 'default nil
                    :family "JetBrains Mono"
                    :height 140)

;; Automatically reload buffers when files change on disk.
(global-auto-revert-mode 1)

;; Copy from line above.
(global-set-key (kbd "M-<up>") #'copy-from-above-command)


;;; ----------------------------------------------------------------------
;;; Which Key
;;; ----------------------------------------------------------------------

(use-package which-key
  :ensure t
  :diminish
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

  ;; Show popup even if there is only one candidate.
  (corfu-min-width 25)

  ;; Keep popup reasonably sized.
  (corfu-count 12)

  ;; Show current candidate position.
  (corfu-preselect 'prompt)

  :init
  (global-corfu-mode 1))


;;; ----------------------------------------------------------------------
;;; Cape
;;; ----------------------------------------------------------------------

(use-package cape
  :ensure t
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
  (setq-local completion-at-point-functions
              (list
               (cape-capf-super
                #'yasnippet-capf
                #'cape-dabbrev)

               #'cape-file)))

(add-hook 'prog-mode-hook #'my/prog-capf-setup)


;;; ----------------------------------------------------------------------
;;; Eglot
;;; ----------------------------------------------------------------------

(use-package eglot
  :ensure nil

  :bind
  (:map eglot-mode-map
        ("C-c l a" . eglot-code-actions)
        ("C-c l r" . eglot-rename)
        ("C-c l f" . eglot-format-buffer)
        ("C-c l d" . eldoc-doc-buffer))

  :custom

  ;; Disable LSP inlay hints.
  (eglot-ignored-server-capabilities
   '(:inlayHintProvider))

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
;;; THIS IS THE IMPORTANT PART.
;;;
;;; Corfu will receive one combined completion table containing:
;;;
;;;     Eglot / LSP
;;;     Yasnippet
;;;     dabbrev
;;;
;;; cape-file is left as a secondary CAPF because file completion
;;; generally has different completion boundaries.
;;; ----------------------------------------------------------------------

(defun my/eglot-capf-setup ()
  "Combine Eglot, snippets and dabbrev into one Corfu candidate list."

  (setq-local completion-at-point-functions
              (list
               ;; Combined source.
               (cape-capf-super
                #'eglot-completion-at-point
                #'yasnippet-capf
                #'cape-dabbrev)

               ;; File completion fallback.
               #'cape-file)))

(add-hook 'eglot-managed-mode-hook
          #'my/eglot-capf-setup)


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
;;; Dart / Flutter
;;; ----------------------------------------------------------------------

(use-package dart-mode
  :ensure t

  :mode
  "\\.dart\\'"

  :hook
  (dart-mode . eglot-ensure)

  :custom
  (dart-format-on-save t))


;;; ----------------------------------------------------------------------
;;; Org
;;; ----------------------------------------------------------------------

(use-package org
  :ensure nil
  :custom
  ;; Latex Preview to temporary directory.
  (org-preview-latex-default-process 'dvisvgm)
  (org-preview-latex-image-directory "/tmp/ltximg/")
  ;; Org Agenda
  (org-agenda-files
   '("~/Dropbox/Documents/org-roam/20250805110520-backlog.org")))

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
  "Increase LaTeX preview size and regenerate all previews."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command only works in Org mode"))
  ;; Make the setting local to this Org buffer.
  (unless (local-variable-p 'org-format-latex-options)
    (setq-local org-format-latex-options
                (copy-tree org-format-latex-options)))
  (let* ((current (or (plist-get org-format-latex-options :scale) 1.0))
         (new (/ (float (round (* 10 (+ current 0.1)))) 10)))
    (setq org-format-latex-options
          (plist-put org-format-latex-options :scale new))
    (my/org-regenerate-all-latex-previews)
    (message "LaTeX preview scale: %.1f" new)))

(defun my/org-decrease-latex-preview-size ()
  "Decrease LaTeX preview size and regenerate all previews."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command only works in Org mode"))
  ;; Make the setting local to this Org buffer.
  (unless (local-variable-p 'org-format-latex-options)
    (setq-local org-format-latex-options
                (copy-tree org-format-latex-options)))
  (let* ((current (or (plist-get org-format-latex-options :scale) 1.0))
         (new (max 0.1
                   (/ (float (round (* 10 (- current 0.1)))) 10))))
    (setq org-format-latex-options
          (plist-put org-format-latex-options :scale new))
    (my/org-regenerate-all-latex-previews)
    (message "LaTeX preview scale: %.1f" new)))

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

(require 'face-remap)

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


;;; ----------------------------------------------------------------------
;;; Org Roam Ask
;;; ----------------------------------------------------------------------

;; Semantic search and Q&A over the org-roam notes, using local models
;; served by Ollama. Needs an embedding model, installed once with:
;;
;;     ollama pull nomic-embed-text
;;
;; Then build the index with C-c n u (M-x org-roam-ask-index-build).
;; Rebuilds are incremental: editing one heading re-embeds one chunk.

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

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
  (eglot-managed-mode . eldoc-box-hover-mode)

  :custom
  (eldoc-box-max-pixel-width 500)
  (eldoc-box-max-pixel-height 200))


;;; ----------------------------------------------------------------------
;;; Python Virtualenv
;;; ----------------------------------------------------------------------

(use-package pyvenv
  :ensure t

  :config
  (pyvenv-mode 1)
  (pyvenv-tracking-mode 1))


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
  (super-save-mode 1))

;; Agent-shell and codex
(use-package gptel
  :ensure t
  ;;:config
  ;;(gptel-make-openai-oauth "OpenAI-sub")
  )


;; Sidebar
(use-package dired-subtree
  :commands (dired-subtree-toggle dired-subtree-cycle)
  :config
  (setq dired-subtree-line-prefix " ")
  (setq dired-subtree-use-backgrounds nil))

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


(use-package gptel
  :ensure t
  :config
  (setq
   gptel-model 'qwen3.5:4b

   gptel-backend
   (gptel-make-ollama
       "Ollama"
     :host "localhost:11434"
     :stream t
     :models
     '((qwen3.5:4b
        :description "Qwen3.5 4B local"
        :capabilities (tool-use)))))
  
  ;; Optional: use Org buffers for gptel chats
  (setq gptel-default-mode 'org-mode))

(use-package gptel-agent
  :after gptel
  :config
  (gptel-agent-update))

(provide 'post-init)

;;; post-init.el ends here
