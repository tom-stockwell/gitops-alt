.PHONY: generate check render-all diff whatruns new-cluster test

generate:
	scripts/generate

check:
	scripts/generate --check
	scripts/lint

render-all:
	rm -rf rendered/*/
	scripts/render-all rendered

diff:
	scripts/diff

whatruns:
	scripts/whatruns

new-cluster:
	@test -n "$(NAME)" -a -n "$(FROM)" || { echo "usage: make new-cluster NAME=<name> FROM=<existing> [DOMAIN=<domain>]" >&2; exit 1; }
	scripts/new-cluster $(NAME) --from $(FROM) $(if $(DOMAIN),--domain $(DOMAIN))

test:
	tests/run.sh
