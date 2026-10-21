.PHONY: generate check render-all diff whatruns new-cluster promote test

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
	@test -n "$(NAME)" -a -n "$(FROM)" || { echo "usage: make new-cluster NAME=<name> FROM=<existing> [DOMAIN=<domain>] [TYPE=<clusterType>] [ENVIRONMENT=<environment>]" >&2; exit 1; }
	scripts/new-cluster $(NAME) --from $(FROM) $(if $(DOMAIN),--domain $(DOMAIN)) $(if $(TYPE),--type $(TYPE)) $(if $(ENVIRONMENT),--environment $(ENVIRONMENT))

promote:
	@test -n "$(CLUSTER)" -a -n "$(REF)" || { echo "usage: make promote CLUSTER=<cluster> REF=<ref> [APPSET=<name>]" >&2; exit 1; }
	scripts/promote $(CLUSTER) $(REF) $(if $(APPSET),--appset $(APPSET))

test:
	tests/run.sh
