;;; This can be loaded into Slime, xc-compile-file will produce trace output
(load "src/cold/shared.lisp")
(in-package "SB-COLD")
(setf *host-obj-prefix* "obj/from-host/")
(pushnew :sb-xc-host *features*)
(pushnew :sb-xc-host-interactive *features*)

(load "src/cold/set-up-cold-packages.lisp")
(load "src/cold/defun-load-or-cload-xcompiler.lisp")

(load-or-cload-xcompiler #'host-cload-stem)
;; (load-or-cload-xcompiler #'host-load-stem) ;; if the FASLs are already compiled

(rename-package :sb-xc :sb-xc '(:sb!xc))

(defun xc-compile-file (file)
  (sb-xc:with-compilation-unit ()
    (sb-xc:compile-file file :trace-file *standard-output*)
    (setf sb!c::*undefined-warnings* nil)))