#!/usr/bin/env bash
# BEGIN-USAGE
# install-packages.sh — Install dependencies for a React Router project
#
# Two choices are made up front, then everything else follows from them.
#
# 1. TEMPLATE (pick one)
#      node        Node custom server (Express)
#                  npx create-react-router@latest \
#                    --template remix-run/react-router-templates/node-custom-server
#      cloudflare  Cloudflare Workers
#                  npm create cloudflare@latest -- <dir> --framework=react-router
#                  https://developers.cloudflare.com/workers/framework-guides/web-apps/react-router/
#
# 2. FEATURES (pick any number)
#      database  auth  email  payments  forms  editor  animation  three
#    Deselecting a feature skips its setup AND uninstalls its packages if a
#    previous run put them in package.json. `auth` requires `database`;
#    `database` on its own is fine.
#
#    Tailwind + daisyUI (the 'remix' dark theme) are NOT a feature — they are
#    installed on every run, including --minimal.
#
# Run this in your project root (where package.json is, or will be).
#
# Usage:
#   ./install-packages.sh                        # prompts for template + features
#   ./install-packages.sh --template=node
#   ./install-packages.sh --template=cloudflare --with=database,auth,forms
#   ./install-packages.sh --template=node --no-three --no-payments
#   ./install-packages.sh --template=node --minimal   # no optional features
#   ./install-packages.sh --template=node --all -y    # everything, no prompts
#   TEMPLATE=cloudflare FEATURES=database,auth ./install-packages.sh
# END-USAGE

set -euo pipefail

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok() { echo -e "  ${GREEN}✔${RESET}  $1"; }
log() { echo -e "  ${CYAN}◼${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}▲${RESET}  $1"; }
err() { echo -e "  ${RED}✖${RESET}  $1" >&2; }

usage() {
    awk '/^# BEGIN-USAGE/{f=1;next} /^# END-USAGE/{exit} f{sub(/^# ?/,"");print}' "$0"
}

# ==============================================================================
# FEATURE REGISTRY
# ==============================================================================
# Each feature owns a set of packages and a set of setup steps. Turning one off
# removes both — the packages are uninstalled, the setup is skipped.
FEATURE_KEYS=(database auth email payments forms editor animation three)

declare -A FEATURE_LABEL=(
    [database]="Database"
    [auth]="Authentication"
    [email]="Email"
    [payments]="Payments"
    [forms]="Forms + validation"
    [editor]="Rich text editor"
    [animation]="Animation"
    [three]="3D / WebGL"
)

declare -A FEATURE_DESC=(
    [database]="Prisma + PostgreSQL via the driver adapter"
    [auth]="Better Auth — requires Database"
    [email]="Resend (transactional email, magic links)"
    [payments]="Stripe server SDK + Stripe CLI"
    [forms]="Zod + React Hook Form"
    [editor]="Lexical + DOMPurify sanitizing"
    [animation]="Motion (formerly Framer Motion)"
    [three]="Three.js"
)

declare -A FEATURE_PROD=(
    [database]="@prisma/client @prisma/adapter-pg pg"
    [auth]="better-auth"
    [email]="resend"
    [payments]="stripe"
    [forms]="zod react-hook-form @hookform/resolvers"
    [editor]="lexical @lexical/react dompurify jsdom"
    [animation]="motion"
    [three]="three"
)

declare -A FEATURE_DEV=(
    [database]="prisma @types/pg"
    [auth]=""
    [email]=""
    [payments]=""
    [forms]=""
    [editor]=""
    [animation]=""
    [three]="@types/three"
)

# "auth needs database" is the only hard edge. Kept as data so the interactive
# picker and the flag parser enforce it the same way.
declare -A FEATURE_REQUIRES=(
    [auth]="database"
)

declare -A FEATURE_ENABLED=()
for _k in "${FEATURE_KEYS[@]}"; do FEATURE_ENABLED["$_k"]=1; done

is_feature() { [[ -n "${FEATURE_ENABLED[$1]:-}" ]]; }
enabled() { [[ "${FEATURE_ENABLED[$1]}" == "1" ]]; }

set_all_features() {
    local value="$1" key
    for key in "${FEATURE_KEYS[@]}"; do FEATURE_ENABLED["$key"]="$value"; done
}

# Pulls in whatever an enabled feature requires. Runs after every change so the
# state is never briefly invalid.
apply_feature_requires() {
    local quiet="${1:-}" key req
    for key in "${FEATURE_KEYS[@]}"; do
        enabled "$key" || continue
        for req in ${FEATURE_REQUIRES[$key]:-}; do
            if ! enabled "$req"; then
                FEATURE_ENABLED["$req"]=1
                [[ "$quiet" == "quiet" ]] || warn "${FEATURE_LABEL[$key]} needs ${FEATURE_LABEL[$req]} — enabling it"
            fi
        done
    done
}

# The reverse edge: switching a requirement off switches off whatever needed it.
disable_feature_dependents() {
    local target="$1" key req
    for key in "${FEATURE_KEYS[@]}"; do
        enabled "$key" || continue
        for req in ${FEATURE_REQUIRES[$key]:-}; do
            if [[ "$req" == "$target" ]]; then
                FEATURE_ENABLED["$key"]=0
                warn "${FEATURE_LABEL[$key]} can't work without ${FEATURE_LABEL[$target]} — turning it off too"
            fi
        done
    done
}

enabled_feature_list() {
    local key out=()
    for key in "${FEATURE_KEYS[@]}"; do enabled "$key" && out+=("$key"); done
    ((${#out[@]})) && printf '%s' "${out[*]}" || printf '(none)'
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
TEMPLATE="${TEMPLATE:-}"
ASSUME_YES=0
FEATURES_SET=0

apply_feature_csv() {
    local value="$1" mode="$2" item   # mode: only | on | off
    [[ "$mode" == "only" ]] && set_all_features 0
    for item in ${value//,/ }; do
        if ! is_feature "$item"; then
            err "Unknown feature '${item}'. Known: ${FEATURE_KEYS[*]}"
            exit 1
        fi
        case "$mode" in
            only|on) FEATURE_ENABLED["$item"]=1 ;;
            off)     FEATURE_ENABLED["$item"]=0; disable_feature_dependents "$item" ;;
        esac
    done
    FEATURES_SET=1
}

[[ -n "${FEATURES:-}" ]] && apply_feature_csv "$FEATURES" only

for arg in "$@"; do
    case "$arg" in
        --template=*)   TEMPLATE="${arg#*=}" ;;
        --node)         TEMPLATE="node" ;;
        --cloudflare)   TEMPLATE="cloudflare" ;;
        --with=*)       apply_feature_csv "${arg#*=}" only ;;
        --without=*)    apply_feature_csv "${arg#*=}" off ;;
        --all)          set_all_features 1; FEATURES_SET=1 ;;
        --minimal)      set_all_features 0; FEATURES_SET=1 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      usage; exit 0 ;;
        --with-*)       apply_feature_csv "${arg#--with-}" on ;;
        --no-*)         apply_feature_csv "${arg#--no-}" off ;;
        *)              err "Unknown argument: $arg"; usage; exit 1 ;;
    esac
done

apply_feature_requires quiet

# ==============================================================================
# TEMPLATE SELECTION
# ==============================================================================
# An existing project already answered the question — re-runs must not be able
# to pick the other template and half-convert the tree.
detect_template() {
    if [[ -f wrangler.jsonc || -f wrangler.json || -f wrangler.toml ]]; then
        echo "cloudflare"
    elif [[ -f server.js ]]; then
        echo "node"
    fi
}

existing_template="$(detect_template)"

if [[ -n "$existing_template" ]]; then
    if [[ -n "$TEMPLATE" && "$TEMPLATE" != "$existing_template" ]]; then
        err "This directory is already a '${existing_template}' project, but --template=${TEMPLATE} was requested."
        err "Refusing to mix templates. Run in a clean directory, or pass --template=${existing_template}."
        exit 1
    fi
    TEMPLATE="$existing_template"
    ok "Detected existing template: ${BOLD}${TEMPLATE}${RESET}"
fi

if [[ -z "$TEMPLATE" ]]; then
    if [[ -t 0 ]]; then
        echo ""
        echo -e "${BOLD}1. Which template do you want?${RESET}"
        echo ""
        echo -e "  ${CYAN}1)${RESET} ${BOLD}Node custom server${RESET}  ${DIM}(Express, runs anywhere Node runs)${RESET}"
        echo -e "     ${DIM}npx create-react-router@latest --template remix-run/react-router-templates/node-custom-server${RESET}"
        echo ""
        echo -e "  ${CYAN}2)${RESET} ${BOLD}Cloudflare Workers${RESET}  ${DIM}(edge runtime, bindings via context.cloudflare.env)${RESET}"
        echo -e "     ${DIM}npm create cloudflare@latest -- <dir> --framework=react-router${RESET}"
        echo ""
        while [[ -z "$TEMPLATE" ]]; do
            read -r -p "  Choose [1/2]: " choice
            case "$choice" in
                1|node|Node)             TEMPLATE="node" ;;
                2|cf|cloudflare|Workers) TEMPLATE="cloudflare" ;;
                *) warn "Enter 1 or 2." ;;
            esac
        done
        echo ""
    else
        err "No template selected and stdin isn't a TTY."
        err "Pass --template=node or --template=cloudflare (or set TEMPLATE=...)."
        exit 1
    fi
fi

case "$TEMPLATE" in
    node|cloudflare) ;;
    *) err "Unknown template '${TEMPLATE}'. Expected 'node' or 'cloudflare'."; exit 1 ;;
esac

# Dev server ports differ, and BETTER_AUTH_URL is the origin baked into magic
# links — it has to match wherever the app is actually served.
if [[ "$TEMPLATE" == "node" ]]; then
    TEMPLATE_LABEL="Node custom server"
    DEV_URL="http://localhost:3000"   # server.js PORT default
else
    TEMPLATE_LABEL="Cloudflare Workers"
    DEV_URL="http://localhost:5173"   # vite dev via @cloudflare/vite-plugin
fi

ok "Template: ${BOLD}${TEMPLATE_LABEL}${RESET}"

# ==============================================================================
# FEATURE SELECTION
# ==============================================================================
render_feature_menu() {
    local i=1 key mark
    echo ""
    echo -e "${BOLD}2. Which features do you need?${RESET}"
    echo -e "  ${DIM}Type numbers to toggle (e.g. \"2 7 8\"), 'a' = all, 'n' = none, Enter = done${RESET}"
    echo ""
    for key in "${FEATURE_KEYS[@]}"; do
        if enabled "$key"; then mark="${GREEN}[x]${RESET}"; else mark="${DIM}[ ]${RESET}"; fi
        printf "  %b %2d) %-19s %b%s%b\n" "$mark" "$i" "${FEATURE_LABEL[$key]}" "$DIM" "${FEATURE_DESC[$key]}" "$RESET"
        i=$((i + 1))
    done
    echo ""
}

toggle_feature() {
    local key="$1"
    if enabled "$key"; then
        FEATURE_ENABLED["$key"]=0
        disable_feature_dependents "$key"
    else
        FEATURE_ENABLED["$key"]=1
        apply_feature_requires
    fi
}

if [[ "$FEATURES_SET" == "0" && "$ASSUME_YES" == "0" ]]; then
    if [[ -t 0 ]]; then
        while true; do
            render_feature_menu
            read -r -p "  > " line || line=""
            [[ -z "$line" ]] && break
            case "$line" in
                a|all)  set_all_features 1; continue ;;
                n|none) set_all_features 0; continue ;;
                q|done) break ;;
            esac
            for token in $line; do
                if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#FEATURE_KEYS[@]} )); then
                    toggle_feature "${FEATURE_KEYS[$((token - 1))]}"
                elif is_feature "$token"; then
                    toggle_feature "$token"
                else
                    warn "Ignoring '${token}' — expected 1-${#FEATURE_KEYS[@]}, a, n or a feature name"
                fi
            done
        done
        echo ""
    else
        warn "Non-interactive shell and no feature flags — defaulting to all features"
        warn "Pass --with=…, --no-…, --minimal or --all to choose."
    fi
fi

apply_feature_requires
ok "Features: ${BOLD}$(enabled_feature_list)${RESET}"

# ==============================================================================
# SCAFFOLD
# ==============================================================================
# Neither scaffolder will write into a non-empty directory, so both scaffold
# into a temp dir and the result is moved up alongside this script.
if [[ ! -f package.json ]]; then
    warn "No package.json found — scaffolding a new ${TEMPLATE_LABEL} project"

    scaffold_dir="$(mktemp -d "${TMPDIR:-/tmp}/rr-scaffold.XXXXXX")"
    trap 'rm -rf "$scaffold_dir"' EXIT

    if [[ "$TEMPLATE" == "node" ]]; then
        npx --yes create-react-router@latest "$scaffold_dir/app" \
            --template remix-run/react-router-templates/node-custom-server \
            --yes \
            --no-install \
            --no-git-init
    else
        # C3 installs dependencies itself; --no-deploy keeps it from pushing to
        # your Cloudflare account on first run.
        npm create cloudflare@latest -- "$scaffold_dir/app" \
            --framework=react-router \
            --no-deploy \
            --no-git \
            -y
    fi

    shopt -s dotglob nullglob
    for entry in "$scaffold_dir/app/"*; do
        name="$(basename "$entry")"
        if [[ -e "$name" ]]; then
            warn "Keeping existing $name (not overwritten by template)"
            continue
        fi
        mv "$entry" .
    done
    shopt -u dotglob nullglob

    rm -rf "$scaffold_dir"
    trap - EXIT

    if [[ ! -f package.json ]]; then
        err "Scaffolding failed — no package.json was created"
        exit 1
    fi

    # The template names the package after its directory, which was the temp dir.
    node -e '
        const fs = require("fs");
        const path = require("path");
        const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
        pkg.name = path.basename(process.cwd());
        fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
    '

    ok "${TEMPLATE_LABEL} project scaffolded"
fi

# create-react-router ran with --no-install, so the template's own dependencies
# aren't on disk yet. Install them before anything reads node_modules.
if [[ ! -d node_modules ]]; then
    log "Installing template dependencies..."
    npm install
    ok "Template dependencies installed"
fi

# ==============================================================================
# CUSTOM SERVER (node template only)
# ==============================================================================
# The stock template's server.js is replaced with the version from
# https://github.com/LittleWizard0083/epic_html/blob/master/server.js
if [[ "$TEMPLATE" == "node" ]]; then
    log "Checking server.js..."

    if grep -q 'startServer' server.js 2>/dev/null; then
        ok "server.js already updated"
    else
        if [[ -f server.js ]]; then
            cp server.js server.js.bak
            warn "Existing server.js backed up to server.js.bak"
        fi

        cat > server.js <<'EOF'
/**
 * Express entry point for the React Router "node-custom-server" template.
 *
 * ── UPDATE ───────────────────────────────────────────────────────────────────
 * This file is an update of the stock template server.js, taken from:
 *   https://github.com/LittleWizard0083/epic_html/blob/master/server.js
 *
 * What it changes versus upstream
 * (remix-run/react-router-templates/node-custom-server/server.js):
 *
 *   1. The bootstrap lives in an async `startServer()` function instead of
 *      relying on top-level `await`. Top-level await forces the whole module
 *      into the async-graph, which makes stack traces from a failed dev-server
 *      or a bad build import much harder to read.
 *   2. `startServer()` has a `.catch()`, so a failure during startup prints
 *      "Failed to start the server: <error>" and exits cleanly instead of
 *      surfacing as an unhandled promise rejection.
 *
 * Everything else — compression, the Vite middleware-mode dev server, the
 * immutable /assets cache headers, morgan logging and the built-output import
 * — is unchanged from upstream.
 * ─────────────────────────────────────────────────────────────────────────────
 */

import compression from "compression";
import express from "express";
import morgan from "morgan";

// Short-circuit the type-checking of the built output.
const BUILD_PATH = "./build/server/index.js";
const DEVELOPMENT = process.env.NODE_ENV === "development";
const PORT = Number.parseInt(process.env.PORT || "3000");

const app = express();

app.use(compression());
app.disable("x-powered-by");

async function startServer() {
  if (DEVELOPMENT) {
    console.log("Starting development server");
    const viteDevServer = await import("vite").then((vite) =>
      vite.createServer({
        server: { middlewareMode: true },
      }),
    );
    app.use(viteDevServer.middlewares);
    app.use(async (req, res, next) => {
      try {
        const source = await viteDevServer.ssrLoadModule("./server/app.ts");
        return await source.app(req, res, next);
      } catch (error) {
        if (typeof error === "object" && error instanceof Error) {
          viteDevServer.ssrFixStacktrace(error);
        }
        next(error);
      }
    });
  } else {
    console.log("Starting production server");
    app.use(
      "/assets",
      express.static("build/client/assets", { immutable: true, maxAge: "1y" }),
    );
    app.use(morgan("tiny"));
    app.use(express.static("build/client", { maxAge: "1h" }));
    app.use(await import(BUILD_PATH).then((mod) => mod.app));
  }

  app.listen(PORT, () => {
    console.log(`Server is running on http://localhost:${PORT}`);
  });
}

startServer().catch((error) => {
  console.error("Failed to start the server:", error);
});
EOF
        ok "server.js written (update from LittleWizard0083/epic_html)"
    fi
fi

echo ""
echo "📦 Dependencies — ${TEMPLATE_LABEL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read_declared_deps() {
    declared_deps="$(node -p '
        const pkg = require("./package.json");
        Object.keys({ ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) }).join("\n");
    ')"
}

# A package counts as installed only if package.json declares it *and* it's
# actually unpacked in node_modules — a declared-but-missing dep still needs
# npm to fetch it.
read_declared_deps

# Strips a version suffix from a spec: pkg@1.2.3 -> pkg, @scope/pkg@1.2.3 -> @scope/pkg
spec_name() {
    local spec="$1"
    local prefix=""
    if [[ "$spec" == @* ]]; then
        prefix="@"
        spec="${spec:1}"
    fi
    printf '%s%s\n' "$prefix" "${spec%%@*}"
}

is_declared() { grep -qxF "$1" <<<"$declared_deps"; }
is_installed() { is_declared "$1" && [[ -d "node_modules/$1" ]]; }

# Prints the specs from "$@" that still need installing, one per line on stdout.
# Skip notices go to stderr so callers can capture stdout as a clean list.
missing_specs() {
    local spec name
    for spec in "$@"; do
        name="$(spec_name "$spec")"
        if is_installed "$name"; then
            ok "${name} already installed — skipping" >&2
        else
            printf '%s\n' "$spec"
        fi
    done
}

# ==============================================================================
# REMOVE PACKAGES FOR DISABLED FEATURES
# ==============================================================================
# A feature that was on during an earlier run leaves its packages behind. Turning
# it off has to take them with it, otherwise "no database" still ships Prisma.
log "Checking for packages from disabled features..."

remove_pkgs=()
for key in "${FEATURE_KEYS[@]}"; do
    enabled "$key" && continue
    for pkg in ${FEATURE_PROD[$key]} ${FEATURE_DEV[$key]}; do
        is_declared "$pkg" && remove_pkgs+=("$pkg")
    done
done

if [[ ${#remove_pkgs[@]} -eq 0 ]]; then
    ok "Nothing to remove"
else
    warn "Removing ${#remove_pkgs[@]} package(s) from disabled features:"
    printf '        %s\n' "${remove_pkgs[@]}"
    npm uninstall "${remove_pkgs[@]}"
    read_declared_deps
    ok "Removed"
fi

# Source files a disabled feature generated on an earlier run. Reported, never
# deleted — they may contain your edits, and only you know if they're dead.
orphans=()
enabled auth || for f in app/lib/auth.server.ts app/lib/auth-client.ts 'app/routes/api.auth.$.ts'; do
    [[ -e "$f" ]] && orphans+=("$f")
done
enabled database || for f in prisma app/generated/prisma; do
    [[ -e "$f" ]] && orphans+=("$f")
done

if [[ ${#orphans[@]} -gt 0 ]]; then
    warn "These files belong to disabled features and were left in place:"
    printf '        %s\n' "${orphans[@]}"
    warn "Delete them by hand once you're sure (and drop the auth route from app/routes.ts)."
fi

# ==============================================================================
# PRODUCTION DEPENDENCIES
# ==============================================================================
log "Checking production dependencies..."

# react, react-dom, react-router and the runtime adapter (@react-router/express
# on node, the Cloudflare vite plugin on Workers) come from the template, pinned
# as an exact-version set. Reinstalling them re-resolves to latest and breaks
# that set, so only add what's missing here.
#
# @react-router/fs-routes must match the pinned @react-router/dev exactly —
# it declares a `^<same-minor>` peer on it.
rr_version="$(node -p "require('./package.json').devDependencies['@react-router/dev']")"

# Base set: always installed, whatever the feature selection.
prod_deps=("@react-router/fs-routes@${rr_version}")

# dotenv only earns its place on Node — a Worker reads bindings, not .env.
[[ "$TEMPLATE" == "node" ]] && prod_deps+=(dotenv)

for key in "${FEATURE_KEYS[@]}"; do
    enabled "$key" || continue
    for pkg in ${FEATURE_PROD[$key]}; do prod_deps+=("$pkg"); done
done

if [[ "$TEMPLATE" == "cloudflare" ]] && enabled editor; then
    warn "jsdom is a Node-only package — it will not run inside a Worker."
    warn "Sanitize Lexical HTML at write time (Node/CI) or use a Workers-safe sanitizer."
fi

mapfile -t prod_missing < <(missing_specs "${prod_deps[@]}")

if [[ ${#prod_missing[@]} -eq 0 ]]; then
    ok "All production dependencies already installed"
else
    log "Installing ${#prod_missing[@]} production package(s)..."
    npm install "${prod_missing[@]}"
    ok "Production dependencies installed"
fi

# ==============================================================================
# DEVELOPMENT DEPENDENCIES
# ==============================================================================
log "Checking development dependencies..."

# typescript, vite and the React/Node type packages come from the template.
# dompurify ships its own types, so @types/dompurify is a deprecated stub.
dev_deps=(tsx)

# wrangler comes with the C3 template, but a project scaffolded some other way
# still needs it for `wrangler types` / `wrangler deploy`.
[[ "$TEMPLATE" == "cloudflare" ]] && dev_deps+=(wrangler)

for key in "${FEATURE_KEYS[@]}"; do
    enabled "$key" || continue
    for pkg in ${FEATURE_DEV[$key]}; do dev_deps+=("$pkg"); done
done

mapfile -t dev_missing < <(missing_specs "${dev_deps[@]}")

if [[ ${#dev_missing[@]} -eq 0 ]]; then
    ok "All development dependencies already installed"
else
    log "Installing ${#dev_missing[@]} development package(s)..."
    npm install --save-dev "${dev_missing[@]}"
    ok "Development dependencies installed"
fi

# ==============================================================================
# TAILWIND + DAISYUI  (always — not a feature)
# ==============================================================================
# Part of the base set: every project gets the theme, including --minimal. It is
# a build-time Tailwind plugin, so it belongs in devDependencies. Handled outside
# dev_deps because it needs the explicit @latest, and because an older copy may
# still be sitting in "dependencies" from a previous run.
log "Checking daisyUI..."

daisy_is_dev="$(node -p "!!(require('./package.json').devDependencies || {}).daisyui")"

if [[ "$daisy_is_dev" == "true" && -d node_modules/daisyui ]]; then
    ok "daisyui already installed (dev dependency)"
else
    log "Installing daisyui@latest as a dev dependency..."
    npm i -D daisyui@latest
    ok "daisyui installed"
fi

# The daisyUI "remix" theme. Left alone once it's in place, so later tweaks
# to app.css survive a re-run.
if grep -q '@plugin "daisyui"' app/app.css 2>/dev/null; then
    ok "app/app.css already configured for daisyUI"
else
    log "Writing daisyUI theme into app/app.css..."
    mkdir -p app
    cat > app/app.css <<'EOF'
@import "tailwindcss" source(".");
@plugin "daisyui" {
  themes: remix --default;
}
@plugin "daisyui/theme" {
  name: "remix";
  color-scheme: dark;

  --color-base-100: #1a1a1a;   /* card bg  */
  --color-base-200: #121212;   /* page/hero bg (gray-900) */
  --color-base-300: #383838;   /* borders  (gray-800) */
  --color-base-content: #e3e3e3;

  --color-primary: #3992ff;    /* Remix blue */
  --color-primary-content: #ffffff;
  --color-neutral: #3992ff;    /* so `btn-neutral` in your markup is blue */
  --color-neutral-content: #ffffff;

  --radius-box: 1rem;          /* card */
  --radius-field: 0.5rem;      /* input + button (rounded-lg) */
  --radius-selector: 0.5rem;
}

@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif,
    "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";
}

html, body { @apply bg-base-200; color-scheme: dark; }
EOF
    ok "app/app.css written (daisyUI 'remix' theme)"
fi

# ==============================================================================
# GLOBAL TOOLS  (feature: payments)
# ==============================================================================
if enabled payments; then
    log "Checking global tools..."

    if ! command -v stripe >/dev/null 2>&1; then
        warn "Stripe CLI not installed. Installing globally..."
        npm install -g @stripe/cli || warn "Couldn't install Stripe CLI globally"
    else
        ok "Stripe CLI already installed"
    fi
fi

# ==============================================================================
# ENVIRONMENT FILE
# ==============================================================================
# Runs before Prisma and Better Auth: both read DATABASE_URL / BETTER_AUTH_SECRET
# from .env, so the file has to exist first. Only the selected features get a
# block — no dead keys for things this project doesn't use.
gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32
    else
        node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
    fi
}

ensure_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        ok "${key} already set"
    else
        printf '%s="%s"\n' "$key" "$value" >> .env
        ok "${key} added to .env"
    fi
}

build_env_template() {
    if enabled database; then
        printf '# Database\n'
        printf 'DATABASE_URL="postgresql://localhost:5432/mydb"\n'
        printf '\n# Shadow database (for Prisma migrations against a hosted DB)\n'
        printf 'SHADOW_DATABASE_URL=""\n\n'
    fi
    if enabled auth; then
        printf '# Auth. The URL must match where the app is actually served — it is the\n'
        printf '# origin baked into magic links. %s dev serves on %s.\n' "$TEMPLATE_LABEL" "$DEV_URL"
        printf 'BETTER_AUTH_SECRET="%s"\n' "$(gen_secret)"
        printf 'BETTER_AUTH_URL="%s"\n\n' "$DEV_URL"
    fi
    if enabled email; then
        printf '# Email. Without RESEND_API_KEY a magic link is logged to the server\n'
        printf '# console instead of being emailed.\n'
        printf 'RESEND_API_KEY=""\n'
        printf 'EMAIL_FROM="onboarding@resend.dev"\n\n'
    fi
    if enabled payments; then
        printf '# Payments\n'
        printf 'STRIPE_SECRET_KEY=""\n'
        printf 'STRIPE_WEBHOOK_SECRET=""\n\n'
    fi
}

env_body="$(build_env_template)"

if [[ -z "$env_body" ]]; then
    log "No feature needs environment variables — skipping .env"
elif [[ ! -f .env ]]; then
    log "Creating .env file..."
    printf '%s' "$env_body" > .env
    ok ".env created"
else
    ok ".env already exists"
    enabled database && ensure_env_var DATABASE_URL "postgresql://localhost:5432/mydb"
    if enabled auth; then
        ensure_env_var BETTER_AUTH_SECRET "$(gen_secret)"
        ensure_env_var BETTER_AUTH_URL "${DEV_URL}"
    fi
    enabled email && ensure_env_var EMAIL_FROM "onboarding@resend.dev"
    enabled payments && ensure_env_var STRIPE_SECRET_KEY ""
fi

# Workers don't read .env at runtime — `wrangler dev` reads .dev.vars, and
# production values come from `wrangler secret put`. .env stays for the Prisma
# and Better Auth CLIs, which run in Node.
if [[ "$TEMPLATE" == "cloudflare" && -f .env ]]; then
    if [[ -f .dev.vars ]]; then
        ok ".dev.vars already exists"
    else
        log "Creating .dev.vars (local Worker bindings)..."
        # Comments and blanks stripped; `|| true` because grep exits 1 on no match.
        grep -Ev '^[[:space:]]*(#|$)' .env > .dev.vars || true
        ok ".dev.vars created from .env"
    fi

    if [[ -f .gitignore ]] && ! grep -qxF ".dev.vars" .gitignore; then
        printf '\n.dev.vars\n' >> .gitignore
        ok ".dev.vars added to .gitignore"
    fi
fi

# ==============================================================================
# PRISMA SETUP  (feature: database)
# ==============================================================================
if enabled database; then
    log "Setting up Prisma..."

    if [[ ! -f prisma/schema.prisma ]]; then
        log "Initializing Prisma..."
        npx prisma init --output ../app/generated/prisma
        ok "Prisma initialized"
    else
        ok "Prisma already initialized"
    fi

    # With auth on, the client has to exist before the Better Auth CLI runs: it
    # loads app/lib/auth.server.ts, which imports app/generated/prisma/client.
    # Generating from a model-less schema is fine — the models get added below
    # and the client is regenerated at the end.
    if [[ ! -d app/generated/prisma ]]; then
        log "Generating an initial Prisma client..."
        npx prisma generate
        ok "Initial Prisma client generated"
    fi
else
    log "Skipping Prisma (database feature off)"
fi

# ==============================================================================
# BETTER AUTH SETUP  (feature: auth — implies database)
# ==============================================================================
if enabled auth; then
log "Setting up Better Auth..."

mkdir -p app/lib app/routes

# The auth instance. Named .server.ts so React Router never bundles it into the
# client. Prisma 7 requires a driver adapter, hence PrismaPg.
if [[ -f app/lib/auth.server.ts ]]; then
    ok "app/lib/auth.server.ts already exists"
elif [[ "$TEMPLATE" == "node" ]]; then
    cat > app/lib/auth.server.ts <<'EOF'
import { PrismaPg } from "@prisma/adapter-pg";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";

// Relative, not "~/": the Better Auth CLI loads this file outside Vite, where
// the tsconfig path alias isn't resolved.
import { PrismaClient } from "../generated/prisma/client";

const adapter = new PrismaPg({
  connectionString: process.env.DATABASE_URL,
});

const prisma = new PrismaClient({ adapter });

export const auth = betterAuth({
  database: prismaAdapter(prisma, {
    provider: "postgresql",
  }),
  secret: process.env.BETTER_AUTH_SECRET,
  baseURL: process.env.BETTER_AUTH_URL,
  emailAndPassword: {
    enabled: true,
  },
});
EOF
    ok "app/lib/auth.server.ts created (Node custom server)"
else
    cat > app/lib/auth.server.ts <<'EOF'
import { PrismaPg } from "@prisma/adapter-pg";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";

// Relative, not "~/": the Better Auth CLI loads this file outside Vite, where
// the tsconfig path alias isn't resolved.
import { PrismaClient } from "../generated/prisma/client";

export type AuthEnv = {
  DATABASE_URL: string;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL: string;
};

// One instance per (connection string + base URL), memoized for the life of the
// isolate. A module-level betterAuth({...}) singleton can't work on Workers:
// env only exists per-request, so top-level process.env reads are empty.
const instances = new Map<string, ReturnType<typeof betterAuth>>();

export function buildAuth(env: AuthEnv) {
  const key = `${env.DATABASE_URL}::${env.BETTER_AUTH_URL}`;
  const cached = instances.get(key);
  if (cached) return cached;

  const prisma = new PrismaClient({
    adapter: new PrismaPg({ connectionString: env.DATABASE_URL }),
  });

  const instance = betterAuth({
    database: prismaAdapter(prisma, {
      provider: "postgresql",
    }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    emailAndPassword: {
      enabled: true,
    },
  });

  instances.set(key, instance);
  return instance;
}

// Schema generation only. The Better Auth CLI runs this file in Node and looks
// for an exported `auth`. Route code must call buildAuth(context.cloudflare.env)
// instead — process.env is empty inside a Worker.
export const auth = buildAuth({
  DATABASE_URL: process.env.DATABASE_URL ?? "",
  BETTER_AUTH_SECRET: process.env.BETTER_AUTH_SECRET ?? "",
  BETTER_AUTH_URL: process.env.BETTER_AUTH_URL ?? "http://localhost:5173",
});
EOF
    ok "app/lib/auth.server.ts created (Cloudflare Workers, per-request factory)"
fi

if [[ ! -f app/lib/auth-client.ts ]]; then
    cat > app/lib/auth-client.ts <<'EOF'
import { createAuthClient } from "better-auth/react";

// Same-origin: the auth routes are served by this app, so baseURL is optional.
export const authClient = createAuthClient();

export const { signIn, signUp, signOut, useSession } = authClient;
EOF
    ok "app/lib/auth-client.ts created"
else
    ok "app/lib/auth-client.ts already exists"
fi

# Catch-all handler for /api/auth/*
if [[ -f 'app/routes/api.auth.$.ts' ]]; then
    ok "app/routes/api.auth.\$.ts already exists"
elif [[ "$TEMPLATE" == "node" ]]; then
    cat > 'app/routes/api.auth.$.ts' <<'EOF'
import type { ActionFunctionArgs, LoaderFunctionArgs } from "react-router";

import { auth } from "~/lib/auth.server";

export async function loader({ request }: LoaderFunctionArgs) {
  return auth.handler(request);
}

export async function action({ request }: ActionFunctionArgs) {
  return auth.handler(request);
}
EOF
    ok "app/routes/api.auth.\$.ts created"
else
    cat > 'app/routes/api.auth.$.ts' <<'EOF'
import type { ActionFunctionArgs, LoaderFunctionArgs } from "react-router";

import { buildAuth, type AuthEnv } from "~/lib/auth.server";

// Secrets live in the Worker env (.dev.vars locally, `wrangler secret put` in
// production), never process.env.
function authFor(context: LoaderFunctionArgs["context"]) {
  return buildAuth(context.cloudflare.env as unknown as AuthEnv);
}

export async function loader({ request, context }: LoaderFunctionArgs) {
  return authFor(context).handler(request);
}

export async function action({ request, context }: ActionFunctionArgs) {
  return authFor(context).handler(request);
}
EOF
    ok "app/routes/api.auth.\$.ts created (Workers env bindings)"
fi

# Register the handler in the route config (config-based routing, not fs-routes).
if grep -q "api/auth" app/routes.ts 2>/dev/null; then
    ok "Auth route already registered in app/routes.ts"
else
    log "Registering auth route in app/routes.ts..."
    node -e '
        const fs = require("fs");
        const file = "app/routes.ts";
        let src = fs.readFileSync(file, "utf8");

        src = src.replace(
            /import \{([^}]*)\} from "@react-router\/dev\/routes";/,
            (_match, names) => {
                const list = names.split(",").map((n) => n.trim()).filter(Boolean);
                if (!list.includes("route")) list.push("route");
                return `import { ${list.join(", ")} } from "@react-router/dev/routes";`;
            },
        );

        src = src.replace(
            /\[([\s\S]*?)\] satisfies RouteConfig/,
            (_match, inner) => {
                const entries = inner.trim().replace(/,$/, "");
                const added = `route("api/auth/*", "routes/api.auth.$.ts")`;
                return `[\n  ${entries},\n  ${added},\n] satisfies RouteConfig`;
            },
        );

        fs.writeFileSync(file, src);
    '
    ok "Auth route registered"
fi

# Generate the Better Auth models (user, session, account, verification) into
# prisma/schema.prisma. Skipped once the models are there.
if grep -qE '^model (User|user) ' prisma/schema.prisma 2>/dev/null; then
    ok "Better Auth models already in prisma/schema.prisma"
else
    log "Generating Better Auth schema into prisma/schema.prisma..."
    npx --yes auth@latest generate \
        --config app/lib/auth.server.ts \
        --output prisma/schema.prisma \
        --yes
    ok "Better Auth schema generated"
fi

else
    log "Skipping Better Auth (auth feature off)"
fi

# ==============================================================================
# GENERATE PRISMA CLIENT  (feature: database)
# ==============================================================================
if enabled database; then
    if grep -q "DATABASE_URL=" .env 2>/dev/null; then
        log "Generating Prisma client..."
        npx prisma generate
        ok "Prisma client generated"
    else
        warn "DATABASE_URL not set in .env. Skipping prisma generate"
        warn "Set DATABASE_URL and run: npx prisma generate"
    fi
fi

# ==============================================================================
# WORKER TYPES (cloudflare only)
# ==============================================================================
if [[ "$TEMPLATE" == "cloudflare" ]]; then
    log "Generating Worker binding types..."
    npx wrangler types || warn "wrangler types failed — run it once you've configured wrangler.jsonc"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ Done!${RESET}  ${TEMPLATE_LABEL} · $(enabled_feature_list)"
echo ""
echo "📋 Installed packages:"
echo ""
echo "  Production:"
npm list --depth=0 --prod 2>/dev/null | tail -n +2 || echo "    (see package.json)"
echo ""
echo "  Development:"
npm list --depth=0 --dev 2>/dev/null | tail -n +2 || echo "    (see package.json)"
echo ""
echo "  Next steps:"
step=1
if enabled database; then
    echo "  ${step}. Edit .env with your DATABASE_URL"; step=$((step + 1))
    echo "  ${step}. Run: npx prisma migrate dev --name init"; step=$((step + 1))
fi
if enabled email || enabled payments; then
    echo "  ${step}. Fill in the API keys in .env"; step=$((step + 1))
fi
if [[ "$TEMPLATE" == "node" ]]; then
    echo "  ${step}. Run: npm run dev          # server.js via Vite middleware, ${DEV_URL}"
    echo "     Prod: npm run build && npm start"
else
    echo "  ${step}. Mirror your secrets into .dev.vars (already seeded from .env)"; step=$((step + 1))
    echo "  ${step}. Run: npm run dev          # ${DEV_URL}"
    echo "     Prod: npm run deploy      # wrangler deploy"
    echo "     Secrets: npx wrangler secret put BETTER_AUTH_SECRET   # etc."
fi
echo ""
if enabled auth; then
    echo "  Better Auth:"
    echo "    server:  app/lib/auth.server.ts"
    echo "    client:  app/lib/auth-client.ts"
    echo "    handler: app/routes/api.auth.\$.ts  ->  /api/auth/*"
    echo ""
fi
