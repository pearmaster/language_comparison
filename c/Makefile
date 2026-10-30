CC      ?= gcc
CFLAGS  ?= -Os -Wall -Wextra -std=c11 -ffunction-sections -fdata-sections
LDFLAGS ?= -Wl,--gc-sections -s
LDLIBS  := -lmosquitto -lm

BIN := build/mqtt_bench
SRC := main.c vendor/cJSON.c

$(BIN): $(SRC) vendor/cJSON.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS) $(LDLIBS)

.PHONY: clean
clean:
	rm -rf build
