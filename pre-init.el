;;; pre-init.el --- Package management -*- no-byte-compile: t; lexical-binding: t; -*-

;; minimal-emacs initializes package.el and loads use-package in init.el.
;; Org's development checkout needs generated version and autoload files.
(setq package-vc-allow-build-commands '(org))

;; Prefer Git-installed Org over bundled Org.
(let ((org-lisp (expand-file-name
                 "elpa/org/lisp" user-emacs-directory)))
  (when (file-exists-p (expand-file-name "org.el" org-lisp))
    ;; Always put Git Org first.
    (setq load-path
          (cons org-lisp (remove org-lisp load-path)))))

;;; pre-init.el ends here
