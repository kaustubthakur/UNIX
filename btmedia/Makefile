PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin
CONFDIR := $(HOME)/.config/btmedia
SCRIPTS := btmedia-daemon.sh mediactl.sh btmedia-art.sh btmedia-bt.sh btmedia-ctl.sh btmedia-stats.sh

.PHONY: install uninstall check lint clean

install:
	@mkdir -p "$(BINDIR)" "$(CONFDIR)"
	@chmod +x $(addprefix bin/,$(SCRIPTS))
	@for s in $(SCRIPTS); do \
		ln -sf "$(CURDIR)/bin/$$s" "$(BINDIR)/$${s%.sh}"; \
	done
	@if [ ! -f "$(CONFDIR)/btmedia.conf" ]; then \
		cp config/btmedia.conf "$(CONFDIR)/btmedia.conf"; \
		echo "Installed default config -> $(CONFDIR)/btmedia.conf"; \
	fi
	@echo "Linked commands into $(BINDIR): $(SCRIPTS:.sh=)"

uninstall:
	@for s in $(SCRIPTS); do rm -f "$(BINDIR)/$${s%.sh}"; done
	@echo "Removed symlinks from $(BINDIR)"

check:
	@bash bin/btmedia-ctl.sh doctor

lint:
	@command -v shellcheck >/dev/null || { echo "Install shellcheck first"; exit 1; }
	@shellcheck -x lib/common.sh $(addprefix bin/,$(SCRIPTS))

clean:
	@bash bin/btmedia-art.sh --clear
