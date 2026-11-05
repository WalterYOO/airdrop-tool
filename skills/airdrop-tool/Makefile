BIN_DIR := bin
BINS := $(BIN_DIR)/airdrop $(BIN_DIR)/click

.PHONY: all clean
all: $(BINS)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(BIN_DIR)/airdrop: src/airdrop.swift | $(BIN_DIR)
	swiftc -O $< -o $@

$(BIN_DIR)/click: src/click.swift | $(BIN_DIR)
	swiftc -O $< -o $@

clean:
	rm -rf $(BIN_DIR)
