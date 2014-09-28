;; Initialize cask to get the correct version of org-mode
(require 'cask "/usr/local/share/emacs/site-lisp/cask.el")
(cask-initialize)

;; Load customization
;; Keep emacs custom-settings in separate file
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load-file custom-file)
;; (setq use-package-verbose t)
(if (file-exists-p my-init-file)
    (load-file my-init-file)
  (progn
    (org-babel-load-file
     (expand-file-name "emacs-init.org" user-emacs-directory))))
