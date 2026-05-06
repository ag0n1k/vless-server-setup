.PHONY: help check plan plan-from apply status switch refresh-nodes lint vault-edit vault-encrypt-staging facts build-wdtt gen-password

ANSIBLE       ?= ansible-playbook
INV           ?= ansible/inventory/hosts.yml
HOST          ?= vpn1
# Если ansible.cfg задаёт vault_password_file — этого достаточно.
# Можно переопределить через `make apply VAULT_PASS=/path/to/file`.
VAULT_PASS    ?=
SKIP_TAGS     ?=
ANSIBLE_FLAGS ?= $(if $(VAULT_PASS),--vault-password-file=$(VAULT_PASS)) \
                 $(if $(SKIP_TAGS),--skip-tags=$(SKIP_TAGS))

help:
	@echo "make check            — syntax check всех playbooks"
	@echo "make plan             — dry-run site.yml (--check --diff)"
	@echo "make plan-from ROLES=wdtt,singbox,tproxy — dry-run только указанных ролей"
	@echo "                        (pre_tasks с tags=always всегда запускаются)"
	@echo "make apply            — применить site.yml (с подтверждением diff)"
	@echo "make apply-from ROLES=wdtt,singbox,tproxy — apply только указанных ролей"
	@echo "make apply SKIP_TAGS=apt — пропустить установку пакетов (если уже стоит)"
	@echo "make status           — собрать факты и показать состояние сервисов"
	@echo "make refresh-nodes    — обновить /etc/sing-box/nodes.json из подписки"
	@echo "make switch INDEX=2   — переключить sing-box на ноду #2"
	@echo "make switch NEXT=1    — следующая нода"
	@echo "make build-wdtt       — собрать wdtt-server в .local/ (нужен go)"
	@echo "make gen-password     — сгенерировать пароль (24 байта base64)"
	@echo "make lint             — ansible-lint (если установлен)"
	@echo "make vault-edit       — редактировать group_vars/all/vault.yml"
	@echo "make facts            — снять и закешировать факты с боевого хоста"

check:
	@$(ANSIBLE) --syntax-check ansible/playbooks/site.yml

plan:
	@$(ANSIBLE) ansible/playbooks/site.yml --check --diff $(ANSIBLE_FLAGS)

plan-from:
	@test -n "$(ROLES)" || (echo 'usage: make plan-from ROLES=wdtt,singbox,tproxy' >&2; exit 1)
	@$(ANSIBLE) ansible/playbooks/site.yml --check --diff --tags 'always,$(ROLES)' $(ANSIBLE_FLAGS)

apply:
	@$(ANSIBLE) ansible/playbooks/site.yml --diff $(ANSIBLE_FLAGS)

apply-from:
	@test -n "$(ROLES)" || (echo 'usage: make apply-from ROLES=wdtt,singbox,tproxy' >&2; exit 1)
	@$(ANSIBLE) ansible/playbooks/site.yml --diff --tags 'always,$(ROLES)' $(ANSIBLE_FLAGS)

status:
	@$(ANSIBLE) ansible/playbooks/status.yml $(ANSIBLE_FLAGS)

refresh-nodes:
	@$(ANSIBLE) ansible/playbooks/refresh-nodes.yml $(ANSIBLE_FLAGS)

switch:
	@$(ANSIBLE) ansible/playbooks/switch-node.yml \
		-e "switch_mode=$(if $(INDEX),index,$(if $(NAME),name,$(if $(NEXT),next,first)))" \
		-e "switch_index=$(INDEX)" \
		-e "switch_name=$(NAME)" \
		$(ANSIBLE_FLAGS)

lint:
	@command -v ansible-lint >/dev/null && ansible-lint ansible/playbooks/site.yml || echo "ansible-lint not installed"

vault-edit:
	@ansible-vault edit ansible/inventory/group_vars/all/vault.yml $(if $(VAULT_PASS),--vault-password-file=$(VAULT_PASS))

facts:
	@$(ANSIBLE) ansible/playbooks/status.yml --tags facts $(ANSIBLE_FLAGS)

build-wdtt:
	@bash scripts/build-wdtt-server.sh $(VERSION)

gen-password:
	@openssl rand -base64 24
