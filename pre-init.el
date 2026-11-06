;;; pre-init.el --- Package management -*- no-byte-compile: t; lexical-binding: t; -*-

;; minimal-emacs initializes package.el and loads use-package in init.el.
;; Org's development checkout needs generated version and autoload files.
(setq package-vc-allow-build-commands '(org))

;;; pre-init.el ends here
