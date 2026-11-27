SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: help up down stop build rebuild reset ps logs logs-agg logs-telco logs-merchant logs-nginx tail sql smoke status urls \
        telco merchant auto fire pay retry settlements clean

help:
	@echo "Payment Chaos Lab"
	@echo
	@echo "  make up            build and start the whole stack"
	@echo "  make down          stop the stack (keeps the database volume)"
	@echo "  make reset         delete the database volume + logs, then rebuild"
	@echo "  make ps            show container status"
	@echo "  make logs          follow all container logs"
	@echo "  make tail          follow all host log files"
	@echo "  make logs-agg      follow the aggregator log file"
	@echo "  make sql           open a MariaDB shell"
	@echo "  make q Q='...'     run one SQL query"
	@echo "  make smoke         wait for services and send one payment"
	@echo "  make status        show service health and URLs"
	@echo
	@echo "Chaos:"
	@echo "  make telco MODE=normal|timeout|503|drop_callback|bad_format"
	@echo "  make merchant MODE=ok|403_waf|302_redirect|500_crash|bad_hmac"
	@echo "  make auto STATE=on|off"
	@echo "  make fire N=10 [DUP=1]"
	@echo "  make pay ORDER=ord_manual_1"
	@echo "  make retry TRX=trx_..."
	@echo "  make settlements"
	@echo
	@echo "URLs:"
	@echo "  Merchant UI     http://localhost:8001"
	@echo "  Telco UI        http://localhost:8003"
	@echo "  Aggregator API  http://localhost:8080/docs  (direct: http://localhost:8000/docs)"
	@echo "  Grafana         http://localhost:3000   (admin/admin)"
	@echo "  Adminer         http://localhost:8081   (root/rootpass, db)"
	@echo "  Loki API        http://localhost:3100"

up:
	$(COMPOSE) up -d --build
	@echo
	@echo "Stack starting. Run 'make smoke' once the database is ready."

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

build:
	$(COMPOSE) build

rebuild:
	$(COMPOSE) build --no-cache

reset:
	./scripts/reset.sh

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

logs-agg:
	./scripts/tail.sh aggregator

logs-telco:
	./scripts/tail.sh telco

logs-merchant:
	./scripts/tail.sh merchant

logs-nginx:
	./scripts/tail.sh nginx

tail:
	./scripts/tail.sh

sql:
	./scripts/sql.sh

q:
	@if [[ -z "$(Q)" ]]; then echo "Usage: make q Q='SELECT ...'"; exit 1; fi
	@./scripts/sql.sh "$(Q)"

smoke:
	./scripts/smoke.sh

status:
	./scripts/chaos.sh status

urls:
	@echo "Merchant UI     http://localhost:8001"
	@echo "Telco UI        http://localhost:8003"
	@echo "Aggregator API  http://localhost:8080/docs  (direct: http://localhost:8000/docs)"
	@echo "Grafana         http://localhost:3000   (admin/admin)"
	@echo "Adminer         http://localhost:8081   (root/rootpass, db)"
	@echo "Loki API        http://localhost:3100"

telco:
	@if [[ -z "$(MODE)" ]]; then echo "Usage: make telco MODE=normal|timeout|503|drop_callback|bad_format"; exit 1; fi
	./scripts/chaos.sh telco "$(MODE)"

merchant:
	@if [[ -z "$(MODE)" ]]; then echo "Usage: make merchant MODE=ok|403_waf|302_redirect|500_crash|bad_hmac"; exit 1; fi
	./scripts/chaos.sh merchant "$(MODE)"

auto:
	@if [[ -z "$(STATE)" ]]; then echo "Usage: make auto STATE=on|off"; exit 1; fi
	./scripts/chaos.sh auto "$(STATE)"

fire:
	@if [[ "$(DUP)" == "1" ]]; then ./scripts/chaos.sh fire "$(or $(N),1)" --duplicate; else ./scripts/chaos.sh fire "$(or $(N),1)"; fi

pay:
	@if [[ -z "$(ORDER)" ]]; then echo "Usage: make pay ORDER=ord_manual_1"; exit 1; fi
	./scripts/chaos.sh pay "$(ORDER)"

retry:
	@if [[ -z "$(TRX)" ]]; then echo "Usage: make retry TRX=trx_..."; exit 1; fi
	./scripts/chaos.sh retry "$(TRX)"

settlements:
	./scripts/chaos.sh settlements

clean:
	$(COMPOSE) down -v --remove-orphans
	find logs -type f -name '*.log' -delete
