;;;; "cold" core image builder: This is how we create a target Lisp
;;;; system from scratch, by converting from fasl files to an image
;;;; file in the cross-compilation host, without the help of the
;;;; target Lisp system.
;;;;
;;;; As explained by Rob MacLachlan on the CMU CL mailing list Wed, 06
;;;; Jan 1999 11:05:02 -0500, this cold load generator more or less
;;;; fakes up static function linking. I.e. it makes sure that all the
;;;; DEFUN-defined functions in the fasl files it reads are bound to the
;;;; corresponding symbols before execution starts. It doesn't do
;;;; anything to initialize variable values; instead it just arranges
;;;; for !COLD-INIT to be called at cold load time. !COLD-INIT is
;;;; responsible for explicitly initializing anything which has to be
;;;; initialized early before it transfers control to the ordinary
;;;; top level forms.
;;;;
;;;; (In CMU CL, and in SBCL as of 0.6.9 anyway, functions not defined
;;;; by DEFUN aren't set up specially by GENESIS.)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!FASL")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (use-package "SB-COREFILE")) ; not SB!COREFILE

(defconstant core-magic
  (logior (ash (sb!xc:char-code #\S) 24)
          (ash (sb!xc:char-code #\B) 16)
          (ash (sb!xc:char-code #\C) 8)
          (sb!xc:char-code #\L)))

(defun round-up (number size)
  "Round NUMBER up to be an integral multiple of SIZE."
  (* size (ceiling number size)))

;;;; implementing the concept of "vector" in (almost) portable
;;;; Common Lisp
;;;;
;;;; "If you only need to do such simple things, it doesn't really
;;;; matter which language you use." -- _ANSI Common Lisp_, p. 1, Paul
;;;; Graham (evidently not considering the abstraction "vector" to be
;;;; such a simple thing:-)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +smallvec-length+
    (expt 2 16)))

;;; an element of a BIGVEC -- a vector small enough that we have
;;; a good chance of it being portable to other Common Lisps
(deftype smallvec ()
  `(simple-array (unsigned-byte 8) (,+smallvec-length+)))

(defun make-smallvec ()
  (make-array +smallvec-length+ :element-type '(unsigned-byte 8)
              :initial-element 0))

;;; a big vector, implemented as a vector of SMALLVECs
;;;
;;; KLUDGE: This implementation seems portable enough for our
;;; purposes, since realistically every modern implementation is
;;; likely to support vectors of at least 2^16 elements. But if you're
;;; masochistic enough to read this far into the contortions imposed
;;; on us by ANSI and the Lisp community, for daring to use the
;;; abstraction of a large linearly addressable memory space, which is
;;; after all only directly supported by the underlying hardware of at
;;; least 99% of the general-purpose computers in use today, then you
;;; may be titillated to hear that in fact this code isn't really
;;; portable, because as of sbcl-0.7.4 we need somewhat more than
;;; 16Mbytes to represent a core, and ANSI only guarantees that
;;; ARRAY-DIMENSION-LIMIT is not less than 1024. -- WHN 2002-06-13
(defstruct (bigvec (:constructor %make-bigvec (&optional outer-vector)))
  (outer-vector (vector (make-smallvec)) :type (vector smallvec)))
(defun make-bigvec (&optional (min-size 0))
  (expand-bigvec (%make-bigvec) min-size))

;;; analogous to SVREF, but into a BIGVEC
(defun bvref (bigvec index)
  (multiple-value-bind (outer-index inner-index)
      (floor index +smallvec-length+)
    (aref (the smallvec
            (svref (bigvec-outer-vector bigvec) outer-index))
          inner-index)))
(defun (setf bvref) (new-value bigvec index)
  (multiple-value-bind (outer-index inner-index)
      (floor index +smallvec-length+)
    (setf (aref (the (simple-array (unsigned-byte 8) (*))
                  (svref (bigvec-outer-vector bigvec) outer-index))
                inner-index)
          new-value)))

;;; analogous to LENGTH, but for a BIGVEC
;;;
;;; the length of BIGVEC, measured in the number of BVREFable bytes it
;;; can hold
(defun bvlength (bigvec)
  (* (length (bigvec-outer-vector bigvec))
     +smallvec-length+))

;;; analogous to WRITE-SEQUENCE, but for a BIGVEC
(defun write-bigvec-as-sequence (bigvec stream &key (start 0) end pad-with-zeros)
  (let* ((bvlength (bvlength bigvec))
         (data-length (min (or end bvlength) bvlength)))
    (loop for i of-type index from start below data-length do
      (write-byte (bvref bigvec i)
                  stream))
    (when (and pad-with-zeros (< bvlength data-length))
      (loop repeat (- data-length bvlength) do (write-byte 0 stream)))))

;;; analogous to READ-SEQUENCE-OR-DIE, but for a BIGVEC
(defun read-bigvec-as-sequence-or-die (bigvec stream &key (start 0) end)
  (loop for i of-type index from start below (or end (bvlength bigvec)) do
        (setf (bvref bigvec i)
              (read-byte stream))))

;;; Grow BIGVEC (exponentially, so that large increases in size have
;;; asymptotic logarithmic cost per byte).
(defun expand-bigvec (bigvec required-length)
  (loop
    (when (>= (bvlength bigvec) required-length)
      (return bigvec))
    (let* ((old-outer-vector (bigvec-outer-vector bigvec))
           (length-old-outer-vector (length old-outer-vector))
           (new-outer-vector (make-array (* 2 length-old-outer-vector))))
      (replace new-outer-vector old-outer-vector)
      (loop for i from length-old-outer-vector below (length new-outer-vector)
            do (setf (svref new-outer-vector i) (make-smallvec)))
      (setf (bigvec-outer-vector bigvec)
            new-outer-vector))))

;;;; looking up bytes and multi-byte values in a BIGVEC (considering
;;;; it as an image of machine memory on the cross-compilation target)

;;; BVREF-32 and friends. These are like SAP-REF-n, except that
;;; instead of a SAP we use a BIGVEC.
(macrolet ((make-bvref-n (n)
            (let ((name (intern (format nil "BVREF-~A" n)))
                  (le-octet-indices
                   (loop with n-octets = (/ n 8)
                         for i from 0 below n-octets
                         collect `(+ byte-index #!+big-endian ,(- n-octets i 1)
                                                #!-big-endian ,i))))
              `(progn
                 (defun ,name (bigvec byte-index)
                   (logior ,@(loop for index in le-octet-indices
                                   for i from 0
                                   collect `(ash (bvref bigvec ,index) ,(* i 8)))))
                 (defun (setf ,name) (new-value bigvec byte-index)
                   ;; We don't carefully distinguish between signed and unsigned,
                   ;; since there's only one setter function per byte size.
                   (declare (type (or (signed-byte ,n) (unsigned-byte ,n))
                                  new-value))
                   (setf ,@(loop for index in le-octet-indices
                                 for i from 0
                          append `((bvref bigvec ,index)
                                   (ldb (byte 8 ,(* i 8)) new-value)))))))))
  (make-bvref-n 8)
  (make-bvref-n 16)
  (make-bvref-n 32)
  (make-bvref-n 64))

;; lispobj-sized word, whatever that may be
;; hopefully nobody ever wants a 128-bit SBCL...
(macrolet ((acc (bv index) `(#!+64-bit bvref-64 #!-64-bit bvref-32 ,bv ,index)))
  (defun (setf bvref-word) (new-val bytes index) (setf (acc bytes index) new-val))
  (defun bvref-word (bytes index) (acc bytes index)))

;;;; representation of spaces in the core

;;; If there is more than one dynamic space in memory (i.e., if a
;;; copying GC is in use), then only the active dynamic space gets
;;; dumped to core.
(defvar *dynamic*)
(defvar *static*)
(defvar *read-only*)

#!+immobile-space
(progn
  (defvar *immobile-fixedobj*)
  (defvar *immobile-varyobj*)
  (defvar *immobile-space-map* nil))

(defconstant max-core-space-id (+ 3 #!+immobile-space 2))

;;; a GENESIS-time representation of a memory space (e.g. read-only
;;; space, dynamic space, or static space)
(defstruct (gspace (:constructor %make-gspace)
                   (:copier nil))
  ;; name and identifier for this GSPACE
  (name (missing-arg) :type symbol :read-only t)
  (identifier (missing-arg) :type fixnum :read-only t)
  ;; the word address where the data will be loaded
  (word-address (missing-arg) :type unsigned-byte :read-only t)
  ;; the gspace contents as a BIGVEC
  (data (make-bigvec) :type bigvec :read-only t)
  (objects nil)
  ;; the index of the next unwritten word (i.e. chunk of
  ;; SB!VM:N-WORD-BYTES bytes) in DATA, or equivalently the number of
  ;; words actually written in DATA. In order to convert to an actual
  ;; index into DATA, thus must be multiplied by SB!VM:N-WORD-BYTES.
  (free-word-index 0))

(defun gspace-byte-address (gspace)
  (ash (gspace-word-address gspace) sb!vm:word-shift))

(cl:defmethod print-object ((gspace gspace) stream)
  (print-unreadable-object (gspace stream :type t)
    (format stream "@#x~X ~S" (gspace-byte-address gspace) (gspace-name gspace))))

(defun make-gspace (name identifier byte-address)
  ;; Genesis should be agnostic of space alignment except in so far as it must
  ;; be a multiple of the backend page size. We used to care more, in that
  ;; descriptor-bits were composed of a high half and low half for the
  ;; questionable motive of caring about fixnum-ness of the halves,
  ;; despite the wonderful abstraction INTEGER that transparently becomes
  ;; a BIGNUM if the host's fixnum is limited in size.
  ;; So it's not clear whether this test belongs here, because if we do need it,
  ;; then it best belongs where we assign space addresses in the first place.
  (let ((target-space-alignment sb!c:+backend-page-bytes+))
    (unless (zerop (rem byte-address target-space-alignment))
      (error "The byte address #X~X is not aligned on a #X~X-byte boundary."
             byte-address target-space-alignment)))
  (%make-gspace :name name
                :identifier identifier
                ;; Track object boundaries if a page table will be produced.
                :objects (if (= identifier dynamic-core-space-id)
                             (make-array 5000 :fill-pointer 0 :adjustable t))
                :word-address (ash byte-address (- sb!vm:word-shift))))

;;;; representation of descriptors

(declaim (inline is-fixnum-lowtag))
(defun is-fixnum-lowtag (lowtag)
  (zerop (logand lowtag sb!vm:fixnum-tag-mask)))

(defun is-other-immediate-lowtag (lowtag)
  ;; The other-immediate lowtags are similar to the fixnum lowtags, in
  ;; that they have an "effective length" that is shorter than is used
  ;; for the pointer lowtags.  Unlike the fixnum lowtags, however, the
  ;; other-immediate lowtags are always effectively two bits wide.
  (= (logand lowtag 3) sb!vm:other-immediate-0-lowtag))

(defstruct (descriptor
            (:constructor make-descriptor (bits &optional gspace word-offset))
            (:copier nil))
  ;; the GSPACE that this descriptor is allocated in, or NIL if not set yet.
  (gspace nil :type (or gspace null))
  ;; the offset in words from the start of GSPACE, or NIL if not set yet
  (word-offset nil :type (or sb!vm:word null))
  (bits 0 :read-only t :type (unsigned-byte #.sb!vm:n-machine-word-bits)))

(declaim (inline descriptor=))
(defun descriptor= (a b) (eql (descriptor-bits a) (descriptor-bits b)))

(defun make-random-descriptor (bits)
  (make-descriptor (logand bits sb!ext:most-positive-word)))

(declaim (inline descriptor-lowtag))
(defun descriptor-lowtag (des)
  "the lowtag bits for DES"
  (logand (descriptor-bits des) sb!vm:lowtag-mask))

(defmethod print-object ((des descriptor) stream)
  (let ((gspace (descriptor-gspace des))
        (bits (descriptor-bits des))
        (lowtag (descriptor-lowtag des)))
    (print-unreadable-object (des stream :type t)
      (cond ((eq gspace :load-time-value)
             (format stream "for LTV ~D" (descriptor-word-offset des)))
            ((is-fixnum-lowtag lowtag)
             (format stream "for fixnum: ~W" (descriptor-fixnum des)))
            ((is-other-immediate-lowtag lowtag)
             (format stream
                     "for other immediate: #X~X, type #b~8,'0B"
                     (ash bits (- sb!vm:n-widetag-bits))
                     (logand bits sb!vm:widetag-mask)))
            (t
             (format stream
                     "for pointer: #X~X, lowtag #b~v,'0B, ~A"
                     (logandc2 bits sb!vm:lowtag-mask)
                     sb!vm:n-lowtag-bits lowtag
                     (if gspace (gspace-name gspace) "unknown")))))))

;;; Return a descriptor for a block of LENGTH bytes out of GSPACE. The
;;; free word index is boosted as necessary, and if additional memory
;;; is needed, we grow the GSPACE. The descriptor returned is a
;;; pointer of type LOWTAG.
(defun allocate-cold-descriptor (gspace length lowtag &optional page-attributes)
  (let* ((word-index
          (gspace-claim-n-bytes gspace length page-attributes))
         (ptr (+ (gspace-word-address gspace) word-index)))
    #!+gencgc
    (when (gspace-objects gspace)
      (let ((this (ash word-index sb!vm:word-shift))
            (next (ash (gspace-free-word-index gspace) sb!vm:word-shift))
            (objects (gspace-objects gspace)))
        (flet ((page-index (offset) (floor offset sb!vm:gencgc-card-bytes)))
          ;; Record this object's byte offset unless it is unimportant
          ;; for finding page scan start offsets. Define "unimportant" as:
          ;; starts and ends on same page, and the preceding object does too.
          ;; This records more objects than are strictly necessary,
          ;; but it makes life simpler.
          (unless (and (plusp (length objects))
                       (= (page-index (aref objects (1- (length objects))))
                          (page-index (1- this))
                          (page-index this)
                          (page-index (1- next))))
            (vector-push-extend this objects)))))
    (make-descriptor (logior (ash ptr sb!vm:word-shift) lowtag)
                     gspace
                     word-index)))

(defun gspace-claim-n-words (gspace n-words)
  (let* ((old-free-word-index (gspace-free-word-index gspace))
         (new-free-word-index (+ old-free-word-index n-words)))
    ;; Grow GSPACE as necessary
    (expand-bigvec (gspace-data gspace) (* new-free-word-index sb!vm:n-word-bytes))
    ;; Now that GSPACE is big enough, we can meaningfully grab a chunk of it.
    (setf (gspace-free-word-index gspace) new-free-word-index)
    old-free-word-index))

;; layoutp is true if we need to force objects on this page to LAYOUT-ALIGN
;; boundaries. This doesn't need to be generalized - everything of type
;; INSTANCE is either on its natural alignment, or the layout alignment.
;; [See doc/internals-notes/compact-instance for why you might want it at all]
;; PAGE-KIND is a heuristic for placement of symbols
;; based on being interned/uninterned/likely-special-variable.
(defun make-page-attributes (layoutp page-kind)
  (declare (type (or null (integer 0 3)) page-kind))
  (logior (ash (or page-kind 0) 1) (if layoutp 1 0)))

(defun gspace-claim-n-bytes (gspace specified-n-bytes page-attributes)
  (declare (ignorable page-attributes))
  (let* ((n-bytes (round-up specified-n-bytes (ash 1 sb!vm:n-lowtag-bits)))
         (n-words (ash n-bytes (- sb!vm:word-shift))))
    (aver (evenp n-words))
    (cond #!+immobile-space
          ((eq gspace *immobile-fixedobj*)
           (aver page-attributes)
           ;; An immobile fixedobj page can only have one value of object-spacing
           ;; and size for all objects on it. Different widetags are ok.
           (let* ((key (cons specified-n-bytes page-attributes))
                  (found (cdr (assoc key *immobile-space-map* :test 'equal)))
                  (page-n-words (/ sb!vm:immobile-card-bytes sb!vm:n-word-bytes)))
             (unless found ; grab one whole GC page from immobile space
               (let ((free-word-index
                      (gspace-claim-n-words gspace page-n-words)))
                 (setf found (cons 0 free-word-index))
                 (push (cons key found) *immobile-space-map*)))
             (destructuring-bind (page-word-index . page-base-index) found
               (let ((next-word
                      (+ page-word-index
                         (if (logbitp 0 page-attributes)
                             (/ sb!vm:layout-align sb!vm:n-word-bytes)
                             n-words))))
                 (if (> next-word (- page-n-words n-words))
                     ;; no more objects fit on this page
                     (setf *immobile-space-map*
                           (delete key *immobile-space-map* :key 'car :test 'equal))
                     (setf (car found) next-word)))
               (+ page-word-index page-base-index))))
          (t
           (gspace-claim-n-words gspace n-words)))))

(defun descriptor-fixnum (des)
  (unless (is-fixnum-lowtag (descriptor-lowtag des))
    (error "descriptor-fixnum called on non-fixnum ~S" des))
  (let* ((descriptor-bits (descriptor-bits des))
         (bits (ash descriptor-bits (- sb!vm:n-fixnum-tag-bits))))
    (if (logbitp (1- sb!vm:n-word-bits) descriptor-bits)
        (logior bits (ash -1 (1+ sb!vm:n-positive-fixnum-bits)))
        bits)))

(defun descriptor-word-sized-integer (des)
  ;; Extract an (unsigned-byte 32), from either its fixnum or bignum
  ;; representation.
  (let ((lowtag (descriptor-lowtag des)))
    (if (is-fixnum-lowtag lowtag)
        (make-random-descriptor (descriptor-fixnum des))
        (read-wordindexed des 1))))

;;; common idioms
(defun descriptor-mem (des)
  (gspace-data (descriptor-intuit-gspace des)))
(defun descriptor-byte-offset (des)
  (ash (descriptor-word-offset des) sb!vm:word-shift))

;;; If DESCRIPTOR-GSPACE is already set, just return that. Otherwise,
;;; figure out a GSPACE which corresponds to DES, set it into
;;; (DESCRIPTOR-GSPACE DES), set a consistent value into
;;; (DESCRIPTOR-WORD-OFFSET DES), and return the GSPACE.
(declaim (ftype (function (descriptor) gspace) descriptor-intuit-gspace))
(defun descriptor-intuit-gspace (des)
  (or (descriptor-gspace des)

      ;; gspace wasn't set, now we have to search for it.
      (let* ((lowtag (descriptor-lowtag des))
             (abs-word-addr (ash (- (descriptor-bits des) lowtag)
                                 (- sb!vm:word-shift))))

        ;; Non-pointer objects don't have a gspace.
        (unless (or (eql lowtag sb!vm:fun-pointer-lowtag)
                    (eql lowtag sb!vm:instance-pointer-lowtag)
                    (eql lowtag sb!vm:list-pointer-lowtag)
                    (eql lowtag sb!vm:other-pointer-lowtag))
          (error "don't even know how to look for a GSPACE for ~S" des))

        (dolist (gspace (list *dynamic* *static* *read-only*
                              #!+immobile-space *immobile-fixedobj*
                              #!+immobile-space *immobile-varyobj*)
                 (error "couldn't find a GSPACE for ~S" des))
          ;; Bounds-check the descriptor against the allocated area
          ;; within each gspace.
          (when (and (<= (gspace-word-address gspace)
                         abs-word-addr
                         (+ (gspace-word-address gspace)
                            (gspace-free-word-index gspace))))
            ;; Update the descriptor with the correct gspace and the
            ;; offset within the gspace and return the gspace.
            (setf (descriptor-word-offset des)
                  (- abs-word-addr (gspace-word-address gspace)))
            (return (setf (descriptor-gspace des) gspace)))))))

(defun %fixnum-descriptor-if-possible (num)
  (and (typep num '(signed-byte #.sb!vm:n-fixnum-bits))
       (make-random-descriptor (ash num sb!vm:n-fixnum-tag-bits))))

(defun make-fixnum-descriptor (num)
  (or (%fixnum-descriptor-if-possible num)
      (error "~W is too big for a fixnum." num)))

(defun make-other-immediate-descriptor (data type)
  (make-descriptor (logior (ash data sb!vm:n-widetag-bits) type)))

(defun make-character-descriptor (data)
  (make-other-immediate-descriptor data sb!vm:character-widetag))


;;;; miscellaneous variables and other noise

;;; a numeric value to be returned for undefined foreign symbols, or NIL if
;;; undefined foreign symbols are to be treated as an error.
;;; (In the first pass of GENESIS, needed to create a header file before
;;; the C runtime can be built, various foreign symbols will necessarily
;;; be undefined, but we don't need actual values for them anyway, and
;;; we can just use 0 or some other placeholder. In the second pass of
;;; GENESIS, all foreign symbols should be defined, so any undefined
;;; foreign symbol is a problem.)
;;;
;;; KLUDGE: It would probably be cleaner to rewrite GENESIS so that it
;;; never tries to look up foreign symbols in the first place unless
;;; it's actually creating a core file (as in the second pass) instead
;;; of using this hack to allow it to go through the motions without
;;; causing an error. -- WHN 20000825
(defvar *foreign-symbol-placeholder-value*)

;;; a handle on the trap object
(defvar *unbound-marker*
  (make-other-immediate-descriptor 0 sb!vm:unbound-marker-widetag))

;;; a handle on the NIL object
(defvar *nil-descriptor*)

;;; the head of a list of TOPLEVEL-THINGs describing stuff to be done
;;; when the target Lisp starts up
;;;
;;; Each TOPLEVEL-THING can be a function to be executed or a fixup or
;;; loadtime value, represented by (CONS KEYWORD ..).
(declaim (special *!cold-toplevels* *!cold-defconstants*
                  *!cold-defuns* *cold-methods*))


;;;; miscellaneous stuff to read and write the core memory

;; Like above, but the list is held in the target's image of the host symbol,
;; not the host's value of the symbol.
(defun cold-target-push (cold-thing host-symbol)
  (cold-set host-symbol (cold-cons cold-thing (cold-symbol-value host-symbol))))

(declaim (ftype (function (descriptor sb!vm:word) descriptor) read-wordindexed))
(macrolet ((read-bits ()
             `(bvref-word (descriptor-mem address)
                          (ash (+ index (descriptor-word-offset address))
                               sb!vm:word-shift))))
  (defun read-bits-wordindexed (address index)
    (read-bits))
  (defun read-wordindexed (address index)
  "Return the value which is displaced by INDEX words from ADDRESS."
    (make-random-descriptor (read-bits))))

(defstruct (ltv-patch (:copier nil) (:constructor make-ltv-patch (index)))
  (index 0 :read-only t))
(declaim (ftype (function (descriptor sb!vm:word (or symbol descriptor ltv-patch)))
                write-wordindexed))
(macrolet ((write-bits (bits)
             `(setf (bvref-word (descriptor-mem address)
                                (ash (+ index (descriptor-word-offset address))
                                     sb!vm:word-shift))
                    ,bits)))
  (defun write-wordindexed (address index value)
    "Write VALUE displaced INDEX words from ADDRESS."
    (write-bits
     (cond ((ltv-patch-p value)
            (if (= (logand (read-bits-wordindexed address 0) sb!vm:widetag-mask)
                   sb!vm:code-header-widetag)
                (push (cold-list (cold-intern :load-time-value-fixup)
                                 address
                                 (number-to-core index)
                                 (number-to-core (ltv-patch-index value)))
                      *!cold-toplevels*)
                (bug "Can't patch load-time-value into ~S" address))
            sb!vm:unbound-marker-widetag)
          (t
           ;; If we're passed a symbol as a value then it needs to be interned.
           (descriptor-bits (cond ((symbolp value) (cold-intern value))
                                  (t value)))))))

  (defun write-wordindexed/raw (address index bits)
    (declare (type descriptor address) (type sb!vm:word index)
             (type (or sb!vm:word sb!vm:signed-word) bits))
    (write-bits (logand bits sb!ext:most-positive-word))))

;;;; allocating images of primitive objects in the cold core

(defun write-header-word (des header-data widetag)
  ;; In immobile space, all objects start life as pseudo-static as if by 'save'.
  (let ((gen #!+gencgc (if (or #!+immobile-space
                               (let ((gspace (descriptor-gspace des)))
                                 (or (eq gspace *immobile-fixedobj*)
                                     (eq gspace *immobile-varyobj*))))
                           sb!vm:+pseudo-static-generation+
                         0)
             #!-gencgc 0))
    (write-wordindexed/raw des 0
                           (logior (ash (logior (ash gen 16) header-data)
                                        sb!vm:n-widetag-bits) widetag))))

(defun set-header-data (object data)
  (write-header-word object data (ldb (byte sb!vm:n-widetag-bits 0)
                                      (read-bits-wordindexed object 0)))
  object) ; return the object itself, like SB!KERNEL:SET-HEADER-DATA

(defun get-header-data (object)
  (ash (read-bits-wordindexed object 0) (- sb!vm:n-widetag-bits)))

;;; There are three kinds of blocks of memory in the type system:
;;; * Boxed objects (cons cells, structures, etc): These objects have no
;;;   header as all slots, or almost all slots, are descriptors.
;;;   This also includes code objects, which are mostly non-descriptors.
;;; * Unboxed objects (bignums): There is a single header word that contains
;;;   the length.
;;; * Vector objects: There is a header word with the type, then a word for
;;;   the length, then the data.
(defun allocate-object (gspace length lowtag &optional layoutp)
  "Allocate LENGTH words in GSPACE and return a new descriptor of type LOWTAG
  pointing to them."
  (allocate-cold-descriptor gspace (ash length sb!vm:word-shift) lowtag
                            (make-page-attributes layoutp 0)))
(defun allocate-header+object (gspace length widetag)
  "Allocate LENGTH words plus a header word in GSPACE and
  return an ``other-pointer'' descriptor to them. Initialize the header word
  with the resultant length and WIDETAG."
  (let ((des (allocate-cold-descriptor
              gspace (ash (1+ length) sb!vm:word-shift)
              sb!vm:other-pointer-lowtag
              (make-page-attributes nil 0))))
    (write-header-word des length widetag)
    des))
(defun allocate-vector-object (gspace element-bits length widetag)
  "Allocate LENGTH units of ELEMENT-BITS size plus a header plus a length slot in
  GSPACE and return an ``other-pointer'' descriptor to them. Initialize the
  header word with WIDETAG and the length slot with LENGTH."
  ;; ALLOCATE-COLD-DESCRIPTOR will take any rational number of bytes
  ;; and round up to a double-word. This doesn't need to use CEILING.
  (let* ((bytes (/ (* element-bits length) sb!vm:n-byte-bits))
         (des (allocate-cold-descriptor gspace
                                        (+ bytes (* 2 sb!vm:n-word-bytes))
                                        sb!vm:other-pointer-lowtag)))
    (write-header-word des 0 widetag)
    (write-wordindexed des
                       sb!vm:vector-length-slot
                       (make-fixnum-descriptor length))
    des))

;;; the hosts's representation of LAYOUT-of-LAYOUT
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *host-layout-of-layout* (find-layout 'layout)))

(defun cold-layout-length (layout)
  (descriptor-fixnum (read-slot layout *host-layout-of-layout* :length)))
(defun cold-layout-depthoid (layout)
  (descriptor-fixnum (read-slot layout *host-layout-of-layout* :depthoid)))

;; Make a structure and set the header word and layout.
;; LAYOUT-LENGTH is as returned by the like-named function.
(defun allocate-struct
    (gspace layout &optional (layout-length (cold-layout-length layout))
                             is-layout)
  ;; Count +1 for the header word when allocating.
  (let ((des (allocate-object gspace (1+ layout-length)
                              sb!vm:instance-pointer-lowtag is-layout)))
    ;; Length as stored in the header is the exact number of useful words
    ;; that follow, as is customary. A padding word, if any is not "useful"
    (write-header-word des
                       (logior layout-length
                               #!+compact-instance-header
                               (if layout (ash (descriptor-bits layout) 24) 0))
                       sb!vm:instance-widetag)
    #!-compact-instance-header
    (write-wordindexed des sb!vm:instance-slots-offset layout)
    des))

;;;; copying simple objects into the cold core

(defun base-string-to-core (string &optional (gspace *dynamic*))
  "Copy STRING (which must only contain STANDARD-CHARs) into the cold
core and return a descriptor to it."
  ;; (Remember that the system convention for storage of strings leaves an
  ;; extra null byte at the end to aid in call-out to C.)
  (let* ((length (length string))
         (des (allocate-vector-object gspace
                                      sb!vm:n-byte-bits
                                      (1+ length)
                                      sb!vm:simple-base-string-widetag))
         (bytes (gspace-data gspace))
         (offset (+ (* sb!vm:vector-data-offset sb!vm:n-word-bytes)
                    (descriptor-byte-offset des))))
    (write-wordindexed des
                       sb!vm:vector-length-slot
                       (make-fixnum-descriptor length))
    (dotimes (i length)
      (setf (bvref bytes (+ offset i))
            (sb!xc:char-code (aref string i))))
    (setf (bvref bytes (+ offset length))
          0) ; null string-termination character for C
    des))

(defun base-string-from-core (descriptor)
  (let* ((len (descriptor-fixnum
               (read-wordindexed descriptor sb!vm:vector-length-slot)))
         (str (make-string len))
         (bytes (descriptor-mem descriptor)))
    (dotimes (i len str)
      (setf (aref str i)
            (code-char (bvref bytes
                              (+ (descriptor-byte-offset descriptor)
                                 (* sb!vm:vector-data-offset sb!vm:n-word-bytes)
                                 i)))))))

(defun bignum-to-core (n)
  "Copy a bignum to the cold core."
  (let* ((words (ceiling (1+ (integer-length n)) sb!vm:n-word-bits))
         (handle
          (allocate-header+object *dynamic* words sb!vm:bignum-widetag)))
    (declare (fixnum words))
    (do ((index 1 (1+ index))
         (remainder n (ash remainder (- sb!vm:n-word-bits))))
        ((> index words)
         (unless (zerop (integer-length remainder))
           ;; FIXME: Shouldn't this be a fatal error?
           (warn "~W words of ~W were written, but ~W bits were left over."
                 words n remainder)))
      (write-wordindexed/raw handle index
                             (ldb (byte sb!vm:n-word-bits 0) remainder)))
    handle))

(defun bignum-from-core (descriptor)
  (let ((n-words (get-header-data descriptor))
        (val 0))
    (dotimes (i n-words val)
      (let ((bits (read-bits-wordindexed descriptor
                                         (+ i sb!vm:bignum-digits-offset))))
        ;; sign-extend the highest word
        (when (and (= i (1- n-words)) (logbitp (1- sb!vm:n-word-bits) bits))
          (setq bits (dpb bits (byte sb!vm:n-word-bits 0) -1)))
        (setq val (logior (ash bits (* i sb!vm:n-word-bits)) val))))))

(defun number-pair-to-core (first second type)
  "Makes a number pair of TYPE (ratio or complex) and fills it in."
  (let ((des (allocate-header+object *dynamic* 2 type)))
    (write-wordindexed des 1 first)
    (write-wordindexed des 2 second)
    des))

(defun write-double-float-bits (address index x)
  (let ((high-bits (double-float-high-bits x))
        (low-bits (double-float-low-bits x)))
    (ecase sb!vm:n-word-bits
      (32
       (ecase sb!c:*backend-byte-order*
         (:little-endian
          (write-wordindexed/raw address index low-bits)
          (write-wordindexed/raw address (1+ index) high-bits))
         (:big-endian
          (write-wordindexed/raw address index high-bits)
          (write-wordindexed/raw address (1+ index) low-bits))))
      (64
       (let ((bits (ecase sb!c:*backend-byte-order*
                     (:little-endian (logior low-bits (ash high-bits 32)))
                     ;; Just guessing.
                     #+nil (:big-endian (logior (logand high-bits #xffffffff)
                                                (ash low-bits 32))))))
         (write-wordindexed/raw address index bits))))

    address))

(defun float-to-core (x)
  (etypecase x
    (single-float
     ;; 64-bit platforms have immediate single-floats.
     #!+64-bit
     (make-random-descriptor (logior (ash (single-float-bits x) 32)
                                     sb!vm:single-float-widetag))
     #!-64-bit
     (let ((des (allocate-header+object *dynamic*
                                         (1- sb!vm:single-float-size)
                                         sb!vm:single-float-widetag)))
       (write-wordindexed/raw des sb!vm:single-float-value-slot
                              (single-float-bits x))
       des))
    (double-float
     (let ((des (allocate-header+object *dynamic*
                                         (1- sb!vm:double-float-size)
                                         sb!vm:double-float-widetag)))
       (write-double-float-bits des sb!vm:double-float-value-slot x)))))

(defun complex-single-float-to-core (num)
  (declare (type (complex single-float) num))
  (let ((des (allocate-header+object *dynamic*
                                      (1- sb!vm:complex-single-float-size)
                                      sb!vm:complex-single-float-widetag)))
    #!-64-bit
    (progn
      (write-wordindexed/raw des sb!vm:complex-single-float-real-slot
                             (single-float-bits (realpart num)))
      (write-wordindexed/raw des sb!vm:complex-single-float-imag-slot
                             (single-float-bits (imagpart num))))
    #!+64-bit
    (write-wordindexed/raw
     des sb!vm:complex-single-float-data-slot
     (logior (ldb (byte 32 0) (single-float-bits (realpart num)))
             (ash (single-float-bits (imagpart num)) 32)))
    des))

(defun complex-double-float-to-core (num)
  (declare (type (complex double-float) num))
  (let ((des (allocate-header+object *dynamic*
                                      (1- sb!vm:complex-double-float-size)
                                      sb!vm:complex-double-float-widetag)))
    (write-double-float-bits des sb!vm:complex-double-float-real-slot
                             (realpart num))
    (write-double-float-bits des sb!vm:complex-double-float-imag-slot
                             (imagpart num))))

;;; Copy the given number to the core.
(defun number-to-core (number)
  (typecase number
    (integer (or (%fixnum-descriptor-if-possible number)
                 (bignum-to-core number)))
    (ratio (number-pair-to-core (number-to-core (numerator number))
                                (number-to-core (denominator number))
                                sb!vm:ratio-widetag))
    ((complex single-float) (complex-single-float-to-core number))
    ((complex double-float) (complex-double-float-to-core number))
    #!+long-float
    ((complex long-float)
     (error "~S isn't a cold-loadable number at all!" number))
    (complex (number-pair-to-core (number-to-core (realpart number))
                                  (number-to-core (imagpart number))
                                  sb!vm:complex-widetag))
    (float (float-to-core number))
    (t (error "~S isn't a cold-loadable number at all!" number))))

;;; Allocate a cons cell in GSPACE and fill it in with CAR and CDR.
(defun cold-cons (car cdr &optional (gspace *dynamic*))
  (let ((dest (allocate-object gspace 2 sb!vm:list-pointer-lowtag)))
    (write-wordindexed dest sb!vm:cons-car-slot car)
    (write-wordindexed dest sb!vm:cons-cdr-slot cdr)
    dest))
(defun list-to-core (list)
  (let ((head *nil-descriptor*)
        (tail nil))
    ;; A recursive algorithm would have the first cons at the highest
    ;; address. This way looks nicer when viewed in ldb.
    (loop
     (unless list (return head))
     (let ((cons (cold-cons (pop list) *nil-descriptor*)))
       (if tail (cold-rplacd tail cons) (setq head cons))
       (setq tail cons)))))
(defun cold-list (&rest args) (list-to-core args))
(defun cold-list-length (list) ; but no circularity detection
  ;; a recursive implementation uses too much stack for some Lisps
  (let ((n 0))
    (loop (if (cold-null list) (return n))
          (incf n)
          (setq list (cold-cdr list)))))

;;; Make a simple-vector on the target that holds the specified
;;; OBJECTS, and return its descriptor.
;;; This is really "vectorify-list-into-core" but that's too wordy,
;;; so historically it was "vector-in-core" which is a fine name.
(defun vector-in-core (objects &optional (gspace *dynamic*))
  (let* ((size (length objects))
         (result (allocate-vector-object gspace sb!vm:n-word-bits size
                                         sb!vm:simple-vector-widetag)))
    (dotimes (index size result)
      (write-wordindexed result (+ index sb!vm:vector-data-offset)
                         (pop objects)))))

(defun cold-svset (vector index value)
  (let ((i (if (integerp index) index (descriptor-fixnum index))))
    (write-wordindexed vector (+ i sb!vm:vector-data-offset) value)))

(setf (get 'vector :sb-cold-funcall-handler/for-value)
      (lambda (&rest args) (vector-in-core args)))

(declaim (inline cold-vector-len cold-svref))
(defun cold-vector-len (vector)
  (descriptor-fixnum (read-wordindexed vector sb!vm:vector-length-slot)))
(defun cold-svref (vector i)
  (read-wordindexed vector (+ (if (integerp i) i (descriptor-fixnum i))
                              sb!vm:vector-data-offset)))
(defun cold-vector-elements-eq (a b)
  (and (eql (cold-vector-len a) (cold-vector-len b))
       (dotimes (k (cold-vector-len a) t)
         (unless (descriptor= (cold-svref a k) (cold-svref b k))
           (return nil)))))
(defun vector-from-core (descriptor &optional (transform #'identity))
  (let* ((len (cold-vector-len descriptor))
         (vector (make-array len)))
    (dotimes (i len vector)
      (setf (aref vector i) (funcall transform (cold-svref descriptor i))))))

;;;; symbol magic

;; Simulate *FREE-TLS-INDEX*. This is a word count, not a displacement.
(defvar *genesis-tls-counter* sb!thread::tls-index-start)

#!+sb-thread
(progn
  ;; Assign SYMBOL the tls-index INDEX. SYMBOL must be a descriptor.
  ;; This is a backend support routine, but the style within this file
  ;; is to conditionalize by the target features.
  (defun cold-assign-tls-index (symbol index)
    #!+64-bit
    (write-wordindexed/raw
     symbol 0 (logior (ash index 32) (read-bits-wordindexed symbol 0)))
    #!-64-bit
    (write-wordindexed/raw symbol sb!vm:symbol-tls-index-slot index))

  ;; Return SYMBOL's tls-index,
  ;; choosing a new index if it doesn't have one yet.
  (defun ensure-symbol-tls-index (symbol)
    (let* ((cold-sym (cold-intern symbol))
           (tls-index
            #!+64-bit
            (ldb (byte 32 32) (read-bits-wordindexed cold-sym 0))
            #!-64-bit
            (read-bits-wordindexed cold-sym sb!vm:symbol-tls-index-slot)))
      (unless (plusp tls-index)
        (let ((next (prog1 *genesis-tls-counter* (incf *genesis-tls-counter*))))
          (setq tls-index (ash next sb!vm:word-shift))
          (cold-assign-tls-index cold-sym tls-index)))
      tls-index)))

(defvar *cold-symbol-gspace* (or #!+immobile-space '*immobile-fixedobj* '*dynamic*))

;;; Allocate (and initialize) a symbol.
(defun allocate-symbol (name &key (gspace (symbol-value *cold-symbol-gspace*)))
  (declare (simple-string name))
  (let ((symbol (allocate-header+object gspace (1- sb!vm:symbol-size)
                                        sb!vm:symbol-widetag)))
    (write-wordindexed symbol sb!vm:symbol-value-slot *unbound-marker*)
    (write-wordindexed symbol sb!vm:symbol-hash-slot (make-fixnum-descriptor 0))
    (write-wordindexed symbol sb!vm:symbol-info-slot *nil-descriptor*)
    (write-wordindexed symbol sb!vm:symbol-name-slot
                       (set-readonly (base-string-to-core name *dynamic*)))
    (write-wordindexed symbol sb!vm:symbol-package-slot *nil-descriptor*)
    symbol))

;;; Set the cold symbol value of SYMBOL-OR-SYMBOL-DES, which can be either a
;;; descriptor of a cold symbol or (in an abbreviation for the
;;; most common usage pattern) an ordinary symbol, which will be
;;; automatically cold-interned.
(defun cold-set (symbol-or-symbol-des value)
  (let ((symbol-des (etypecase symbol-or-symbol-des
                      (descriptor symbol-or-symbol-des)
                      (symbol (cold-intern symbol-or-symbol-des)))))
    (write-wordindexed symbol-des sb!vm:symbol-value-slot value)))
(defun cold-symbol-value (symbol)
  (let ((val (read-wordindexed (cold-intern symbol) sb!vm:symbol-value-slot)))
    (if (= (descriptor-bits val) sb!vm:unbound-marker-widetag)
        (unbound-cold-symbol-handler symbol)
        val)))
(defun cold-fdefn-fun (cold-fdefn)
  (read-wordindexed cold-fdefn sb!vm:fdefn-fun-slot))

(defun unbound-cold-symbol-handler (symbol)
  (let ((host-val (and (boundp symbol) (symbol-value symbol))))
    (if (typep host-val 'named-type)
        (let ((target-val (ctype-to-core (named-type-name host-val) host-val)))
          ;; Though it looks complicated to assign cold symbols on demand,
          ;; it avoids writing code to build the layout of NAMED-TYPE in the
          ;; way we build other primordial stuff such as layout-of-layout.
          (cold-set symbol target-val)
          target-val)
        (error "Taking Cold-symbol-value of unbound symbol ~S" symbol))))

;;;; layouts and type system pre-initialization

;;; Since we want to be able to dump structure constants and
;;; predicates with reference layouts, we need to create layouts at
;;; cold-load time. We use the name to intern layouts by, and dump a
;;; list of all cold layouts in *!INITIAL-LAYOUTS* so that type system
;;; initialization can find them. The only thing that's tricky [sic --
;;; WHN 19990816] is initializing layout's layout, which must point to
;;; itself.

;;; a map from name as a host symbol to the descriptor of its target layout
(defvar *cold-layouts*)

;;; a map from DESCRIPTOR-BITS of cold layouts to the name, for inverting
;;; mapping
(defvar *cold-layout-names*)

;;; the descriptor for layout's layout (needed when making layouts)
(defvar *layout-layout*)

(defvar *known-structure-classoids*)

(defconstant target-layout-length
  ;; LAYOUT-LENGTH counts the number of words in an instance,
  ;; including the layout itself as 1 word
  (layout-length *host-layout-of-layout*))

;;; Trivial methods [sic] require that we sort possible methods by the depthoid.
;;; Most of the objects printed in cold-init are ordered hierarchically in our
;;; type lattice; the major exceptions are ARRAY and VECTOR at depthoid -1.
;;; Of course we need to print VECTORs because a STRING is a vector,
;;; and vector has to precede ARRAY. Kludge it for now.
(defun class-depthoid (class-name) ; DEPTHOID-ish thing, any which way you can
  (case class-name
    (vector 0.5)
    (array  0.25)
    ;; The depthoid of CONDITION has to be faked. The proper value is 1.
    ;; But STRUCTURE-OBJECT is also at depthoid 1, and its predicate
    ;; is %INSTANCEP (which is too weak), so to select the correct method
    ;; we have to make CONDITION more specific.
    ;; In reality it is type disjoint from structure-object.
    (condition 2)
    (t
     (let ((target-layout (gethash class-name *cold-layouts*)))
       (if target-layout
           (cold-layout-depthoid target-layout)
           (let ((host-layout (find-layout class-name)))
             (if (layout-invalid host-layout)
                 (error "~S has neither a host not target layout" class-name)
                 (layout-depthoid host-layout))))))))

;;; Return a list of names created from the cold layout INHERITS data
;;; in X.
(defun listify-cold-inherits (x)
  (map 'list (lambda (cold-layout)
               (or (gethash (descriptor-bits cold-layout) *cold-layout-names*)
                   (error "~S is not the descriptor of a cold-layout" cold-layout)))
       (vector-from-core x)))

;;; COLD-DD-SLOTS is a cold descriptor for the list of slots
;;; in a cold defstruct-description. INDEX is a DSD-INDEX.
;;; Return the host's accessor name for the host image of that slot.
(defun dsd-accessor-from-cold-slots (cold-dd-slots desired-index)
  (let* ((dsd-slots (dd-slots
                     (find-defstruct-description 'defstruct-slot-description)))
         (bits-slot
          (dsd-index (find 'sb!kernel::bits dsd-slots :key #'dsd-name)))
         (accessor-fun-name-slot
          (dsd-index (find 'sb!kernel::accessor-name dsd-slots :key #'dsd-name))))
    (do ((list cold-dd-slots (cold-cdr list)))
        ((cold-null list))
      (when (= (ash (descriptor-fixnum
                     (read-wordindexed (cold-car list)
                                       (+ sb!vm:instance-slots-offset bits-slot)))
                    (- sb!kernel::+dsd-index-shift+))
               desired-index)
        (return
         (warm-symbol
          (read-wordindexed (cold-car list)
                            (+ sb!vm:instance-slots-offset
                               accessor-fun-name-slot))))))))

(defun cold-dsd-index (cold-dsd dsd-layout)
  (ash (descriptor-fixnum (read-slot cold-dsd dsd-layout :bits))
       (- sb!kernel::+dsd-index-shift+)))

(defun cold-dsd-raw-type (cold-dsd dsd-layout)
  (1- (ldb (byte 3 0) (descriptor-fixnum (read-slot cold-dsd dsd-layout :bits)))))

(flet ((get-slots (host-layout-or-type)
         (etypecase host-layout-or-type
           (layout (dd-slots (layout-info host-layout-or-type)))
           (symbol (dd-slots-from-core host-layout-or-type))))
       (get-slot-index (slots initarg)
         (+ sb!vm:instance-slots-offset
            (if (descriptor-p slots)
                (do ((dsd-layout (find-layout 'defstruct-slot-description))
                     (slots slots (cold-cdr slots)))
                    ((cold-null slots) (error "No slot for ~S" initarg))
                  (let* ((dsd (cold-car slots))
                         (slot-name (read-slot dsd dsd-layout :name)))
                    (when (eq (keywordicate (warm-symbol slot-name)) initarg)
                      ;; Untagged slots are not accessible during cold-load
                      (aver (eql (cold-dsd-raw-type dsd dsd-layout) -1))
                      (return (cold-dsd-index dsd dsd-layout)))))
                (let ((dsd (find initarg slots
                                 :test (lambda (x y)
                                         (eq x (keywordicate (dsd-name y)))))))
                  (aver (eq (dsd-raw-type dsd) t)) ; Same as above: no can do.
                  (dsd-index dsd))))))
  (defun write-slots (cold-object host-layout-or-type &rest assignments)
    (aver (evenp (length assignments)))
    (let ((slots (get-slots host-layout-or-type)))
      (loop for (initarg value) on assignments by #'cddr
            do (write-wordindexed
                cold-object (get-slot-index slots initarg) value)))
    cold-object)

  ;; For symmetry, the reader takes an initarg, not a slot name.
  (defun read-slot (cold-object host-layout-or-type slot-initarg)
    (let ((slots (get-slots host-layout-or-type)))
      (read-wordindexed cold-object (get-slot-index slots slot-initarg)))))

;; Given a TYPE-NAME of a structure-class, find its defstruct-description
;; as a target descriptor, and return the slot list as a target descriptor.
(defun dd-slots-from-core (type-name)
  (let* ((host-dd-layout (find-layout 'defstruct-description))
         (target-dd
          ;; This is inefficient, but not enough so to worry about.
          (or (car (assoc (cold-intern type-name) *known-structure-classoids*
                          :key (lambda (x) (read-slot x host-dd-layout :name))
                          :test #'descriptor=))
              (error "No known layout for ~S" type-name))))
    (read-slot target-dd host-dd-layout :slots)))

(defvar *simple-vector-0-descriptor*)
(defvar *vacuous-slot-table*)
(defvar *cold-layout-gspace* (or #!+immobile-space '*immobile-fixedobj* '*dynamic*))
(defvar *cold-package-gspace*
  (or #!+(and immobile-space 64-bit) '*immobile-fixedobj* '*dynamic*))
(declaim (ftype (function (symbol descriptor descriptor descriptor descriptor)
                          descriptor)
                make-cold-layout))
(defun make-cold-layout (name length inherits depthoid bitmap)
  (let ((result (allocate-struct (symbol-value *cold-layout-gspace*) *layout-layout*
                                 target-layout-length t)))
    ;; Don't set the CLOS hash value: done in cold-init instead.
    ;;
    ;; Set other slot values.
    ;;
    ;; leave CLASSOID uninitialized for now
    (multiple-value-call
     #'write-slots result *host-layout-of-layout*
     :invalid *nil-descriptor*
     :inherits inherits
     :depthoid depthoid
     :length length
     :%flags (let* ((inherit-names (listify-cold-inherits inherits))
                    (second (second inherit-names)))
               (make-fixnum-descriptor
                 ;; Note similarity to FOP-LAYOUT here, but with extra
                 ;; test for the subtree roots.
                 (cond ((or (eq second 'structure-object) (eq name 'structure-object))
                        +structure-layout-flag+)
                       ((or (eq second 'condition) (eq name 'condition))
                        +condition-layout-flag+)
                       (t 0))))
     :info *nil-descriptor*
     :bitmap bitmap
      ;; Nothing in cold-init needs to call EQUALP on a structure with raw slots,
      ;; but for type-correctness this slot needs to be a simple-vector.
     :equalp-tests *simple-vector-0-descriptor*
     :source-location *nil-descriptor*
     :slot-list *nil-descriptor*
     (if (member name '(null list symbol))
      ;; Assign an empty slot-table.  Why this is done only for three
      ;; classoids is ... too complicated to explain here in a few words,
      ;; but revision 18c239205d9349abc017b07e7894a710835c5205 broke it.
      ;; Keep this in sync with MAKE-SLOT-TABLE in pcl/slots-boot.
         (values :slot-table (if (boundp '*vacuous-slot-table*)
                                 *vacuous-slot-table*
                                 (setq *vacuous-slot-table*
                                       (host-constant-to-core '#(1 nil)))))
         (values)))

    (setf (gethash (descriptor-bits result) *cold-layout-names*) name
          (gethash name *cold-layouts*) result)))

(defun predicate-for-specializer (type-name)
  (let ((classoid (find-classoid type-name nil)))
    (typecase classoid
      (structure-classoid
       (cond ((dd-predicate-name (layout-info (classoid-layout classoid))))
             ;; All early INSTANCEs should be STRUCTURE-OBJECTs.
             ;; Except: see hack for CONDITIONs in CLASS-DEPTHOID.
             ((eq type-name 'structure-object) '%instancep)))
      (built-in-classoid
       (let ((translation (specifier-type type-name)))
         (aver (not (contains-unknown-type-p translation)))
         (let ((predicate (find translation sb!c::*backend-type-predicates*
                                :test #'type= :key #'car)))
           (cond (predicate (cdr predicate))
                 ((eq type-name 'stream) 'streamp)
                 ((eq type-name 't) 'constantly-t)
                 (t (error "No predicate for builtin: ~S" type-name))))))
      (null
       #+nil (format t "~&; PREDICATE-FOR-SPECIALIZER: no classoid for ~S~%"
                     type-name)
       (case type-name
         (condition 'sb!kernel::!condition-p))))))

;;; Convert SPECIFIER (equivalently OBJ) to its representation as a ctype
;;; in the cold core.
(defvar *ctype-cache*)

(defvar *ctype-nullified-slots* nil)
(defvar *built-in-classoid-nullified-slots* nil)

;; This function is memoized because it's essentially a constant,
;; but *nil-descriptor* isn't initialized by the time it's defined.
(defun get-exceptional-slots (obj-type)
  (flet ((index (classoid-name slot-name)
           (dsd-index (find slot-name
                            (dd-slots (find-defstruct-description classoid-name))
                            :key #'dsd-name))))
    (case obj-type
      (built-in-classoid
       (or *built-in-classoid-nullified-slots*
           (setq *built-in-classoid-nullified-slots*
                 (append (get-exceptional-slots 'ctype)
                         (list (cons (index 'built-in-classoid 'sb!kernel::subclasses)
                                     *nil-descriptor*)
                               (cons (index 'built-in-classoid 'layout)
                                     *nil-descriptor*))))))
      (t
       (or *ctype-nullified-slots*
           (setq *ctype-nullified-slots*
                 (list (cons (index 'ctype 'sb!kernel::class-info)
                             *nil-descriptor*))))))))

(defun ctype-to-core (specifier obj)
  (declare (type ctype obj))
  (if (classoid-p obj)
      (let* ((cell (cold-find-classoid-cell (classoid-name obj) :create t))
             (cold-classoid
              (read-slot cell (find-layout 'sb!kernel::classoid-cell) :classoid)))
        (unless (cold-null cold-classoid)
          (return-from ctype-to-core cold-classoid)))
      ;; CTYPEs can't be TYPE=-hashed, but specifiers can be EQUAL-hashed.
      ;; Don't check the cache for classoids though; that would be wrong.
      ;; e.g. named-type T and classoid T both unparse to T.
      (awhen (gethash specifier *ctype-cache*)
        (return-from ctype-to-core it)))
  (let ((result
         (ctype-to-core-helper
               obj
               (lambda (obj)
                 (typecase obj
                   (xset (ctype-to-core-helper obj nil nil))
                   (ctype (ctype-to-core (type-specifier obj) obj))))
               (get-exceptional-slots (type-of obj)))))
    (let ((type-class-vector
           (cold-symbol-value 'sb!kernel::*type-classes*))
          (index (position (sb!kernel::type-class-info obj)
                           sb!kernel::*type-classes*)))
      ;; Push this instance into the list of fixups for its type class
      (cold-svset type-class-vector index
                  (cold-cons result (cold-svref type-class-vector index))))
    (if (classoid-p obj)
        ;; Place this classoid into its clasoid-cell.
        (let ((cell (cold-find-classoid-cell (classoid-name obj) :create t)))
          (write-slots cell (find-layout 'sb!kernel::classoid-cell)
                       :classoid result))
        ;; Otherwise put it in the general cache
        (setf (gethash specifier *ctype-cache*) result))
    result))

(defun ctype-to-core-helper (obj obj-to-core-helper exceptional-slots)
  (let* ((host-type (type-of obj))
         (target-layout (or (gethash host-type *cold-layouts*)
                            (error "No target layout for ~S" obj)))
         (result (allocate-struct *dynamic* target-layout))
         (cold-dd-slots (dd-slots-from-core host-type)))
    (aver (eql (layout-bitmap (find-layout host-type))
               sb!kernel::+layout-all-tagged+))
    ;; Dump the slots.
    (do ((len (cold-layout-length target-layout))
         (index sb!vm:instance-data-start (1+ index)))
        ((= index len) result)
      (write-wordindexed
       result
       (+ sb!vm:instance-slots-offset index)
       (acond ((assq index exceptional-slots) (cdr it))
              (t (host-constant-to-core
                  (funcall (dsd-accessor-from-cold-slots cold-dd-slots index)
                           obj)
                  obj-to-core-helper)))))))

;; This is called to backpatch two small sets of objects:
;;  - layouts created before layout-of-layout is made (3 counting LAYOUT itself)
;;  - a small number of classoid-cells (~ 4).
(defun set-instance-layout (thing layout)
  #!+compact-instance-header
  ;; High half of the header points to the layout
  (write-wordindexed/raw thing 0 (logior (ash (descriptor-bits layout) 32)
                                         (read-bits-wordindexed thing 0)))
  #!-compact-instance-header
  ;; Word following the header is the layout
  (write-wordindexed thing sb!vm:instance-slots-offset layout))

(defun cold-layout-of (cold-struct)
  #!+compact-instance-header
  (let ((bits (ash (read-bits-wordindexed cold-struct 0) -32)))
    (if (zerop bits) *nil-descriptor* (make-random-descriptor bits)))
  #!-compact-instance-header
  (read-wordindexed cold-struct sb!vm:instance-slots-offset))

(defun initialize-layouts ()
  (clrhash *cold-layouts*)
  ;; This assertion is due to the fact that MAKE-COLD-LAYOUT does not
  ;; know how to set any raw slots.
  (aver (eql (layout-bitmap *host-layout-of-layout*)
             sb!kernel::+layout-all-tagged+))
  (setq *layout-layout* (make-fixnum-descriptor 0))
  (flet ((chill-layout (name &rest inherits)
           ;; Check that the number of specified INHERITS matches
           ;; the length of the layout's inherits in the cross-compiler.
           (let ((warm-layout (classoid-layout (find-classoid name))))
             (assert (eql (length (layout-inherits warm-layout))
                          (length inherits)))
             (make-cold-layout
              name
              (number-to-core (layout-length warm-layout))
              (vector-in-core inherits)
              (number-to-core (layout-depthoid warm-layout))
              (number-to-core (layout-bitmap warm-layout))))))
    (let* ((t-layout   (chill-layout 't))
           (fun-layout (chill-layout 'function t-layout))
           (s-o-layout (chill-layout 'structure-object t-layout)))
      (setf *layout-layout* (chill-layout 'layout t-layout s-o-layout))
      (dolist (layout (list t-layout fun-layout s-o-layout *layout-layout*))
        (set-instance-layout layout *layout-layout*))
      (chill-layout 'package t-layout s-o-layout)
      (let* ((sequence (chill-layout 'sequence t-layout))
             (list     (chill-layout 'list t-layout sequence))
             (symbol   (chill-layout 'symbol t-layout)))
        (chill-layout 'null t-layout sequence list symbol)))))

;;;; interning symbols in the cold image

;;; a map from package name as a host string to
;;; ((external-symbols . internal-symbols) . cold-package-descriptor)
(defvar *cold-package-symbols*)
(declaim (type hash-table *cold-package-symbols*))

(setf (get 'find-package :sb-cold-funcall-handler/for-value)
      (lambda (descriptor &aux (name (base-string-from-core descriptor)))
        (or (cdr (gethash name *cold-package-symbols*))
            (error "Genesis could not find a target package named ~S" name))))

(defvar *classoid-cells*)
(defun cold-find-classoid-cell (name &key create)
  (aver (eq create t))
  (or (gethash name *classoid-cells*)
      (let ((layout (gethash 'sb!kernel::classoid-cell *cold-layouts*)) ; ok if nil
            (host-layout (find-layout 'sb!kernel::classoid-cell)))
        (setf (gethash name *classoid-cells*)
              (write-slots (allocate-struct *dynamic* layout
                                            (layout-length host-layout))
                           host-layout
                           :name name
                           :pcl-class *nil-descriptor*
                           :classoid *nil-descriptor*)))))

(setf (get 'find-classoid-cell :sb-cold-funcall-handler/for-value)
      #'cold-find-classoid-cell)

;;; a map from descriptors to symbols, so that we can back up. The key
;;; is the address in the target core.
(defvar *cold-symbols*)
(declaim (type hash-table *cold-symbols*))

(defun set-readonly (string) (set-header-data string sb!vm:+vector-shareable+))

(defun initialize-packages ()
  (let ((package-data-list
         ;; docstrings are set in src/cold/warm. It would work to do it here,
         ;; but seems preferable not to saddle Genesis with such responsibility.
         (list* (sb-cold:make-package-data :name "COMMON-LISP" :doc nil)
                (sb-cold:make-package-data :name "KEYWORD" :doc nil)
                ;; ANSI encourages us to put extension packages
                ;; in the USE list of COMMON-LISP-USER.
                (sb-cold:make-package-data
                 :name "COMMON-LISP-USER" :doc nil
                 :use '("COMMON-LISP" "SB!ALIEN" "SB!DEBUG" "SB!EXT" "SB!GRAY" "SB!PROFILE"))
                (sb-cold::package-list-for-genesis)))
        (package-layout (find-layout 'package))
        (target-pkg-list nil))
    (labels ((init-cold-package (name &optional docstring)
               (let ((cold-package (allocate-struct (symbol-value *cold-package-gspace*)
                                                    (gethash 'package *cold-layouts*))))
                 (setf (gethash name *cold-package-symbols*)
                       (cons (cons nil nil) cold-package))
                 ;; Initialize string slots
                 (write-slots cold-package package-layout
                              :%name (set-readonly
                                      (base-string-to-core
                                       (target-package-name name)))
                              :%nicknames (chill-nicknames name)
                              :doc-string (if docstring
                                              (base-string-to-core docstring)
                                              *nil-descriptor*)
                              :%use-list *nil-descriptor*)
                 ;; the cddr of this will accumulate the 'used-by' package list
                 (push (list name cold-package) target-pkg-list)))
             (target-package-name (string)
               (if (eql (mismatch string "SB!") 3)
                   (concatenate 'string "SB-" (subseq string 3))
                   string))
             (chill-nicknames (pkg-name)
                 ;; Make the package nickname lists for the standard packages
                 ;; be the minimum specified by ANSI, regardless of what value
                 ;; the cross-compilation host happens to use.
                 ;; For packages other than the standard packages, the nickname
                 ;; list was specified by our package setup code, and we can just
                 ;; propagate the current state into the target.
               (list-to-core
                  (mapcar #'base-string-to-core
                          (cond ((string= pkg-name "COMMON-LISP") '("CL"))
                                ((string= pkg-name "COMMON-LISP-USER")
                                 '("CL-USER"))
                                ((string= pkg-name "KEYWORD") '())
                                (t
                                 ;; 'package-data-list' contains no nicknames.
                                 ;; (See comment in 'set-up-cold-packages')
                                 (aver (null (package-nicknames
                                              (find-package pkg-name))))
                                 nil)))))
             (find-cold-package (name)
               (cadr (find-package-cell name)))
             (find-package-cell (name)
               (or (assoc (if (string= name "CL") "COMMON-LISP" name)
                          target-pkg-list :test #'string=)
                   (error "No cold package named ~S" name))))
      ;; pass 1: make all proto-packages
      (dolist (pd package-data-list)
        (init-cold-package (sb-cold:package-data-name pd)
                           #!+sb-doc(sb-cold::package-data-doc pd)))
      ;; pass 2: set the 'use' lists and collect the 'used-by' lists
      (dolist (pd package-data-list)
        (let ((this (find-cold-package (sb-cold:package-data-name pd)))
              (use nil))
          (dolist (that (sb-cold:package-data-use pd))
            (let ((cell (find-package-cell that)))
              (push (cadr cell) use)
              (push this (cddr cell))))
          (write-slots this package-layout
                       :%use-list (list-to-core (nreverse use)))))
      ;; pass 3: set the 'used-by' lists
      (dolist (cell target-pkg-list)
        (write-slots (cadr cell) package-layout
                     :%used-by-list (list-to-core (cddr cell)))))))

;;; sanity check for a symbol we're about to create on the target
;;;
;;; Make sure that the symbol has an appropriate package. In
;;; particular, catch the so-easy-to-make error of typing something
;;; like SB-KERNEL:%BYTE-BLT in cold sources when what you really
;;; need is SB!KERNEL:%BYTE-BLT.
(defun package-ok-for-target-symbol-p (package)
  (let ((package-name (package-name package)))
    (or
     ;; Cold interning things in these standard packages is OK. (Cold
     ;; interning things in the other standard package, CL-USER, isn't
     ;; OK. We just use CL-USER to expose symbols whose homes are in
     ;; other packages. Thus, trying to cold intern a symbol whose
     ;; home package is CL-USER probably means that a coding error has
     ;; been made somewhere.)
     (find package-name '("COMMON-LISP" "KEYWORD") :test #'string=)
     ;; Cold interning something in one of our target-code packages,
     ;; which are ever-so-rigorously-and-elegantly distinguished by
     ;; this prefix on their names, is OK too.
     (string= package-name "SB!" :end1 3 :end2 3)
     ;; This one is OK too, since it ends up being COMMON-LISP on the
     ;; target.
     (string= package-name "SB!XC")
     ;; Anything else looks bad. (maybe COMMON-LISP-USER? maybe an extension
     ;; package in the xc host? something we can't think of
     ;; a valid reason to cold intern, anyway...)
     )))

;;; like SYMBOL-PACKAGE, but safe for symbols which end up on the target
;;;
;;; Most host symbols we dump onto the target are created by SBCL
;;; itself, so that as long as we avoid gratuitously
;;; cross-compilation-unfriendly hacks, it just happens that their
;;; SYMBOL-PACKAGE in the host system corresponds to their
;;; SYMBOL-PACKAGE in the target system. However, that's not the case
;;; in the COMMON-LISP package, where we don't get to create the
;;; symbols but instead have to use the ones that the xc host created.
;;; In particular, while ANSI specifies which symbols are exported
;;; from COMMON-LISP, it doesn't specify that their home packages are
;;; COMMON-LISP, so the xc host can keep them in random packages which
;;; don't exist on the target (e.g. CLISP keeping some CL-exported
;;; symbols in the CLOS package).
(defun symbol-package-for-target-symbol (symbol)
  ;; We want to catch weird symbols like CLISP's
  ;; CL:FIND-METHOD=CLOS::FIND-METHOD, but we don't want to get
  ;; sidetracked by ordinary symbols like :CHARACTER which happen to
  ;; have the same SYMBOL-NAME as exports from COMMON-LISP.
  (multiple-value-bind (cl-symbol cl-status)
      (find-symbol (symbol-name symbol) *cl-package*)
    (if (and (eq symbol cl-symbol)
             (eq cl-status :external))
        ;; special case, to work around possible xc host weirdness
        ;; in COMMON-LISP package
        *cl-package*
        ;; ordinary case
        (let ((result (symbol-package symbol)))
          (unless (package-ok-for-target-symbol-p result)
            (bug "~A in bad package for target: ~A" symbol result))
          result))))

(defvar *uninterned-symbol-table* (make-hash-table :test #'equal))
;; This coalesces references to uninterned symbols, which is allowed because
;; "similar-as-constant" is defined by string comparison, and since we only have
;; base-strings during Genesis, there is no concern about upgraded array type.
;; There is a subtlety of whether coalescing may occur across files
;; - the target compiler doesn't and couldn't - but here it doesn't matter.
(defun get-uninterned-symbol (name)
  (ensure-gethash name *uninterned-symbol-table* (allocate-symbol name)))

;;; Dump the target representation of HOST-VALUE,
;;; the type of which is in a restrictive set.
(defun host-constant-to-core (host-value &optional helper)
  (let ((visited (make-hash-table :test #'eq)))
    (named-let target-representation ((value host-value))
      (unless (typep value '(or symbol number descriptor))
        (let ((found (gethash value visited)))
          (cond ((eq found :pending)
                 (bug "circular constant?")) ; Circularity not permitted
                (found
                 (return-from target-representation found))))
        (setf (gethash value visited) :pending))
      (setf (gethash value visited)
            (typecase value
              (descriptor value)
              (symbol (if (symbol-package value)
                          (cold-intern value)
                          (get-uninterned-symbol (string value))))
              (number (number-to-core value))
              (string (base-string-to-core value))
              (cons (cold-cons (target-representation (car value))
                               (target-representation (cdr value))))
              (simple-vector
               (vector-in-core (map 'list #'target-representation value)))
              (t
               (or (and helper (funcall helper value))
                   (error "host-constant-to-core: can't convert ~S"
                          value))))))))

;; Look up the target's descriptor for #'FUN where FUN is a host symbol.
(defun cold-symbol-function (symbol &optional (errorp t))
  (let ((f (cold-fdefn-fun (cold-fdefinition-object symbol))))
    (cond ((not (cold-null f)) f)
          (errorp (error "Expected a definition for ~S in cold load" symbol))
          (t nil))))

;;; Return a handle on an interned symbol. If necessary allocate the
;;; symbol and record its home package.
(defun cold-intern (symbol
                    &key (access nil)
                         (gspace (symbol-value *cold-symbol-gspace*))
                    &aux (package (symbol-package-for-target-symbol symbol)))

  (declare (symbol symbol))
  ;; Anything on the cross-compilation host which refers to the target
  ;; machinery through the host SB!XC package should be translated to
  ;; something on the target which refers to the same machinery
  ;; through the target COMMON-LISP package.
  (let ((p (find-package "SB!XC")))
    (when (eq package p)
      (setf package *cl-package*))
    (when (eq (symbol-package symbol) p)
      (setf symbol (intern (symbol-name symbol) *cl-package*))))

  (or (get symbol 'cold-intern-info)
      (let ((handle (allocate-symbol (symbol-name symbol) :gspace gspace)))
        (setf (get symbol 'cold-intern-info) handle)
        ;; maintain reverse map from target descriptor to host symbol
        (setf (gethash (descriptor-bits handle) *cold-symbols*) symbol)
        (let ((pkg-info (or (gethash (package-name package) *cold-package-symbols*)
                            (error "No target package descriptor for ~S" package))))
          (write-wordindexed handle sb!vm:symbol-package-slot (cdr pkg-info))
          (record-accessibility
           (or access (nth-value 1 (find-symbol (symbol-name symbol) package)))
           pkg-info handle package symbol))
        #!+sb-thread
        (let ((index (info :variable :wired-tls symbol)))
          (when (integerp index) ; thread slot
            (cold-assign-tls-index handle index)))
        (when (eq package *keyword-package*)
          (cold-set handle handle))
        handle)))

(defun record-accessibility (accessibility target-pkg-info symbol-descriptor
                             &optional host-package host-symbol)
  (let ((access-lists (car target-pkg-info)))
    (case accessibility
      (:external (push symbol-descriptor (car access-lists)))
      (:internal (push symbol-descriptor (cdr access-lists)))
      (t (error "~S inaccessible in package ~S" host-symbol host-package)))))

;;; Construct and return a value for use as *NIL-DESCRIPTOR*.
;;; It might be nice to put NIL on a readonly page by itself to prevent unsafe
;;; code from destroying the world with (RPLACx nil 'kablooey)
(defun make-nil-descriptor ()
  (let* ((des (allocate-header+object *static* sb!vm:symbol-size 0))
         (result (make-descriptor (+ (descriptor-bits des)
                                     (* 2 sb!vm:n-word-bytes)
                                     (- sb!vm:list-pointer-lowtag
                                        sb!vm:other-pointer-lowtag)))))
    (write-wordindexed des
                       1
                       (make-other-immediate-descriptor
                        0
                        sb!vm:symbol-widetag))
    (write-wordindexed des
                       (+ 1 sb!vm:symbol-value-slot)
                       result)
    (write-wordindexed des
                       (+ 2 sb!vm:symbol-value-slot) ; = 1 + symbol-hash-slot
                       result)
    (write-wordindexed des
                       (+ 1 sb!vm:symbol-info-slot)
                       (cold-cons result result)) ; NIL's info is (nil . nil)
    (write-wordindexed des
                       (+ 1 sb!vm:symbol-name-slot)
                       ;; NIL's name is in dynamic space because any extra
                       ;; bytes allocated in static space would need to
                       ;; be accounted for by STATIC-SYMBOL-OFFSET.
                       (set-readonly (base-string-to-core "NIL" *dynamic*)))
    (setf (gethash (descriptor-bits result) *cold-symbols*) nil
          (get nil 'cold-intern-info) result)))

;;; Since the initial symbols must be allocated before we can intern
;;; anything else, we intern those here. We also set the value of T.
(defun initialize-static-space ()
  "Initialize the cold load symbol-hacking data structures."
  ;; NIL did not have its package assigned. Do that now.
  (let ((target-cl-pkg-info (gethash "COMMON-LISP" *cold-package-symbols*)))
    ;; -1 is magic having to do with nil-as-cons vs. nil-as-symbol
    (write-wordindexed *nil-descriptor* (- sb!vm:symbol-package-slot 1)
                       (cdr target-cl-pkg-info))
    (record-accessibility :external target-cl-pkg-info *nil-descriptor*))
  ;; Intern the others.
  (dovector (symbol sb!vm:+static-symbols+)
    (let* ((des (cold-intern symbol :gspace *static*))
           (offset-wanted (sb!vm:static-symbol-offset symbol))
           (offset-found (- (descriptor-bits des)
                            (descriptor-bits *nil-descriptor*))))
      (unless (= offset-wanted offset-found)
        (error "Offset from ~S to ~S is ~W, not ~W"
              symbol
              nil
              offset-found
              offset-wanted))))

  ;; Assign TLS indices of C interface symbols
  #!+sb-thread
  (dolist (binding sb!vm::!per-thread-c-interface-symbols)
    (ensure-symbol-tls-index (car (ensure-list binding))))

  ;; Establish the value of T.
  (let ((t-symbol (cold-intern t :gspace *static*)))
    (cold-set t-symbol t-symbol))

  ;; Establish the value of SB-VM:FUNCTION-LAYOUT
  #!+(and immobile-space 64-bit)
  (let ((address-bits (descriptor-bits (gethash 'function *cold-layouts*))))
    (aver (eql address-bits sb!vm:function-layout))
    (write-wordindexed/raw (cold-intern 'sb!vm:function-layout)
                           sb!vm:symbol-value-slot
                           (ash address-bits 32)))

  (dolist (sym sb!vm::+c-callable-fdefns+)
    (cold-fdefinition-object (cold-intern sym) nil *static*))

  ;; With immobile-code, static-fdefns as a concept are useful -
  ;; the implication is that the function's definition will not change.
  ;; But the fdefn per se is not useful - callers refer to callees directly.
  #!-immobile-code
  (dovector (sym sb!vm:+static-fdefns+)
    (let* ((fdefn (cold-fdefinition-object (cold-intern sym) nil *static*))
           (offset (- (+ (- (descriptor-bits fdefn)
                            sb!vm:other-pointer-lowtag)
                         (* sb!vm:fdefn-raw-addr-slot sb!vm:n-word-bytes))
                      (descriptor-bits *nil-descriptor*)))
           (desired (sb!vm:static-fun-offset sym)))
      (unless (= offset desired)
        (error "Offset from FDEFN ~S to ~S is ~W, not ~W."
               sym nil offset desired)))))

;;; Sort *COLD-LAYOUTS* to return them in a deterministic order.
(defun sort-cold-layouts ()
  (sort (%hash-table-alist *cold-layouts*) #'<
        :key (lambda (x) (descriptor-bits (cdr x)))))

;;; Establish initial values for magic symbols.
;;;
(defun finish-symbols ()
  (cold-set '*!initial-layouts*
            (vector-in-core
             (mapcar (lambda (layout)
                       (cold-cons (cold-intern (car layout)) (cdr layout)))
                     (sort-cold-layouts))))

  #!+sb-thread
  (let ((bindings sb!kernel::*!thread-initial-bindings*))
    ;; Assign the initialization vector for create_thread_struct()
    (cold-set 'sb!thread::*thread-initial-bindings*
              (vector-in-core
               (mapcar (lambda (pair &aux (name (car pair)))
                         ;; Sanity check - no overlap with GC/interrupt controls
                         (aver (not (member name sb!vm::!per-thread-c-interface-symbols)))
                         (let* ((name (cold-intern name))
                                (value (cdr pair))
                                (initform
                                 (cond ((symbolp value)
                                        (cold-intern value))
                                       ((is-fixnum-lowtag (descriptor-lowtag value))
                                        value)
                                       (t
                                        (bug "Unsupported thread-local initform")))))
                           (if (null value) name (cold-cons initform name))))
                       bindings)))
    (dolist (binding bindings)
      (ensure-symbol-tls-index (car (ensure-list binding))))
    (cold-set 'sb!vm::*free-tls-index*
              (make-descriptor (ash *genesis-tls-counter* sb!vm:word-shift))))

  (dolist (symbol sb!impl::*cache-vector-symbols*)
    (cold-set symbol *nil-descriptor*))

  ;; Symbols for which no call to COLD-INTERN would occur - due to not being
  ;; referenced until warm init - must be artificially cold-interned.
  ;; Inasmuch as the "offending" things are compiled by ordinary target code
  ;; and not cold-init, I think we should use an ordinary DEFPACKAGE for
  ;; the added-on bits. What I've done is somewhat of a fragile kludge.
  (let (syms)
    (with-package-iterator (iter '("SB!PCL" "SB!MOP" "SB!GRAY" "SB!SEQUENCE"
                                   "SB!PROFILE" "SB!EXT" "SB!VM"
                                   "SB!C" "SB!FASL" "SB!DEBUG")
                                 :external)
      (loop
         (multiple-value-bind (foundp sym accessibility package) (iter)
           (declare (ignore accessibility))
           (cond ((not foundp) (return))
                 ((eq (symbol-package sym) package) (push sym syms))))))
    (setf syms (stable-sort syms #'string<))
    (dolist (sym syms)
      (cold-intern sym)))

  (cold-set
   'sb!impl::*!initial-symbols*
   (list-to-core
    (mapcar
     (lambda (pkgcons)
      (destructuring-bind (pkg-name . pkg-info) pkgcons
        (let ((shadow
               ;; Record shadowing symbols (except from SB!XC) in SB! packages.
               (when (eql (mismatch pkg-name "SB!") 3)
                 ;; Be insensitive to the host's ordering.
                 (sort (remove (find-package "SB!XC")
                               (package-shadowing-symbols (find-package pkg-name))
                               :key #'symbol-package) #'string<))))
          (write-slots (cdr pkg-info) ; package
                       (find-layout 'package)
                       :%shadowing-symbols (list-to-core
                                            (mapcar 'cold-intern shadow))))
        (unless (member pkg-name '("COMMON-LISP" "KEYWORD") :test 'string=)
          (let ((host-pkg (find-package pkg-name))
                (sb-xc-pkg (find-package "SB!XC"))
                syms)
            ;; Now for each symbol directly present in this host-pkg,
            ;; i.e. accessible but not :INHERITED, figure out if the symbol
            ;; came from a different package, and if so, make a note of it.
            (with-package-iterator (iter host-pkg :internal :external)
              (loop (multiple-value-bind (foundp sym accessibility) (iter)
                      (unless foundp (return))
                      (unless (or (eq (symbol-package sym) host-pkg)
                                  (eq (symbol-package sym) sb-xc-pkg))
                        (push (cons sym accessibility) syms)))))
            (dolist (symcons (sort syms #'string< :key #'car))
              (destructuring-bind (sym . accessibility) symcons
                (record-accessibility accessibility pkg-info (cold-intern sym)
                                      host-pkg sym)))))
        (cold-list (cdr pkg-info)
                   (vector-in-core (caar pkg-info))
                   (vector-in-core (cdar pkg-info)))))
     (sort (%hash-table-alist *cold-package-symbols*)
           #'string< :key #'car)))) ; Sort by package-name

  (dump-symbol-info-vectors
   (attach-fdefinitions-to-symbols
    (attach-classoid-cells-to-symbols (make-hash-table :test #'eq))))

  #!+x86
  (progn
    (cold-set 'sb!vm::*fp-constant-0d0* (number-to-core 0d0))
    (cold-set 'sb!vm::*fp-constant-1d0* (number-to-core 1d0))
    (cold-set 'sb!vm::*fp-constant-0f0* (number-to-core 0f0))
    (cold-set 'sb!vm::*fp-constant-1f0* (number-to-core 1f0))))

;;;; functions and fdefinition objects

;;; a hash table mapping from fdefinition names to descriptors of cold
;;; objects
;;;
;;; Note: Since fdefinition names can be lists like '(SETF FOO), and
;;; we want to have only one entry per name, this must be an 'EQUAL
;;; hash table, not the default 'EQL.
(defvar *cold-fdefn-objects*)

;;; Given a cold representation of a symbol, return a warm
;;; representation.
(defun warm-symbol (des)
  ;; Note that COLD-INTERN is responsible for keeping the
  ;; *COLD-SYMBOLS* table up to date, so if DES happens to refer to an
  ;; uninterned symbol, the code below will fail. But as long as we
  ;; don't need to look up uninterned symbols during bootstrapping,
  ;; that's OK..
  (multiple-value-bind (symbol found-p)
      (gethash (descriptor-bits des) *cold-symbols*)
    (declare (type symbol symbol))
    (unless found-p
      (error "no warm symbol"))
    symbol))

;;; like CL:CAR, CL:CDR, and CL:NULL but for cold values
(defun cold-car (des)
  (aver (= (descriptor-lowtag des) sb!vm:list-pointer-lowtag))
  (read-wordindexed des sb!vm:cons-car-slot))
(defun cold-cdr (des)
  (aver (= (descriptor-lowtag des) sb!vm:list-pointer-lowtag))
  (read-wordindexed des sb!vm:cons-cdr-slot))
(defun cold-rplacd (des newval)
  (aver (= (descriptor-lowtag des) sb!vm:list-pointer-lowtag))
  (write-wordindexed des sb!vm:cons-cdr-slot newval)
  des)
(defun cold-null (des) (descriptor= des *nil-descriptor*))

;;; Given a cold representation of a function name, return a warm
;;; representation.
(declaim (ftype (function ((or symbol descriptor)) (or symbol list)) warm-fun-name))
(defun warm-fun-name (des)
  (let ((result
         (if (symbolp des)
             ;; This parallels the logic at the start of COLD-INTERN
             ;; which re-homes symbols in SB!XC to COMMON-LISP.
             (if (eq (symbol-package des) (find-package "SB!XC"))
                 (intern (symbol-name des) *cl-package*)
                 des)
             (ecase (descriptor-lowtag des)
              (#.sb!vm:list-pointer-lowtag
               (aver (not (cold-null des))) ; function named NIL? please no..
               (let ((rest (cold-cdr des)))
                 (aver (cold-null (cold-cdr rest)))
                 (list (warm-symbol (cold-car des))
                       (warm-symbol (cold-car rest)))))
              (#.sb!vm:other-pointer-lowtag
               (warm-symbol des))))))
    (legal-fun-name-or-type-error result)
    result))

#!+x86-64
(defun encode-fdefn-raw-addr (fdefn jump-target opcode)
  (let ((disp (- jump-target
                 (+ (descriptor-bits fdefn)
                    (- sb!vm:other-pointer-lowtag)
                    (ash sb!vm:fdefn-raw-addr-slot sb!vm:word-shift)
                    5))))
    (logior (ash (ldb (byte 32 0) (the (signed-byte 32) disp)) 8) opcode)))

(defun cold-fdefinition-object (cold-name &optional leave-fn-raw
                                          (gspace #!+immobile-space *immobile-fixedobj*
                                                  #!-immobile-space *dynamic*))
  (declare (type (or symbol descriptor) cold-name))
  (declare (special core-file-name))
  (let ((warm-name (warm-fun-name cold-name)))
    (or (gethash warm-name *cold-fdefn-objects*)
        (let ((fdefn (allocate-header+object gspace (1- sb!vm:fdefn-size) sb!vm:fdefn-widetag)))
          (setf (gethash warm-name *cold-fdefn-objects*) fdefn)
          (write-wordindexed fdefn sb!vm:fdefn-name-slot cold-name)
          (write-wordindexed fdefn sb!vm:fdefn-fun-slot *nil-descriptor*)
          (unless leave-fn-raw
            (let ((tramp
                   (or (lookup-assembler-reference
                        #!+(and x86-64 immobile-code) 'sb!vm::undefined-fdefn
                        #!-(and x86-64 immobile-code) 'sb!vm::undefined-tramp
                        :direct core-file-name)
                       ;; Our preload for the tramps doesn't happen during host-1,
                       ;; so substitute a usable value.
                       0)))
              (write-wordindexed/raw fdefn sb!vm:fdefn-raw-addr-slot
                                     #!+(and immobile-code x86-64)
                                     (encode-fdefn-raw-addr fdefn tramp #xE8)
                                     #!-immobile-code tramp)))
          fdefn))))

(defun cold-fun-entry-addr (fun)
  (aver (= (descriptor-lowtag fun) sb!vm:fun-pointer-lowtag))
  (+ (descriptor-bits fun)
     (- sb!vm:fun-pointer-lowtag)
     (ash sb!vm:simple-fun-code-offset sb!vm:word-shift)))

;;; Handle a DEFUN in cold-load.
(defun cold-fset (name defn &optional inline-expansion dxable-args)
  (binding* (((cold-name warm-name)
              ;; (SETF f) was descriptorized when dumped, symbols were not.
                     (if (symbolp name)
                         (values (cold-intern name) name)
                         (values name (warm-fun-name name))))
                    (fdefn (cold-fdefinition-object cold-name t)))
    (unless (cold-null (cold-fdefn-fun fdefn))
      (error "Duplicate DEFUN for ~S" warm-name))
    ;; There can't be any closures or funcallable instances.
    (aver (= (logand (read-bits-wordindexed defn 0) sb!vm:widetag-mask)
             sb!vm:simple-fun-widetag))
    (push (cold-list cold-name inline-expansion dxable-args) *!cold-defuns*)
    (write-wordindexed fdefn sb!vm:fdefn-fun-slot defn)
    (let ((fun-entry-addr
            (+ (logandc2 (descriptor-bits defn) sb!vm:lowtag-mask)
               (ash sb!vm:simple-fun-code-offset sb!vm:word-shift))))
      (declare (ignorable fun-entry-addr)) ; sparc and arm don't need
      #!+(and immobile-code x86-64)
      (write-wordindexed/raw fdefn sb!vm:fdefn-raw-addr-slot
                             (encode-fdefn-raw-addr fdefn fun-entry-addr #xE9))
      #!-immobile-code
      (progn
        #!+(or sparc arm) (write-wordindexed fdefn sb!vm:fdefn-raw-addr-slot defn)
        #!-(or sparc arm) (write-wordindexed/raw fdefn sb!vm:fdefn-raw-addr-slot
                                                 fun-entry-addr)))
    fdefn))

;;; Handle a DEFMETHOD in cold-load. "Very easily done". Right.
(defun cold-defmethod (name &rest stuff)
  (let ((gf (assoc name *cold-methods*)))
    (unless gf
      (setq gf (cons name nil))
      (push gf *cold-methods*))
    (push stuff (cdr gf))))

(defun attach-classoid-cells-to-symbols (hashtable)
  (let ((num (sb!c::meta-info-number (sb!c::meta-info :type :classoid-cell)))
        (layout (gethash 'sb!kernel::classoid-cell *cold-layouts*)))
    (when (plusp (hash-table-count *classoid-cells*))
      (aver layout))
    ;; Iteration order is immaterial. The symbols will get sorted later.
    (maphash (lambda (symbol cold-classoid-cell)
               ;; Some classoid-cells are dumped before the cold layout
               ;; of classoid-cell has been made, so fix those cases now.
               ;; Obviously it would be better if, in general, ALLOCATE-STRUCT
               ;; knew when something later must backpatch a cold layout
               ;; so that it could make a note to itself to do those ASAP
               ;; after the cold layout became known.
               (when (cold-null (cold-layout-of cold-classoid-cell))
                 (set-instance-layout cold-classoid-cell layout))
               (setf (gethash symbol hashtable)
                     (packed-info-insert
                      (gethash symbol hashtable +nil-packed-infos+)
                      sb!impl::+no-auxilliary-key+ num cold-classoid-cell)))
             *classoid-cells*))
  hashtable)

;; Create pointer from SYMBOL and/or (SETF SYMBOL) to respective fdefinition
;;
(defun attach-fdefinitions-to-symbols (hashtable)
    ;; Collect fdefinitions that go with one symbol, e.g. CAR and (SETF CAR),
    ;; using the host's code for manipulating a packed info-vector.
    (maphash (lambda (warm-name cold-fdefn)
               (with-globaldb-name (key1 key2) warm-name
                 :hairy (error "Hairy fdefn name in genesis: ~S" warm-name)
                 :simple
                 (setf (gethash key1 hashtable)
                       (packed-info-insert
                        (gethash key1 hashtable +nil-packed-infos+)
                        key2 +fdefn-info-num+ cold-fdefn))))
              *cold-fdefn-objects*)
    hashtable)

(defun dump-symbol-info-vectors (hashtable)
    ;; Emit in the same order symbols reside in core to avoid
    ;; sensitivity to the iteration order of host's maphash.
    (loop for (warm-sym . info)
          in (sort (%hash-table-alist hashtable) #'<
                   :key (lambda (x) (descriptor-bits (cold-intern (car x)))))
          do (write-wordindexed
              (cold-intern warm-sym) sb!vm:symbol-info-slot
              ;; Each vector will have one fixnum, possibly the symbol SETF,
              ;; and one or two #<fdefn> objects in it, and/or a classoid-cell.
              (vector-in-core
                     (map 'list (lambda (elt)
                                  (etypecase elt
                                    (symbol (cold-intern elt))
                                    (fixnum (make-fixnum-descriptor elt))
                                    (descriptor elt)))
                          info)))))


;;;; fixups and related stuff

;;; an EQUAL hash table
(defvar *cold-foreign-symbol-table*)
(declaim (type hash-table *cold-foreign-symbol-table*))

;; Read the sbcl.nm file to find the addresses for foreign-symbols in
;; the C runtime.
#!-sb-dynamic-core
(defun load-cold-foreign-symbol-table (filename)
  (with-open-file (file filename)
    (loop for line = (read-line file nil nil)
          while line do
          ;; UNIX symbol tables might have tabs in them, and tabs are
          ;; not in Common Lisp STANDARD-CHAR, so there seems to be no
          ;; nice portable way to deal with them within Lisp, alas.
          ;; Fortunately, it's easy to use UNIX command line tools like
          ;; sed to remove the problem, so it's not too painful for us
          ;; to push responsibility for converting tabs to spaces out to
          ;; the caller.
          ;;
          ;; Other non-STANDARD-CHARs are problematic for the same reason.
          ;; Make sure that there aren't any..
          (let ((ch (find-if (lambda (char)
                               (not (typep char 'standard-char)))
                             line)))
            (when ch
              (error "non-STANDARD-CHAR ~S found in foreign symbol table:~%~S"
                     ch
                     line)))
          (setf line (string-trim '(#\space) line))
          (let ((p1 (position #\space line :from-end nil))
                (p2 (position #\space line :from-end t)))
            (if (not (and p1 p2 (< p1 p2)))
                ;; KLUDGE: It's too messy to try to understand all
                ;; possible output from nm, so we just punt the lines we
                ;; don't recognize. We realize that there's some chance
                ;; that might get us in trouble someday, so we warn
                ;; about it.
                (warn "ignoring unrecognized line ~S in ~A" line filename)
                (multiple-value-bind (value name)
                    (if (string= "0x" line :end2 2)
                        (values (parse-integer line :start 2 :end p1 :radix 16)
                                (subseq line (1+ p2)))
                        (values (parse-integer line :end p1 :radix 16)
                                (subseq line (1+ p2))))
                  ;; KLUDGE CLH 2010-05-31: on darwin, nm gives us
                  ;; _function but dlsym expects us to look up
                  ;; function, without the leading _ . Therefore, we
                  ;; strip it off here.
                  #!+darwin
                  (when (equal (char name 0) #\_)
                    (setf name (subseq name 1)))
                  (multiple-value-bind (old-value found)
                      (gethash name *cold-foreign-symbol-table*)
                    (when (and found
                               (not (= old-value value)))
                      (warn "redefining ~S from #X~X to #X~X"
                            name old-value value)))
                  (setf (gethash name *cold-foreign-symbol-table*) value)
                  #!+win32
                  (let ((at-position (position #\@ name)))
                    (when at-position
                      (let ((name (subseq name 0 at-position)))
                        (multiple-value-bind (old-value found)
                            (gethash name *cold-foreign-symbol-table*)
                          (when (and found
                                     (not (= old-value value)))
                            (warn "redefining ~S from #X~X to #X~X"
                                  name old-value value)))
                        (setf (gethash name *cold-foreign-symbol-table*)
                              value)))))))))
  (values))     ;; PROGN

#!-sb-dynamic-core
(defun cold-foreign-symbol-address (name)
  (declare (ignorable name))
  #!+crossbuild-test #xf00fa8 ; any random 4-octet-aligned value should do
  #!-crossbuild-test
  (or (find-foreign-symbol-in-table name *cold-foreign-symbol-table*)
      *foreign-symbol-placeholder-value*
      (progn
        (format *error-output* "~&The foreign symbol table is:~%")
        (maphash (lambda (k v)
                   (format *error-output* "~&~S = #X~8X~%" k v))
                 *cold-foreign-symbol-table*)
        (error "The foreign symbol ~S is undefined." name))))

(defvar *cold-assembler-obj*) ; a single code component
(defvar *cold-assembler-routines*)
(defvar *cold-static-call-fixups*)

;;; Basically the same as the real CODE-HEADER-WORDS * n-word-bytes
(defun code-header-bytes (code-object) ; Return boxed part size in bytes
  (* (ash (get-header-data code-object) (+ #!+64-bit -24))
     sb!vm:n-word-bytes))

(defun lookup-assembler-reference (symbol &optional (mode :direct) (errorp t))
  (let* ((code-component *cold-assembler-obj*)
         (list *cold-assembler-routines*)
         (offset (or (cdr (assq symbol list))
                     (and errorp (error "Assembler routine ~S not defined." symbol)))))
    (when offset
      (+ (logandc2 (descriptor-bits code-component) sb!vm:lowtag-mask)
         (ecase mode
           (:direct
            (+ (code-header-bytes code-component) offset))
           (:indirect
            (ash (+ (round-up sb!vm:code-constants-offset 2)
                    (count-if (lambda (x) (< (cdr x) offset)) list))
                 sb!vm:word-shift)))))))

;;; Unlike in the target, FOP-KNOWN-FUN sometimes has to backpatch.
(defvar *deferred-known-fun-refs*)

;;; In case we need to store code fixups in code objects.
;;; At present only the x86 backends use this
(defvar *code-fixup-notes*)
(defvar *allocation-point-fixup-notes*)

(declaim (ftype (sfunction (descriptor sb!vm:word sb!vm:word keyword keyword)
                           descriptor)
                cold-fixup))
(defun cold-fixup (code-object after-header value kind flavor)
  (declare (ignorable flavor))
  (let* ((offset-within-code-object
          (+ (code-header-bytes code-object) after-header))
         (gspace-byte-offset (+ (descriptor-byte-offset code-object)
                                offset-within-code-object)))
    #!-(or x86 x86-64)
    (sb!vm::fixup-code-object code-object gspace-byte-offset value kind flavor)

    #!+(or x86 x86-64)
    (let* ((gspace-data (descriptor-mem code-object))
           (obj-start-addr (logandc2 (descriptor-bits code-object) sb!vm:lowtag-mask))
           (code-end-addr
            (+ obj-start-addr
               (code-header-bytes code-object)
               (descriptor-fixnum
                (read-wordindexed code-object sb!vm:code-code-size-slot))))
           (gspace-base (gspace-byte-address (descriptor-gspace code-object)))
           (in-dynamic-space
            (= (gspace-identifier (descriptor-intuit-gspace code-object))
               dynamic-core-space-id))
           (addr (+ value
                    (sb!vm::sign-extend (bvref-32 gspace-data gspace-byte-offset)
                                        32))))

      (declare (ignorable code-end-addr in-dynamic-space))
      (assert (= obj-start-addr
                 (+ gspace-base (descriptor-byte-offset code-object))))

      ;; FIXME: every other backend has the code factored out nicely into
      ;; {target}-vm.lisp, but x86 doesn't. Is it really so impossible?
      ;; See FIXUP-CODE-OBJECT in x86-vm.lisp and x86-64-vm.lisp.
      ;; Except for the use of saps, this is basically identical.
      (when (ecase kind
             (:absolute
              (setf (bvref-32 gspace-data gspace-byte-offset)
                    (the (unsigned-byte 32) addr))
              ;; Absolute fixups are recorded if within the object for x86.
              #!+x86 (and in-dynamic-space
                          (< obj-start-addr addr code-end-addr))
              ;; Absolute fixups on x86-64 do not refer to this code component,
              ;; because we have RIP-relative addressing, but references to
              ;; other immobile-space objects must be recorded.
              #!+x86-64
              (member flavor '(:named-call :layout :immobile-object
                               :assembly-routine :static-call)))
             #!+x86-64
             (:absolute64
              (setf (bvref-64 gspace-data gspace-byte-offset)
                    (the (unsigned-byte 64) addr))
              ;; Never record it. (FIXME: this is a problem for relocatable heap)
              nil)
             (:relative ; (used for arguments to X86 relative CALL instruction)
              (setf (bvref-32 gspace-data gspace-byte-offset)
                    (the (signed-byte 32)
                      (- addr (+ gspace-base gspace-byte-offset 4)))) ; 4 = size of rel32off
              ;; Relative fixups are recorded if outside of the object.
              ;; Except that read-only space contains calls to asm routines,
              ;; and we don't record those fixups.
              #!+x86 (and in-dynamic-space
                          (not (< obj-start-addr addr code-end-addr)))
              #!+x86-64 (eq flavor :foreign)))
        (push (cons kind after-header)
              (gethash (descriptor-bits code-object) *code-fixup-notes*)))))
  code-object)

(defun resolve-static-call-fixups ()
  (dolist (fixup *cold-static-call-fixups*)
    (destructuring-bind (name kind code offset) fixup
      (cold-fixup code offset
                  (cold-fun-entry-addr (cold-symbol-function name))
                  kind :static-call))))

;;; Save packed lists of absolute and relative fixups.
;;; (cf. FINISH-FIXUPS in generic/target-core.)
(defun repack-fixups (list)
  (collect ((relative) (absolute))
    (dolist (item list)
      (ecase (car item)
        (:relative (relative (cdr item)))
        (:absolute (absolute (cdr item)))))
    (number-to-core (sb!c::pack-code-fixup-locs (absolute) (relative)))))

#!+sb-dynamic-core
(defun dyncore-note-symbol (symbol-name datap)
  "Register a symbol and return its address in proto-linkage-table."
  (+ sb!vm:linkage-table-space-start
     (* sb!vm:linkage-table-entry-size
        (ensure-gethash (if datap (list symbol-name) symbol-name)
                        *cold-foreign-symbol-table*
                        (hash-table-count *cold-foreign-symbol-table*)))))

;;; Leave space for this many assembly routine addresses so that we can create
;;; a vector of entrypoints in the code component header, allowing for
;;; memory-indirect call on x86 where would otherwise a register would be needed
;;; due to lack of an absolute call instruction.
(defconstant asm-routine-table-size ; must be a multiple of 2
  (+ #!+x86    40
     #!+x86-64 64))

;;; *COLD-FOREIGN-SYMBOL-TABLE* becomes *!INITIAL-FOREIGN-SYMBOLS* in
;;; the core. When the core is loaded, !LOADER-COLD-INIT uses this to
;;; create *STATIC-FOREIGN-SYMBOLS*, which the code in
;;; target-load.lisp refers to.
(defun foreign-symbols-to-core ()
  (flet ((to-core (list transducer target-symbol)
           (cold-set target-symbol (vector-in-core (mapcar transducer list)))))
    #!-sb-dynamic-core
    ;; Sort by name
    (to-core (sort (%hash-table-alist *cold-foreign-symbol-table*) #'string< :key #'car)
             (lambda (symbol)
               (cold-cons (set-readonly (base-string-to-core (car symbol)))
                          (number-to-core (cdr symbol))))
             '*!initial-foreign-symbols*)
    #!+sb-dynamic-core
    ;; Sort by index into linkage table
    (to-core (sort (%hash-table-alist *cold-foreign-symbol-table*) #'< :key #'cdr)
             (lambda (pair &aux (key (car pair))
                                (sym (set-readonly (base-string-to-core
                                                    (if (listp key) (car key) key)))))
               (if (listp key) (cold-list sym) sym))
             'sb!vm::+required-foreign-symbols+)
    (cold-set (cold-intern '*assembler-routines*) *cold-assembler-obj*)
    (setq *cold-assembler-routines*
          (sort *cold-assembler-routines* #'< :key #'cdr))
    (when (plusp asm-routine-table-size)
      ;; The number of routines must be strictly less than the table size
      ;; so that there's room for a 0 word marking the end of the list.
      (unless (< (length *cold-assembler-routines*) asm-routine-table-size)
        (bug "Please increase ASM-ROUTINE-TABLE-SIZE for this platform"))
      (let ((index (round-up sb!vm:code-constants-offset 2)))
        (dolist (item *cold-assembler-routines*)
          (write-wordindexed/raw *cold-assembler-obj* index
                                 (lookup-assembler-reference (car item)))
          (incf index))))
    (to-core *cold-assembler-routines*
             (lambda (rtn)
               (cold-cons (cold-intern (first rtn)) (make-fixnum-descriptor (cdr rtn))))
             '*!initial-assembler-routines*)))


;;;; general machinery for cold-loading FASL files

(defun pop-fop-stack (stack)
  (let ((top (svref stack 0)))
    (declare (type index top))
    (when (eql 0 top)
      (error "FOP stack empty"))
    (setf (svref stack 0) (1- top))
    (svref stack top)))

;;; Cause a fop to have a special definition for cold load.
;;;
;;; This is similar to DEFINE-FOP, but unlike DEFINE-FOP, this version
;;; looks up the encoding for this name (created by a previous DEFINE-FOP)
;;; instead of creating a new encoding.
(defmacro define-cold-fop ((name &optional arglist) &rest forms)
  #+c-headers-only (declare (ignore name arglist forms))
  #-c-headers-only
  (let* ((code (get name 'opcode))
         (argc (aref (car **fop-signatures**) code))
         (fname (symbolicate "COLD-" name)))
    (unless code
      (error "~S is not a defined FOP." name))
    (when (and (plusp argc) (not (singleton-p arglist)))
      (error "~S must take one argument" name))
    `(progn
       (defun ,fname (.fasl-input. ,@arglist)
         (declare (ignorable .fasl-input.))
         (macrolet ((fasl-input () '(the fasl-input .fasl-input.))
                    (fasl-input-stream () '(%fasl-input-stream (fasl-input)))
                    (pop-stack ()
                      '(pop-fop-stack (%fasl-input-stack (fasl-input)))))
           ,@forms))
       ;; We simply overwrite elements of **FOP-FUNS** since the contents
       ;; of the host are never propagated directly into the target core.
       ,@(loop for i from code to (logior code (if (plusp argc) 3 0))
               collect `(setf (svref **fop-funs** ,i) #',fname)))))

;;; Cause a fop to be undefined in cold load.
(defmacro not-cold-fop (name)
  `(define-cold-fop (,name)
     (error "The fop ~S is not supported in cold load." ',name)))

;;; COLD-LOAD loads stuff into the core image being built by calling
;;; LOAD-AS-FASL with the fop function table rebound to a table of cold
;;; loading functions.
(defun cold-load (filename verbose)
  "Load the file named by FILENAME into the cold load image being built."
  (when verbose
    (write-line (namestring filename)))
  (with-open-file (s filename :element-type '(unsigned-byte 8))
    (load-as-fasl s nil nil)))

;;;; miscellaneous cold fops

(define-cold-fop (fop-misc-trap) *unbound-marker*)

(define-cold-fop (fop-character (c))
  (make-character-descriptor c))

(define-cold-fop (fop-empty-list) nil)
(define-cold-fop (fop-truth) t)

(define-cold-fop (fop-struct (size)) ; n-words incl. layout, excluding header
  (let* ((layout (pop-stack))
         (result (allocate-struct *dynamic* layout size))
         (bitmap (descriptor-fixnum
                  (read-slot layout *host-layout-of-layout* :bitmap))))
    ;; Raw slots can not possibly work because dump-struct uses
    ;; %RAW-INSTANCE-REF/WORD which does not exist in the cross-compiler.
    ;; Remove this assertion if that problem is somehow circumvented.
    (unless (eql bitmap sb!kernel::+layout-all-tagged+)
      (error "Raw slots not working in genesis."))
    (loop for index downfrom (1- size) to sb!vm:instance-data-start
          for val = (pop-stack) then (pop-stack)
          do (write-wordindexed result
                                (+ index sb!vm:instance-slots-offset)
                                (if (logbitp index bitmap)
                                    val
                                    (descriptor-word-sized-integer val))))
    result))

(define-cold-fop (fop-layout)
  (let* ((bitmap-des (pop-stack))
         (length-des (pop-stack))
         (depthoid-des (pop-stack))
         (cold-inherits (pop-stack))
         (name (pop-stack))
         (old-layout-descriptor (gethash name *cold-layouts*)))
    (declare (type descriptor length-des depthoid-des cold-inherits))
    (declare (type symbol name))
    ;; If a layout of this name has been defined already
    (if old-layout-descriptor
      ;; Enforce consistency between the previous definition and the
      ;; current definition, then return the previous definition.
      (flet ((get-slot (keyword)
               (read-slot old-layout-descriptor *host-layout-of-layout* keyword)))
        (let ((old-length (descriptor-fixnum (get-slot :length)))
              (old-depthoid (descriptor-fixnum (get-slot :depthoid)))
              (old-bitmap (host-object-from-core (get-slot :bitmap)))
              (length (descriptor-fixnum length-des))
              (depthoid (descriptor-fixnum depthoid-des))
              (bitmap (host-object-from-core bitmap-des)))
          (unless (= length old-length)
            (error "cold loading a reference to class ~S when the compile~%~
                    time length was ~S and current length is ~S"
                   name
                   length
                   old-length))
          (unless (cold-vector-elements-eq cold-inherits (get-slot :inherits))
            (error "cold loading a reference to class ~S when the compile~%~
                    time inherits were ~S~%~
                    and current inherits are ~S"
                   name
                   (listify-cold-inherits cold-inherits)
                   (listify-cold-inherits (get-slot :inherits))))
          (unless (= depthoid old-depthoid)
            (error "cold loading a reference to class ~S when the compile~%~
                    time inheritance depthoid was ~S and current inheritance~%~
                    depthoid is ~S"
                   name
                   depthoid
                   old-depthoid))
          (unless (= bitmap old-bitmap)
            (error "cold loading a reference to class ~S when the compile~%~
                    time raw-slot-bitmap was ~S and is currently ~S"
                   name bitmap old-bitmap)))
        old-layout-descriptor)
      ;; Make a new definition from scratch.
      (make-cold-layout name length-des cold-inherits depthoid-des bitmap-des))))

;;;; cold fops for loading symbols

;;; Load a symbol SIZE characters long from FASL-INPUT, and
;;; intern that symbol in PACKAGE.
(defun cold-load-symbol (length+flag package fasl-input)
  (let ((string (make-string (ash length+flag -1))))
    (read-string-as-bytes (%fasl-input-stream fasl-input) string)
    (push-fop-table (intern string package) fasl-input)))

;; I don't feel like hacking up DEFINE-COLD-FOP any more than necessary,
;; so this code is handcrafted to accept two operands.
#-c-headers-only
(flet ((fop-cold-symbol-in-package-save (fasl-input length+flag pkg-index)
         (cold-load-symbol length+flag (ref-fop-table fasl-input pkg-index)
                           fasl-input)))
  (let ((i (get 'fop-symbol-in-package-save 'opcode)))
    (fill **fop-funs** #'fop-cold-symbol-in-package-save :start i :end (+ i 4))
    (values)))

(define-cold-fop (fop-lisp-symbol-save (length+flag))
  (cold-load-symbol length+flag *cl-package* (fasl-input)))

(define-cold-fop (fop-keyword-symbol-save (length+flag))
  (cold-load-symbol length+flag *keyword-package* (fasl-input)))

(define-cold-fop (fop-uninterned-symbol-save (length+flag))
  (let ((name (make-string (ash length+flag -1))))
    (read-string-as-bytes (fasl-input-stream) name)
    (push-fop-table (get-uninterned-symbol name) (fasl-input))))

(define-cold-fop (fop-copy-symbol-save (index))
  (let* ((symbol (ref-fop-table (fasl-input) index))
         (name
          (if (symbolp symbol)
              (symbol-name symbol)
              (base-string-from-core
               (read-wordindexed symbol sb!vm:symbol-name-slot)))))
    ;; Genesis performs additional coalescing of uninterned symbols
    (push-fop-table (get-uninterned-symbol name) (fasl-input))))

;;;; cold fops for loading packages

(define-cold-fop (fop-named-package-save (namelen))
  (let ((name (make-string namelen)))
    (read-string-as-bytes (fasl-input-stream) name)
    (push-fop-table (find-package name) (fasl-input))))

;;;; cold fops for loading lists

;;; Make a list of the top LENGTH things on the fop stack. The last
;;; cdr of the list is set to LAST.
(defmacro cold-stack-list (length last)
  `(do* ((index ,length (1- index))
         (result ,last (cold-cons (pop-stack) result)))
        ((= index 0) result)
     (declare (fixnum index))))

(define-cold-fop (fop-list)
  (cold-stack-list (read-byte-arg (fasl-input-stream)) *nil-descriptor*))
(define-cold-fop (fop-list*)
  (cold-stack-list (read-byte-arg (fasl-input-stream)) (pop-stack)))
(define-cold-fop (fop-list-1)
  (cold-stack-list 1 *nil-descriptor*))
(define-cold-fop (fop-list-2)
  (cold-stack-list 2 *nil-descriptor*))
(define-cold-fop (fop-list-3)
  (cold-stack-list 3 *nil-descriptor*))
(define-cold-fop (fop-list-4)
  (cold-stack-list 4 *nil-descriptor*))
(define-cold-fop (fop-list-5)
  (cold-stack-list 5 *nil-descriptor*))
(define-cold-fop (fop-list-6)
  (cold-stack-list 6 *nil-descriptor*))
(define-cold-fop (fop-list-7)
  (cold-stack-list 7 *nil-descriptor*))
(define-cold-fop (fop-list-8)
  (cold-stack-list 8 *nil-descriptor*))
(define-cold-fop (fop-list*-1)
  (cold-stack-list 1 (pop-stack)))
(define-cold-fop (fop-list*-2)
  (cold-stack-list 2 (pop-stack)))
(define-cold-fop (fop-list*-3)
  (cold-stack-list 3 (pop-stack)))
(define-cold-fop (fop-list*-4)
  (cold-stack-list 4 (pop-stack)))
(define-cold-fop (fop-list*-5)
  (cold-stack-list 5 (pop-stack)))
(define-cold-fop (fop-list*-6)
  (cold-stack-list 6 (pop-stack)))
(define-cold-fop (fop-list*-7)
  (cold-stack-list 7 (pop-stack)))
(define-cold-fop (fop-list*-8)
  (cold-stack-list 8 (pop-stack)))

;;;; cold fops for loading vectors

(define-cold-fop (fop-base-string (len))
  (let ((string (make-string len)))
    (read-string-as-bytes (fasl-input-stream) string)
    (set-readonly (base-string-to-core string))))

#!+sb-unicode
(define-cold-fop (fop-character-string (len))
  (bug "CHARACTER-STRING[~D] dumped by cross-compiler." len))

(define-cold-fop (fop-vector (size))
  (if (zerop size)
      *simple-vector-0-descriptor*
      (let ((result (allocate-vector-object *dynamic*
                                            sb!vm:n-word-bits
                                            size
                                            sb!vm:simple-vector-widetag)))
        (do ((index (1- size) (1- index)))
            ((minusp index))
          (declare (fixnum index))
          (write-wordindexed result
                             (+ index sb!vm:vector-data-offset)
                             (pop-stack)))
        (set-readonly result))))

(define-cold-fop (fop-spec-vector)
  (let* ((len (read-word-arg (fasl-input-stream)))
         (type (read-byte-arg (fasl-input-stream)))
         (sizebits (aref **saetp-bits-per-length** type))
         (result (progn (aver (< sizebits 255))
                        (allocate-vector-object *dynamic* sizebits len type)))
         (start (+ (descriptor-byte-offset result)
                   (ash sb!vm:vector-data-offset sb!vm:word-shift)))
         (end (+ start
                 (ceiling (* len sizebits)
                          sb!vm:n-byte-bits))))
    (read-bigvec-as-sequence-or-die (descriptor-mem result)
                                    (fasl-input-stream)
                                    :start start
                                    :end end)
    (set-readonly result)))

(not-cold-fop fop-array)
#+nil
;; This code is unexercised. The only use of FOP-ARRAY is from target-dump.
;; It would be a shame to delete it though, as it might come in handy.
(define-cold-fop (fop-array)
  (let* ((rank (read-word-arg (fasl-input-stream)))
         (data-vector (pop-stack))
         (result (allocate-object *dynamic*
                                  (+ sb!vm:array-dimensions-offset rank)
                                  sb!vm:other-pointer-lowtag)))
    (write-header-word result rank sb!vm:simple-array-widetag)
    (write-wordindexed result sb!vm:array-fill-pointer-slot *nil-descriptor*)
    (write-wordindexed result sb!vm:array-data-slot data-vector)
    (write-wordindexed result sb!vm:array-displacement-slot *nil-descriptor*)
    (write-wordindexed result sb!vm:array-displaced-p-slot *nil-descriptor*)
    (write-wordindexed result sb!vm:array-displaced-from-slot *nil-descriptor*)
    (let ((total-elements 1))
      (dotimes (axis rank)
        (let ((dim (pop-stack)))
          (unless (is-fixnum-lowtag (descriptor-lowtag dim))
            (error "non-fixnum dimension? (~S)" dim))
          (setf total-elements (* total-elements (descriptor-fixnum dim)))
          (write-wordindexed result
                             (+ sb!vm:array-dimensions-offset axis)
                             dim)))
      (write-wordindexed result
                         sb!vm:array-elements-slot
                         (make-fixnum-descriptor total-elements)))
    result))


;;;; cold fops for loading numbers

(defmacro define-cold-number-fop (fop &optional arglist)
  ;; Invoke the ordinary warm version of this fop to cons the number.
  `(define-cold-fop (,fop ,arglist)
     (number-to-core (,fop (fasl-input) ,@arglist))))

(define-cold-number-fop fop-single-float)
(define-cold-number-fop fop-double-float)
(define-cold-number-fop fop-word-integer)
(define-cold-number-fop fop-byte-integer)
(define-cold-number-fop fop-complex-single-float)
(define-cold-number-fop fop-complex-double-float)
(define-cold-number-fop fop-integer (n-bytes))

(define-cold-fop (fop-ratio)
  (let ((den (pop-stack)))
    (number-pair-to-core (pop-stack) den sb!vm:ratio-widetag)))

(define-cold-fop (fop-complex)
  (let ((im (pop-stack)))
    (number-pair-to-core (pop-stack) im sb!vm:complex-widetag)))

;;;; cold fops for calling (or not calling)

(not-cold-fop fop-eval)
(not-cold-fop fop-eval-for-effect)

(defvar *load-time-value-counter*)

(flet ((pop-args (fasl-input)
         (let ((args)
               (stack (%fasl-input-stack fasl-input)))
           (dotimes (i (read-byte-arg (%fasl-input-stream fasl-input))
                       (values (pop-fop-stack stack) args))
             (push (pop-fop-stack stack) args))))
       (call (fun-name handler-name args)
         (acond ((get fun-name handler-name) (apply it args))
                (t (error "Can't ~S ~S in cold load" handler-name fun-name)))))

  (define-cold-fop (fop-funcall)
    (multiple-value-bind (fun args) (pop-args (fasl-input))
      (if args
          (case fun
           (fdefinition
            ;; Special form #'F fopcompiles into `(FDEFINITION ,f)
            (aver (and (singleton-p args) (symbolp (car args))))
            (cold-symbol-function (car args)))
           (cons (cold-cons (first args) (second args)))
           (symbol-global-value (cold-symbol-value (first args)))
           (t (call fun :sb-cold-funcall-handler/for-value args)))
          (let ((counter *load-time-value-counter*))
            (push (cold-list (cold-intern :load-time-value) fun
                             (number-to-core counter)) *!cold-toplevels*)
            (setf *load-time-value-counter* (1+ counter))
            (make-ltv-patch counter)))))

  (define-cold-fop (fop-funcall-for-effect)
    (multiple-value-bind (fun args) (pop-args (fasl-input))
      (if (not args)
          (push fun *!cold-toplevels*)
          (case fun
            (sb!impl::%defun (apply #'cold-fset args))
            (sb!pcl::!trivial-defmethod (apply #'cold-defmethod args))
            (sb!kernel::%defstruct
             (push args *known-structure-classoids*)
             (push (apply #'cold-list (cold-intern 'defstruct) args)
                   *!cold-toplevels*))
            (sb!c::%defconstant
             (destructuring-bind (name val . rest) args
               (cold-set name (if (symbolp val) (cold-intern val) val))
               (push (cold-cons (cold-intern name) (list-to-core rest))
                     *!cold-defconstants*)))
            (set
             (aver (= (length args) 2))
             (cold-set (first args)
                       (let ((val (second args)))
                         (if (symbolp val) (cold-intern val) val))))
            (%svset (apply 'cold-svset args))
            (t (call fun :sb-cold-funcall-handler/for-effect args)))))))

;;; Needed for certain L-T-V lambdas that use the -NO-SKIP variant of funcall.
#-c-headers-only
(setf (svref **fop-funs** (get 'fop-funcall-no-skip 'opcode))
      (svref **fop-funs** (get 'fop-funcall 'opcode)))

(defun finalize-load-time-value-noise ()
  (cold-set '*!load-time-values*
            (allocate-vector-object *dynamic*
                                    sb!vm:n-word-bits
                                    *load-time-value-counter*
                                    sb!vm:simple-vector-widetag)))


;;;; cold fops for fixing up circularities

(define-cold-fop (fop-rplaca)
  (let ((obj (ref-fop-table (fasl-input) (read-word-arg (fasl-input-stream))))
        (idx (read-word-arg (fasl-input-stream))))
    (write-wordindexed (cold-nthcdr idx obj) 0 (pop-stack))))

(define-cold-fop (fop-rplacd)
  (let ((obj (ref-fop-table (fasl-input) (read-word-arg (fasl-input-stream))))
        (idx (read-word-arg (fasl-input-stream))))
    (write-wordindexed (cold-nthcdr idx obj) 1 (pop-stack))))

(define-cold-fop (fop-svset)
  (let ((obj (ref-fop-table (fasl-input) (read-word-arg (fasl-input-stream))))
        (idx (read-word-arg (fasl-input-stream))))
    (write-wordindexed obj
                   (+ idx
                      (ecase (descriptor-lowtag obj)
                        (#.sb!vm:instance-pointer-lowtag 1)
                        (#.sb!vm:other-pointer-lowtag 2)))
                   (pop-stack))))

(define-cold-fop (fop-structset)
  (let ((obj (ref-fop-table (fasl-input) (read-word-arg (fasl-input-stream))))
        (idx (read-word-arg (fasl-input-stream))))
    (write-wordindexed obj (+ idx sb!vm:instance-slots-offset) (pop-stack))))

(define-cold-fop (fop-nthcdr)
  (cold-nthcdr (read-word-arg (fasl-input-stream)) (pop-stack)))

(defun cold-nthcdr (index obj)
  (dotimes (i index)
    (setq obj (read-wordindexed obj sb!vm:cons-cdr-slot)))
  obj)

;;;; cold fops for loading code objects and functions

(define-cold-fop (fop-fdefn)
  (cold-fdefinition-object (pop-stack)))

(define-cold-fop (fop-known-fun)
  (let ((name (pop-stack)))
    (or (cold-symbol-function name nil) ; no error if undefined
        `(:known-fun . ,name))))

;;; Setting this variable shows what code looks like before any
;;; fixups (or function headers) are applied.
(defvar *show-pre-fixup-code-p* nil)

;;; Invert GET-HEADER-DATA for a code object
(defun make-code-header-data (boxed-nwords)
  (ash (sb!vm::make-code-header-word boxed-nwords)
       (- sb!vm:n-widetag-bits)))

(defun cold-load-code (fasl-input code-size n-boxed-words)
  (macrolet ((pop-stack () '(pop-fop-stack (%fasl-input-stack fasl-input))))
     (let* (;; The number of constants is rounded up to even (if required)
            ;; to ensure that the code vector will be properly aligned.
            (aligned-n-boxed-words (align-up n-boxed-words sb!c::code-boxed-words-align))
            (immobile-p (pop-stack))
            (debug-info (pop-stack))
            (des (allocate-cold-descriptor
                  (or #!+immobile-code (and immobile-p *immobile-varyobj*) *dynamic*)
                  (+ (ash aligned-n-boxed-words sb!vm:word-shift) code-size)
                  sb!vm:other-pointer-lowtag)))
       (declare (ignorable immobile-p))
       (write-header-word des
                          (make-code-header-data aligned-n-boxed-words)
                          sb!vm:code-header-widetag)
       (write-wordindexed des sb!vm:code-code-size-slot
                          (make-fixnum-descriptor code-size))
       (write-wordindexed des sb!vm:code-debug-info-slot debug-info)
       (do ((index (1- n-boxed-words) (1- index)))
           ((< index sb!vm:code-constants-offset))
         (let ((obj (pop-stack)))
           (if (and (consp obj) (eq (car obj) :known-fun))
               (push (list* (cdr obj) des index) *deferred-known-fun-refs*)
               (write-wordindexed des index obj))))
       (let* ((start (+ (descriptor-byte-offset des)
                        (ash aligned-n-boxed-words sb!vm:word-shift)))
              (end (+ start code-size)))
         (read-bigvec-as-sequence-or-die (descriptor-mem des)
                                         (%fasl-input-stream fasl-input)
                                         :start start
                                         :end end)
         (when *show-pre-fixup-code-p*
           (format *trace-output*
                   "~&/raw code from code-fop ~W ~W:~%"
                   n-boxed-words code-size)
           (do ((i start (+ i sb!vm:n-word-bytes)))
               ((>= i end))
             (format *trace-output*
                     "/#X~8,'0x: #X~8,'0x~%"
                     (+ i (gspace-byte-address (descriptor-gspace des)))
                     (bvref-32 (descriptor-mem des) i)))))
       (apply-fixups (%fasl-input-stack fasl-input) des 0))))

#-c-headers-only
(let ((i (get 'fop-load-code 'opcode)))
  (fill **fop-funs** #'cold-load-code :start i :end (+ i 4))
  (values))

(defun resolve-deferred-known-funs ()
  (dolist (item *deferred-known-fun-refs*)
    (let ((fun (cold-symbol-function (car item)))
          (place (cdr item)))
      (write-wordindexed (car place) (cdr place) fun))))

(define-cold-fop (fop-alter-code (slot))
  (let ((value (pop-stack))
        (code (pop-stack)))
    (write-wordindexed code slot value)))

(defun compute-fun (code-object fun-index)
  (let ((fun-offset
         (bvref-32 (descriptor-mem code-object)
                   (+ (descriptor-byte-offset code-object)
                      (code-header-bytes code-object)
                      (descriptor-fixnum
                       (read-wordindexed code-object sb!vm:code-code-size-slot))
                      -2 ; skip back past the trailing CODE-N-ENTRIES
                      (* (1+ fun-index) -4))))) ; and back to the desired index
    (let ((fun (+ (logandc2 (descriptor-bits code-object) sb!vm:lowtag-mask)
                  (code-header-bytes code-object)
                  fun-offset)))
      (unless (zerop (logand fun sb!vm:lowtag-mask))
        (error "unaligned function entry ~S ~S" code-object fun-index))
      (make-descriptor (logior fun sb!vm:fun-pointer-lowtag)))))

(defun cold-fop-fun-entry (fasl-input fun-index)
  (binding* (((info type arglist name code-object)
              (macrolet ((pop-stack ()
                           '(pop-fop-stack (%fasl-input-stack fasl-input))))
                (values (pop-stack) (pop-stack) (pop-stack) (pop-stack) (pop-stack))))
             (fn (compute-fun code-object fun-index)))
    #!+(or x86 x86-64) ; store a machine-native pointer to the function entry
    ;; note that the bit pattern looks like fixnum due to alignment
    (write-wordindexed/raw fn sb!vm:simple-fun-self-slot
                           (+ (- (descriptor-bits fn) sb!vm:fun-pointer-lowtag)
                              (ash sb!vm:simple-fun-code-offset sb!vm:word-shift)))
    #!-(or x86 x86-64) ; store a pointer back to the function itself in 'self'
    (write-wordindexed fn sb!vm:simple-fun-self-slot fn)
    (write-wordindexed fn sb!vm:simple-fun-name-slot name)
    (write-wordindexed fn sb!vm:simple-fun-arglist-slot arglist)
    (write-wordindexed fn sb!vm:simple-fun-type-slot type)
    (write-wordindexed fn sb!vm::simple-fun-info-slot info)
    fn))

#-c-headers-only
(let ((i (get 'fop-fun-entry 'opcode)))
  (fill **fop-funs** #'cold-fop-fun-entry :start i :end (+ i 4))
  (values))

(define-cold-fop (fop-assembler-code)
  (let* ((length (read-word-arg (fasl-input-stream)))
         (rounded-length (round-up length (* 2 sb!vm:n-word-bytes)))
         (header-n-words
          ;; Note: we round the number of constants up to ensure that
          ;; the code vector will be properly aligned.
          (round-up sb!vm:code-constants-offset 2))
         (asm-code *cold-assembler-obj*)
         ;; OFFSET is the byte offset into CODE-INSTRUCTIONS
         ;; at which this newly loaded set of routines will begin.
         (offset (ash asm-routine-table-size sb!vm:word-shift))
         (space (or #!+immobile-space *immobile-varyobj* *read-only*)))
    (cond (asm-code
           (setq offset
                 (descriptor-fixnum (read-wordindexed asm-code
                                                      sb!vm:code-code-size-slot)))
           (aver (= (gspace-free-word-index space)
                    (+ (/ offset sb!vm:n-word-bytes) header-n-words)))
           (incf (gspace-free-word-index space) (/ rounded-length sb!vm:n-word-bytes)))
          (t
           (setq asm-code
                 (allocate-cold-descriptor
                  space
                  (+ (ash header-n-words sb!vm:word-shift) offset length)
                  sb!vm:other-pointer-lowtag))
           (setf *cold-assembler-obj* asm-code)
           (write-header-word asm-code
                              (make-code-header-data header-n-words)
                              sb!vm:code-header-widetag)))
    (write-wordindexed asm-code sb!vm:code-code-size-slot
                       (make-fixnum-descriptor (+ offset rounded-length)))
    (let ((start (+ (descriptor-byte-offset asm-code)
                    (ash header-n-words sb!vm:word-shift)
                    offset)))
      (read-bigvec-as-sequence-or-die (descriptor-mem asm-code)
                                      (fasl-input-stream)
                                      :start start
                                      :end (+ start length)))
    ;; Update the name -> address table.
    (dotimes (i (descriptor-fixnum (pop-stack)))
      (let ((offset (+ offset (descriptor-fixnum (pop-stack))))
            (name (pop-stack)))
        (push (cons name offset) *cold-assembler-routines*)))
    (apply-fixups (%fasl-input-stack (fasl-input)) asm-code offset)))

;;; Target variant of this is defined in 'target-load'
(defun apply-fixups (fop-stack code-obj extra-offset)
  (dotimes (i (descriptor-fixnum (pop-fop-stack fop-stack)) code-obj)
    (binding* ((info (descriptor-fixnum (pop-fop-stack fop-stack)))
               (sym (pop-fop-stack fop-stack))
               ((offset kind flavor) (!unpack-fixup-info info)))
      (incf offset extra-offset) ; for assembler routines
      (if (eq flavor :static-call)
          (push (list sym kind code-obj offset) *cold-static-call-fixups*)
          (cold-fixup
           code-obj offset
           (ecase flavor
             (:assembly-routine (lookup-assembler-reference sym))
             (:assembly-routine* (lookup-assembler-reference sym :indirect))
             (:foreign
              (let ((sym (base-string-from-core sym)))
                #!+sb-dynamic-core (dyncore-note-symbol sym nil)
                #!-sb-dynamic-core (cold-foreign-symbol-address sym)))
             (:foreign-dataref
              (let ((sym (base-string-from-core sym)))
                #!+sb-dynamic-core (dyncore-note-symbol sym t)
                #!-sb-dynamic-core
                (progn (maphash (lambda (k v)
                                  (format *error-output* "~&~S = #X~8X~%" k v))
                                *cold-foreign-symbol-table*)
                       (error "shared foreign symbol in cold load: ~S (~S)" sym kind))))
             (:code-object (descriptor-bits code-obj))
             #!+sb-thread ; ENSURE-SYMBOL-TLS-INDEX isn't defined otherwise
             (:symbol-tls-index (ensure-symbol-tls-index sym))
             (:layout (descriptor-bits (or (gethash sym *cold-layouts*)
                                           (error "No cold-layout for ~S~%" sym))))
             (:immobile-object
              ;; an interned symbol is represented by its host symbol,
              ;; but an uninterned symbol is a descriptor.
              (descriptor-bits (if (symbolp sym) (cold-intern sym) sym)))
             (:named-call
              (+ (descriptor-bits (cold-fdefinition-object sym))
                 (ash sb!vm:fdefn-raw-addr-slot sb!vm:word-shift)
                 (- sb!vm:other-pointer-lowtag))))
           kind flavor))
      (when (and (member sym '(sb!vm::enable-alloc-counter
                               sb!vm::enable-sized-alloc-counter))
                 ;; Ignore symbol fixups naming these assembly routines!
                 (member flavor '(:assembly-routine :assembly-routine*)))
        (push (cold-cons code-obj (make-fixnum-descriptor offset))
              *allocation-point-fixup-notes*)))))

;;;; sanity checking space layouts

(defun check-spaces ()
  ;;; Co-opt type machinery to check for intersections...
  (let (types)
    (flet ((check (start end space)
             (unless (< start end)
               (error "Bogus space: ~A" space))
             (let ((type (specifier-type `(integer ,start (,end)))))
               (dolist (other types)
                 (unless (eq *empty-type* (type-intersection (cdr other) type))
                   (error "Space overlap: ~A with ~A" space (car other))))
               (push (cons space type) types))))
      (check sb!vm:read-only-space-start sb!vm:read-only-space-end :read-only)
      (check sb!vm:static-space-start sb!vm:static-space-end :static)
      #!+gencgc
      (check sb!vm:dynamic-space-start
             (+ sb!vm:dynamic-space-start sb!vm::default-dynamic-space-size)
             :dynamic)
      #!+immobile-space
      ;; Must be a multiple of 32 because it makes the math a nicer
      ;; when computing word and bit index into the 'touched' bitmap.
      (assert (zerop (rem sb!vm:fixedobj-space-size
                          (* 32 sb!vm:immobile-card-bytes))))
      #!-gencgc
      (check sb!vm:dynamic-0-space-start sb!vm:dynamic-0-space-end :dynamic-0)
      #!+linkage-table
      (check sb!vm:linkage-table-space-start sb!vm:linkage-table-space-end :linkage-table))))

;;;; emitting C header file

(defun tailwise-equal (string tail)
  (and (>= (length string) (length tail))
       (string= string tail :start1 (- (length string) (length tail)))))

(defun write-boilerplate (*standard-output*)
  (format t "/*~%")
  (dolist (line
           '("This is a machine-generated file. Please do not edit it by hand."
             "(As of sbcl-0.8.14, it came from WRITE-CONFIG-H in genesis.lisp.)"
             nil
             "This file contains low-level information about the"
             "internals of a particular version and configuration"
             "of SBCL. It is used by the C compiler to create a runtime"
             "support environment, an executable program in the host"
             "operating system's native format, which can then be used to"
             "load and run 'core' files, which are basically programs"
             "in SBCL's own format."))
    (format t " *~@[ ~A~]~%" line))
  (format t " */~%"))

(defun c-name (string &optional strip)
  (delete #\+
          (substitute-if #\_ (lambda (c) (member c '(#\- #\/ #\%)))
                         (remove-if (lambda (c) (position c strip))
                                    string))))

(defun c-symbol-name (symbol &optional strip)
  (c-name (symbol-name symbol) strip))

(defun write-makefile-features (*standard-output*)
  ;; propagating SB!XC:*FEATURES* into the Makefiles
  (dolist (target-feature-name (sort (mapcar #'c-symbol-name sb!xc:*features*)
                                     #'string<))
    (format t "LISP_FEATURE_~A=1~%" target-feature-name)))

(defun write-config-h (*standard-output*)
  ;; propagating SB!XC:*FEATURES* into C-level #define's
  (dolist (target-feature-name (sort (mapcar #'c-symbol-name sb!xc:*features*)
                                     #'string<))
    (format t "#define LISP_FEATURE_~A~%" target-feature-name))
  (terpri)
  ;; and miscellaneous constants
  (format t "#define SBCL_VERSION_STRING ~S~%"
            (sb!xc:lisp-implementation-version))
  (format t "#define CORE_MAGIC 0x~X~%" core-magic)
  (format t "#ifndef LANGUAGE_ASSEMBLY~2%")
  (format t "#define LISPOBJ(x) ((lispobj)x)~2%")
  (format t "#else /* LANGUAGE_ASSEMBLY */~2%")
  (format t "#define LISPOBJ(thing) thing~2%")
  (format t "#endif /* LANGUAGE_ASSEMBLY */~2%")
  (terpri))

(defvar +c-literal-64bit+
  #!+(and win32 x86-64) "LLU" ; "long" is 32 bits, "long long" is 64 bits
  #!-(and win32 x86-64) "LU") ; "long" is 64 bits

(defun write-constants-h (*standard-output*)
  ;; writing entire families of named constants
  (let ((constants nil))
    (dolist (package-name '("SB!VM"
                            ;; We also propagate magic numbers
                            ;; related to file format,
                            ;; which live here instead of SB!VM.
                            "SB!FASL"
                            ;; Home package of some constants which aren't
                            ;; in the target Lisp but are propagated to C.
                            "SB-COREFILE"))
      (do-external-symbols (symbol (find-package package-name))
        (when (constantp symbol)
          (let ((name (symbol-name symbol)))
            (labels ( ;; shared machinery
                     (record (string priority suffix)
                       (push (list string
                                   priority
                                   (symbol-value symbol)
                                   suffix
                                   (documentation symbol 'variable))
                             constants))
                     ;; machinery for old-style CMU CL Lisp-to-C
                     ;; arbitrary renaming, being phased out in favor of
                     ;; the newer systematic RECORD-WITH-TRANSLATED-NAME
                     ;; renaming
                     (record-with-munged-name (prefix string priority)
                       (record (concatenate
                                'simple-string
                                prefix
                                (delete #\- (string-capitalize string)))
                               priority
                               ""))
                     (maybe-record-with-munged-name (tail prefix priority)
                       (when (tailwise-equal name tail)
                         (record-with-munged-name prefix
                                                  (subseq name 0
                                                          (- (length name)
                                                             (length tail)))
                                                  priority)))
                     ;; machinery for new-style SBCL Lisp-to-C naming
                     (record-with-translated-name (priority large)
                       (record (c-name name) priority
                               (if large +c-literal-64bit+ "")))
                     (maybe-record-with-translated-name (suffixes priority &key large)
                       (when (some (lambda (suffix)
                                     (tailwise-equal name suffix))
                                   suffixes)
                         (record-with-translated-name priority large))))
              (maybe-record-with-translated-name '("-LOWTAG"  "-ALIGN") 0)
              (maybe-record-with-translated-name '("-WIDETAG" "-SHIFT") 1)
              (maybe-record-with-munged-name "-FLAG" "flag_" 2)
              (maybe-record-with-munged-name "-TRAP" "trap_" 3)
              (maybe-record-with-munged-name "-SUBTYPE" "subtype_" 4)
              (maybe-record-with-translated-name '("SHAREABLE+" "SHAREABLE-NONSTD+") 4)
              (maybe-record-with-munged-name "-SC-NUMBER" "sc_" 5)
              (maybe-record-with-translated-name '("-SIZE" "-INTERRUPTS") 6)
              (maybe-record-with-translated-name '("-START" "-END" "-PAGE-BYTES"
                                                   "-CARD-BYTES" "-GRANULARITY")
                                                 7 :large t)
              (maybe-record-with-translated-name '("-CORE-ENTRY-TYPE-CODE") 8)
              (maybe-record-with-translated-name '("-CORE-SPACE-ID") 9)
              (maybe-record-with-translated-name '("-CORE-SPACE-ID-FLAG") 9)
              (maybe-record-with-translated-name '("-GENERATION+") 10))))))
    ;; KLUDGE: these constants are sort of important, but there's no
    ;; pleasing way to inform the code above about them.  So we fake
    ;; it for now.  nikodemus on #lisp (2004-08-09) suggested simply
    ;; exporting every numeric constant from SB!VM; that would work,
    ;; but the C runtime would have to be altered to use Lisp-like names
    ;; rather than the munged names currently exported.  --njf, 2004-08-09
    (dolist (c '(sb!vm:n-word-bits sb!vm:n-word-bytes
                 sb!vm:n-lowtag-bits sb!vm:lowtag-mask
                 sb!vm:n-widetag-bits sb!vm:widetag-mask
                 sb!vm:n-fixnum-tag-bits sb!vm:fixnum-tag-mask
                 sb!vm:short-header-max-words))
      (push (list (c-symbol-name c)
                  -1                    ; invent a new priority
                  (symbol-value c)
                  ""
                  nil)
            constants))
    ;; One more symbol that doesn't fit into the code above.
    (let ((c 'sb!impl::+magic-hash-vector-value+))
      (push (list (c-symbol-name c) 9 (symbol-value c) +c-literal-64bit+ nil)
            constants))
    ;; And still one more
    #!+64-bit
    (let ((c 'sb!vm::immediate-widetags-mask))
      (push (list (c-symbol-name c)
                  1
                  (logior (ash 1 (ash sb!vm:character-widetag -2))
                          (ash 1 (ash sb!vm:single-float-widetag -2))
                          (ash 1 (ash sb!vm:unbound-marker-widetag -2)))
                  "LU"
                  nil)
            constants))
    (setf constants
          (sort constants
                (lambda (const1 const2)
                  (if (= (second const1) (second const2))
                      (if (= (third const1) (third const2))
                          (string< (first const1) (first const2))
                          (< (third const1) (third const2)))
                      (< (second const1) (second const2))))))
    (let ((prev-priority (second (car constants))))
      (dolist (const constants)
        (destructuring-bind (name priority value suffix doc) const
          (unless (= prev-priority priority)
            (terpri)
            (setf prev-priority priority))
          (when (minusp value)
            (error "stub: negative values unsupported"))
          (format t "#define ~A ~A~A /* 0x~X ~@[ -- ~A ~]*/~%" name value suffix value doc))))
    (terpri))

  (format t "#define BACKEND_PAGE_BYTES ~D~%" sb!c:+backend-page-bytes+)
  #!+gencgc ; value never needed in Lisp, so therefore not a defconstant
  (format t "#define GENCGC_CARD_SHIFT ~D~%"
            (1- (integer-length sb!vm:gencgc-card-bytes)))

  (let ((size #!+cheneygc (- sb!vm:dynamic-0-space-end sb!vm:dynamic-0-space-start)
              #!+gencgc sb!vm::default-dynamic-space-size))
  ;; "-DDEFAULT_DYNAMIC_SPACE_SIZE=n" in CFLAGS will override this.
    (format t "#ifndef DEFAULT_DYNAMIC_SPACE_SIZE
#define DEFAULT_DYNAMIC_SPACE_SIZE ~D /* ~:*0x~X */
#endif~2%" size))

  ;; writing information about internal errors
  ;; Assembly code needs only the constants for UNDEFINED_[ALIEN_]FUN_ERROR
  ;; but to avoid imparting that knowledge here, we'll expose all error
  ;; number constants except for OBJECT-NOT-<x>-ERROR ones.
  (loop for (description name) across sb!c:+backend-internal-errors+
        for i from 0
        when (stringp description)
        do (format t "#define ~A ~D~%" (c-symbol-name name) i))

  (terpri)

  ;; FIXME: The SPARC has a PSEUDO-ATOMIC-TRAP that differs between
  ;; platforms. If we export this from the SB!VM package, it gets
  ;; written out as #define trap_PseudoAtomic, which is confusing as
  ;; the runtime treats trap_ as the prefix for illegal instruction
  ;; type things. We therefore don't export it, but instead do
  #!+sparc
  (when (boundp 'sb!vm::pseudo-atomic-trap)
    (format t
            "#define PSEUDO_ATOMIC_TRAP ~D /* 0x~:*~X */~%"
            sb!vm::pseudo-atomic-trap)
    (terpri))
  ;; possibly this is another candidate for a rename (to
  ;; pseudo-atomic-trap-number or pseudo-atomic-magic-constant
  ;; [possibly applicable to other platforms])

  #!+sb-safepoint
  (format t "#define GC_SAFEPOINT_PAGE_ADDR ((void*)0x~XUL) /* ~:*~A */~%"
            sb!vm:gc-safepoint-page-addr)
  #!+sb-safepoint
  (format t "#define GC_SAFEPOINT_TRAP_ADDR ((void*)0x~XUL) /* ~:*~A */~%"
            (+ sb!vm:gc-safepoint-page-addr
               sb!c:+backend-page-bytes+
               (- sb!vm:gc-safepoint-trap-offset)))

  (dolist (symbol '(sb!vm:float-traps-byte
                    sb!vm::float-exceptions-byte
                    sb!vm:float-sticky-bits
                    sb!vm::float-rounding-mode))
    (format t "#define ~A_POSITION ~A /* ~:*0x~X */~%"
            (c-symbol-name symbol)
            (sb!xc:byte-position (symbol-value symbol)))
    (format t "#define ~A_MASK 0x~X /* ~:*~A */~%"
            (c-symbol-name symbol)
            (sb!xc:mask-field (symbol-value symbol) -1))))

(defun write-errnames-h (stream)
  ;; C code needs strings for describe_internal_error()
  (format stream "#define INTERNAL_ERROR_NAMES ~{\\~%~S~^, ~}~2%"
          (map 'list 'sb!kernel::!c-stringify-internal-error
               sb!c:+backend-internal-errors+))
  (format stream "#define INTERNAL_ERROR_NARGS {~{~S~^, ~}}~2%"
          (map 'list #'cddr sb!c:+backend-internal-errors+)))

(defun write-tagnames-h (out)
  (labels
      ((pretty-name (symbol strip)
         (let ((name (string-downcase symbol)))
           (substitute #\Space #\-
                       (subseq name 0 (- (length name) (length strip))))))
       (list-sorted-tags (tail)
         (loop for symbol being the external-symbols of "SB!VM"
               when (and (constantp symbol)
                         (tailwise-equal (string symbol) tail)
                         ;; FIXME: these symbols are obsolete
                         (not (member symbol
                                      '(sb!vm:simple-fun-header-widetag
                                        sb!vm:closure-header-widetag))))
               collect symbol into tags
               finally (return (sort tags #'< :key #'symbol-value))))
       (write-tags (visibility kind limit ash-count)
         (format out "~%~Aconst char *~(~A~)_names[] = {~%"
                 visibility (subseq kind 1))
         (let ((tags (list-sorted-tags kind)))
           (dotimes (i limit)
             (if (eql i (ash (or (symbol-value (first tags)) -1) ash-count))
                 (format out "    \"~A\"" (pretty-name (pop tags) kind))
                 (format out "    \"unknown [~D]\"" i))
             (unless (eql i (1- limit))
               (write-string "," out))
             (terpri out)))
         (write-line "};" out)))
    (write-tags "static " "-LOWTAG" sb!vm:lowtag-limit 0)
    ;; this -2 shift depends on every OTHER-IMMEDIATE-?-LOWTAG
    ;; ending with the same 2 bits. (#b10)
    (write-tags "" "-WIDETAG" (ash (1+ sb!vm:widetag-mask) -2) -2))
  ;; Inform print_otherptr() of all array types that it's too dumb to print
  (let ((array-type-bits (make-array 32 :initial-element 0)))
    (flet ((toggle (b)
             (multiple-value-bind (ofs bit) (floor b 8)
               (setf (aref array-type-bits ofs) (ash 1 bit)))))
      (dovector (saetp sb!vm:*specialized-array-element-type-properties*)
        (unless (member (sb!vm:saetp-specifier saetp) '(character base-char t))
          (toggle (sb!vm:saetp-typecode saetp))
          (awhen (sb!vm:saetp-complex-typecode saetp) (toggle it)))))
    (format out
            "~%static unsigned char unprintable_array_types[32] =~% {~{~d~^,~}};~%"
            (coerce array-type-bits 'list)))
  (dolist (prim-obj '(symbol ratio complex sb!vm::code simple-fun
                      closure funcallable-instance
                      weak-pointer fdefn sb!vm::value-cell))
    (format out "static char *~A_slots[] = {~%~{ \"~A: \",~} NULL~%};~%"
            (c-name (string-downcase prim-obj))
            (mapcar (lambda (x) (c-name (string-downcase (sb!vm:slot-name x))))
                    (remove-if 'sb!vm:slot-rest-p
                               (sb!vm::primitive-object-slots
                                (find prim-obj sb!vm:*primitive-objects*
                                      :key 'sb!vm:primitive-object-name))))))
  (values))

(defun write-cast-operator (name c-name lowtag)
  (format t "static inline struct ~A* ~A(lispobj obj) {
  return (struct ~A*)(obj - ~D);~%}~%" c-name name c-name lowtag))

(defun write-primitive-object (obj *standard-output*)
  (let* ((name (sb!vm:primitive-object-name obj))
         (c-name (c-name (string-downcase name)))
         (slots (sb!vm:primitive-object-slots obj))
         (lowtag (or (symbol-value (sb!vm:primitive-object-lowtag obj)) 0)))
  ;; writing primitive object layouts
    (format t "#ifndef LANGUAGE_ASSEMBLY~2%")
    (format t "struct ~A {~%" c-name)
    (when (sb!vm:primitive-object-widetag obj)
      (format t "    lispobj header;~%"))
    (dolist (slot slots)
      (format t "    ~A ~A~@[[1]~];~%"
              (getf (sb!vm:slot-options slot) :c-type "lispobj")
              (c-name (string-downcase (sb!vm:slot-name slot)))
              (sb!vm:slot-rest-p slot)))
    (format t "};~%")
    (when (member name '(cons vector symbol fdefn))
      (write-cast-operator name c-name lowtag))
    (format t "~%#else /* LANGUAGE_ASSEMBLY */~2%")
    (format t "/* These offsets are SLOT-OFFSET * N-WORD-BYTES - LOWTAG~%")
    (format t " * so they work directly on tagged addresses. */~2%")
    (dolist (slot slots)
      (format t "#define ~A_~A_OFFSET ~D~%"
              (c-symbol-name name)
              (c-symbol-name (sb!vm:slot-name slot))
              (- (* (sb!vm:slot-offset slot) sb!vm:n-word-bytes) lowtag))))
  (format t "~%#endif /* LANGUAGE_ASSEMBLY */~2%"))

(defun write-structure-object (dd *standard-output*)
  (flet ((cstring (designator) (c-name (string-downcase designator))))
    (format t "#ifndef LANGUAGE_ASSEMBLY~2%")
    (format t "struct ~A {~%" (cstring (dd-name dd)))
    (format t "    lispobj header; // = word_0_~%")
    ;; "self layout" slots are named '_layout' instead of 'layout' so that
    ;; classoid's expressly declared layout isn't renamed as a special-case.
    #!-compact-instance-header (format t "    lispobj _layout;~%")
    ;; Output exactly the number of Lisp words consumed by the structure,
    ;; no more, no less. C code can always compute the padded length from
    ;; the precise length, but the other way doesn't work.
    (let ((names
           (coerce (loop for i from sb!vm:instance-data-start below (dd-length dd)
                         collect (list (format nil "word_~D_" (1+ i))))
                   'vector)))
      (dolist (slot (dd-slots dd))
        (let ((cell (aref names (- (dsd-index slot) sb!vm:instance-data-start)))
              (name (cstring (dsd-name slot))))
          (if (eq (dsd-raw-type slot) t)
              (rplaca cell name)
              (rplacd cell name))))
      (loop for slot across names
            do (format t "    lispobj ~A;~@[ // ~A~]~%" (car slot) (cdr slot))))
    (format t "};~%")
    (when (member (dd-name dd) '(layout))
      (write-cast-operator (dd-name dd) (cstring (dd-name dd))
                           sb!vm:instance-pointer-lowtag))
    (format t "~%#endif /* LANGUAGE_ASSEMBLY */~2%")))

(defun write-thread-init (stream)
  (dolist (binding sb!vm::!per-thread-c-interface-symbols)
    (format stream "INITIALIZE_TLS(~A, ~A);~%"
            (c-symbol-name (if (listp binding) (car binding) binding) "*")
            (if (listp binding) (second binding)))))

(defun write-static-symbols (stream)
  (dolist (symbol (cons nil (coerce sb!vm:+static-symbols+ 'list)))
    ;; FIXME: It would be nice to use longer names than NIL and
    ;; (particularly) T in #define statements.
    (format stream "#define ~A LISPOBJ(0x~X)~%"
            ;; FIXME: It would be nice not to need to strip anything
            ;; that doesn't get stripped always by C-SYMBOL-NAME.
            (c-symbol-name symbol "%*.!")
            (if *static*                ; if we ran GENESIS
              ;; We actually ran GENESIS, use the real value.
              (descriptor-bits (cold-intern symbol))
              ;; We didn't run GENESIS, so guess at the address.
              (+ sb!vm:static-space-start
                 sb!vm:n-word-bytes
                 sb!vm:other-pointer-lowtag
                 (if symbol (sb!vm:static-symbol-offset symbol) 0)))))
  #!+sb-thread
  (dolist (binding sb!vm::!per-thread-c-interface-symbols)
    (let* ((symbol (car (ensure-list binding)))
           (c-symbol (c-symbol-name symbol "*")))
      (unless (member symbol sb!vm::+common-static-symbols+)
        ;; So that "#ifdef thing" works, but not as a C expression
        (format stream "#define ~A (*)~%" c-symbol))
      (format stream "#define ~A_tlsindex 0x~X~%"
              c-symbol (ensure-symbol-tls-index symbol))))
  (loop for symbol in sb!vm::+c-callable-fdefns+
        for index from 0
        do
    (format stream "#define ~A_FDEFN LISPOBJ(0x~X)~%"
            (c-symbol-name symbol)
            (if *static*                ; if we ran GENESIS
              ;; We actually ran GENESIS, use the real value.
              (descriptor-bits (cold-fdefinition-object symbol))
              ;; We didn't run GENESIS, so guess at the address.
              (+ sb!vm:static-space-start
                 sb!vm:n-word-bytes
                 sb!vm:other-pointer-lowtag
                 (* (length sb!vm:+static-symbols+)
                    (sb!vm:pad-data-block sb!vm:symbol-size))
                 (* index (sb!vm:pad-data-block sb!vm:fdefn-size)))))))

(defun write-sc+offset-coding (stream)
  (flet ((write-array (name bytes)
           (format stream "static struct sc_and_offset_byte ~A[] = {~@
                      ~{    {~{ ~2D, ~2D ~}}~^,~%~}~@
                      };~2%"
                   name
                   (mapcar (lambda (byte)
                             (list (byte-size byte) (byte-position byte)))
                           bytes))))
    (format stream "struct sc_and_offset_byte {
    int size;
    int position;
};~2%")
    (write-array "sc_and_offset_sc_number_bytes" sb!c::+sc+offset-scn-bytes+)
    (write-array "sc_and_offset_offset_bytes"    sb!c::+sc+offset-offset-bytes+)))

;;;; writing map file

;;; Write a map file describing the cold load. Some of this
;;; information is subject to change due to relocating GC, but even so
;;; it can be very handy when attempting to troubleshoot the early
;;; stages of cold load.
(defun write-map (*standard-output*)
  (let ((*print-pretty* nil)
        (*print-case* :upcase))
    (format t "Table of contents~%")
    (format t "=================~%")
    (let ((sections '("assembler routines"
                      "defined functions"
                      "undefined functions"
                      "layouts"
                      "type specifiers"
                      "symbols")))
      (dotimes (i (length sections))
        (format t "~4<~@R.~> ~A~%" (1+ i) (nth i sections))))
    (format t "=================~2%")
    (format t "I. assembler routines defined in core image:~2%")
    (dolist (routine *cold-assembler-routines*)
      (let ((name (car routine)))
        (format t "~8,'0X: ~S~%" (lookup-assembler-reference name) name)))
    (let ((funs nil)
          (undefs nil))
      (maphash (lambda (name fdefn &aux (fun (cold-fdefn-fun fdefn)))
                 (let ((fdefn-bits (descriptor-bits fdefn)))
                   (if (cold-null fun)
                       (push `(,fdefn-bits ,name) undefs)
                       (push `(,fdefn-bits ,(descriptor-bits fun) ,name) funs))))
               *cold-fdefn-objects*)
      (format t "~%~|~%II. defined functions (alphabetically):

     FDEFN   FUNCTION  NAME
========== ==========  ====~:{~%~10,'0X ~10,'0X  ~S~}~%"
              (sort funs #'string<
                    :key (lambda (x) (fun-name-block-name (caddr x)))))

      (format t "~%~|
(a note about initially undefined function references: These functions
are referred to by code which is installed by GENESIS, but they are not
installed by GENESIS. This is not necessarily a problem; functions can
be defined later, by cold init toplevel forms, or in files compiled and
loaded at warm init, or elsewhere. As long as they are defined before
they are called, everything should be OK. Things are also OK if the
cross-compiler knew their inline definition and used that everywhere
that they were called before the out-of-line definition is installed,
as is fairly common for structure accessors.)

III. initially undefined function references (alphabetically):

     FDEFN  NAME
==========  ====~:{~%~10,'0X  ~S~}~%"
              (sort undefs
                    (lambda (a b &aux (pkg-a (package-name (symbol-package a)))
                                      (pkg-b (package-name (symbol-package b))))
                      (cond ((string< pkg-a pkg-b) t)
                            ((string> pkg-a pkg-b) nil)
                            (t (string< a b))))
                    :key (lambda (x) (fun-name-block-name (cadr x))))))

    (format t "~%~|~%IV. layout names:~2%")
    (dolist (x (sort-cold-layouts))
      (let* ((des (cdr x))
             (inherits (read-slot des *host-layout-of-layout* :inherits)))
        (format t "~8,'0X: ~S[~D]~%~10T~:S~%" (descriptor-bits des) (car x)
                  (cold-layout-length des) (listify-cold-inherits inherits))))

    (format t "~%~|~%V. parsed type specifiers:~2%")
    (mapc (lambda (cell)
            (format t "~X: ~S~%" (descriptor-bits (cdr cell)) (car cell)))
          (sort (%hash-table-alist *ctype-cache*) #'<
                :key (lambda (x) (descriptor-bits (cdr x))))))

    (format t "~%~|~%VI. symbols (numerically):~2%")
    (mapc (lambda (cell) (format t "~X: ~S~%" (car cell) (cdr cell)))
          (sort (%hash-table-alist *cold-symbols*) #'< :key #'car))

  (values))

;;;; writing core file

(defun output-gspace (gspace data-page core-file write-word verbose)
  (force-output core-file)
  (let* ((posn (file-position core-file))
         (bytes (* (gspace-free-word-index gspace) sb!vm:n-word-bytes))
         (pages (ceiling bytes sb!c:+backend-page-bytes+))
         (total-bytes (* pages sb!c:+backend-page-bytes+)))

    (file-position core-file (* sb!c:+backend-page-bytes+ (1+ data-page)))
    (when verbose
      (format t "writing ~S byte~:P [~S page~:P] from ~S~%"
              total-bytes pages gspace))

    ;; Note: It is assumed that the GSPACE allocation routines always
    ;; allocate whole pages (of size +backend-page-bytes+) and that any
    ;; empty gspace between the free pointer and the end of page will
    ;; be zero-filled. This will always be true under Mach on machines
    ;; where the page size is equal. (RT is 4K, PMAX is 4K, Sun 3 is
    ;; 8K).
    (write-bigvec-as-sequence (gspace-data gspace)
                              core-file
                              :end total-bytes
                              :pad-with-zeros t)
    (force-output core-file)
    (file-position core-file posn)

    ;; Write part of a (new) directory entry which looks like this:
    ;;   GSPACE IDENTIFIER
    ;;   WORD COUNT
    ;;   DATA PAGE
    ;;   ADDRESS
    ;;   PAGE COUNT
    (funcall write-word (gspace-identifier gspace))
    (funcall write-word (gspace-free-word-index gspace))
    (funcall write-word data-page)
    (funcall write-word (gspace-byte-address gspace))
    (funcall write-word pages)

    (+ data-page pages)))

#!+gencgc
(defun output-page-table (gspace data-page core-file write-word verbose)
  (declare (ignore verbose))
  ;; Write as many PTEs as there are pages used.
  ;; A corefile PTE is { uword_t scan_start_offset; page_bytes_t bytes_used; }
  (let* ((data-bytes (* (gspace-free-word-index gspace) sb!vm:n-word-bytes))
         (n-ptes (ceiling data-bytes sb!vm:gencgc-card-bytes))
         (sizeof-usage ; see similar expression in 'src/code/room'
          (if (typep sb!vm:gencgc-card-bytes '(unsigned-byte 16)) 2 4))
         (sizeof-corefile-pte (+ sb!vm:n-word-bytes sizeof-usage))
         (pte-bytes (round-up (* sizeof-corefile-pte n-ptes) sb!vm:n-word-bytes))
         (ptes (make-bigvec))
         (start 0))
    (expand-bigvec ptes pte-bytes)
    (dotimes (page-index n-ptes)
      ;; compute scan-start-offset
      (let ((sso (let* ((page-start (* page-index sb!vm:gencgc-card-bytes))
                        (p (position page-start (gspace-objects gspace)
                                     :test #'<= :start start)))
                   ;; P is the position in OBJECTS of the first object whose start
                   ;; is >= PAGE-START. If page-spanning, we want the preceding object
                   ;; because SCAN-START must satisfy the condition that it points to
                   ;; an object such that scanning from it will cover every byte of the
                   ;; page. If the very last item in OBJECTS spans pages, P will be NIL,
                   ;; because no object's start is >= PAGE-START.
                   (cond ((not p)
                          (setq p (1- (length (gspace-objects gspace)))))
                         ((> (aref (gspace-objects gspace) p) page-start)
                          (decf p)))
                   ;; This is an optimization, not a correctness requirement:
                   ;; the next scan-start object can't be at an index less than P.
                   (setq start p)
                   (- page-start (aref (gspace-objects gspace) p))))
            (usage sb!vm:gencgc-card-bytes)
            (pte-offset (* page-index sizeof-corefile-pte)))
        (when (= page-index (1- n-ptes)) ; calculate last page's exact usage
          (decf usage (- (* n-ptes sb!vm:gencgc-card-bytes) data-bytes)))
        ;; #b11 = worst-case assumption: boxed and unboxed data on the page
        (setf (bvref-word ptes pte-offset) (logior sso #b11))
        (funcall (if (eql sizeof-usage 2) #'(setf bvref-16) #'(setf bvref-32))
                 usage ptes (+ pte-offset sb!vm:n-word-bytes))))
    (force-output core-file)
    (let ((posn (file-position core-file)))
      (file-position core-file (* sb!c:+backend-page-bytes+ (1+ data-page)))
      (write-bigvec-as-sequence ptes core-file :end pte-bytes)
      (force-output core-file)
      (file-position core-file posn))
    (mapc write-word ; 5 = number of words in this core header entry
          `(,page-table-core-entry-type-code 5 ,n-ptes ,pte-bytes ,data-page))))

;;; Create a core file created from the cold loaded image. (This is
;;; the "initial core file" because core files could be created later
;;; by executing SAVE-LISP in a running system, perhaps after we've
;;; added some functionality to the system.)
(defun write-initial-core-file (filename verbose)

  (when verbose
    (format t "[building initial core file in ~S: ~%" filename))

  (with-open-file (core-file (namestring filename) ; why NAMESTRING? dunno
                             :direction :output
                             :element-type '(unsigned-byte 8)
                             :if-exists :rename-and-delete)
   (let ((bv (%make-bigvec (vector (make-array sb!vm:n-word-bytes
                                               :element-type '(unsigned-byte 8)))))
         (data-page 0))
    (flet ((write-word (word)
             (setf (bvref-word bv 0) (the sb!vm:word word))
             (write-sequence (elt (bigvec-outer-vector bv) 0) core-file)))
      ;; Write the magic number.
      (write-word core-magic)

      ;; Write the build ID, which contains a generated string
      ;; plus a suffix identifying a certain configuration of the C compiler.
      (binding* ((build-id (concatenate
                            'string
                            (with-open-file (s "output/build-id.inc") (read s))
                            (if (member :msan sb!xc:*features*) "-msan" "")))
                 ((nwords padding) (ceiling (length build-id) sb!vm:n-word-bytes)))
        (declare (type simple-string build-id))
        ;; Write BUILD-ID-CORE-ENTRY-TYPE-CODE, the length of the header,
        ;; length of the string, then base string chars + maybe padding.
        (write-word build-id-core-entry-type-code)
        (write-word (+ 3 nwords)) ; 3 = fixed overhead including this word
        (write-word (length build-id))
        (dovector (char build-id) (write-byte (sb!xc:char-code char) core-file))
        (dotimes (j (- padding)) (write-byte #xff core-file)))

      ;; Write the Directory entry header.
      (write-word directory-core-entry-type-code)
      (let ((spaces (nconc (list *read-only* *static*)
                           #!+immobile-space
                           (list *immobile-fixedobj* *immobile-varyobj*)
                           (list *dynamic*))))
        ;; length = (5 words/space) * N spaces + 2 for header.
        (write-word (+ (* (length spaces) 5) 2))
        (dolist (space spaces)
          (setq data-page (output-gspace space data-page
                                         core-file #'write-word verbose))))
      #!+gencgc (output-page-table *dynamic* data-page
                                   core-file #'write-word verbose)

      ;; Write the initial function.
      (write-word initial-fun-core-entry-type-code)
      (write-word 3)
      (let ((initial-fun (descriptor-bits (cold-symbol-function '!cold-init))))
        (when verbose
          (format t "~&/INITIAL-FUN=#X~X~%" initial-fun))
        (write-word initial-fun))

      ;; Write the End entry.
      (write-word end-core-entry-type-code)
      (write-word 2))))

  (when verbose
    (format t "done]~%")
    (force-output))
  (values))

;;;; the actual GENESIS function

;;; Read the FASL files in OBJECT-FILE-NAMES and produce a Lisp core,
;;; and/or information about a Lisp core, therefrom.
;;;
;;; input file arguments:
;;;   SYMBOL-TABLE-FILE-NAME names a UNIX-style .nm file *with* *any*
;;;     *tab* *characters* *converted* *to* *spaces*. (We push
;;;     responsibility for removing tabs out to the caller it's
;;;     trivial to remove them using UNIX command line tools like
;;;     sed, whereas it's a headache to do it portably in Lisp because
;;;     #\TAB is not a STANDARD-CHAR.) If this file is not supplied,
;;;     a core file cannot be built (but a C header file can be).
;;;
;;; output files arguments (any of which may be NIL to suppress output):
;;;   CORE-FILE-NAME gets a Lisp core.
;;;   C-HEADER-DIR-NAME gets the path in which to place generated headers
;;;   MAP-FILE-NAME gets the name of the textual 'cold-sbcl.map' file
(defun sb-cold:genesis (&key object-file-names
                             core-file-name c-header-dir-name map-file-name
                             symbol-table-file-name (verbose t))
  (declare (ignorable symbol-table-file-name))
  (declare (special core-file-name))

  (when verbose
    (format t
          "~&beginning GENESIS, ~A~%"
          (if core-file-name
            ;; Note: This output summarizing what we're doing is
            ;; somewhat telegraphic in style, not meant to imply that
            ;; we're not e.g. also creating a header file when we
            ;; create a core.
            (format nil "creating core ~S" core-file-name)
            (format nil "creating headers in ~S" c-header-dir-name))))

  (let ((*cold-foreign-symbol-table* (make-hash-table :test 'equal)))

    #!-(or sb-dynamic-core crossbuild-test)
    (when core-file-name
      (if symbol-table-file-name
          (load-cold-foreign-symbol-table symbol-table-file-name)
          (error "can't output a core file without symbol table file input")))

    ;; Now that we've successfully read our only input file (by
    ;; loading the symbol table, if any), it's a good time to ensure
    ;; that there'll be someplace for our output files to go when
    ;; we're done.
    (flet ((frob (filename)
             (when filename
               (ensure-directories-exist filename :verbose t))))
      (frob core-file-name)
      (frob map-file-name))

    ;; (This shouldn't matter in normal use, since GENESIS normally
    ;; only runs once in any given Lisp image, but it could reduce
    ;; confusion if we ever experiment with running, tweaking, and
    ;; rerunning genesis interactively.)
    (do-all-symbols (sym)
      (remprop sym 'cold-intern-info))

    (check-spaces)

    (let  ((*foreign-symbol-placeholder-value* (if core-file-name nil 0))
           (*load-time-value-counter* 0)
           (*cold-fdefn-objects* (make-hash-table :test 'equal))
           (*cold-symbols* (make-hash-table :test 'eql)) ; integer keys
           (*cold-package-symbols* (make-hash-table :test 'equal)) ; string keys
           (*read-only* (make-gspace :read-only
                                     read-only-core-space-id
                                     sb!vm:read-only-space-start))
           (*static*    (make-gspace :static
                                     static-core-space-id
                                     sb!vm:static-space-start))
           #!+immobile-space
           (*immobile-fixedobj* (make-gspace :immobile-fixedobj
                                             immobile-fixedobj-core-space-id
                                             sb!vm:fixedobj-space-start))
           #!+immobile-space
           (*immobile-varyobj* (make-gspace :immobile-varyobj
                                            immobile-varyobj-core-space-id
                                            sb!vm:varyobj-space-start))
           (*dynamic*   (make-gspace :dynamic
                                     dynamic-core-space-id
                                     #!+gencgc sb!vm:dynamic-space-start
                                     #!-gencgc sb!vm:dynamic-0-space-start))
           (*nil-descriptor*)
           (*simple-vector-0-descriptor*)
           (*known-structure-classoids* nil)
           (*classoid-cells* (make-hash-table :test 'eq))
           (*ctype-cache* (make-hash-table :test 'equal))
           (*cold-layouts* (make-hash-table :test 'eq)) ; symbol -> cold-layout
           (*cold-layout-names* (make-hash-table :test 'eql)) ; addr -> symbol
           (*!cold-defconstants* nil)
           (*!cold-defuns* nil)
           ;; '*COLD-METHODS* is never seen in the target, so does not need
           ;; to adhere to the #\! convention for automatic uninterning.
           (*cold-methods* nil)
           (*!cold-toplevels* nil)
           *cold-static-call-fixups*
           *cold-assembler-routines*
           *cold-assembler-obj*
           (*code-fixup-notes* (make-hash-table))
           (*allocation-point-fixup-notes* nil)
           (*deferred-known-fun-refs* nil))

      (setf *nil-descriptor* (make-nil-descriptor)
            *simple-vector-0-descriptor* (vector-in-core nil))

      ;; Load all assembler code
      (flet ((assembler-file-p (name) (tailwise-equal (namestring name) ".assem-obj")))
        (dolist (file-name (remove-if-not #'assembler-file-p object-file-names))
          (cold-load file-name verbose))
        ;; Add 2 zero words to the end of the assembler object.  The trailing
        ;; bytes convey the count of simple-funs (of which there are none)
        ;; in this code component, thereby avoiding a special case in GC.
        (let ((code *cold-assembler-obj*))
          (when code
            (incf (gspace-free-word-index (descriptor-gspace code)) 2)
            (write-wordindexed code sb!vm:code-code-size-slot
                               (make-fixnum-descriptor
                                (+ (descriptor-fixnum
                                    (read-wordindexed code sb!vm:code-code-size-slot))
                                   (* 2 sb!vm:n-word-bytes))))))
        (setf object-file-names (remove-if #'assembler-file-p object-file-names)))

      ;; Prepare for cold load.
      (initialize-layouts)
      (initialize-packages)
      (initialize-static-space)
      (when *cold-assembler-obj*
        (write-wordindexed
         *cold-assembler-obj* sb!vm:code-debug-info-slot
         ;; code-debug-info stores the name->addr hashtable.
         ;; Make sure readonly space doesn't point to dynamic space here.
         (let ((z (make-fixnum-descriptor 0)))
           (cold-cons z z (ecase (gspace-name
                                  (descriptor-gspace *cold-assembler-obj*))
                            (:read-only *static*)
                            (:immobile-varyobj *dynamic*))))))

      ;; Initialize the *COLD-SYMBOLS* system with the information
      ;; from common-lisp-exports.lisp-expr.
      ;; Packages whose names match SB!THING were set up on the host according
      ;; to "package-data-list.lisp-expr" which expresses the desired target
      ;; package configuration, so we can just mirror the host into the target.
      ;; But by waiting to observe calls to COLD-INTERN that occur during the
      ;; loading of the cross-compiler's outputs, it is possible to rid the
      ;; target of accidental leftover symbols, not that it wouldn't also be
      ;; a good idea to clean up package-data-list once in a while.
      (dolist (exported-name
               (sb-cold:read-from-file "common-lisp-exports.lisp-expr"))
        (cold-intern (intern exported-name *cl-package*) :access :external))

      ;; Create SB!KERNEL::*TYPE-CLASSES* as an array of NIL
      (cold-set (cold-intern 'sb!kernel::*type-classes*)
                (vector-in-core (make-list (length sb!kernel::*type-classes*))))

      ;; Cold load.
      (dolist (file-name object-file-names)
        (cold-load file-name verbose))

      (when *known-structure-classoids*
        (let ((dd-layout (find-layout 'defstruct-description)))
          (dolist (defstruct-args *known-structure-classoids*)
            (let* ((dd (first defstruct-args))
                   (name (warm-symbol (read-slot dd dd-layout :name)))
                   (layout (gethash name *cold-layouts*)))
              (aver layout)
              (write-slots layout *host-layout-of-layout* :info dd))))
        (when verbose
          (format t "~&; SB!Loader: (~D~@{+~D~}) structs/consts/funs/methods/other~%"
                  (length *known-structure-classoids*)
                  (length *!cold-defconstants*)
                  (length *!cold-defuns*)
                  (reduce #'+ *cold-methods* :key (lambda (x) (length (cdr x))))
                  (length *!cold-toplevels*))))

      (dolist (symbol '(*!cold-defconstants* *!cold-defuns* *!cold-toplevels*))
        (cold-set symbol (list-to-core (nreverse (symbol-value symbol))))
        (makunbound symbol)) ; so no further PUSHes can be done

      (cold-set
       'sb!pcl::*!trivial-methods*
       (list-to-core
        (loop for (gf-name . methods) in *cold-methods*
              collect
              (cold-cons
               (cold-intern gf-name)
               (vector-in-core
                (loop for (class qual lambda-list fun source-loc)
                      ;; Methods must be sorted because we invoke
                      ;; only the first applicable one.
                      in (stable-sort methods #'> ; highest depthoid first
                                      :key (lambda (method)
                                             (class-depthoid (car method))))
                      collect
                      (cold-list (cold-intern
                                  (and (null qual) (predicate-for-specializer class)))
                                 fun
                                 (cold-intern class)
                                 (cold-intern qual)
                                 lambda-list source-loc)))))))

      ;; Tidy up loose ends left by cold loading. ("Postpare from cold load?")
      (resolve-deferred-known-funs)
      (resolve-static-call-fixups)
      (foreign-symbols-to-core)
      #!+(or x86 immobile-space)
      (dolist (pair (sort (%hash-table-alist *code-fixup-notes*) #'< :key #'car))
        (write-wordindexed (make-random-descriptor (car pair))
                           sb!vm::code-fixups-slot (repack-fixups (cdr pair))))
      (cold-set 'sb!c::*!cold-allocation-point-fixups*
                (vector-in-core *allocation-point-fixup-notes*))
      (when core-file-name
        (finish-symbols))
      (finalize-load-time-value-noise)

      ;; Write results to files.
      (when map-file-name
        (with-open-file (stream map-file-name :direction :output :if-exists :supersede)
          (write-map stream)))
      (when core-file-name
        (write-initial-core-file core-file-name verbose))
      (unless c-header-dir-name
        (return-from sb-cold:genesis))
      (let ((filename (format nil "~A/Makefile.features" c-header-dir-name)))
        (ensure-directories-exist filename)
        (with-open-file (stream filename :direction :output :if-exists :supersede)
          (write-makefile-features stream)))

      (macrolet ((out-to (name &body body) ; write boilerplate and inclusion guard
                   `(with-open-file (stream (format nil "~A/~A.h" c-header-dir-name ,name)
                                            :direction :output :if-exists :supersede)
                       (write-boilerplate stream)
                       (format stream
                               "#ifndef SBCL_GENESIS_~A~%#define SBCL_GENESIS_~:*~A~%"
                               (c-name (string-upcase ,name)))
                       ,@body
                       (format stream "#endif~%"))))
        (out-to "config" (write-config-h stream))
        (out-to "constants" (write-constants-h stream))
        (out-to "errnames" (write-errnames-h stream))
        (out-to "gc-tables" (sb!vm::write-gc-tables stream))
        (out-to "tagnames" (write-tagnames-h stream))
        (let ((structs (sort (copy-list sb!vm:*primitive-objects*) #'string<
                             :key #'sb!vm:primitive-object-name)))
          (dolist (obj structs)
            (out-to (string-downcase (sb!vm:primitive-object-name obj))
              (write-primitive-object obj stream)))
          (out-to "primitive-objects"
            (dolist (obj structs)
              (format stream "~&#include \"~A.h\"~%"
                      (string-downcase (sb!vm:primitive-object-name obj))))))
        (dolist (class '(classoid defstruct-description hash-table layout package
                         sb!c::compiled-debug-info sb!c::compiled-debug-fun))
          (out-to (string-downcase class)
            (write-structure-object (layout-info (find-layout class)) stream)))
        (with-open-file (stream (format nil "~A/thread-init.inc" c-header-dir-name)
                                :direction :output :if-exists :supersede)
          (write-boilerplate stream) ; no inclusion guard, it's not a ".h" file
          (write-thread-init stream))
        (out-to "static-symbols" (write-static-symbols stream))
        (out-to "sc-offset" (write-sc+offset-coding stream))))))

;;; Invert the action of HOST-CONSTANT-TO-CORE. If STRICTP is given as NIL,
;;; then we can produce a host object even if it is not a faithful rendition.
(defun host-object-from-core (descriptor &optional (strictp t))
  (named-let recurse ((x descriptor))
    (when (cold-null x)
      (return-from recurse nil))
    (when (eq (descriptor-gspace x) :load-time-value)
      (error "Can't warm a deferred LTV placeholder"))
    (when (is-fixnum-lowtag (descriptor-lowtag x))
      (return-from recurse (descriptor-fixnum x)))
    (ecase (descriptor-lowtag x)
      (#.sb!vm:instance-pointer-lowtag
       (if strictp (error "Can't invert INSTANCE type") "#<instance>"))
      (#.sb!vm:list-pointer-lowtag
       (cons (recurse (cold-car x)) (recurse (cold-cdr x))))
      (#.sb!vm:fun-pointer-lowtag
       (if strictp
           (error "Can't map cold-fun -> warm-fun")
           (let ((name (read-wordindexed x sb!vm:simple-fun-name-slot)))
             `(function ,(recurse name)))))
      (#.sb!vm:other-pointer-lowtag
       (let ((widetag (logand (read-bits-wordindexed x 0) sb!vm:widetag-mask)))
         (ecase widetag
           (#.sb!vm:symbol-widetag
            (if strictp
                (warm-symbol x)
                (or (gethash (descriptor-bits x) *cold-symbols*) ; first try
                    (make-symbol
                     (recurse (read-wordindexed x sb!vm:symbol-name-slot))))))
           (#.sb!vm:simple-base-string-widetag (base-string-from-core x))
           (#.sb!vm:simple-vector-widetag (vector-from-core x #'recurse))
           (#.sb!vm:bignum-widetag (bignum-from-core x))))))))
