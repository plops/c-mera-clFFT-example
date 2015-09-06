This program generates a C99 source which in turn uses clFFT to
calculate the 2D FFT of a real array. The absolute value of the
transform result is plotted using Gnuplot.

Required software to convert this program into the C99 source
clfft.c: Common Lisp (I use SBCL), C-Mera (I installed it in
~/quicklisp/local-projects and load it using Quicklisp).

Required software to run the generated program: make, gcc, some
OpenCL ICD (I developed using the one from Intel), clFFT (the
OpenCL initialization code is based on their example in the
README.md), gnuplot (for realtime plotting)
