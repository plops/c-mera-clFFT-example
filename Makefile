# I installed clFFT into /usr/local/ you might have to adjust for your directories.

CFLAGS=-std=gnu99 -I/home/martin.kielhorn/usr/include/ -march=native -pipe -Wall -Wextra
# optimization
CFLAGS+=-Ofast -fomit-frame-pointer -fopenmp
# instrumentation for debugging
#CFLAGS+=-Og -ggdb -Q -fprofile-arcs -fno-omit-frame-pointer -pg -fsanitize=address
# listing of assembly mixed with C source
#CFLAGS+=-Og -Wa,-adhln -ggdb
LDFLAGS=-L/usr/local/lib -lOpenCL -lclFFT -lm -Wl,-rpath=/usr/local/lib

clfft: clfft.c Makefile

clean:
	rm -rf clfft cmdfifo run_gnuplot
	killall gnuplot

# Note: for the plotting animations in Gnuplot I open one Gnuplot
# process and communicate with it over a fifo.

cmdfifo:
	mkfifo cmdfifo

run_gnuplot:
	touch run_gnuplot
	tail -f cmdfifo | gnuplot &

plot: cmdfifo run_gnuplot clfft
	./clfft

# during development I usually have slime open and emit code directly into clfft-generator.lisp

clfft.c: clfft-generator.lisp
	sbcl --load clfft-generator.lisp


