BINS := airdrop click

.PHONY: all clean
all: $(BINS)

airdrop: airdrop.swift
	swiftc -O airdrop.swift -o $@

click: click.swift
	swiftc -O click.swift -o $@

clean:
	rm -f $(BINS)
