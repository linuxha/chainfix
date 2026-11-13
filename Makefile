CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

chainfix: chainfix.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f chainfix

.PHONY: clean
