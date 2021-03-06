;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.
;;;
;;; This file defines new special forms, form attributes
;;; and utility functions used by the translator.
;;;

(in-package :cl-gpu)

(deflayer gpu-target)

;; Some ad-hoc attribute definitions

(def (form-attribute-accessor :debug t) form-c-type
  :type (or gpu-type null))

(def form-attribute-accessor gpu-variable
  #|:type (or gpu-variable null)|# :forms name-definition-form)

(def form-attribute-accessor shared-identity
  :type (or gpu-shared-identity null) :forms name-definition-form)

(def form-attribute-accessor assigned-to?
  :type boolean :forms (lexical-variable-binding-form
                        function-argument-form))

(def form-attribute-accessor c-name
  :forms (go-tag-form block-form))

(def form-attribute-accessor is-expression?
  :forms (implicit-progn-mixin if-form))

(def form-attribute-accessor is-merged-assignment?
  :forms setq-form)

(defstruct side-effects reads writes)

(def method make-load-form ((obj side-effects) &optional env)
  (declare (ignore env))
  `(make-side-effects :reads (list ,@(side-effects-reads obj))
                      :writes (list ,@(side-effects-writes obj))))

(def form-attribute-accessor side-effects #|:type (or side-effects null)|#)

;; A wrapper for global variables

(def form-class global-var-binding-form (name-definition-form)
  ((gpu-variable :type (or gpu-variable null))
   (assigned-to? nil :type boolean)))

;; Forced cast

(def (macro e) cast (type body)
  `(the ,type ,body))

(def form-class cast-form (the-form)
  ())

(def (walker :in gpu-target) cast
  (with-form-object (cast 'cast-form -parent- :declared-type (second -form-))
    (setf (value-of cast) (recurse (third -form-) cast))))

(def unwalker cast-form (value)
  `(cast ,(declared-type-of -form-) ,(recurse value)))

;; Values

(def form-class values-form ()
  ((values :ast-link t)))

(def (walker :in gpu-target) values
  (with-form-object (values 'values-form -parent-)
    (setf (values-of values)
          (mapcar (lambda (x) (recurse x values)) (rest -form-)))))

(def unwalker values-form (values)
  `(values ,@(recurse-on-body values)))

;; Multiple value setq

(def form-class multiple-value-setq-form ()
  ((variables :ast-link t)
   (value :ast-link t)
   (is-merged-assignment? nil)))

(def (walker :in gpu-target) multiple-value-setq
  (with-form-object (setq 'multiple-value-setq-form -parent-)
    (setf (variables-of setq)
          (mapcar (lambda (x) (recurse x setq)) (second -form-)))
    (setf (value-of setq) (recurse (third -form-) setq))))

(def unwalker multiple-value-setq-form (variables value)
  `(multiple-value-setq ,(recurse-on-body variables) ,(recurse value)))

;; Multiple value bind

(def form-class multiple-value-bind-form (binder-form-mixin
                                          implicit-progn-with-declarations-mixin)
  ((value :ast-link t)))

(def (walker :in gpu-target) multiple-value-bind
  (with-form-object (bind 'multiple-value-bind-form -parent-)
    (setf (bindings-of bind)
          (mapcar (lambda (name)
                    (with-current-form name
                      (with-form-object (binding 'lexical-variable-binding-form bind
                                                 :name name :initial-value nil))))
                  (second -form-)))
    (setf (value-of bind) (recurse (third -form-) bind))
    (walk-implict-progn
     bind (cdddr -form-) -environment-
     :declarations-allowed t
     :declarations-callback (lambda (declarations &aux var-names)
                              (dolist (binding (bindings-of bind))
                                (push (name-of binding) var-names)
                                (if (find-form-by-name (name-of binding) declarations
                                                       :type 'special-variable-declaration-form)
                                    (setf (special-binding? binding) t)
                                    (-augment- :variable (name-of binding) binding)))
                              (values -environment- var-names)))))

(def unwalker multiple-value-bind-form (value body declarations)
  `(multiple-value-bind ,(mapcar #'name-of (bindings-of -form-))
       ,(recurse value)
     ,@(unwalk-declarations declarations)
     ,@(recurse-on-body body)))

;; A SETF form.

(def form-class setf-application-form (application-form)
  ((value :ast-link t)))

(def (walker :in gpu-target) setf
  (if (> (length -form-) 3)
      (recurse `(progn
                  ,@(loop
                       :for (name value) :on (cdr -form-) :by #'cddr
                       :collect `(setf ,name ,value))))
      (with-form-object (setf 'setq-form -parent-)
        (let ((target (recurse (second -form-) setf)))
          (typecase target
            (variable-reference-form
             (setf (variable-of setf) target))
            (values-form
             (change-class setf 'multiple-value-setq-form
                           :variables (values-of target))
             (adjust-parents (variables-of setf)))
            ((or free-application-form lexical-application-form)
             (change-class setf 'setf-application-form
                           :operator (operator-of target)
                           :arguments (arguments-of target))
             (adjust-parents (arguments-of setf)))
            (t
             (gpu-code-error target "Not an lvalue form."))))
        (setf (value-of setf) (recurse (third -form-) setf)))))

(def unwalker setf-application-form (value)
  `(setf (,(operator-of -form-)
           ,@(recurse-on-body (arguments-of -form-)))
         ,(recurse value)))

;; A verbatim inline C form

(defmacro inline-verbatim (&whole full (ret-type) &body code)
  (declare (ignore ret-type code))
  (error "This form cannot be used in ordinary lisp code: ~S" full))

(def form-class verbatim-code-form ()
  ((body)
   (form-c-type)
   (is-expression?)))

(def (walker :in gpu-target) inline-verbatim
  (destructuring-bind ((ret-type &key statement?) &rest code)
      (rest -form-)
    (with-form-object (vcode 'verbatim-code-form -parent-
                             :is-expression? (not statement?))
      (setf (form-c-type-of vcode)
            (ignore-errors
              (if (keywordp ret-type)
                  (make-foreign-gpu-type ret-type)
                  (parse-lisp-type ret-type :error-cb (curry #'gpu-code-error vcode))))
            (body-of vcode)
            (mapcar (lambda (form) (recurse form vcode)) code)))))

(def unwalker verbatim-code-form (body form-c-type is-expression?)
  `(inline-verbatim (,form-c-type :statement? ,(not is-expression?))
     ,@(recurse-on-body body)))

;; A let with an implicit block - used to expand function calls

(def form-class block-let-form (let*-form block-form)
  ())

(def unwalker block-let-form ()
  (let ((rv (call-next-method)))
    `(block-let* ,(name-of -form-) ,@(cdr rv))))

(def form-class block-multiple-value-bind-form (multiple-value-bind-form block-form)
  ())

(def unwalker block-multiple-value-bind-form ()
  (let ((rv (call-next-method)))
    `(block-multiple-value-bind ,(name-of -form-) ,@(cdr rv))))

;;; AND & OR - parse them as ordinary function calls

(def (macro e) unevaluated (expr)
  "May be used as an init expression to specify type without actually evaluating."
  (declare (ignore expr))
  nil)

(macrolet ((walk-as-call (name)
             `(def (walker :in gpu-target) ,name
                (with-form-object (appl 'free-application-form -parent-
                                        :operator ',name)
                  (setf (arguments-of appl)
                        (mapcar (lambda (f) (recurse f appl)) (rest -form-)))))))
  (walk-as-call or)
  (walk-as-call and)
  (walk-as-call unevaluated))

;;; Macros

(def generic expand-gpu-macro (name form env)
  (:method (name form env)
    (declare (ignore name env))
    form))

(def layered-method hu.dwim.walker::walker-macroexpand-1 :in gpu-target ((form cons) &optional env)
  (let ((rvalue (expand-gpu-macro (first form) form env)))
    (if (eq rvalue form)
        (call-next-method)
        (values rvalue t))))

(def (definer e) gpu-macro (name args &body code)
  "Like compiler-macro, but for GPU code."
  (with-unique-names (whole env vname)
    (when (eq (first args) '&whole)
      (setf whole (second args)
            args (cddr args)))
    (awhen (position '&environment args)
      (setf env (nth (1+ it) args)
            args (append (subseq args 0 it)
                         (subseq args (+ it 2)))))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (defmethod expand-gpu-macro ((,vname (eql ',name)) ,whole ,env)
         (declare (ignore ,vname)
                  (ignorable ,env))
         (destructuring-bind ,args (cdr ,whole)
           ,@code)))))

;;; Shared variable decls

(declaim (declaration shared))

(def form-class shared-declaration-form (variable-declaration-form)
  ())

(def unwalker shared-declaration-form ()
  `(shared ,(name-of -form-)))

(def declaration-walker shared (&rest vars)
  (do-list-collect (var vars)
    (make-declaration 'shared-declaration-form :name var)))

;;; Optimize decls

(declaim (declaration gpu-optimize))

(def form-class gpu-optimize-declaration-form (declaration-form)
  (specification))

(def unwalker gpu-optimize-declaration-form (specification)
  `(gpu-optimize ,specification))

(defparameter *known-optimize-flags* '(debug speed safety space
                                       :check-bounds :fast-math :fast-div
                                       :fast-sin :fast-cos :fast-tan
                                       :fast-log :fast-exp))

(def declaration-walker gpu-optimize (&rest specs)
  (do-list-collect (optimize-spec specs)
    (unless (member (ensure-car optimize-spec) *known-optimize-flags*)
      (simple-walker-style-warning "Unknown GPU optimize setting: ~S" optimize-spec))
    (make-declaration 'gpu-optimize-declaration-form :specification optimize-spec)))

(defparameter *optimize-flags* '((safety 1) (debug 1)))

(def (function i) get-optimize-value (name &optional (default 0) (implicit 3))
  (aif (assoc name *optimize-flags*)
       (if (cdr it) (cadr it) implicit)
       default))

(def (function i) is-optimize-level? (name value)
  (>= (get-optimize-value name) value))

(def function is-optimize-level-any? (&rest keyvals)
  (loop
     for entry in *optimize-flags*
     for value = (or (second entry) 3)
     for rq-value = (getf keyvals (first entry))
     when rq-value return (>= value rq-value)))

(def function collect-optimize-decls (form)
  (loop for decl in (declarations-of form)
     when (typep decl 'optimize-declaration-form)
     collect (ensure-cons (specification-of decl)) into lisp-decls
     when (typep decl 'gpu-optimize-declaration-form)
     collect (ensure-cons (specification-of decl)) into gpu-decls
     finally
       (return (nreverse (nconc lisp-decls gpu-decls)))))

(def macro with-optimize-context ((form) &body code)
  `(let ((*optimize-flags*
          (nconc (collect-optimize-decls ,form) *optimize-flags*)))
     ,@code))

;;; Misc

(def layered-method function-name? :in gpu-target ((s symbol))
  (or (symbol-gpu-function s)
      (call-next-method)))

(def function has-merged-assignment? (form)
  (atypecase (parent-of form)
    ((or multiple-value-setq-form setq-form)
     (is-merged-assignment? it))
    (t nil)))

(def function ensure-gpu-var (ref)
  (unless (typep ref 'walked-lexical-variable-reference-form)
    (gpu-code-error ref "Must be a local variable reference."))
  (let ((defn (definition-of ref)))
    (unless defn
      (gpu-code-error ref "Undefined variable reference."))
    (or (gpu-variable-of defn)
        (gpu-code-error ref "Unallocated variable reference."))))

(def function ensure-constant (obj)
  (unless (typep obj 'constant-form)
    (gpu-code-error obj "Must be a constant."))
  (value-of obj))

(def function ensure-int-constant (obj)
  (aprog1 (ensure-constant obj)
    (unless (typep it 'integer)
      (gpu-code-error obj "Must be an integer constant."))))

(def function unwrap-keyword-const (val)
  (if (and (typep val 'constant-form)
           (keywordp (value-of val)))
      (value-of val)
      val))

(def function constant-number-value (form)
  (and (typep form 'constant-form)
       (numberp (value-of form))
       (value-of form)))

(def function power-of-two (value)
  (if (and (integerp value)
           (> value 0)
           (= (logand value (1- value)) 0))
      (values (round (log value 2)) (1- value))))

(def function nil-constant? (obj)
  (and (typep obj 'constant-form)
       (eq (value-of obj) nil)))

(def function ensure-c-type-of (obj)
  (typecase obj
    (walked-form (form-c-type-of obj))
    (t obj)))

(def function make-lexical-binding (parent &key (name (make-symbol "_T")) initial-value c-type)
  (with-form-object (binding 'lexical-variable-binding-form parent
                             :name name :initial-value initial-value)
    (setf (form-c-type-of binding) (ensure-c-type-of c-type))))

(def function make-lexical-var (definition &optional parent)
  (with-form-object (var `walked-lexical-variable-reference-form parent
                         :name (name-of definition)
                         :definition definition)
    (setf (form-c-type-of var)
          (form-c-type-of definition))))

(def function make-lexical-assignment (dest-def src-def &optional parent)
  (with-form-object (assn 'setq-form parent)
    (setf (variable-of assn) (make-lexical-var dest-def assn)
          (value-of assn) (make-lexical-var src-def assn))
    (setf (form-c-type-of assn) (form-c-type-of dest-def))))

(def function wrap-body-in-form (parent body &key declarations)
  (cond (declarations
         (with-form-object (obj 'locally-form parent
                                :declarations declarations :body body)
           (adjust-parents (declarations-of obj))
           (adjust-parents (body-of obj))))
        ((cdr body)
         (with-form-object (obj 'progn-form parent :body body)
           (adjust-parents (body-of obj))))
        ((car body)
         (setf (parent-of (car body)) parent)
         (car body))
        (t
         (with-form-object (obj 'constant-form parent :value nil)))))

(def function nop-form? (obj)
  (or (null obj)
      (nil-constant? obj)
      (and (typep obj 'values-form)
           (null (values-of obj)))))

(def function unknown-type? (type)
  (case type
    ((nil t number real) t)))

(def function parse-verbatim-flag (list-pos flags)
  (ecase (value-of (car list-pos))
    (:stmt (setf (getf flags :stmt) t))
    (:return
     (setf (getf flags :return-nth) 0))
    (:return!
     (setf (getf flags :return-nth) 0
           (getf flags :force-return) t))
    (:return-nth
     (setf (getf flags :return-nth) (ensure-int-constant (cadr list-pos))
           list-pos (cdr list-pos)))
    (:return-nth!
     (setf (getf flags :return-nth) (ensure-int-constant (cadr list-pos))
           list-pos (cdr list-pos)
           (getf flags :force-return) t))
    (:type
     (setf (getf flags :type) (ensure-constant (cadr list-pos))
           list-pos (cdr list-pos))))
  (values list-pos flags))

(def macro do-verbatim-code ((item flags form &key flatten?) &body code)
  (with-unique-names (list-pos skip-tag)
    `(let ((,flags nil))
       (do ((,list-pos (body-of ,form) (cdr ,list-pos)))
           ((null ,list-pos))
         (,(if flatten? 'let 'symbol-macrolet) ((,item (car ,list-pos)))
           (when (typep ,item 'constant-form)
             (atypecase (value-of ,item)
               (keyword
                (setf (values ,list-pos ,flags)
                      (parse-verbatim-flag ,list-pos ,flags))
                (go ,skip-tag))
               ,@(if flatten?
                     `(((or string character)
                        (setf ,item it))))))
           ,@code)
         (setf ,flags nil)
         ,skip-tag))))

(def function mark-mutated-vars (tree)
  (flet ((mark-var (variable form)
           (unless (typep variable 'walked-lexical-variable-reference-form)
             (gpu-code-error form "Setting non-lexical variables is not supported."))
           (setf (assigned-to? (definition-of variable)) t)))
    (map-ast (lambda (form)
               (typecase form
                 (setq-form
                  (mark-var (variable-of form) form))
                 (multiple-value-setq-form
                  (dolist (var (variables-of form))
                    (mark-var var form))))
               form)
             tree)))

(def function extract-function-stack (form &key gpu-function)
  (cond (form
         (loop for cur = form then (parent-of cur)
            while cur
            when (typecase cur
                   ((or block-let-form block-multiple-value-bind-form
                        block-lambda-function-form)
                    t))
            collect (name-of cur)))
        (gpu-function
         (list (name-of gpu-function)))))

(def method print-object :after ((obj gpu-code-condition) stream)
  (unless *print-escape*
    (when (or (gpu-function-of obj) (enclosing-form-of obj))
      (format stream "~&GPU function: ~:[(unknown)~;~:*~{~S~^ in ~}~]"
              (extract-function-stack (enclosing-form-of obj)
                                      :gpu-function (gpu-function-of obj)))
      (awhen (aand (gpu-module-of obj) (name-of it))
        (format stream " of module ~S" it)))
    (awhen (enclosing-form-of obj)
      (let ((*print-length* 5)
            (*print-level* 2))
        (format stream "~&Form: ~S" (unwalk-form it))))))
