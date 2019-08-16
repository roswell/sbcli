(uiop/package:define-package :sbcli/repl (:nicknames) (:use :cl :cffi)
                             (:shadow) (:import-from :alexandria)
                             (:import-from :cl-readline)
                             (:export :sbcli :*repl-version* :*repl-name*
                              :*prompt* :*prompt2* :*ret* :*config-file*
                              :*hist-file* :*special* :*last-result*
                              :main)
                             (:intern))
(in-package :sbcli/repl)
;;don't edit above

(defvar *repl-version* "0.1.3")
(defvar *repl-name*    "Veit's REPL for SBCL")
(defvar *prompt*       "sbcl> ")
(defvar *prompt2*       "....> ")
(defvar *ret*          "=> ")
(defvar *config-file*  "~/.sbclirc")
(defvar *hist-file*    "~/.sbcli_history")
(defvar *last-result*  nil)
(defvar *hist*         (list))
(declaim (special *special*))

(defun read-hist-file ()
  (with-open-file (in *hist-file* :if-does-not-exist :create)
    (loop for line = (read-line in nil nil)
          while line
          ; hack because cl-readline has no function for this. sorry.
          do (cffi:foreign-funcall "add_history"
                                   :string line
                                   :void))))

(defun update-hist-file (str)
  (with-open-file (out *hist-file*
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create)
    (format out "~a~%" str)))


(defun end ()
  "Ends the session"
  (format t "Bye for now.~%")
  (ros:quit))

(defun reset ()
  "Resets the session environment"
  (delete-package :sbcli/repl)
  (defpackage :sbcli/repl (:use :common-lisp))
  (in-package :sbcli/repl))

(defun split (str chr)
  (loop for i = 0 then (1+ j)
        as j = (position chr str :start i)
        collect (subseq str i j)
        while j))

(defun novelty-check (str1 str2)
  (string/= (string-trim " " str1)
            (string-trim " " str2)))

(defun add-res (txt res) (setq *hist* (cons (list txt res) *hist*)))

(defun format-output (&rest args)
  (format (car args) "~a ; => ~a" (caadr args) (cadadr args)))

(defun write-to-file (fname)
  "Writes the current session to a file <filename>"
  (with-open-file (file fname
                        :direction :output
                        :if-exists :supersede
                        :if-does-not-exist :create)
    (format file "~{~/sbcli/repl:format-output/~^~%~}" (reverse *hist*))))

(defun help (sym)
  "Gets help on a symbol <sym>"
  (handler-case (inspect (read-from-string sym))
    (error (c) (format *error-output* "Error during inspection: ~a~%" c))))

(defun general-help ()
  "Prints a general help message"
  (format t "~a version ~a~%" *repl-name* *repl-version*)
  (format t "Special commands:~%")
  (maphash
   (lambda (k v) (format t "  :~a: ~a~%" k (documentation (cdr v) t)))
   *special*)
  (format t "Currently defined:~%")
  (do-all-symbols (s *package*)
    (when (and (or (fboundp s) (boundp s)) (eql (symbol-package s) *package*))
      (let ((what (if (fboundp s) 'function 'variable)))
        (format t " ~a: ~a (~a) ~a~%" (string-downcase (string s))
                (or (documentation s what)
                    "No documentation")
                what
                (if (boundp s)
                    (format nil "(value ~a)" (eval s))
                    ""))))))

(defun dump-disasm (sym)
  "Dumps the disassembly of a symbol <sym>"
  (handler-case (disassemble (read-from-string sym))
    (unbound-variable (var) (format t "~a~%" var))
    (type-error (err) (format t "~a~%" err))
    (undefined-function (fun) (format t "~a~%" fun))))

(defun custom-complete (text start end)
  (declare (ignore start) (ignore end))
  (labels ((common-prefix (items)
             (let ((lst 0))
              (loop for n from 1 below (reduce #'min (mapcar #'length items)) do
                (when (every (lambda (x)
                             (char= (char (car items) n)
                                    (char x           n)))
                         (cdr items))
                  (setf lst n)))
              (write lst)
              (subseq (car items) 0 (+ lst 1))))
           (starts-with (text)
             (lambda (sym)
               (let* ((symstr (string-downcase sym))
                      (cmp (subseq symstr 0 (min (length symstr) (length text)))))
                 (string= text cmp))))
           (select-completions (list)
             (let* ((els (remove-if-not (starts-with text)
                                       (mapcar #'string list)))
                    (els (if (cdr els) (cons (common-prefix els) els) els)))
                (if (string= text (string-downcase text))
                  (mapcar #'string-downcase els)
                  els)))
           (get-all-symbols ()
             (let ((lst ()))
               (do-all-symbols (s lst)
                 (when (or (fboundp s) (boundp s)) (push s lst)))
               lst)))
      (select-completions (get-all-symbols))))

(defvar *special*
  (alexandria:alist-hash-table
    `(("h" . (1 . ,#'help))
      ("help" . (0 . ,#'general-help))
      ("s" . (1 . ,#'write-to-file))
      ("d" . (1 . ,#'dump-disasm))
      ("q" . (0 . ,#'end))
      ("r" . (0 . ,#'reset))) :test 'equal))

(defun sbcli (txt p)
  (let ((text
          (rl:readline :prompt (if (functionp p) (funcall p) p)
                       :add-history t
                       :novelty-check #'novelty-check)))
    (in-package :sbcli/user)
    (if (not text) (end))
    (if (string= text "") (sbcli "" *prompt*))
    (when *hist-file* (update-hist-file text))
    (cond
      ((and (> (length text) 1) (string= (subseq text 0 1) ":"))
        (let* ((splt (split text #\Space))
               (k (subseq (car splt) 1 (length (car splt))))
               (v (gethash k *special*)))
          (if (not v)
            (format *error-output* "Unknown special command: ~a~%" k)
            (let ((l (car v))
                  (rl (length (cdr splt))))
              (if (< rl l)
                (format *error-output* "Expected ~a arguments to ~a, but got ~a!~%"
                        l (car splt) rl)
                (apply (cdr v) (subseq (cdr splt) 0 (car v))))))))
      (t
        (let* ((new-txt (format nil "~a ~a" txt text))
               (parsed (handler-case (read-from-string new-txt)
                         (end-of-file () (sbcli new-txt *prompt2*))
                         (error (condition)
                          (format *error-output* "Parser error: ~a~%" condition)))))
          (if parsed
            (progn
              (setf *last-result*
                      (handler-case (eval parsed)
                        (unbound-variable (var) (format *error-output* "~a~%" var))
                        (undefined-function (fun) (format *error-output* "~a~%" fun))
                        (sb-int:compiled-program-error ()
                          (format *error-output* "Compiler error.~%"))
                        (error (condition)
                          (format *error-output* "Evaluation error: ~a~%" condition))))
              (add-res text *last-result*)
              (if *last-result* (format t "~a~a~%" *ret* *last-result*)))))))
    (in-package :sbcli/repl)
    (finish-output nil)
    (sbcli "" *prompt*)))

(defun main ()
  (rl:register-function :complete #'custom-complete)

  (if (probe-file *config-file*)
      (load *config-file*))

  (format t "~a version ~a~%" *repl-name* *repl-version*)
  (format t "Press CTRL-C or CTRL-D or type :q to exit~%~%")
  (finish-output nil)

  (when *hist-file* (read-hist-file))

  (handler-case (sbcli "" *prompt*)
    (sb-sys:interactive-interrupt () (end))))
