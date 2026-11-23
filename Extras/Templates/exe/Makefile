# Builds {{name}} with kairo. POSIX make: GNU make and BSD make both run it.
#
#   make            the debug program, build/debug/$(NAME)
#   make release    the optimized program, build/release/$(NAME)
#   make run        builds the debug program and runs it
#   make clean      removes build/
#
# kairo recompiles only what changed (the object cache in $(CACHE)), so every
# target runs it and lets it decide.

NAME   = {{name}}
KAIRO ?= kairo
CACHE ?= build/cache
FLAGS  = -I include --cache-dir $(CACHE)

debug:
	mkdir -p build/debug $(CACHE)
	$(KAIRO) source/main.k $(FLAGS) -O0 -g -o build/debug/$(NAME)

release:
	mkdir -p build/release $(CACHE)
	$(KAIRO) source/main.k $(FLAGS) -O2 -o build/release/$(NAME)

run: debug
	./build/debug/$(NAME)

clean:
	rm -rf build

.PHONY: debug release run clean
