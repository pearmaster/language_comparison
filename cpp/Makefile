CXX      ?= g++
CXXFLAGS ?= -Os -Wall -Wextra -std=c++17 -ffunction-sections -fdata-sections
LDFLAGS  ?= -Wl,--gc-sections -s
LDLIBS   := -lmosquitto

BIN := build/mqtt_bench
SRC := main.cpp

$(BIN): $(SRC)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ $(SRC) $(LDFLAGS) $(LDLIBS)

.PHONY: clean
clean:
	rm -rf build
