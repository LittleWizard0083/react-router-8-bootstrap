#!/usr/bin/env bash
# ==============================================================================
# install-deps.sh — Install ALL dependencies for React Router 7 project
#
# Run this in your project root (where package.json is)
# ==============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

ok() { echo -e "  ${GREEN}✔${RESET}  $1"; }
log() { echo -e "  ${CYAN}◼${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}▲${RESET}  $1"; }
err() { echo -e "  ${RED}✖${RESET}  $1" >&2; }

# Scaffold a React Router 7 project if there isn't one here yet.
# create-react-router won't write into a non-empty directory, so it scaffolds
# into a temp dir and the result is moved up alongside this script.
if [[ ! -f package.json ]]; then
    warn "No package.json found — scaffolding a new React Router 7 project"

    scaffold_dir="$(mktemp -d "${TMPDIR:-/tmp}/rr7-scaffold.XXXXXX")"
    trap 'rm -rf "$scaffold_dir"' EXIT

    npx --yes create-react-router@latest "$scaffold_dir/app" \
        --yes \
        --no-install \
        --no-git-init

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

    ok "React Router 7 project scaffolded"
fi

echo ""
echo "📦 Installing dependencies for React Router 7"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# A package counts as installed only if package.json declares it *and* it's
# actually unpacked in node_modules — a declared-but-missing dep still needs
# npm to fetch it.
declared_deps="$(node -p '
    const pkg = require("./package.json");
    Object.keys({ ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) }).join("\n");
')"

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

is_installed() {
    local name="$1"
    grep -qxF "$name" <<<"$declared_deps" && [[ -d "node_modules/$name" ]]
}

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
# PRODUCTION DEPENDENCIES
# ==============================================================================
log "Checking production dependencies..."

# react, react-dom, react-router, @react-router/node and @react-router/serve
# come from the template, pinned as an exact-version set. Reinstalling them
# re-resolves to latest and breaks that set, so only add what's missing here.
#
# @react-router/fs-routes must match the pinned @react-router/dev exactly —
# it declares a `^<same-minor>` peer on it.
rr_version="$(node -p "require('./package.json').devDependencies['@react-router/dev']")"

prod_deps=(
    "@react-router/fs-routes@${rr_version}"
    better-auth
    @prisma/client
    @prisma/adapter-pg
    dotenv
    pg
    three
    motion
    zod
    lexical
    @lexical/react
    resend
    stripe
    dompurify
    jsdom
    react-hook-form
    @hookform/resolvers
)

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
dev_deps=(
    prisma
    tsx
    @types/pg
    @types/three
)

mapfile -t dev_missing < <(missing_specs "${dev_deps[@]}")

if [[ ${#dev_missing[@]} -eq 0 ]]; then
    ok "All development dependencies already installed"
else
    log "Installing ${#dev_missing[@]} development package(s)..."
    npm install --save-dev "${dev_missing[@]}"
    ok "Development dependencies installed"
fi

# ==============================================================================
# TAILWIND + DAISYUI
# ==============================================================================
# daisyUI is a build-time Tailwind plugin, so it belongs in devDependencies.
# Handled outside dev_deps because it needs the explicit @latest, and because an
# older copy may still be sitting in "dependencies" from a previous run.
log "Checking daisyUI..."

daisy_is_dev="$(node -p "!!(require('./package.json').devDependencies || {}).daisyui")"

if [[ "$daisy_is_dev" == "true" && -d node_modules/daisyui ]]; then
    ok "daisyui already installed (dev dependency)"
else
    log "Installing daisyui@latest as a dev dependency..."
    npm i -D daisyui@latest
    ok "daisyui installed"
fi

# The daisyUI "remix" theme. Left alone once it's in place, so later tweaks to
# app.css survive a re-run.
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
# GLOBAL TOOLS (optional)
# ==============================================================================
log "Checking global tools..."

if ! command -v stripe >/dev/null 2>&1; then
    warn "Stripe CLI not installed. Installing globally..."
    npm install -g @stripe/cli || warn "Couldn't install Stripe CLI globally"
else
    ok "Stripe CLI already installed"
fi

# ==============================================================================
# ENVIRONMENT FILE
# ==============================================================================
# Runs before Prisma and Better Auth: both read DATABASE_URL / BETTER_AUTH_SECRET
# from .env, so the file has to exist first.
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

if [[ ! -f .env ]]; then
    log "Creating .env file..."

    auth_secret="$(gen_secret)"

    cat > .env <<EOF
# Database
DATABASE_URL="postgresql://localhost:5432/mydb"

# Auth. The URL must match where the app is actually served — it's the origin
# baked into magic links. Vite dev serves on 5173.
BETTER_AUTH_SECRET="${auth_secret}"
BETTER_AUTH_URL="http://localhost:5173"

# Email (magic-link delivery). Without RESEND_API_KEY the link is logged
# to the server console instead of being emailed.
RESEND_API_KEY=""
EMAIL_FROM="onboarding@resend.dev"

# Payments
STRIPE_SECRET_KEY=""

# Shadow Database (for Prisma)
SHADOW_DATABASE_URL=""
EOF
    ok ".env created"
else
    ok ".env already exists"
    ensure_env_var BETTER_AUTH_SECRET "$(gen_secret)"
    ensure_env_var BETTER_AUTH_URL "http://localhost:5173"
    ensure_env_var EMAIL_FROM "onboarding@resend.dev"
fi

# ==============================================================================
# PRISMA SETUP
# ==============================================================================
log "Setting up Prisma..."

if [[ ! -f prisma/schema.prisma ]]; then
    log "Initializing Prisma..."
    npx prisma init --output ../app/generated/prisma
    ok "Prisma initialized"
else
    ok "Prisma already initialized"
fi

# ==============================================================================
# BETTER AUTH SETUP
# ==============================================================================
log "Setting up Better Auth..."

mkdir -p app/lib app/routes

# The auth instance. Named .server.ts so React Router never bundles it into the
# client. Prisma 7 requires a driver adapter, hence PrismaPg.
if [[ ! -f app/lib/auth.server.ts ]]; then
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
    ok "app/lib/auth.server.ts created"
else
    ok "app/lib/auth.server.ts already exists"
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
if [[ ! -f 'app/routes/api.auth.$.ts' ]]; then
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
    ok "app/routes/api.auth.\$.ts already exists"
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

# ==============================================================================
# GENERATE PRISMA CLIENT
# ==============================================================================
if grep -q "DATABASE_URL=" .env 2>/dev/null; then
    log "Generating Prisma client..."
    npx prisma generate
    ok "Prisma client generated"
else
    warn "DATABASE_URL not set in .env. Skipping prisma generate"
    warn "Set DATABASE_URL and run: npx prisma generate"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ All dependencies installed!${RESET}"
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
echo "  1. Edit .env with your DATABASE_URL and API keys"
echo "  2. Run: npx prisma migrate dev --name init   # creates the Better Auth tables"
echo "  3. Run: npm run dev"
echo ""
echo "  Better Auth:"
echo "    server:  app/lib/auth.server.ts"
echo "    client:  app/lib/auth-client.ts"
echo "    handler: app/routes/api.auth.\$.ts  ->  /api/auth/*"
echo ""
