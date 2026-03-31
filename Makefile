.PHONY: watch dhcp up down build-config setup status provision reset

watch:
	sudo .venv/bin/python3 pxe-watcher/watcher.py

dhcp:
	sudo dnsmasq --conf-file=netboot/dnsmasq.conf --tftp-root=$(CURDIR)/netboot --log-facility=$(CURDIR)/dnsmasq.log --no-daemon 2>&1 | grep -v '^dnsmasq-dhcp'

up:
	docker compose up -d

down:
	docker compose down

build-config:
	./scripts/build-config.sh

setup:
	./scripts/setup-pxe-server.sh

provision:
	@test -n "$(CONFIG)" || (echo "Usage: make provision CONFIG=config/my-batch.env" && exit 1)
	./scripts/provision-batch.sh --config $(CONFIG)

reset:
	@echo "Resetting queue (marking all slots as unassigned)..."
	@.venv/bin/python3 -c "import json; \
	  q=json.load(open('http-server/machines/queue.json')); \
	  [s.update({'assigned': False, 'mac': None}) for s in q]; \
	  json.dump(q, open('http-server/machines/queue.json', 'w'), indent=2)"
	@echo "Cleaning MAC-keyed directories..."
	sudo rm -rf http-server/machines/[0-9a-f][0-9a-f]:*
	@echo "Done. Queue ready for re-use."

status:
	@echo "=== Queue ==="
	@.venv/bin/python3 -c "import json; q=json.load(open('http-server/machines/queue.json')); \
	  [print(f\"  {'✓' if s.get('assigned') else '○'} {s['name']:<25} {s.get('mac', 'waiting...')}\") for s in q]"
	@echo ""
	@echo "=== Services ==="
	@docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || echo "  Docker not running"
	@pgrep -x dnsmasq >/dev/null 2>&1 && echo "  dnsmasq: running" || echo "  dnsmasq: stopped"
