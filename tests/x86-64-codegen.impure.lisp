;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

#-(and x86-64 immobile-space sb-thread) (sb-ext:exit :code 104) ; can't run these tests

(defun disasm (safety expr &optional (remove-epilogue t))
  ;; This lambda has a name because if it doesn't, then the name
  ;; is something stupid like (lambda () in ...) which pretty-prints
  ;; on a random number of lines.
  (let ((fun (compile nil
                      `(sb-int:named-lambda test ()
                         (declare (optimize (debug 0) (safety ,safety)
                                            (sb-c::verify-arg-count 0)))
                         ,expr))))
    (sb-int:encapsulate 'sb-disassem::add-debugging-hooks 'test
                        (lambda (f &rest args) (declare (ignore f args))))
    (let ((lines
           (split-string
            (with-output-to-string (s)
              (let ((sb-disassem:*disassem-location-column-width* 0))
                (disassemble fun :stream s)))
            #\newline)))
      (sb-int:unencapsulate 'sb-disassem::add-debugging-hooks 'test)
      (setq lines (cddr lines)) ; remove "Disassembly for"
      (when (string= (car (last lines)) "")
        (setq lines (nbutlast lines)))
      ;; For human-readability, kill the whitespace
      (setq lines (mapcar (lambda (x) (string-left-trim " ;" x)) lines))
      ;; If the last 4 lines are of the expected form
      ;;   MOV RSP, RBP / CLC / POP RBP / RET
      ;; then strip them out
      (if (and remove-epilogue
               (every #'search
                      '("MOV RSP, RBP" "CLC" "POP RBP" "RET")
                      (subseq lines (- (length lines) 4))))
          (butlast lines 4)
          lines))))

(with-test (:name :symeval-known-thread-local)
  ;; It should take 1 instruction to read a known thread-local var
  (assert (= (length (disasm 1 'sb-thread:*current-thread*)) 1))
  (assert (= (length (disasm 1 'sb-kernel:*restart-clusters*)) 1))
  (assert (= (length (disasm 1 'sb-kernel:*handler-clusters*)) 1)))

;; Lack of earmuffs on this symbol allocates it in dynamic space
(defvar foo)
(assert (not (sb-kernel:immobile-space-obj-p 'foo)))
;; This compilation causes a side-effect of assigning FOO a TLS index
;; DO NOT REMOVE!
(compile nil '(lambda (foo) (eval 'frob)))

(with-test (:name :symeval-known-tls-index)
  ;; When symbol SC is IMMEDIATE:
  ;;    498B942478210000   MOV RDX, [R12+8568]       ; tls: *PRINT-BASE*
  ;;    83FA61             CMP EDX, 97
  ;;    480F44142538F94B20 CMOVEQ RDX, [#x204BF938]  ; *PRINT-BASE*
  ;; (TODO: could use "CMOVEQ RDX, [RIP-n]" in immobile code)
  (assert (= (length (disasm 0 '*print-base*)) 3))

  ;; When symbol SC is CONSTANT:
  ;;    498B942478290000   MOV RDX, [R12+10616]        ; tls: FOO
  ;;    488B05A4FFFFFF     MOV RAX, [RIP-92]           ; 'FOO
  ;;    83FA61             CMP EDX, 97
  ;;    480F4450F9         CMOVEQ RDX, [RAX-7]
  (assert (= (length (disasm 0 'foo)) 4)))

(defvar *blub*) ; immobile space
(defvar blub)   ; dynamic space
(assert (sb-kernel:immobile-space-obj-p '*blub*))
(assert (not (sb-kernel:immobile-space-obj-p 'blub)))

(with-test (:name :symeval-unknown-tls-index)
  ;; When symbol SC is immediate:
  ;;    8B142514A24C20     MOV EDX, [#x204CA214]    ; tls_index: *BLUB*
  ;;    498B1414           MOV RDX, [R12+RDX]
  ;;    83FA61             CMP EDX, 97
  ;;    480F44142518A24C20 CMOVEQ RDX, [#x204CA218] ; *BLUB*
  ;; (TODO: could use "CMOVEQ RDX, [RIP-n]" in immobile code)
  (assert (= (length (disasm 0 '*blub*)) 4))

  ;; When symbol SC is constant:
  ;;    488B05B3FFFFFF     MOV RAX, [RIP-77]          ; 'BLUB"
  ;;    8B50F5             MOV EDX, [RAX-11]
  ;;    498B1414           MOV RDX, [R12+RDX]
  ;;    83FA61             CMP EDX, 97
  ;;    480F4450F9         CMOVEQ RDX, [RAX-7]
  (assert (= (length (disasm 0 'blub)) 5)))