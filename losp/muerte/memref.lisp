;;;;------------------------------------------------------------------
;;;; 
;;;;    Copyright (C) 2001-2004, 
;;;;    Department of Computer Science, University of Tromso, Norway.
;;;; 
;;;;    For distribution policy, see the accompanying file COPYING.
;;;; 
;;;; Filename:      memref.lisp
;;;; Description:   Low-level memory access.
;;;; Author:        Frode Vatvedt Fjeld <frodef@acm.org>
;;;; Created at:    Tue Mar  6 21:25:49 2001
;;;;                
;;;; $Id: memref.lisp,v 1.6 2004/03/31 16:49:23 ffjeld Exp $
;;;;                
;;;;------------------------------------------------------------------

(provide :muerte/memref)

(in-package muerte)

(defun memwrite2 (address value)
  "Writes the 16-bit VALUE to memory ADDRESS."
  (with-inline-assembly (:returns :nothing)
    (:compile-form (:result-mode :eax) address)
    (:compile-form (:result-mode :ebx) value)
    (:sarl #.movitz::+movitz-fixnum-shift+ :eax)
    (:sarl #.movitz::+movitz-fixnum-shift+ :ebx)
    (:movw :bx (:eax))))

(define-compiler-macro memref (&whole form object offset index type &environment env)
;;;  (assert (typep offset '(integer 0 0)) (offset)
;;;    (error "memref offset not supported."))
  (if (not (movitz:movitz-constantp type))
      form
    (labels ((extract-constant-delta (form)
	     "Try to extract at compile-time an integer offset from form."
	     (cond
	      ((movitz:movitz-constantp form env)
	       (let ((x (movitz::eval-form form env)))
		 (check-type x integer)
		 (values x 0)))
	      ((not (consp form))
	       (values 0 form))
	      (t (case (car form)
		   (1+ (values 1 (second form)))
		   (1- (values -1 (second form)))
		   (+ (case (length form)
			(1 (values 0 0))
			(2 (values 0 (second form)))
			(t (loop with x = 0 and f = nil for sub-form in (cdr form)
			       as sub-value = (when (movitz:movitz-constantp sub-form env)
						(movitz::eval-form sub-form env))
			       do (if (integerp sub-value)
				      (incf x sub-value)
				    (push sub-form f))
			       finally (return (values x (cons '+ (nreverse f))))))))
		   (t #+ignore (warn "extract from: ~S" form)
		      (values 0 form)))))))
      (multiple-value-bind (constant-index index)
	  (extract-constant-delta index)
	(multiple-value-bind (constant-offset offset)
	    (extract-constant-delta offset)
	  (flet ((offset-by (element-size)
		   (+ constant-offset (* constant-index element-size))))
	    #+ignore
	    (warn "o: ~S, co: ~S, i: ~S, ci: ~S"
		  offset constant-offset
		  index constant-index)
	    (let ((type (movitz::eval-form type env)))
	      (case type
		(:unsigned-byte8
		 `(with-inline-assembly (:returns :untagged-fixnum-eax)
		    (:compile-form (:result-mode :push) ,object)
		    (:compile-two-forms (:ecx :ebx) ,offset ,index)
		    (:popl :eax)	; object
		    (:addl :ecx :ebx)	; index += offset
		    (:sarl #.movitz::+movitz-fixnum-shift+ :ebx)
		    (:movzxb (:eax :ebx ,(offset-by 1)) :eax)))
		(:unsigned-byte16
		 `(with-inline-assembly (:returns :untagged-fixnum-ecx)
		    (:compile-form (:result-mode :push) ,object)
		    (:compile-two-forms (:eax :ebx) ,offset ,index)
		    (:sarl #.(cl:1- movitz::+movitz-fixnum-shift+) :ebx)
		    (:sarl #.movitz::+movitz-fixnum-shift+ :eax)
		    (:addl :eax :ebx)
		    (:popl :eax)	; object
		    (:movzxw (:eax :ebx ,(offset-by 2)) :ecx)))
		(:unsigned-byte32
		 (assert (= 2 movitz::+movitz-fixnum-shift+))
		 (let ((overflow (gensym "overflow-")))
		   `(with-inline-assembly (:returns :untagged-fixnum-ecx)
		      (:compile-form (:result-mode :push) ,object)
		      (:compile-two-forms (:ecx :ebx) ,offset ,index)
		      (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
		      (:addl :ebx :ecx)
		      (:popl :eax)	; object
		      (:movl (:eax :ecx ,(offset-by 4)) :ecx)
		      (:cmpl ,movitz::+movitz-most-positive-fixnum+ :ecx)
		      (:jg '(:sub-program (,overflow) (:int 4))))))
		(:unsigned-byte29+3
		 ;; Two values: the 29 upper bits as unsigned integer,
		 ;; and secondly the lower 3 bits as unsigned.
		 (assert (= 2 movitz::+movitz-fixnum-shift+))
		 `(with-inline-assembly (:returns :multiple-values)
		    (:compile-form (:result-mode :push) ,object)
		    (:compile-two-forms (:ecx :ebx) ,offset ,index)
		    (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
		    (:addl :ebx :ecx)
		    (:popl :eax)	; object
		    (:movl (:eax :ecx ,(offset-by 4)) :ecx)
		    (:leal ((:ecx 4)) :ebx)
		    (:shrl 1 :ecx)
		    (:andl #b11100 :ebx)
		    (:andl -4 :ecx)
		    (:movl :ecx :eax)
		    (:movl 2 :ecx)
		    (:stc)))
		(:signed-byte30+2
		 ;; Two values: the 30 upper bits as signed integer,
		 ;; and secondly the lower 2 bits as unsigned.
		 (assert (= 2 movitz::+movitz-fixnum-shift+))
		 `(with-inline-assembly (:returns :multiple-values)
		    (:compile-form (:result-mode :push) ,object)
		    (:compile-two-forms (:ecx :ebx) ,offset ,index)
		    (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
		    (:addl :ebx :ecx)
		    (:popl :eax)	; object
		    (:movl (:eax :ecx ,(offset-by 4)) :ecx)
		    (:leal ((:ecx 4)) :ebx)
		    (:andl #b1100 :ebx)
		    (:andl -4 :ecx)
		    (:movl :ecx :eax)
		    (:movl 2 :ecx)
		    (:stc)))
		(:character
		 (when (eq 0 index) (warn "zero char index!"))
		 (cond
		  ((eq 0 offset)
		   `(with-inline-assembly (:returns :eax)
		      (:compile-two-forms (:ecx :ebx) ,object ,index)
		      (:xorl :eax :eax)
		      (:movb #.(movitz:tag :character) :al)
		      (:sarl #.movitz::+movitz-fixnum-shift+ :ebx) ; scale index
		      (:movb (:ecx :ebx ,(offset-by 1)) :ah)))
		  (t `(with-inline-assembly (:returns :eax)
			(:compile-form (:result-mode :push) ,object)
			(:compile-two-forms (:ecx :ebx) ,offset ,index)
			(:addl :ecx :ebx)
			(:xorl :eax :eax)
			(:movb #.(movitz:tag :character) :al)
			(:popl :ecx)	; pop object
			(:sarl #.movitz::+movitz-fixnum-shift+ :ebx) ; scale offset+index
			(:movb (:ebx :ecx ,(offset-by 1)) :ah)))))
		(:lisp
		 (cond
		  ((and (eq 0 index) (eq 0 offset))
		   `(with-inline-assembly (:returns :register)
		      (:compile-form (:result-mode :register) ,object)
		      (:movl ((:result-register) ,(offset-by 4)) (:result-register))))
		  ((eq 0 offset)
		   `(with-inline-assembly (:returns :eax)
		      (:compile-two-forms (:eax :ecx) ,object ,index)
		      ,@(when (cl:plusp (cl:- movitz::+movitz-fixnum-shift+ 2))
			  `((:sarl ,(cl:- movitz::+movitz-fixnum-shift+ 2)) :ecx))
		      (:movl (:eax :ecx ,(offset-by 4)) :eax)))
		  (t `(with-inline-assembly (:returns :eax)
			(:compile-form (:result-mode :push) ,object)
			(:compile-two-forms (:untagged-fixnum-eax :ecx) ,offset ,index)
			,@(when (cl:plusp (cl:- movitz::+movitz-fixnum-shift+ 2))
			    `((:sarl ,(cl:- movitz::+movitz-fixnum-shift+ 2)) :ecx))
			(:addl :ecx :eax)
			(:popl :ebx)	; pop object
			(:movl (:eax :ebx ,(offset-by 4)) :eax)))))
		(t (error "Unknown memref type: ~S" (movitz::eval-form type nil nil))
		   form)))))))))

(defun memref (object offset index type)
  (ecase type
    (:unsigned-byte8    (memref object offset index :unsigned-byte8))
    (:unsigned-byte16   (memref object offset index :unsigned-byte16))
    (:unsigned-byte32   (memref object offset index :unsigned-byte32))
    (:character         (memref object offset index :character))
    (:lisp              (memref object offset index :lisp))
    (:signed-byte30+2   (memref object offset index :signed-byte30+2))
    (:unsigned-byte29+3 (memref object offset index :unsigned-byte29+3))))

(define-compiler-macro (setf memref) (&whole form &environment env value object offset index type)
  (if (not (movitz:movitz-constantp type env))
      form
    (case (movitz::eval-form type)
      (:character
       (cond
	((and (movitz:movitz-constantp value env)
	      (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value movitz-character)
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-form (:result-mode :ebx) ,object)
		(:movb ,(movitz:movitz-intern value)
		       (:ebx ,(+ (movitz:movitz-eval offset env)
				 (* 1 (movitz:movitz-eval index env))))))
	      ,value)))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 `(with-inline-assembly (:returns :eax)
	    (:compile-two-forms (:eax :ebx) ,value ,object)
	    (:movb :ah (:ebx ,(+ (movitz:movitz-eval offset env)
				 (* 1 (movitz:movitz-eval index env)))))))
	((movitz:movitz-constantp offset env)
	 (let ((value-var (gensym "memref-value-")))
	   `(let ((,value-var ,value)) 
	      (with-inline-assembly (:returns :eax)
		(:compile-two-forms (:ebx :untagged-fixnum-ecx) ,object ,index)
		(:load-lexical (:lexical-binding ,value-var) :eax)
		(:movb :ah (:ebx :ecx ,(+ (movitz:movitz-eval offset env))))))))
	(t (let ((object-var (gensym "memref-object-"))
		 (offset-var (gensym "memref-offset-")))
	     `(let ((,object-var ,object) (,offset-var ,offset))
		(with-inline-assembly (:returns :nothing)
		  (:compile-two-forms (:ecx :eax) ,index ,value)
		  (:load-lexical (:lexical-binding ,offset-var) :ebx)
		  (:addl :ebx :ecx)
		  (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
		  (:load-lexical (:lexical-binding ,object-var) :ebx)
		  (:movb :ah (:ebx :ecx))))))))
      (:unsigned-byte32
       (assert (= 4 movitz::+movitz-fixnum-factor+))
       (cond
	((and (movitz:movitz-constantp value env)
	      (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 32))
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-form (:result-mode :ebx) ,object)
		(:movl ,value (:ebx ,(+ (movitz:movitz-eval offset env)
					(* 2 (movitz:movitz-eval index env))))))
	      ,value)))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 `(with-inline-assembly (:returns :untagged-fixnum-ecx)
	    (:compile-two-forms (:ecx :ebx) ,value ,object)
	    (:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
	    (:movl :ecx (:ebx ,(+ (movitz:movitz-eval offset env)
				  (* 4 (movitz:movitz-eval index env)))))))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp value env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 32))
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-two-forms (:ecx :ebx) ,index ,object)
		(:movl ,value (:ebx :ecx ,(movitz:movitz-eval offset env))))
	      ,value)))
	((movitz:movitz-constantp offset env)
	 (let ((value-var (gensym "memref-value-")))
	   `(let ((,value-var ,value))
	      (with-inline-assembly (:returns :untagged-fixnum-ecx)
		(:compile-two-forms (:ebx :eax) ,object ,index)
		(:load-lexical (:lexical-binding ,value-var) :ecx)
		(:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
		(:movl :ecx (:eax :ebx ,(movitz:movitz-eval offset env)))))))
	(t (warn "Compiling unsafely: ~A" form)
	   `(with-inline-assembly (:returns :untagged-fixnum-eax)
	      (:compile-form (:result-mode :push) ,object)
	      (:compile-form (:result-mode :push) ,offset)
	      (:compile-two-forms (:ebx :eax) ,index ,value)
	      (:popl :ecx)		; offset
	      (:shrl #.movitz::+movitz-fixnum-shift+ :eax)
	      (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
	      (:addl :ebx :ecx)		; index += offset
	      (:popl :ebx)		; object
	      (:movl :eax (:ebx :ecx))))))
      (:unsigned-byte16
       (cond
	((and (movitz:movitz-constantp value env)
	      (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 16))
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-form (:result-mode :ebx) ,object)
		(:movw ,value (:ebx ,(+ (movitz:movitz-eval offset env)
					(* 2 (movitz:movitz-eval index env))))))
	      ,value)))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 `(with-inline-assembly (:returns :untagged-fixnum-ecx)
	    (:compile-two-forms (:ecx :ebx) ,value ,object)
	    (:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
	    (:movw :cx (:ebx ,(+ (movitz:movitz-eval offset env)
				 (* 2 (movitz:movitz-eval index env)))))))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp value env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 16))
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-two-forms (:ecx :ebx) ,index ,object)
		(:shrl ,(1- movitz:+movitz-fixnum-shift+) :ecx)
		(:movw ,value (:ebx :ecx ,(movitz:movitz-eval offset env))))
	      ,value)))
	((movitz:movitz-constantp offset env)
	 (let ((value-var (gensym "memref-value-")))
	   (if (<= 16 movitz:*compiler-allow-untagged-word-bits*)
	       `(let ((,value-var ,value))
		  (with-inline-assembly (:returns :untagged-fixnum-eax)
		    (:compile-two-forms (:ebx :ecx) ,object ,index)
		    (:load-lexical (:lexical-binding ,value-var) :untagged-fixnum-eax)
		    (:shrl ,(1- movitz:+movitz-fixnum-shift+) :ecx)
		    (:movw :ax (:ebx :ecx  ,(movitz:movitz-eval offset env)))))
	     `(let ((,value-var ,value))
		(with-inline-assembly (:returns :nothing)
		  (:compile-two-forms (:ebx :ecx) ,object ,index)
		  (:load-lexical (:lexical-binding ,value-var) :eax)
		  (:shrl ,(1- movitz:+movitz-fixnum-shift+) :ecx)
		  (:shll ,(- 8 movitz:+movitz-fixnum-shift+) :eax)
		  (:movb :ah (:ebx :ecx  ,(movitz:movitz-eval offset env)))
		  (:andl #xff0000 :eax)
		  (:shrl 8 :eax)
		  (:movb :ah (:ebx :ecx ,(1+ (movitz:movitz-eval offset env)))))
		,value-var))))
	(t (let ((value-var (gensym "memref-value-"))
		 (object-var (gensym "memref-object-")))
	     (if (<= 16 movitz:*compiler-allow-untagged-word-bits*)
		 `(let ((,value-var ,offset) (,object-var ,object))
		    (with-inline-assembly (:returns :untagged-fixnum-eax)
		      (:compile-two-forms (:ebx :ecx) ,offset ,index)
		      (:load-lexical (:lexical-binding ,value-var) :eax)
		      (:andl ,(* movitz:+movitz-fixnum-factor+ #xffff) :eax)
		      (:leal (:ebx (:ecx 2)) :ecx)
		      (:shrl ,movitz:+movitz-fixnum-shift+ :eax)
		      (:sarl ,movitz:+movitz-fixnum-shift+ :ecx)
		      (:load-lexical (:lexical-binding ,object-var) :ebx)
		      (:movw :ax (:ebx :ecx))))
	       `(let ((,value-var ,value) (,object-var ,object))
		  (with-inline-assembly (:returns :nothing)
		    (:compile-two-forms (:ebx :ecx) ,offset ,index)
		    (:load-lexical (:lexical-binding ,value-var) :eax)
		    (:leal (:ebx (:ecx 2)) :ecx)
		    (:shll ,(- 8 movitz:+movitz-fixnum-shift+) :eax)
		    (:sarl ,movitz:+movitz-fixnum-shift+ :ecx)
		    (:load-lexical (:lexical-binding ,object-var) :ebx)
		    (:movb :ah (:ebx :ecx))
		    (:andl #xff0000 :eax)
		    (:shrl 8 :eax)
		    (:movb :ah (:ebx :ecx 1)))
		  ,value-var))))))
      (:unsigned-byte8
       (cond
	((and (movitz:movitz-constantp value env)
	      (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 8))
	   `(progn
	      (with-inline-assembly (:returns :nothing)
		(:compile-form (:result-mode :ebx) ,object)
		(:movb ,value (:ebx ,(+ (movitz:movitz-eval offset env)
					(* 1 (movitz:movitz-eval index env))))))
	      ,value)))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 `(with-inline-assembly (:returns :untagged-fixnum-ecx)
	    (:compile-two-forms (:ecx :ebx) ,value ,object)
	    (:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
	    (:movb :cl (:ebx ,(+ (movitz:movitz-eval offset env)
				 (* 1 (movitz:movitz-eval index env)))))))
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp value env))
	 (let ((value (movitz:movitz-eval value env)))
	   (check-type value (unsigned-byte 8))
	   `(progn
	      (with-inline-assembly (:returns :untagged-fixnum-ecx)
		(:compile-two-forms (:eax :ecx) ,object ,index)
		(:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
		(:movb ,value (:eax :ecx ,(movitz:movitz-eval offset env))))
	      value)))
	((movitz:movitz-constantp offset env)
	 (let ((value-var (gensym "memref-value-")))
	   `(let ((,value-var ,value))
	      (with-inline-assembly (:returns :nothing)
		(:compile-two-forms (:ebx :ecx) ,object ,index)
		(:load-lexical (:lexical-binding ,value-var) :eax)
		(:shrl ,movitz:+movitz-fixnum-shift+ :ecx)
		(:shll ,(- 8 movitz:+movitz-fixnum-shift+) :eax) ; value into :AH
		(:movb :ah (:ebx :ecx ,(movitz:movitz-eval offset env))))
	      ,value-var)))
	(t (let ((value-var (gensym "memref-value-"))
		 (object-var (gensym "memref-object-")))
	     `(let ((,value-var ,value) (,object-var ,object))
		(with-inline-assembly (:returns :nothing)
		  (:compile-two-forms (:ebx :ecx) ,offset ,index)
		  (:load-lexical (:lexical-binding ,value-var) :eax)
		  (:addl :ebx :ecx)
		  (:load-lexical (:lexical-binding ,object-var) :ebx) ; value into :AH
		  (:shll ,(- 8 movitz:+movitz-fixnum-shift+) :eax)
		  (:sarl ,movitz::+movitz-fixnum-shift+ :ecx)
		  (:movb :ah (:ebx :ecx)))
		,value-var)))))
      (:lisp
       (cond
	((and (movitz:movitz-constantp offset env)
	      (movitz:movitz-constantp index env))
	 `(with-inline-assembly (:returns :eax)
	    (:compile-two-forms (:eax :ebx) ,value ,object)
	    (:movl :eax (:ebx ,(+ (movitz:movitz-eval offset env)
				  (* 4 (movitz:movitz-eval index env)))))))
	((movitz:movitz-constantp offset env)
	 (let ((value-var (gensym "memref-value-")))
	   `(let ((,value-var ,value))
	      (with-inline-assembly (:returns :eax)
		(:compile-two-forms (:ebx :ecx) ,object ,index)
		(:load-lexical (:lexical-binding ,value-var) :eax)
		,@(when (plusp (- movitz:+movitz-fixnum-shift+ 2))
		    `((:sarl ,(- movitz:+movitz-fixnum-shift+ 2)) :ecx))
		(:movl :eax (:ebx :ecx ,(movitz:movitz-eval offset env)))))))
	(t (let ((value-var (gensym "memref-value-"))
		 (object-var (gensym "memref-object-")))
	     `(let ((,value-var ,value) (,object-var ,object))
		(with-inline-assembly (:returns :eax)
		  (:compile-two-forms (:untagged-fixnum-ecx :ebx) ,offset ,index)
		  (:load-lexical (:lexical-binding ,value-var) :eax)
		  ,@(when (cl:plusp (cl:- movitz::+movitz-fixnum-shift+ 2))
		      `((:sarl ,(cl:- movitz::+movitz-fixnum-shift+ 2)) :ebx))
		  (:addl :ebx :ecx)	; index += offset
		  (:load-lexical (:lexical-binding ,object-var) :ebx)
		  (:movl :eax (:ebx :ecx))))))))
      (t ;; (warn "Can't handle inline MEMREF: ~S" form)
	 form))))

(defun (setf memref) (value object offset index type)
  (ecase type
    (:character
     (setf (memref object offset index :character) value))
    (:unsigned-byte8
     (setf (memref object offset index :unsigned-byte8) value))
    (:unsigned-byte16
     (setf (memref object offset index :unsigned-byte16) value))
    (:unsigned-byte32
     (setf (memref object offset index :unsigned-byte32) value))
    (:lisp
     (setf (memref object offset index :lisp) value))))

(define-compiler-macro memref-int (&whole form &environment env address offset index type
				   &optional physicalp)
  (if (or (not (movitz:movitz-constantp type physicalp))
	  (not (movitz:movitz-constantp physicalp env)))
      form
    (let* ((physicalp (movitz::eval-form physicalp env))
	   (prefixes (if physicalp '(:gs-override) ())))
      (ecase (movitz::eval-form type)
	(:lisp
	 `(with-inline-assembly (:returns :eax)
	    (:compile-form (:result-mode :push) ,address)
	    (:compile-form (:result-mode :push) ,offset)
	    (:compile-form (:result-mode :ecx) ,index)
	    (:popl :ebx)		; offset
	    (:popl :eax)		; address
	    (:shll 2 :ecx)
	    (:addl :ecx :eax)
	    (:addl :ebx :eax)
	    (:shrl #.movitz::+movitz-fixnum-shift+ :eax)
	    (,prefixes :movl (:eax) :eax)))
	(:unsigned-byte8
	 `(with-inline-assembly (:returns :untagged-fixnum-eax)
	    (:compile-form (:result-mode :push) ,address)
	    (:compile-form (:result-mode :push) ,offset)
	    (:compile-form (:result-mode :ecx) ,index)
	    (:popl :eax)		; offset
	    (:popl :ebx)		; address
	    (:addl :ecx :ebx)		; add index
	    (:addl :eax :ebx)		; add offset
	    (:xorl :eax :eax)
	    (:shrl #.movitz::+movitz-fixnum-shift+ :ebx) ; scale down address
	    (,prefixes :movb (:ebx) :al)))
	(:unsigned-byte32
	 `(with-inline-assembly (:returns :eax)
	    (:compile-form (:result-mode :push) ,address)
	    (:compile-two-forms (:eax :ecx) ,offset ,index)
	    (:popl :ebx)		; address
	    (:shll 2 :ecx)
	    (:addl :ebx :eax)
	    (:into)
	    (:testb ,(cl:mask-field (cl:byte (cl:+ 2 movitz::+movitz-fixnum-shift+) 0) -1)
		    :al)
	    (:jnz '(:sub-program (unaligned) (:int 63)))
	    (:addl :ecx :eax)
	    (:shrl #.movitz::+movitz-fixnum-shift+ :eax) ; scale down address
	    (,prefixes :movl (:eax) :ecx)
	    (:cmpl ,movitz::+movitz-most-positive-fixnum+ :ecx)
	    (:jg '(:sub-program (overflow) (:int 4)))
	    (:leal ((:ecx ,movitz::+movitz-fixnum-factor+)
		    :edi ,(- (movitz::image-nil-word movitz::*image*)))
		   :eax)))
	(:unsigned-byte16
	 (cond
	  ((and (eq 0 offset) (eq 0 index))
	   `(with-inline-assembly (:returns :untagged-fixnum-eax)
	      (:compile-form (:result-mode :ebx) ,address)
	      (:xorl :eax :eax)
	      (:shrl #.movitz::+movitz-fixnum-shift+ :ebx) ; scale down address
	      (,prefixes :movw (:ebx (:ecx 2)) :ax)))
	  (t `(with-inline-assembly (:returns :untagged-fixnum-eax)
		(:compile-form (:result-mode :push) ,address)
		(:compile-form (:result-mode :push) ,offset)
		(:compile-form (:result-mode :ecx) ,index)
		(:popl :eax)		; offset
		(:popl :ebx)		; address
		(:shrl #.movitz::+movitz-fixnum-shift+ :ecx) ; scale index
		(:addl :eax :ebx)	; add offset
		(:xorl :eax :eax)
		(:shrl #.movitz::+movitz-fixnum-shift+ :ebx) ; scale down address
		(,prefixes :movw (:ebx (:ecx 2)) :ax)))))))))

(defun memref-int (address offset index type &optional physicalp)
  (cond
   ((not physicalp)
    (ecase type
      (:lisp
       (memref-int address offset index :lisp))
      (:unsigned-byte8
       (memref-int address offset index :unsigned-byte8))
      (:unsigned-byte16
       (memref-int address offset index :unsigned-byte16))
      (:unsigned-byte32
       (memref-int address offset index :unsigned-byte32))))
   (physicalp
    (ecase type
      (:lisp
       (memref-int address offset index :lisp t))
      (:unsigned-byte8
       (memref-int address offset index :unsigned-byte8 t))
      (:unsigned-byte16
       (memref-int address offset index :unsigned-byte16 t))
      (:unsigned-byte32
       (memref-int address offset index :unsigned-byte32 t))))))

(define-compiler-macro (setf memref-int) (&whole form &environment env value address offset index type
								   &optional physicalp)
  (if (or (not (movitz:movitz-constantp type env))
	  (not (movitz:movitz-constantp physicalp env)))
      (progn
	(warn "setf memref-int form: ~S, ~S ~S" form type physicalp)
	form)
    (let* ((physicalp (movitz::eval-form physicalp env))
	   (prefixes (if physicalp '(:gs-override) ())))
      (ecase type
	(:lisp
	 (assert (= 4 movitz:+movitz-fixnum-factor+))
	 `(with-inline-assembly (:returns :untagged-fixnum-eax)
	    (:compile-form (:result-mode :push) ,address)
	    (:compile-form (:result-mode :push) ,index)
	    (:compile-form (:result-mode :push) ,offset)
	    (:compile-form (:result-mode :eax) ,value)
	    (:popl :edx)		; offset
	    (:popl :ebx)		; index
	    (:popl :ecx)		; address
	    (:addl :edx :ecx)
	    (:shrl #.movitz::+movitz-fixnum-shift+ :ecx)
	    (,prefixes :movl :eax (:ecx :ebx))))
	(:unsigned-byte8
	 `(with-inline-assembly (:returns :untagged-fixnum-eax)
	    (:compile-form (:result-mode :push) ,address)
	    (:compile-form (:result-mode :push) ,index)
	    (:compile-form (:result-mode :push) ,offset)
	    (:compile-form (:result-mode :eax) ,value)
	    (:popl :edx)		; offset
	    (:popl :ebx)		; index
	    (:popl :ecx)		; address
	    (:shrl #.movitz::+movitz-fixnum-shift+ :eax)
	    (:addl :ebx :ecx)
	    (:addl :edx :ecx)
	    (:shrl #.movitz::+movitz-fixnum-shift+ :ecx)
	    (,prefixes :movb :al (:ecx))))
	(:unsigned-byte16
	 (cond
	  ((eq 0 offset)
	   `(with-inline-assembly (:returns :untagged-fixnum-eax)
	      (:compile-form (:result-mode :push) ,address)
	      (:compile-form (:result-mode :push) ,index)
	      (:compile-form (:result-mode :eax) ,value)
	      (:popl :ebx)		; index
	      (:shrl #.movitz::+movitz-fixnum-shift+ :eax) ; scale value
	      (:popl :ecx)		; address
	      (:shll 1 :ebx)		; scale index
	      (:addl :ebx :ecx)
	      (:shrl #.movitz::+movitz-fixnum-shift+ :ecx) ; scale address
	      (,prefixes :movw :ax (:ecx))))
	  (t `(with-inline-assembly (:returns :untagged-fixnum-eax)
		(:compile-form (:result-mode :push) ,address)
		(:compile-form (:result-mode :push) ,index)
		(:compile-form (:result-mode :push) ,offset)
		(:compile-form (:result-mode :eax) ,value)
		(:popl :edx)		; offset
		(:popl :ebx)		; index
		(:popl :ecx)		; address
		(:shrl #.movitz::+movitz-fixnum-shift+ :eax) ; scale value
		(:leal (:ecx (:ebx 2)) :ecx)
		(:addl :edx :ecx)	;
		(:shrl #.movitz::+movitz-fixnum-shift+ :ecx) ; scale offset+address
		(,prefixes :movw :ax (:ecx))))))))))

(defun (setf memref-int) (value address offset index type &optional physicalp)
  (cond
   ((not physicalp)
    (ecase type
      (:unsigned-byte8
       (setf (memref-int address offset index :unsigned-byte8) value))
      (:unsigned-byte16
       (setf (memref-int address offset index :unsigned-byte16) value))))
   (physicalp
    (ecase type
      (:unsigned-byte8
       (setf (memref-int address offset index :unsigned-byte8 t) value))
      (:unsigned-byte16
       (setf (memref-int address offset index :unsigned-byte16 t) value))))))

(defun memcopy (object-1 object-2 offset index-1 index-2 count type)
  (ecase type
    ((:unsigned-byte8 :character)
     (with-inline-assembly (:returns :nothing)
       (:compile-form (:result-mode :edx) offset)
       (:compile-form (:result-mode :ecx) index-1)
       (:addl :edx :ecx)
       (:compile-form (:result-mode :eax) object-1)
       (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
       (:addl :ecx :eax)

       (:compile-form (:result-mode :ecx) index-2)
       (:addl :edx :ecx)
       (:compile-form (:result-mode :ebx) object-2)
       (:sarl #.movitz::+movitz-fixnum-shift+ :ecx)
       (:addl :ecx :ebx)

       (:compile-form (:result-mode :ecx) count)
       (:shrl #.movitz::+movitz-fixnum-shift+ :ecx)
       (:jz 'done)
       (:decl :eax)
       (:decl :ebx)
       loop
       (:movb (:ebx :ecx) :dl)
       (:movb :dl (:eax :ecx))
       (:decl :ecx)
       (:jnz 'loop)
       done))))
	     
;;;       (:shrl 4 :ecx)
;;;       (:jz 'quads-done)
;;;
;;;       quad-loop
;;;       (:movl (:ebx) :edx)
;;;       (:addl 4 :ebx)
;;;       (:movl :edx (:eax))
;;;       (:addl 4 :eax)
;;;       (:decl :ecx)
;;;       (:jnz 'quad-loop)
;;;       
;;;       quads-done
;;;       (:compile-form (:result-mode ) count :ecx)
;;;       (:shrl 2 :ecx)
;;;       (:andl 3 :ecx)
;;;       (:jz 'done)
;;;       loop
;;;       (:movb (:ebx :ecx) :dl)
;;;       (:movb :dl (:eax :ecx))
;;;       (:decl :ecx)
;;;       (:jnz 'loop)
;;;       done))))

(define-compiler-macro %copy-words (destination source count &optional (start1 0) (start2 0)
				    &environment env)
  (assert (= 4 movitz::+movitz-fixnum-factor+))
  (cond
   ((and (movitz:movitz-constantp start1 env)
	 (movitz:movitz-constantp start2 env))
    (let ((start1 (movitz::eval-form start1 env))
	  (start2 (movitz::eval-form start2 env)))
      `(with-inline-assembly-case ()
	 (do-case (t :eax :labels (done copy-loop no-fixnum))
	   (:compile-arglist () ,destination ,source ,count)
	   (:popl :edx)			; count
	   ,@(unless (= 0 start1)
	       `((:addl ,(* start1 movitz::+movitz-fixnum-factor+) :eax)))
	   (:testl :edx :edx)
	   (:jz 'done)
	   ,@(unless (= 0 start2)
	       `((:addl ,(* start2 movitz::+movitz-fixnum-factor+) :ebx)))
	   (:testb ,movitz::+movitz-fixnum-zmask+ :dl)
	   (:jnz '(:sub-program (no-fixnum) (:int 107)))
	  copy-loop
	   (:movl (:ebx :edx) :ecx)
	   (:movl :ecx (:eax :edx))
	   (:subl 4 :edx)
	   (:jnz 'copy-loop)
	  done))))
   (t `(with-inline-assembly-case ()
	 (do-case (t :eax :labels (done copy-loop no-fixnum))
	   (:compile-arglist () ,destination ,source ,count ,start1 ,start2)
	   (:popl :ecx)			; start2
	   (:addl :ecx :ebx)
	   (:popl :ecx)			; start1
	   (:addl :ecx :eax)
	   (:popl :edx)			; count
	   (:testl :edx :edx)
	   (:jz 'done)
	   (:testb ,movitz::+movitz-fixnum-zmask+ :dl)
	   (:jnz '(:sub-program (no-fixnum) (:int 107)))
	  copy-loop
	   (:movl (:ebx :edx) :ecx)
	   (:movl :ecx (:eax :edx))
	   (:subl 4 :edx)
	   (:jnz 'copy-loop)
	  done)))))

(defun %copy-words (destination source count &optional (start1 0) (start2 0))
  (%copy-words destination source count start1 start2))
