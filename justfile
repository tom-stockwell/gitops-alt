set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes.
default:
    @just --list

# Write the cluster overlays (apps/*/clusters/*) from each app's facets.
generate:
    scripts/generate

alias build := generate

# Lint only.
lint:
    scripts/lint

# What CI runs: lint, which also fails if any overlay isn't what generate would write.
alias check := lint

# Acceptance tests.
test:
    tests/run.sh

# Render a cluster overlay: just render apps/<app>/clusters/<cluster> (path tab-completes).
render overlay:
    scripts/render {{overlay}}

# Remove rendered output (rendered/).
clean:
    rm -rf rendered/*

# Render everything into rendered/<cluster>/.
render-all: clean
    scripts/render-all rendered

# Diff rendered manifests against a base ref (default origin/main).
diff *base:
    scripts/diff {{base}}

# Show what runs on each cluster (default: all).
whatruns *clusters:
    scripts/whatruns {{clusters}}

# Scaffold a cluster, generate its overlays and show what will run there:
# just new-cluster <name> <from> [--domain …] [--environment …] [--role …] …
new-cluster name from *flags:
    scripts/new-cluster {{name}} --from {{from}} {{flags}}
    scripts/generate {{name}}
    @echo
    scripts/whatruns {{name}}

# Pin a cluster's ApplicationSet: just promote <cluster> <ref> [--appset <name>]
promote cluster ref *flags:
    scripts/promote {{cluster}} {{ref}} {{flags}}
