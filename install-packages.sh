#!/usr/bin/env bash
# install-packages-cloudflare.sh
# Add-on installer for an EXISTING React Router v8 + Cloudflare Workers project.
#
# Cloudflare template/core packages are NEVER upgraded by this script.
# The project must first be created with Cloudflare's official React Router flow:
#   npm create cloudflare@latest -- my-react-router-app --framework=react-router
#
# Policy:
#   - Keep React / React Router / Vite / Wrangler / Cloudflare Vite plugin exactly
#     as supplied by the template/package-lock.
#   - Install all add-on packages from the original installer.
#   - Standalone add-ons are explicitly upgraded to @latest.
#   - Version-coupled families are installed together at compatible versions:
#       * @react-router/fs-routes == installed @react-router/dev
#       * Prisma CLI/client/adapter share one exact resolved Prisma version
#       * Lexical core/react share one exact resolved Lexical version
#
# Usage:
#   bash ./install-packages-cloudflare.sh
#   bash ./install-packages-cloudflare.sh -y   # skip the single confirmation prompt

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✔${RESET}  $1"; }
log()  { echo -e "  ${CYAN}◼${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}▲${RESET}  $1"; }
err()  { echo -e "  ${RED}✖${RESET}  $1" >&2; }

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Runtime checks
# -----------------------------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
  err "Bash 4+ is required (running ${BASH_VERSION})."
  exit 1
fi

for bin in node npm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "$bin is not available on PATH. Install Node.js/npm first."
    exit 1
  fi
done

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if (( node_major < 20 )); then
  err "Node $(node -v) is too old. Use Node 20 or newer."
  exit 1
fi

if command -v npx >/dev/null 2>&1; then
  NPX() { npx "$@"; }
else
  NPX() {
    local a args=()
    for a in "$@"; do [[ "$a" == "--yes" ]] || args+=("$a"); done
    npm exec --yes -- "${args[@]}"
  }
fi

# -----------------------------------------------------------------------------
# ONE template question — no scaffolding is performed here
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}React Router v8 + Cloudflare add-on installer${RESET}"
echo ""

if (( ASSUME_YES == 0 )); then
  read -r -p "Is the React Router + Cloudflare Workers template already installed in THIS directory? [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES|Yes) ;;
    *)
      echo ""
      warn "This installer intentionally does not create or upgrade the Cloudflare template."
      echo "  Create it first with Cloudflare's current command:"
      echo ""
      echo "    npm create cloudflare@latest -- my-react-router-app --framework=react-router"
      echo ""
      echo "  Then cd into the project and run this script again."
      exit 0
      ;;
  esac
fi

# -----------------------------------------------------------------------------
# Validate the current Cloudflare React Router project
# -----------------------------------------------------------------------------
if [[ ! -f package.json ]]; then
  err "package.json was not found in $(pwd)."
  err "Run this script from the root of your existing Cloudflare React Router project."
  exit 1
fi

if ! node <<'NODE'
const pkg = require('./package.json');
const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
const required = ['react-router', '@react-router/dev', '@cloudflare/vite-plugin', 'wrangler'];
const missing = required.filter((name) => !deps[name]);
if (missing.length) {
  console.error(missing.join('\n'));
  process.exit(1);
}
NODE
then
  err "This package.json does not look like the current React Router + Cloudflare Workers template."
  err "Expected direct dependencies include react-router, @react-router/dev, @cloudflare/vite-plugin and wrangler."
  exit 1
fi

if [[ ! -f vite.config.ts && ! -f vite.config.js ]]; then
  err "vite.config.ts/js is missing."
  exit 1
fi

if [[ ! -f wrangler.jsonc && ! -f wrangler.json && ! -f wrangler.toml ]]; then
  err "No Wrangler configuration was found."
  err "The official template normally includes wrangler.jsonc."
  exit 1
fi

if [[ ! -f workers/app.ts && ! -f workers/app.js ]]; then
  warn "workers/app.ts was not found. Cloudflare's current full-stack template normally uses it."
  warn "Continuing because older/current variants can still be deployable through Wrangler detection."
fi

ok "Existing React Router + Cloudflare Workers project confirmed"

# Hydrate only what the template/package-lock already declares. Do not ask npm to
# upgrade template-owned direct dependencies.
if [[ ! -d node_modules ]]; then
  if [[ -f package-lock.json ]]; then
    log "Installing the existing locked template dependencies with npm ci..."
    npm ci
  else
    log "Installing the existing template dependencies..."
    npm install
  fi
  ok "Template dependencies installed without forcing template upgrades"
else
  ok "node_modules already exists — leaving template package versions alone"
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
latest_version() {
  npm view "$1" version --silent
}

installed_version() {
  node -e "try{process.stdout.write(require('./node_modules/$1/package.json').version||'')}catch(e){}"
}

# -----------------------------------------------------------------------------
# React Router companion package — MUST match the installed template
# -----------------------------------------------------------------------------
RR_VERSION="$(installed_version '@react-router/dev')"
if [[ -z "$RR_VERSION" ]]; then
  err "Could not read the installed @react-router/dev version."
  exit 1
fi

log "Installing @react-router/fs-routes to match @react-router/dev ${RR_VERSION}..."
npm install "@react-router/fs-routes@${RR_VERSION}"
ok "@react-router/fs-routes pinned to ${RR_VERSION}"

# -----------------------------------------------------------------------------
# Prisma family — resolve once, keep CLI/client/adapter synchronized
# -----------------------------------------------------------------------------
log "Resolving the current Prisma release for the synchronized Prisma family..."
PRISMA_VERSION="$(latest_version prisma)"
if [[ -z "$PRISMA_VERSION" ]]; then
  err "Could not resolve the Prisma version from npm."
  exit 1
fi

log "Installing synchronized Prisma ${PRISMA_VERSION} packages..."
npm install \
  "@prisma/client@${PRISMA_VERSION}" \
  "@prisma/adapter-pg@${PRISMA_VERSION}" \
  "pg@latest"
npm install --save-dev \
  "prisma@${PRISMA_VERSION}" \
  "@types/pg@latest"
ok "Prisma family installed at ${PRISMA_VERSION}"

# -----------------------------------------------------------------------------
# Lexical family — keep core and React integration synchronized
# -----------------------------------------------------------------------------
log "Resolving the current Lexical release..."
LEXICAL_VERSION="$(latest_version lexical)"
if [[ -z "$LEXICAL_VERSION" ]]; then
  err "Could not resolve the Lexical version from npm."
  exit 1
fi

log "Installing synchronized Lexical ${LEXICAL_VERSION} packages..."
npm install "lexical@${LEXICAL_VERSION}" "@lexical/react@${LEXICAL_VERSION}"
ok "Lexical family installed at ${LEXICAL_VERSION}"

# -----------------------------------------------------------------------------
# Independent add-ons — explicitly keep these at @latest
# -----------------------------------------------------------------------------
LATEST_PROD=(
  better-auth@latest
  resend@latest
  stripe@latest
  zod@latest
  react-hook-form@latest
  dompurify@latest
  motion@latest
  three@latest
)

LATEST_DEV=(
  tsx@latest
  jsdom@latest
  @types/three@latest
  daisyui@latest
)

log "Installing/upgrading independent production add-ons to @latest..."
npm install "${LATEST_PROD[@]}"
ok "Independent production add-ons are current"

# @hookform/resolvers has historically had optional-peer resolution collisions.
# Try normal npm peer validation first; use the narrow fallback only if needed.
log "Installing/upgrading @hookform/resolvers@latest..."
if npm install @hookform/resolvers@latest; then
  ok "@hookform/resolvers installed with normal peer validation"
else
  warn "Normal peer resolution failed; retrying only this package with --legacy-peer-deps"
  npm install --legacy-peer-deps @hookform/resolvers@latest
  ok "@hookform/resolvers installed with the compatibility fallback"
fi

log "Installing/upgrading independent development add-ons to @latest..."
npm install --save-dev "${LATEST_DEV[@]}"
ok "Independent development add-ons are current"

warn "jsdom is intentionally a dev dependency: it is Node-only and must not be imported into Worker runtime code."

# -----------------------------------------------------------------------------
# daisyUI / Tailwind CSS 4 integration
# Cloudflare's React Router template already includes Tailwind CSS.
# Do not overwrite a user's existing stylesheet.
# -----------------------------------------------------------------------------
if [[ -f app/app.css ]]; then
  if grep -q '@plugin[[:space:]]\+"daisyui"' app/app.css 2>/dev/null; then
    ok "daisyUI is already referenced by app/app.css"
  else
    log "Adding the daisyUI Tailwind plugin to app/app.css..."
    cat >> app/app.css <<'CSS'

/* Added by install-packages-cloudflare.sh */
@plugin "daisyui";
CSS
    ok "daisyUI plugin added without replacing the existing Cloudflare/Tailwind CSS"
  fi
else
  warn "app/app.css was not found; daisyUI is installed but its @plugin line was not added."
fi

# -----------------------------------------------------------------------------
# Environment files for the installed backend packages
# -----------------------------------------------------------------------------
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32
  else
    node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
  fi
}

ensure_env_var() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    ok "${key} already exists in ${file}"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
    ok "${key} added to ${file}"
  fi
}

log "Preparing CLI/local environment variables..."
ensure_env_var .env DATABASE_URL "postgresql://localhost:5432/mydb"
ensure_env_var .env BETTER_AUTH_SECRET "$(gen_secret)"
ensure_env_var .env BETTER_AUTH_URL "http://localhost:5173"
ensure_env_var .env RESEND_API_KEY ""
ensure_env_var .env EMAIL_FROM "onboarding@resend.dev"
ensure_env_var .env STRIPE_SECRET_KEY ""
ensure_env_var .env STRIPE_WEBHOOK_SECRET ""

# Cloudflare local runtime bindings are read from .dev.vars. Keep existing values.
ensure_env_var .dev.vars DATABASE_URL "postgresql://localhost:5432/mydb"
ensure_env_var .dev.vars BETTER_AUTH_SECRET "$(gen_secret)"
ensure_env_var .dev.vars BETTER_AUTH_URL "http://localhost:5173"
ensure_env_var .dev.vars RESEND_API_KEY ""
ensure_env_var .dev.vars EMAIL_FROM "onboarding@resend.dev"
ensure_env_var .dev.vars STRIPE_SECRET_KEY ""
ensure_env_var .dev.vars STRIPE_WEBHOOK_SECRET ""

if [[ -f .gitignore ]] && ! grep -qxF '.dev.vars' .gitignore; then
  printf '\n.dev.vars\n' >> .gitignore
  ok ".dev.vars added to .gitignore"
fi

# -----------------------------------------------------------------------------
# Prisma setup (Prisma 7 + PostgreSQL driver adapter)
# -----------------------------------------------------------------------------
if [[ ! -f prisma/schema.prisma ]]; then
  log "Initializing Prisma for PostgreSQL..."
  NPX prisma init --datasource-provider postgresql --output ../app/generated/prisma
  ok "Prisma initialized"
else
  ok "Prisma is already initialized"
fi

log "Generating Prisma Client..."
NPX prisma generate
ok "Prisma Client generated"

# -----------------------------------------------------------------------------
# Better Auth files for Cloudflare Workers
# context.cloudflare.env follows the Cloudflare React Router integration.
# Existing user files are never overwritten.
# -----------------------------------------------------------------------------
mkdir -p app/lib app/routes

if [[ ! -f app/lib/auth.server.ts ]]; then
  cat > app/lib/auth.server.ts <<'TS'
import { PrismaPg } from "@prisma/adapter-pg";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { PrismaClient } from "../generated/prisma/client";

export type AuthEnv = {
  DATABASE_URL: string;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL: string;
};

const instances = new Map<string, ReturnType<typeof betterAuth>>();

export function buildAuth(env: AuthEnv) {
  const key = `${env.DATABASE_URL}::${env.BETTER_AUTH_URL}`;
  const cached = instances.get(key);
  if (cached) return cached;

  const prisma = new PrismaClient({
    adapter: new PrismaPg({ connectionString: env.DATABASE_URL }),
  });

  const instance = betterAuth({
    database: prismaAdapter(prisma, { provider: "postgresql" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    emailAndPassword: { enabled: true },
  });

  instances.set(key, instance);
  return instance;
}

// Used by the Better Auth CLI, which executes this config in Node.
export const auth = buildAuth({
  DATABASE_URL: process.env.DATABASE_URL ?? "",
  BETTER_AUTH_SECRET: process.env.BETTER_AUTH_SECRET ?? "",
  BETTER_AUTH_URL: process.env.BETTER_AUTH_URL ?? "http://localhost:5173",
});
TS
  ok "app/lib/auth.server.ts created"
else
  ok "app/lib/auth.server.ts already exists — not overwritten"
fi

if [[ ! -f app/lib/auth-client.ts ]]; then
  cat > app/lib/auth-client.ts <<'TS'
import { createAuthClient } from "better-auth/react";

export const authClient = createAuthClient();
export const { signIn, signUp, signOut, useSession } = authClient;
TS
  ok "app/lib/auth-client.ts created"
else
  ok "app/lib/auth-client.ts already exists — not overwritten"
fi

if [[ ! -f 'app/routes/api.auth.$.ts' ]]; then
  cat > 'app/routes/api.auth.$.ts' <<'TS'
import type { ActionFunctionArgs, LoaderFunctionArgs } from "react-router";
import { buildAuth, type AuthEnv } from "~/lib/auth.server";

function authFor(context: LoaderFunctionArgs["context"]) {
  return buildAuth(context.cloudflare.env as unknown as AuthEnv);
}

export async function loader({ request, context }: LoaderFunctionArgs) {
  return authFor(context).handler(request);
}

export async function action({ request, context }: ActionFunctionArgs) {
  return authFor(context).handler(request);
}
TS
  ok "app/routes/api.auth.\$.ts created"
else
  ok "app/routes/api.auth.\$.ts already exists — not overwritten"
fi

# Add route registration only when app/routes.ts has the common template shape.
if [[ -f app/routes.ts ]] && ! grep -q 'api/auth' app/routes.ts; then
  log "Trying to register /api/auth/* in app/routes.ts..."
  if node <<'NODE'
const fs = require('fs');
const file = 'app/routes.ts';
const before = fs.readFileSync(file, 'utf8');
let src = before;
src = src.replace(
  /import \{([^}]*)\} from ["']@react-router\/dev\/routes["'];/,
  (_m, names) => {
    const list = names.split(',').map((x) => x.trim()).filter(Boolean);
    if (!list.includes('route')) list.push('route');
    return `import { ${list.join(', ')} } from "@react-router/dev/routes";`;
  },
);
src = src.replace(
  /\[([\s\S]*?)\] satisfies RouteConfig/,
  (_m, inner) => {
    const body = inner.trim().replace(/,$/, '');
    const prefix = body ? `${body},\n  ` : '';
    return `[\n  ${prefix}route("api/auth/*", "routes/api.auth.$.ts"),\n] satisfies RouteConfig`;
  },
);
if (src === before) process.exit(3);
fs.writeFileSync(file, src);
NODE
  then
    ok "Auth route registered"
  else
    warn "Could not safely edit app/routes.ts. Add this route manually:"
    warn '  route("api/auth/*", "routes/api.auth.$.ts")'
  fi
fi

# Better Auth currently documents npx auth@latest generate.
if grep -qE '^model (User|user) ' prisma/schema.prisma 2>/dev/null; then
  ok "Better Auth models already exist in prisma/schema.prisma"
else
  log "Generating Better Auth Prisma schema..."
  NPX --yes auth@latest generate \
    --config app/lib/auth.server.ts \
    --output prisma/schema.prisma \
    --yes
  ok "Better Auth schema generated"
fi

log "Regenerating Prisma Client after Better Auth schema generation..."
NPX prisma generate
ok "Prisma Client regenerated"

# -----------------------------------------------------------------------------
# Stripe CLI — latest Linux release, optional convenience tool
# -----------------------------------------------------------------------------
install_stripe_cli() {
  local arch tag version url tmp dest

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "No automatic Stripe CLI build configured for $(uname -m)."; return 0 ;;
  esac

  if command -v stripe >/dev/null 2>&1; then
    ok "Stripe CLI already installed: $(stripe version 2>/dev/null | sed -n '1p' || true)"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is not installed; skipping automatic Stripe CLI installation."
    return 0
  fi

  log "Resolving latest Stripe CLI release..."
  tag="$(curl -fsSL https://api.github.com/repos/stripe/stripe-cli/releases/latest | node -e '
let s=""; process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).tag_name||"")}catch{}});')"
  [[ -n "$tag" ]] || { warn "Could not resolve Stripe CLI release."; return 0; }

  version="${tag#v}"
  url="https://github.com/stripe/stripe-cli/releases/download/${tag}/stripe_${version}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  dest="${HOME}/.local/bin"
  mkdir -p "$dest"

  if curl -fsSL "$url" -o "$tmp/stripe.tar.gz" \
    && tar -xzf "$tmp/stripe.tar.gz" -C "$tmp" stripe \
    && install -m 0755 "$tmp/stripe" "$dest/stripe"; then
    ok "Stripe CLI ${version} installed to ${dest}/stripe"
  else
    warn "Stripe CLI installation failed; the npm Stripe SDK is already installed."
  fi
  rm -rf "$tmp"
}

install_stripe_cli

# -----------------------------------------------------------------------------
# Cloudflare worker types + verification
# -----------------------------------------------------------------------------
log "Generating Cloudflare Worker binding types..."
if npm run typegen >/dev/null 2>&1; then
  ok "Worker types generated with the template's typegen script"
else
  NPX wrangler types || warn "Worker type generation failed; configure wrangler.jsonc and retry."
fi

log "Checking direct dependency tree..."
npm list --depth=0 || warn "npm reported dependency-tree warnings; review the output above."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ Add-on installation complete.${RESET}"
echo ""
echo "Template packages were left under the versions selected by the Cloudflare template."
echo "Standalone add-ons were requested with @latest; coupled package families were synchronized."
echo ""
echo "Next steps:"
echo "  1. Set a real DATABASE_URL in .env and .dev.vars."
echo "  2. Fill in Resend/Stripe keys as needed."
echo "  3. Run: npx prisma migrate dev --name init"
echo "  4. Run: npm run dev"
echo "  5. Deploy with: npm run deploy"
echo ""
