;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.

(in-package :cl-gpu)

(defvar *gpu-module-lookup-fun* nil)

(defvar *named-gpu-modules*
  (make-hash-table :test #'eq #+sbcl :synchronized #+sbcl t)
  "Table of named module objects")

(def macro find-gpu-module (name)
  `(gethash ,name *named-gpu-modules*))

(def class* gpu-variable ()
  ((name           :documentation "Lisp name of the variable")
   (c-name         :documentation "C name of the variable")
   (item-type      :documentation "Type without array dimensions")
   (dimension-mask :documentation "If array, vector of fixed dims")
   (static-asize   :documentation "Full dimension if all dims constant."))
  (:documentation "Common name of a global variable or parameter."))

(def generic array-var? (obj)
  (:method ((obj gpu-variable)) (dimension-mask-of obj)))

(def generic dynarray-var? (obj)
  (:method ((obj gpu-variable))
    (and (dimension-mask-of obj)
         (not (static-asize-of obj)))))

(def method initialize-instance :after ((obj gpu-variable) &key &allow-other-keys)
  (with-slots (dimension-mask static-asize) obj
    (unless (slot-boundp obj 'static-asize)
      (setf static-asize
            (if (and dimension-mask (every #'numberp dimension-mask))
                (reduce #'* dimension-mask)
                nil)))))

(def class* gpu-global-var (gpu-variable)
  ((index          :documentation "Ordinal index for fast access.")
   (constant-var?  nil :accessor constant-var? :type boolean
                   :documentation "Specifies allocation in constant memory."))
  (:documentation "A global variable in a GPU module."))

(def class* gpu-argument (gpu-variable)
  ((includes-locked? nil :accessor includes-locked? :type boolean)
   (include-size?    nil :accessor include-size? :type boolean)
   (included-dims    nil :documentation "Mask of dimensions to append.")
   (include-extent?  nil :accessor include-extent? :type boolean)
   (included-strides nil :documentation "Mask of strides to append."))
  (:documentation "A GPU function or kernel parameter."))

(def method initialize-instance :after ((obj gpu-argument) &key &allow-other-keys)
  (with-slots (dimension-mask included-dims included-strides) obj
    (when dimension-mask
      (unless included-dims
        (setf included-dims
              (make-array (length dimension-mask) :initial-element nil)))
      (unless included-strides
        (setf included-strides
              (make-array (1- (length dimension-mask)) :initial-element nil))))))

(def class* gpu-function ()
  ((name           :documentation "Lisp name of the function")
   (c-name         :documentation "C name of the function")
   (return-type    :documentation "Return type")
   (arguments      :documentation "List of arguments")
   (body           :documentation "Body tree"))
  (:documentation "A function usable on the GPU"))

(def class* gpu-kernel (gpu-function)
  ((index          :documentation "Ordinal for fast access"))
  (:default-initargs :return-type :void)
  (:documentation "A kernel callable from the host"))

(def class* gpu-module ()
  ((name            :documentation "Lisp name of the module")
   (globals         :documentation "List of global variables")
   (functions       :documentation "List of helper functions")
   (kernels         :documentation "List of kernel functions")
   (index-table     (make-hash-table)
                    :documentation "An index assignment table")
   (compiled-code   :documentation "Code string")
   (change-sentinel (cons t nil)
                    :documentation "Used to trigger module reloads"))
  (:documentation "A module that can be loaded to the GPU."))

;;; Namespace

(def function reindex-gpu-module (module)
  (let* ((idx-tbl (index-table-of module))
         (max-idx (reduce #'max (hash-table-values idx-tbl)
                          :initial-value -1)))
    (dolist (item (append (globals-of module)
                          (kernels-of module)))
      (setf (index-of item)
            (gethash-with-init (name-of item) idx-tbl
                               (incf max-idx))))))

(def method reinitialize-instance :after ((obj gpu-module) &key &allow-other-keys)
  (setf (car (change-sentinel-of obj)) nil)
  (setf (change-sentinel-of obj) (cons t nil)))

(def function finalize-gpu-module (module)
  (aprog1
      (if (name-of module)
          (let ((old-instance (find-gpu-module (name-of module))))
            (if old-instance
                (prog1
                    (reinitialize-instance old-instance
                                           :globals (globals-of module)
                                           :functions (functions-of module)
                                           :kernels (kernels-of module)
                                           :compiled-code (compiled-code-of module))
                  (setf (index-table-of module) (index-table-of old-instance)))
                (setf (find-gpu-module (name-of module)) module)))
          module)
    (reindex-gpu-module it)))

;;; Instance management

(defstruct gpu-module-instance
  module change-sentinel item-vector)

;; Initial creation
(def layered-function instantiate-module-item (item instance &key old-value)
  (:documentation "Creates an instance of a global or kernel"))

(def function fill-generic-gpu-instance (instance module old-ivals)
  (let ((old-size (if old-ivals (length old-ivals) 0)))
    (setf (gpu-module-instance-module instance) module
          (gpu-module-instance-change-sentinel instance) (change-sentinel-of module))
    (let* ((items (append (globals-of module) (kernels-of module)))
           (maxid (reduce #'max items :key #'index-of))
           (ivect (make-array (1+ maxid) :initial-element nil)))
      (setf (gpu-module-instance-item-vector instance) ivect)
      (dolist (item items)
        (let* ((idx (index-of item))
               (old-value (if (< idx old-size)
                              (aref old-ivals idx))))
          (setf (aref ivect idx)
                (instantiate-module-item item instance :old-value old-value)))))))

(def layered-function load-gpu-module-instance (module)
  (:documentation "Instantiates a gpu module"))

(def layered-method load-gpu-module-instance ((module symbol))
  (load-gpu-module-instance (find-gpu-module module)))

(def layered-method load-gpu-module-instance :around ((module gpu-module))
  (aprog1 (call-next-method)
    (fill-generic-gpu-instance it module nil)))

;; Reinitialization
(def generic freeze-module-item (item)
  (:documentation "Packages the state of the item")
  (:method ((item t)) nil))

(def generic kill-frozen-object (item object)
  (:documentation "Destroys an object produced by freeze-module-item")
  (:method ((item t) (object array)) nil)
  (:method ((item t) (object number)) nil))

(def layered-function upgrade-gpu-module-instance (module instance)
  (:documentation "Rebuilds the instance after a module update"))

(def layered-method upgrade-gpu-module-instance ((module symbol) instance)
  (upgrade-gpu-module-instance (find-gpu-module module) instance))

(def layered-method upgrade-gpu-module-instance :around ((module gpu-module) instance)
  (let* ((old-ivect (gpu-module-instance-item-vector instance))
         (old-ivals (map 'vector #'freeze-module-item old-ivect))
         (old-size (length old-ivect)))
    (unwind-protect
         (progn
           (call-next-method)
           (fill-generic-gpu-instance instance module old-ivals))
      (dotimes (i old-size)
        (awhen (aref old-ivals i)
          (kill-frozen-object (aref old-ivect i) it))))))

;;;

(def (function i) get-module-instance (module-id)
  (funcall *gpu-module-lookup-fun* module-id))

(def generic gpu-global-value (obj)
  (:documentation "Retrieve the value of a GPU global"))

(def generic (setf gpu-global-value) (value obj)
  (:documentation "Set the value of a GPU global"))

