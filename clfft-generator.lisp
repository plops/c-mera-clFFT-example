;; This program generates a C99 source which in turn uses clFFT to
;; calculate the 2D FFT of a real array. The absolute value of the
;; transform result is plotted using Gnuplot.

;; Required software to convert this program into the C99 source
;; clfft.c: Common Lisp (I use SBCL), C-Mera (I installed it in
;; ~/quicklisp/local-projects and load it using Quicklisp).

;; Required software to run the generated program: make, gcc, some
;; OpenCL ICD (I developed using the one from Intel), clFFT (the
;; OpenCL initialization code is based on their example in the
;; README.md), gnuplot (for realtime plotting)

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


;; To run this code in slime execute the following 4 sexpressions
;; using C-c C-c. Then compile the whole file with C-c C-k. This will
;; declare all the macros but fails in the last sexpression with the
;; whole code. Call this last sexpression with C-M-x to generate
;; clfft.c.

(ql:quickload :cgen) ;; or :cxxgen, etc.
(in-package :cg-user)    ;; cl-user equivalent with c-mera environment
(switch-reader)          ;; optional for prototyping


(progn
  (cgen:add-qualifier 'complex)
  (cgen:add-qualifier 'uint16_t)
  (use-variables CL_CONTEXT_PLATFORM CLFFT_2D CLFFT_FORWARD
		 NULL
		 CL_DEVICE_TYPE_CPU CL_DEVICE_TYPE_GPU
		 CLFFT_SINGLE CLFFT_COMPLEX_INTERLEAVED
		 CLFFT_REAL CLFFT_HERMITIAN_INTERLEAVED
		 CLFFT_HERMITIAN_PLANAR CLFFT_INPLACE
		 CLFFT_OUTOFPLACE CL_MEM_READ_WRITE
		 CL_MEM_WRITE_ONLY CL_MEM_READ_ONLY
		 O_RDONLY O_RDWR O_CREAT O_WRONLY
		 SEEK_SET CL_TRUE CL_SUCCESS))

(defmacro fill-array (array elems)
  `(,'progn
     ,@(loop for i from 0 and
	  e in elems collect
	    `(set (aref ,array ,i) ,e))))

(defmacro cl-funcall (&rest rest)
  "Check the return error of an OpenCL function."
  `(block
     (decl ((int err 0))
       (set err (funcall ,@rest))
       (if (!= CL_SUCCESS err)
	   (funcall printf (format nil "error: ~a returned %d\\n" ',(first rest)) err)))))

(defmacro cl-funcall-end (&rest rest)
  "Check the error of an OpenCL function that returns its error in a
  pointer which is given as the last argument. The return value of the
  function is written into the first argument of this macro."
  `(decl ((int err 0))
     (set ,(car rest) (funcall ,@(cdr rest) &err))
     (if (!= CL_SUCCESS err)
	 (funcall printf (format nil "error: ~a returned %d\\n" ',(cadr rest)) err))))


(defmacro with-clfft (&body body)
  `(decl ((clfftSetupData fftSetup))
     (cl-funcall clfftInitSetupData &fftSetup)
     (cl-funcall clfftSetup &fftSetup)
     ,@body
     (cl-funcall clfftTeardown)))

(defmacro with-fopen ((fd fn mode) &body body)
  ;; Note: I commented this doc string because the parenthesis seem to
  ;; confuse paredit and the quotes the lisp reader.
  
;;   "Open a file with fopen and close it after body has been
;; processed. The first argument is a variable returning the FILE
;; handle.
;; Example: 
;; ;;  (with-fopen (f "Hello World" "w")
;; ;;    (funcall fputs f "Hello World!\\n"))
;; expands into:
;; ;; {
;; ;; 	FILE *f = fopen("Hello World", "w");
;; ;; 	if (NULL == f) {
;; ;; 		printf("error fopen Hello World.");
;; ;; 	}
;; ;; 	fputs(f, "Hello World!\n");
;; ;; 	fclose(f);
;; ;; }
;; " 
  `(block
       (decl ((FILE* ,fd (funcall fopen ,fn ,mode)))
	 (if (== NULL ,fd)
	     (funcall printf ,(format nil "error fopen ~a.\\n" fn)))
	 ,@body
	 (funcall fclose ,fd))))

(defmacro with-copen ((fd fn &key (mode O_RDONLY) (position 0)
			  (permission #o644) ;; note: octal number
			  ) &body body)
;;   "Open a file with open, optionally seek to position and close after
;; body has been processed. The first variable returns a file
;; descriptor. 
;; Example:
;; ;; (decl ((unsigned char a[16]))
;; ;;   (with-copen (fd "out.raw" :mode O_WRONLY)
;; ;;     (if (!= 16 (funcall write fd a 16))
;; ;; 	(funcall printf "error didn't write enough bytes\\n"))))
;; Expands into:
;; ;; unsigned char a[16];
;; ;; {
;; ;; 	int fd = open("out.raw", O_WRONLY, 420);
;; ;; 	if (-1 == fd) {
;; ;; 		printf("error open out.raw.\n");
;; ;; 	}
;; ;; 	if (16 != write(fd, a, 16)) {
;; ;; 		printf("error didn't write enough bytes\n");
;; ;; 	}
;; ;; 	close(fd);
;; ;; }
;; "
  `(block
       (decl ((int ,fd (funcall open ,fn ,mode ,permission)))
	 (if (== -1 ,fd)
	     (funcall printf ,(format nil "error open ~a.\\n" fn)))
	 ,(unless (eq position 0)
	    `(funcall lseek ,fd ,position SEEK_SET))
	 ,@body
	 (funcall close ,fd))))

(defmacro with-gpu-malloc (mallocs &body body)
;;   "Allocate OpenCL Buffers on the GPU. Each of the array declarations
;;   are parsed like this:
;;   ;; (name ctx  len  &key (mode CL_MEM_READ_WRITE)  (host-ptr NULL))
;;   Example:
;;   ;; (with-gpu-malloc ((frame ctx n :mode CL_MEM_READ_ONLY  :host-ptr cpu_frame))
;;   ;;   ... code ...)
;;   Expands into:
;;   ;; cl_mem frame = clCreateBuffer (ctx, CL_MEM_READ_ONLY,
;;   ;; 				    n, cpu_frame, &err);
;;   ;; .. error check ..
;;   ;; .. code ..
;;   ;; clReleaseMemObject (frame);
;; "
  `(block
       (decl (,@(loop for e in mallocs collect
		     (destructuring-bind (name &rest rest) e
		       `(cl_mem ,name))))
	 (,'progn ,@(loop for e in mallocs collect
			 (destructuring-bind (name ctx  len
						   &key (mode CL_MEM_READ_WRITE)
						   (host-ptr NULL)) e
			   `(cl-funcall-end ,name clCreateBuffer ,ctx ,mode ,len ,host-ptr))))
	 ,@body
	 (,'progn ,@(loop for e in mallocs collect
			 (destructuring-bind (name &rest rest) e
			   `(cl-funcall clReleaseMemObject ,name)))))))

(defmacro with-cpu-malloc (mallocs &body body)
  
  ;; "This macro allocates pointers and also declares .._len variables
  ;; containing their length.
  ;; ;; (with-cpu-malloc ((float fft_output 3)
  ;; ;; 		  (float pointer))
  ;; ;;   ...code...)

  ;; ;; int fft_output_len=3*sizeof(float);
  ;; ;; float*fft_output= (float*) malloc (fft_output_len);
  ;; ;; int pointer_output_len=1*sizeof (float);
  ;; ;; float*pointer= (float*) malloc (pointer_output_len);
  ;; ;; ...code...
  ;; ;; free (fft_output);
  ;; ;; free (pointer)
  ;; "
  `(decl (,@(lisp
	     (let ((res nil))
	       (loop for e in mallocs do
		    (destructuring-bind (type name &optional (leng 1)) e
		      (let ((name-len (cintern (format nil "~A_len" name)))
			    (type* (cintern (format nil "~a*" type))))
			(push `(const int ,name-len (* ,leng (funcall sizeof ',type))) res)
			(push `(,type* ,name
				       (cast ,type*
					     (funcall malloc
						      ,name-len)))
			      res))))
	       (reverse res))))
     (,'progn ,@(loop for e in mallocs collect
		     (destructuring-bind (type name &optional (leng 1)) e
		       `(if (== NULL ,name)
			    (funcall puts ,(format nil "error during malloc of ~a" name))))))
     ,@body
     (,'progn ,@(loop for e in mallocs collect
		     (destructuring-bind (type name &optional (leng 1)) e
		       `(funcall free ,name))))))




(let ((NXval 128)
      (NTval 1024))
  (with-open-file (*standard-output* "clfft.c"
				     :direction :output
				     :if-exists :supersede
				     :if-does-not-exist :create)
    (loop for e in
	 (list 
	  (include <stdlib.h>)
	  (include <stdio.h>)
	  (include <unistd.h>)
	  (include <sys/types.h>)
	  (include <stdint.h>)
	  (include <sys/stat.h>)
	  (include <fcntl.h>)
	  (include <complex.h>)
	  (include <math.h>)
	  (include <string.h>)
	  (include <clFFT.h>)
	  
	  (typedef  |FLOAT COMPLEX| complex_float)

	  (function main () -> int
	    (decl ((cl_platform_id platform 0)
		   (cl_device_id device 0)
		   (cl_context_properties props[3])
		   (cl_context ctx 0)
		   (cl_command_queue queue 0))
	      (cl-funcall clGetPlatformIDs 1 &platform NULL)
	      (cl-funcall clGetDeviceIDs platform
			  CL_DEVICE_TYPE_CPU 1
			  &device NULL
			  )
	      (fill-array props (CL_CONTEXT_PLATFORM
				 (cast cl_context_properties platform) 0))
	      (cl-funcall-end ctx
			      clCreateContext props 1 &device
			      NULL NULL)
	      
	      (cl-funcall-end queue
			      clCreateCommandQueue ctx device 0)
	      (with-clfft
		(decl ((const unsigned int NX (lisp NXval))
		       (const unsigned int NT (lisp NTval))
		       (const unsigned int FRAME_SAMPLES (* NX NT))
		       (const unsigned int FFT_OUTPUT_SAMPLES (* (+ 1 (/ NX 2)) NT))
		       (clfftPlanHandle planHandle)
		       (clfftDim dim CLFFT_2D)
		       (size_t clLengths[2])
		       (size_t clInStrides[2])
		       (size_t clOutStrides[2]))
		  (fill-array clLengths (NX NT))
		  (cl-funcall clfftCreateDefaultPlan &planHandle ctx dim clLengths)
		  (fill-array clInStrides (1 NX)) (cl-funcall clfftSetPlanInStride planHandle dim clInStrides)
		  (fill-array clOutStrides (1 (+ 1 (/ NX 2)))) (cl-funcall clfftSetPlanOutStride planHandle dim clOutStrides)
		  (with-cpu-malloc ((float cpu_sf_input_frame FRAME_SAMPLES)
				    (complex_float cpu_icsf_fft_output FFT_OUTPUT_SAMPLES)
				    (float cpu_sf_fft_output FFT_OUTPUT_SAMPLES))
		    
		    (cl-funcall clfftSetPlanPrecision planHandle CLFFT_SINGLE)
		    (cl-funcall clfftSetLayout planHandle
				CLFFT_REAL CLFFT_HERMITIAN_INTERLEAVED)
		    (cl-funcall clfftSetResultLocation planHandle CLFFT_OUTOFPLACE)
		    (cl-funcall clfftBakePlan planHandle 1 &queue NULL NULL)
		    
		    (with-fopen (gp "cmdfifo" "w")
		      (funcall fprintf gp "set palette cubehelix; set cbrange [*:*];"))

		    (with-gpu-malloc ((gpu_sf_input_frame ctx cpu_sf_input_frame_len :mode CL_MEM_READ_ONLY)
				      (gpu_icsf_fft_output ctx cpu_icsf_fft_output_len :mode CL_MEM_READ_WRITE))
		      (for ((unsigned int count 0) (< count 100) count++)
			(funcall memset (cast void* cpu_sf_input_frame) 0 cpu_sf_input_frame_len)
			(set (aref cpu_sf_input_frame (+ 1 count)) 1.0)
			(cl-funcall clEnqueueWriteBuffer queue gpu_sf_input_frame CL_TRUE
				    0 cpu_sf_input_frame_len cpu_sf_input_frame 0 NULL NULL)
			(cl-funcall clfftEnqueueTransform planHandle CLFFT_FORWARD 1
				    (addr-of queue) 0 NULL NULL &gpu_sf_input_frame &gpu_icsf_fft_output NULL)
			(funcall usleep 16000)
			(cl-funcall clFinish queue)
			(cl-funcall clEnqueueReadBuffer queue gpu_icsf_fft_output CL_TRUE
				    0 cpu_icsf_fft_output_len cpu_icsf_fft_output 0 NULL NULL)
			(for ((unsigned int i 0) (< i FFT_OUTPUT_SAMPLES) i++)
			  (set (aref cpu_sf_fft_output i)
			       (funcall crealf (aref cpu_icsf_fft_output i))))
			(with-copen (fd "/dev/shm/o.bin"
					:mode (\| O_CREAT O_WRONLY))
			  (if (!= cpu_sf_fft_output_len
				  (funcall write fd cpu_sf_fft_output cpu_sf_fft_output_len))
			      (funcall printf "error wrote not enough bytes\\n")))
			(with-fopen (gp "cmdfifo" "w")
			  (funcall fputs
				   (lisp (format nil "plot \\\"/dev/shm/o.bin\\\" binary array=~dx~d format=\\\"%float32\\\" using 1 with image\\n"
						 (+ 1 (floor NXval 2)) NTval))
				   gp)))))))
	      (return 0))))
       do
	 (simple-print e))))

