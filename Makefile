SKILL_DIR := skills/airdrop-tool

.PHONY: all clean
all:
	$(MAKE) -C $(SKILL_DIR)
	ln -sf $(SKILL_DIR)/bin/airdrop airdrop
	ln -sf $(SKILL_DIR)/bin/click click

clean:
	$(MAKE) -C $(SKILL_DIR) clean
	rm -f airdrop click
