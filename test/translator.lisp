;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.

(in-package :cl-gpu.test)

(defsuite* (test/translator :in test))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (def function convert-computation (code)
    (let ((num-floats 0)
          (num-ints 0))
      (labels ((make-int (arg)
                 (prog1 `(test-int-val ,num-ints ,arg)
                   (incf num-ints)))
               (make-float (arg)
                 (prog1 `(test-float-val ,num-floats ,arg)
                   (incf num-floats)))
               (make-bool (arg)
                 (make-int `(if ,arg 1 0)))
               (recurse (code)
                 (if (consp code)
                     (case (car code)
                       (test-int
                        `(progn ,@(mapcar #'make-int (rest code))))
                       (test-float
                        `(progn ,@(mapcar #'make-float (rest code))))
                       (test-bool
                        `(progn ,@(mapcar #'make-bool (rest code))))
                       (t
                        (mapcar #'recurse code)))
                     code)))
        (values (recurse code)
                num-floats num-ints)))))

(def function float= (a b)
  (ignore-errors
    (or (= a b)
        (< (/ (abs (- a b)) (max a b)) 0.0001))))

(defvar *last-tested-module* nil)

(def macro with-test-gpu-module (target module-spec &body code)
  (let ((module (handler-bind ((warning #'ignore-warning))
                  (cl-gpu::parse-gpu-module-spec module-spec))))
    (cl-gpu::reindex-gpu-module module)
    (cl-gpu::wrap-gpu-module-bindings
     module
     `(setf *last-tested-module*
            (progn
              (setf *current-gpu-target* ,target)
              (cl-gpu::compile-gpu-module
               (cl-gpu::parse-gpu-module-spec ',module-spec))))
     code)))

(def macro test-computations ((target) &body code)
  "Evaluates forms both in lisp and on the GPU, and compares the results."
  (multiple-value-bind (cvcode num-floats num-ints)
      (convert-computation code)
    `(with-test-gpu-module ,target
         ((:global float-results (vector single-float ,num-floats))
          (:global int-results (vector int32 ,num-ints))
          (:kernel kernel ()
            (macrolet ((test-int-val (idx val)
                         `(setf (raw-aref int-results ,idx) (cast int32 ,val)))
                       (test-float-val (idx val)
                         `(setf (raw-aref float-results ,idx) ,val)))
              ,@cvcode)))
       (is (zero-buffer? float-results))
       (is (zero-buffer? int-results))
       (kernel)
       (let ((float-results (buffer-as-array float-results))
             (int-results (buffer-as-array int-results)))
         (declare (ignorable float-results int-results))
         (macrolet ((test-int-val (idx val)
                      `(is (= (aref int-results ,idx) ,val)))
                    (test-float-val (idx val)
                      `(is (float= (aref float-results ,idx) ,val))))
           ,@cvcode)))))

(def test test/translator/compute-1 (target)
  (test-computations (target)
    (test-int (- 3) (+ 1 8 4) (- 2 7 3) (* 2 9 4)
              (/ 4 2) (1+ 2) (1- 2)
              (abs -3) (abs 3)
              (cast int32 (abs (the uint32 3)))
              (cast int32 (abs (the int64 -3)))
              (max 1) (max 4 2) (max 3 9 6) (max 1 8 2 3)
              (min 1) (min 4 2) (min 3 9 6) (min 1 8 2 3))
    (test-float (- 3.0) (+ 1 8.0 4) (- 2.0 7 3) (* 2.0 9 4)
                (/ 5.0 2) (/ 5.0) (1+ 2.0) (1- 2.0)
                (abs -3.0) (abs 3.0)
                (max 1.0) (max 4.0 2) (max 3.0 9 6) (max 1.0 8 2 3)
                (min 1.0) (min 4.0 2) (min 3.0 9 6) (min 1.0 8 2 3))
    (test-bool t nil (not t) (not nil)
               (zerop 0) (zerop 1) (zerop 0.0) (zerop 1.0)
               (nonzerop 0) (nonzerop 1) (nonzerop 0.0) (nonzerop 1.0)
               (> 1 2) (> 2 1) (> 3 2 1) (> 3 1 2) (> 3 3 2)
               (>= 1 2) (>= 2 1) (>= 3 2 1) (>= 3 1 2) (>= 3 3 2)
               (= 1 1) (= 1 2) (= 1 1 1) (= 1 1 2)
               (/= 1 1) (/= 1 2) (/= 1 3 2) (/= 1 3 1)
               (eql float-results float-results)
               (and) (and t) (and t t) (and t nil)
               (and t t t) (and t t nil)
               (or) (or t) (or t nil) (or nil nil)
               (or nil nil nil) (or nil t nil))))

(def test test/translator/compute-2 (target)
  (test-computations (target)
    (test-int (logand) (logand 56) (logand 57 43) (logand 57 43 254)
              (logior) (logior 56) (logior 57 43) (logior 57 43 254)
              (logxor) (logxor 56) (logxor 57 43) (logxor 57 43 254)
              (logeqv) (logeqv 56) (logeqv 57 43) (logeqv 57 43 254)
              (lognot 5)
              (logandc1 47 255) (logandc2 47 7) (lognand 13 7)
              (logorc1 47 129) (logorc2 47 129) (lognor 13 7))))

(def test test/translator/compute-3 (target)
  (test-computations (target)
    (let ((a 12.3))
      (test-float (sin 0.39) (sinh 0.39) (asin 0.39) (asinh 1.39)
                  (cos 0.39) (cosh 0.39) (acos 0.39) (acosh 1.39)
                  (tan 0.39) (tanh 0.39) (atan 0.39) (atanh 0.39)
                  (exp 0.39) (sqrt 0.39)
                  (log 100) (log 100 2) (log 100 10) (log 100 11) (log 100 a)
                  (expt 2 10) (expt 10 10) (expt 11 10) (expt a 10)))))

(def test test/translator/compute-4 (target)
  (handler-bind ((warning #'ignore-warning))
    (test-computations (target)
      (let ((a 12))
        (declare (type uint32 a))
        (symbol-macrolet ((13U (the uint32 13)))
          (test-float (ffloor 3.5) (ffloor -3.5) (fceiling 3.5) (fceiling -3.5)
                      (ftruncate 3.5) (ftruncate -3.5) (fround 3.5) (fround -3.5)
                      (ffloor 13.5 8) (ffloor -13.5 8) (ffloor 13.5 10) (ffloor -13.5 10)
                      (fceiling 13.5 8) (fceiling -13.5 8) (fceiling 13.5 10) (fceiling -13.5 10)
                      (ftruncate 13.5 8) (ftruncate -13.5 8) (ftruncate 13.5 10) (ftruncate -13.5 10)
                      (fround 13.5 8) (fround -13.5 8) (fround 13.5 10) (fround -13.5 10)
                      (rem 13.5 8) (rem -13.5 8) (rem 13.5 10) (rem -13.5 10))
          (test-int (floor 3.5) (floor -3.5) (ceiling 3.5) (ceiling -3.5)
                    (truncate 3.5) (truncate -3.5) (round 3.5) (round -3.5)
                    (floor 13.5 8) (floor -13.5 8) (floor 13.5 10) (floor -13.5 10)
                    (ceiling 13.5 8) (ceiling -13.5 8) (ceiling 13.5 10) (ceiling -13.5 10)
                    (truncate 13.5 8) (truncate -13.5 8) (truncate 13.5 10) (truncate -13.5 10)
                    (round 13.5 8) (round -13.5 8) (round 13.5 10) (round -13.5 10)
                    (floor 13U 8) (floor -13 8) (floor 13U 10) (floor -13 10) (floor 13U a)
                    (ceiling 13U 8) (ceiling -13 8) (ceiling 13U 10) (ceiling -13 10) (ceiling 13U a)
                    (truncate 13U 8) (truncate -13 8) (truncate 13U 10) (truncate -13 10) (truncate 13U a)
                    (round 13U 8) (round -13 8) (round 13U 10) (round -13 10) (truncate 13U a)
                    (rem 13U 8) (rem -13 8) (rem 13U 10) (rem -13 10) (rem 13U a)))))))

(def gpu-function test-gpu-f (x y z)
  (+ (* x y) z))

(def test test/translator/compute-5 (target)
  (test-computations (target)
    (labels ((test1 (a b &optional (c 0) &key (d 0) (e 0))
               (return-from test1 (+ a b c d e)))
             (test2 (z y &key (c 0) &allow-other-keys)
               (test1 z y c)))
      (test-int (test1 2 3) (test1 2 3 4) (test1 2 3 4 :d 5)
                (test1 2 3 4 :e 7) (test1 2 3 4 :e 7 :d 3)
                (test2 7 3) (test2 7 3 :c 9))
      (test-float (test2 0.3 0.2) (test-gpu-f 7 0.1 -2))
      (let ((iv 0))
        (test-int (test2 1 2 :z (incf iv))
                  (test2 1 2 :c (incf iv) :z (setf iv -3)))))))

(def test test/translator/compute-6 (target)
  (test-computations (target)
    (multiple-value-bind (a b)
        (if t (values 1 2) (values 3 4))
      (test-int a b)
      (multiple-value-setq (a b) (values (1+ a) (1- b)))
      (test-int a b)
      (multiple-value-setq (a b) (values (+ b 2) (- a 3)))
      (test-int a b))
    (multiple-value-call (lambda (a b) (test-int a b))
      (if nil (values 1 2) (values 3 4)))))

(declaim (type int32 *test-int-1*))
(defparameter *test-int-1* 0)

(def test test/translator/compute-7 (target)
  (handler-bind ((warning #'ignore-warning))
    (let ((*test-int-1* 1))
      (test-computations (target)
        (labels ((test1 (a) (+ (incf *test-int-1*) a)))
          (test-int (test1 3))
          (let ((*test-int-1* (+ 8 *test-int-1*))
                (*test-int-1* (+ 5 *test-int-1*)))
            (test-int (test1 5) (test1 6) *test-int-1*))
          (let* ((*test-int-1* (+ 8 *test-int-1*))
                 (*test-int-1* (+ 5 *test-int-1*)))
            (test-int (test1 5) (test1 6) *test-int-1*))
          (test-int (test1 7) *test-int-1*)))
      (is (= *test-int-1* 3)))))

(def test test/translator/compute-8 (target)
  (test-computations (target)
    (labels ((test1 (a) (throw 'foo (+ a 3))))
      (test-int (catch 'foo (test1 3))
                (catch 'foo (test1 4)))
      (catch 'foo
        (test-int (catch 'foo (test1 5))
                  (catch 'foo (test1 6)))))))

(def test test/translator/compute-9 (target)
  (test-computations (target)
    (let ((tmp (make-array '(4 4) :element-type 'int32)))
      (loop for i from 0 below 16 do (setf (raw-aref tmp i) i))
      (let ((a (tuple-aref tmp 0)))
        (setf (tuple-aref tmp 0) (tuple-aref tmp 3)
              (tuple-aref tmp 3) a))
      (multiple-value-bind (a b) (untuple (tuple-raw-aref tmp 2 3))
        (setf (tuple-raw-aref tmp 12 2) (tuple (- b) (- a))))
      (test-int (raw-aref tmp 0) (raw-aref tmp 1) (raw-aref tmp 2) (raw-aref tmp 3)
                (raw-aref tmp 4) (raw-aref tmp 5) (raw-aref tmp 6) (raw-aref tmp 7)
                (raw-aref tmp 8) (raw-aref tmp 9) (raw-aref tmp 10) (raw-aref tmp 11)
                (raw-aref tmp 12) (raw-aref tmp 13) (raw-aref tmp 14) (raw-aref tmp 15)))))

(def test test/translator/compute (target)
  (test/translator/compute-1 target)
  (test/translator/compute-2 target)
  (test/translator/compute-3 target)
  (test/translator/compute-4 target)
  (test/translator/compute-5 target)
  (test/translator/compute-6 target)
  (test/translator/compute-7 target)
  (test/translator/compute-8 target)
  (test/translator/compute-9 target))

