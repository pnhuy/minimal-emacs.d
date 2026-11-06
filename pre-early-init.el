;;; pre-early-init.el --- Package startup settings -*- no-byte-compile: t; lexical-binding: t; -*-

;; Let minimal-emacs initialize package.el during init.el.
(setq package-enable-at-startup nil
      minimal-emacs-package-initialize-and-refresh t)

;;; pre-early-init.el ends here
