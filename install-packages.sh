#!/usr/bin/env bash
# install-packages-cloudflare.sh
# Add-on installer for an EXISTING React Router v8 + Cloudflare Workers project.
#
# Cloudflare template/core packages are NEVER upgraded by this script unless
# --upgrade-template is given. Create the project first with:
#   npm create cloudflare@latest -- my-react-router-app --framework=react-router
#
# Policy:
#   - Keep React / React Router / Vite / Wrangler / Cloudflare Vite plugin exactly
#     as supplied by the template/package-lock (unless --upgrade-template).
#   - Every add-on is resolved to its newest STABLE npm release at run time.
#     Pre-releases (rc/beta/alpha/next/canary/preview/dev, etc.) are never selected,
#     even when a publisher points the `latest` dist-tag at one.
#   - Version-coupled families are installed together at compatible versions:
#       * @react-router/fs-routes == installed @react-router/dev
#       * prisma / @prisma/client / @prisma/adapter-d1 share one exact version
#       * better-auth / @better-auth/passkey share one exact version
#       * lexical / @lexical/react share one exact version
#   - Database: Cloudflare D1 via @prisma/adapter-d1 (default).
#     --postgres adds @prisma/adapter-pg and wires Better Auth to DATABASE_URL instead.
#   - --upgrade-template also moves template-owned packages to newest stable.
#     TypeScript stays on its current major; @types/node follows your Node major.
#   - A version report runs at the end: installed vs newest stable, per package.
#
# Usage (run as your normal user — DO NOT use sudo):
#   ./install-packages-cloudflare.sh
#   ./install-packages-cloudflare.sh -y                  # skip the confirmation prompt
#   ./install-packages-cloudflare.sh --postgres          # PostgreSQL instead of D1
#   ./install-packages-cloudflare.sh --upgrade-template  # also upgrade template packages
#   ./install-packages-cloudflare.sh --report            # only print the version report
# (end of help text)

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
UPGRADE_TEMPLATE=0
REPORT_ONLY=0
USE_POSTGRES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --upgrade-template) UPGRADE_TEMPLATE=1 ;;
    --postgres) USE_POSTGRES=1 ;;
    --report) REPORT_ONLY=1; ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,/(end of help text)/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Runtime checks
# -----------------------------------------------------------------------------
# Never run this project installer with sudo/root. User-managed Node installs
# (nvm/fnm/mise/Volta/local PATH) are commonly invisible to sudo, and running
# npm as root can leave package.json/package-lock.json/node_modules/app files
# owned by root.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo ""
  err "Do not run this installer with sudo or as root."
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
    err "sudo changed the environment from user '${SUDO_USER}' to root, so your normal Node.js PATH may be hidden."
  fi
  echo ""
  echo "  Run it from the project directory as your normal user:"
  echo ""
  echo "    node -v"
  echo "    npm -v"
  echo "    ./install-packages-cloudflare.sh"
  echo ""
  exit 1
fi

if (( BASH_VERSINFO[0] < 4 )); then
  err "Bash 4+ is required (running ${BASH_VERSION})."
  exit 1
fi

for bin in node npm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "$bin is not available on your normal user PATH."
    err "Install/activate Node.js for your user first, then rerun this script WITHOUT sudo."
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
if (( USE_POSTGRES == 1 )); then
  echo -e "  Database mode: ${BOLD}PostgreSQL${RESET} (@prisma/adapter-pg)"
else
  echo -e "  Database mode: ${BOLD}Cloudflare D1${RESET} (@prisma/adapter-d1) — use --postgres for PostgreSQL"
fi
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

WRANGLER_CONFIG=""
for f in wrangler.jsonc wrangler.json wrangler.toml; do
  [[ -f "$f" ]] && { WRANGLER_CONFIG="$f"; break; }
done
if [[ -z "$WRANGLER_CONFIG" ]]; then
  err "No Wrangler configuration was found."
  err "The official template normally includes wrangler.jsonc."
  exit 1
fi

if [[ ! -f workers/app.ts && ! -f workers/app.js ]]; then
  warn "workers/app.ts was not found. Cloudflare's current full-stack template normally uses it."
  warn "Continuing because older/current variants can still be deployable through Wrangler detection."
fi

ok "Existing React Router + Cloudflare Workers project confirmed"

# Hydrate only what the template/package-lock already declares.
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
# Print the highest published stable version of a package. An optional second
# argument restricts the result to one major version (e.g. `stable_version typescript 5`).
# The `latest` dist-tag is intentionally ignored: publishers can (and do) point it
# at prereleases. Stable = exact x.y.z with no SemVer prerelease suffix.
stable_version() {
  local package="$1" major="${2:-}"
  npm view "$package" versions --json 2>/dev/null | MAJOR="$major" node -e '
let input = "";
process.stdin.on("data", (d) => input += d);
process.stdin.on("end", () => {
  let versions;
  try { versions = JSON.parse(input); } catch { process.exit(2); }
  if (!Array.isArray(versions)) versions = [versions];
  const major = process.env.MAJOR;

  const stable = versions
    .filter((v) => typeof v === "string" && /^\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/.test(v))
    .filter((v) => !major || v.split(".")[0] === major)
    .sort((a, b) => {
      const pa = a.split("+")[0].split(".").map(Number);
      const pb = b.split("+")[0].split(".").map(Number);
      return pa[0] - pb[0] || pa[1] - pb[1] || pa[2] - pb[2];
    });

  if (!stable.length) process.exit(3);
  process.stdout.write(stable[stable.length - 1]);
});
'
}

assert_stable_version() {
  local package="$1" version="$2"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
    err "Refusing prerelease/non-stable version for ${package}: ${version}"
    exit 1
  fi
}

installed_version() {
  node -e "try{process.stdout.write(require('./node_modules/$1/package.json').version||'')}catch(e){}"
}

# Resolve the newest stable version of a package (optionally within a major) or abort.
require_stable() {
  local package="$1" major="${2:-}" version
  version="$(stable_version "$package" "$major" || true)"
  if [[ -z "$version" ]]; then
    err "Could not resolve a stable version for ${package}${major:+ (major ${major})}."
    exit 1
  fi
  assert_stable_version "$package" "$version"
  printf '%s' "$version"
}

# Resolve "package@<newest stable>" or abort.
resolve_spec() {
  printf '%s@%s' "$1" "$(require_stable "$@")"
}

# Fail early if a lock-step partner was not published at the same version.
assert_published() {
  local package="$1" version="$2"
  if [[ -z "$(npm view "${package}@${version}" version 2>/dev/null)" ]]; then
    err "${package}@${version} is not published; cannot keep it in lock-step."
    exit 1
  fi
}

# Every package the finished project is expected to carry, with its owner.
# template = created by the Cloudflare template (held unless --upgrade-template)
# held     = template-owned; held to its current major even with --upgrade-template
# addon    = installed by this script
# pg       = add-on installed only with --postgres
REPORT_PACKAGES=(
  "react:template" "react-dom:template" "react-router:template" "isbot:template"
  "@react-router/dev:template" "@cloudflare/vite-plugin:template" "vite:template"
  "wrangler:template" "tailwindcss:template" "@tailwindcss/vite:template"
  "@types/react:template" "@types/react-dom:template"
  "typescript:held" "@types/node:held"
  "@react-router/fs-routes:addon"
  "prisma:addon" "@prisma/client:addon" "@prisma/adapter-d1:addon" "@prisma/adapter-pg:pg"
  "pg:addon" "@types/pg:addon"
  "better-auth:addon" "@better-auth/passkey:addon"
  "lexical:addon" "@lexical/react:addon"
  "resend:addon" "stripe:addon" "zod:addon" "react-hook-form:addon" "@hookform/resolvers:addon"
  "dompurify:addon" "motion:addon" "three:addon" "@types/three:addon" "lucide-react:addon"
  "exceljs:addon" "preline:addon" "uqr:addon"
  "daisyui:addon" "tsx:addon" "jsdom:addon" "sharp:addon" "vitest:addon"
)

version_report() {
  local entry package owner installed latest status
  echo ""
  echo -e "${BOLD}Version report — installed vs newest stable on npm${RESET}"
  printf "  %-26s %-10s %-12s %-12s %s\n" "PACKAGE" "OWNER" "INSTALLED" "LATEST" "STATUS"
  for entry in "${REPORT_PACKAGES[@]}"; do
    package="${entry%%:*}"
    owner="${entry##*:}"
    installed="$(installed_version "$package")"
    # Postgres-only packages are reported only when relevant.
    if [[ "$owner" == "pg" && -z "$installed" && $USE_POSTGRES -eq 0 ]]; then
      continue
    fi
    latest="$(stable_version "$package" || true)"
    if [[ -z "$installed" ]]; then
      status="${RED}missing${RESET}"
    elif [[ "$installed" == "$latest" ]]; then
      status="${GREEN}latest${RESET}"
    elif [[ "$package" == "@react-router/fs-routes" ]]; then
      status="${YELLOW}pinned to @react-router/dev${RESET}"
    elif [[ "$owner" == "held" ]]; then
      status="${DIM}held to current major${RESET}"
    elif [[ "$owner" == "template" ]]; then
      status="${DIM}held by template${RESET}"
    elif [[ "$package" == @prisma/* || "$package" == "prisma" ]]; then
      status="${YELLOW}behind (Prisma family lock-step)${RESET}"
    else
      status="${YELLOW}behind${RESET}"
    fi
    printf "  %-26s %-10s %-12s %-12s " "$package" "$owner" "${installed:--}" "${latest:-?}"
    echo -e "$status"
  done
  echo ""
}

if (( REPORT_ONLY == 1 )); then
  version_report
  exit 0
fi

# -----------------------------------------------------------------------------
# Optional: upgrade template-owned packages (--upgrade-template only)
# -----------------------------------------------------------------------------
if (( UPGRADE_TEMPLATE == 1 )); then
  warn "--upgrade-template: moving template-owned packages to their newest stable releases."

  REACT_TARGET="$(require_stable react)"
  assert_published react-dom "$REACT_TARGET"

  RR_TARGET="$(require_stable react-router)"
  assert_published @react-router/dev "$RR_TARGET"

  TW_TARGET="$(require_stable tailwindcss)"
  assert_published @tailwindcss/vite "$TW_TARGET"

  # TypeScript: newest stable inside the project's current major (a new major
  # breaks builds). @types/node: newest stable matching the running Node major.
  TS_MAJOR="$(installed_version typescript | cut -d. -f1)"
  TS_TARGET="$(require_stable typescript "${TS_MAJOR:-5}")"
  NODE_TYPES_TARGET="$(require_stable @types/node "$node_major")"

  log "react/react-dom ${REACT_TARGET}, react-router/@react-router/dev ${RR_TARGET}, tailwindcss/@tailwindcss/vite ${TW_TARGET}"
  log "typescript ${TS_TARGET} (major ${TS_MAJOR:-5} held), @types/node ${NODE_TYPES_TARGET} (Node ${node_major})"

  npm install \
    "react@${REACT_TARGET}" \
    "react-dom@${REACT_TARGET}" \
    "react-router@${RR_TARGET}" \
    "$(resolve_spec isbot)"
  npm install --save-dev \
    "@react-router/dev@${RR_TARGET}" \
    "tailwindcss@${TW_TARGET}" \
    "@tailwindcss/vite@${TW_TARGET}" \
    "typescript@${TS_TARGET}" \
    "@types/node@${NODE_TYPES_TARGET}" \
    "$(resolve_spec vite)" \
    "$(resolve_spec wrangler)" \
    "$(resolve_spec @cloudflare/vite-plugin)" \
    "$(resolve_spec @types/react)" \
    "$(resolve_spec @types/react-dom)"
  ok "Template-owned packages upgraded to newest stable releases"
fi

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
# Prisma family — resolve once, keep CLI/client/adapters synchronized
# -----------------------------------------------------------------------------
log "Resolving the current stable Prisma release..."
PRISMA_VERSION="$(require_stable prisma)"
PG_VERSION="$(require_stable pg)"
PG_TYPES_VERSION="$(require_stable @types/pg)"

PRISMA_PROD=(
  "@prisma/client@${PRISMA_VERSION}"
  "@prisma/adapter-d1@${PRISMA_VERSION}"
  "pg@${PG_VERSION}"
)
assert_published @prisma/client "$PRISMA_VERSION"
assert_published @prisma/adapter-d1 "$PRISMA_VERSION"
if (( USE_POSTGRES == 1 )); then
  assert_published @prisma/adapter-pg "$PRISMA_VERSION"
  PRISMA_PROD+=("@prisma/adapter-pg@${PRISMA_VERSION}")
fi

# @prisma/adapter-d1 → Cloudflare D1 binding "DB" (default mode).
# @prisma/adapter-pg → PostgreSQL via DATABASE_URL (--postgres only).
log "Installing synchronized stable Prisma ${PRISMA_VERSION} packages..."
npm install "${PRISMA_PROD[@]}"
npm install --save-dev "prisma@${PRISMA_VERSION}" "@types/pg@${PG_TYPES_VERSION}"
ok "Prisma family installed at ${PRISMA_VERSION}"

# -----------------------------------------------------------------------------
# Better Auth family — core and passkey plugin share one exact version
# -----------------------------------------------------------------------------
log "Resolving the current stable Better Auth release..."
BETTER_AUTH_VERSION="$(require_stable better-auth)"
assert_published @better-auth/passkey "$BETTER_AUTH_VERSION"
npm install "better-auth@${BETTER_AUTH_VERSION}" "@better-auth/passkey@${BETTER_AUTH_VERSION}"
ok "better-auth + @better-auth/passkey installed at ${BETTER_AUTH_VERSION}"

# -----------------------------------------------------------------------------
# Lexical family — keep core and React integration synchronized
# -----------------------------------------------------------------------------
log "Resolving the current stable Lexical release..."
LEXICAL_VERSION="$(require_stable lexical)"
assert_published @lexical/react "$LEXICAL_VERSION"
npm install "lexical@${LEXICAL_VERSION}" "@lexical/react@${LEXICAL_VERSION}"
ok "Lexical family installed at ${LEXICAL_VERSION}"

# -----------------------------------------------------------------------------
# Independent add-ons — newest STABLE releases only
# -----------------------------------------------------------------------------
STABLE_PROD_PACKAGES=(
  resend
  stripe
  zod
  react-hook-form
  dompurify
  motion
  three
  lucide-react   # tree-shakeable SVG icon components (import { Icon } from "lucide-react")
  exceljs        # .xlsx read/write — Node-oriented; in Worker code it needs nodejs_compat
  preline        # Tailwind component JS (dropdowns, modals, tabs…)
  uqr            # tiny zero-dependency QR code generator (SVG/ANSI/raw)
)

STABLE_DEV_PACKAGES=(
  tsx
  jsdom
  @types/three
  daisyui
  sharp   # native Node image processing for build/scripts — never import it in Worker code
)

install_stable_packages() {
  local save_mode="$1"
  shift
  local package version specs=()

  for package in "$@"; do
    version="$(require_stable "$package")"
    log "Selected ${package}@${version}"
    specs+=("${package}@${version}")
  done

  if [[ "$save_mode" == "dev" ]]; then
    npm install --save-dev "${specs[@]}"
  else
    npm install "${specs[@]}"
  fi
}

log "Installing/upgrading independent production add-ons to newest stable releases..."
install_stable_packages prod "${STABLE_PROD_PACKAGES[@]}"
ok "Independent production add-ons are on stable releases"

if [[ -n "$(installed_version lucide-react)" ]]; then
  ok "lucide-react $(installed_version lucide-react) installed against React $(installed_version react)"
else
  warn "lucide-react does not appear in node_modules; check the npm output above."
fi

# @hookform/resolvers has historically had optional-peer resolution collisions.
# Use the narrow peer fallback only if the normal install fails.
HOOKFORM_RESOLVERS_VERSION="$(require_stable @hookform/resolvers)"
log "Installing/upgrading @hookform/resolvers@${HOOKFORM_RESOLVERS_VERSION}..."
if npm install "@hookform/resolvers@${HOOKFORM_RESOLVERS_VERSION}"; then
  ok "@hookform/resolvers installed with normal peer validation"
else
  warn "Normal peer resolution failed; retrying only this package with --legacy-peer-deps"
  npm install --legacy-peer-deps "@hookform/resolvers@${HOOKFORM_RESOLVERS_VERSION}"
  ok "@hookform/resolvers installed with the compatibility fallback"
fi

log "Installing/upgrading independent development add-ons to newest stable releases..."
install_stable_packages dev "${STABLE_DEV_PACKAGES[@]}"
ok "Independent development add-ons are on stable releases"

# Vitest declares a peer range on vite. If the template's vite is outside it,
# do NOT force it — tell the user to upgrade the template instead.
VITEST_VERSION="$(require_stable vitest)"
log "Installing vitest@${VITEST_VERSION} against vite $(installed_version vite)..."
if npm install --save-dev "vitest@${VITEST_VERSION}"; then
  ok "vitest ${VITEST_VERSION} installed"
  if [[ -z "$(node -p "require('./package.json').scripts?.test ?? ''")" ]]; then
    npm pkg set scripts.test="vitest"
    ok "Added \"test\": \"vitest\" to package.json scripts"
  fi
else
  warn "vitest ${VITEST_VERSION} could not be installed against vite $(installed_version vite)."
  warn "Rerun with --upgrade-template to move vite forward, then rerun this script."
fi

warn "jsdom and sharp are dev dependencies: both are Node-only and must not be imported into Worker runtime code."

# -----------------------------------------------------------------------------
# daisyUI + Preline / Tailwind CSS 4 integration
# Cloudflare's React Router template already includes Tailwind CSS.
# The user's existing stylesheet is edited in place, never replaced.
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
    ok "daisyUI plugin added"
  fi

  if grep -q 'preline' app/app.css 2>/dev/null; then
    ok "Preline is already referenced by app/app.css"
  elif [[ ! -f node_modules/preline/variants.css ]]; then
    warn "node_modules/preline/variants.css not found; add Preline's CSS manually (see preline.co/docs)."
  else
    log "Adding Preline variants + sources to app/app.css..."
    # CSS @import must sit at the top of the file, so it goes right after the
    # Tailwind import instead of being appended at the end.
    if node <<'NODE'
const fs = require('fs');
const file = 'app/app.css';
const src = fs.readFileSync(file, 'utf8');
const re = /^@import\s+["']tailwindcss["'][^;\n]*;[^\n]*$/m;
if (!re.test(src)) process.exit(3);
const out = src.replace(re, (line) =>
  `${line}\n@import "preline/variants.css";\n@source "../node_modules/preline/dist/*.js";`);
fs.writeFileSync(file, out);
NODE
    then
      ok "Preline CSS wired into app/app.css"
    else
      warn "Could not find '@import \"tailwindcss\";' in app/app.css. Add these lines after it manually:"
      warn '  @import "preline/variants.css";'
      warn '  @source "../node_modules/preline/dist/*.js";'
    fi
  fi
else
  warn "app/app.css was not found; daisyUI/Preline are installed but their CSS lines were not added."
fi

mkdir -p app/lib app/routes

# Preline's JS must run in the browser and re-init after client-side navigation.
if [[ ! -f app/lib/use-preline.ts ]]; then
  cat > app/lib/use-preline.ts <<'TS'
import { useEffect } from "react";
import { useLocation } from "react-router";

type PrelineWindow = Window & {
  HSStaticMethods?: { autoInit: (collection?: string | string[]) => void };
};

/**
 * Call once in app/root.tsx (inside App) to initialise Preline components
 * on first load and after every client-side navigation.
 */
export function usePreline() {
  const location = useLocation();

  useEffect(() => {
    let cancelled = false;
    import("preline").then(() => {
      if (!cancelled) (window as PrelineWindow).HSStaticMethods?.autoInit();
    });
    return () => {
      cancelled = true;
    };
  }, [location.pathname]);
}
TS
  ok "app/lib/use-preline.ts created (call usePreline() in app/root.tsx)"
else
  ok "app/lib/use-preline.ts already exists — not overwritten"
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
if (( USE_POSTGRES == 1 )); then
  ensure_env_var .env DATABASE_URL "postgresql://localhost:5432/mydb"
else
  # Only read by the Prisma CLI; the Worker talks to D1 through the "DB" binding.
  ensure_env_var .env DATABASE_URL "file:./dev.db"
fi
ensure_env_var .env BETTER_AUTH_SECRET "$(gen_secret)"
ensure_env_var .env BETTER_AUTH_URL "http://localhost:5173"
ensure_env_var .env RESEND_API_KEY ""
ensure_env_var .env EMAIL_FROM "onboarding@resend.dev"
ensure_env_var .env STRIPE_SECRET_KEY ""
ensure_env_var .env STRIPE_WEBHOOK_SECRET ""

# Cloudflare local runtime bindings are read from .dev.vars. Keep existing values.
if (( USE_POSTGRES == 1 )); then
  ensure_env_var .dev.vars DATABASE_URL "postgresql://localhost:5432/mydb"
fi
ensure_env_var .dev.vars BETTER_AUTH_SECRET "$(gen_secret)"
ensure_env_var .dev.vars BETTER_AUTH_URL "http://localhost:5173"
ensure_env_var .dev.vars RESEND_API_KEY ""
ensure_env_var .dev.vars EMAIL_FROM "onboarding@resend.dev"
ensure_env_var .dev.vars STRIPE_SECRET_KEY ""
ensure_env_var .dev.vars STRIPE_WEBHOOK_SECRET ""

for ignored in .dev.vars .env; do
  if [[ -f .gitignore ]] && ! grep -qxF "$ignored" .gitignore; then
    printf '\n%s\n' "$ignored" >> .gitignore
    ok "${ignored} added to .gitignore"
  fi
done

# -----------------------------------------------------------------------------
# Prisma setup (Prisma 7 + driver adapter, Workers runtime)
# -----------------------------------------------------------------------------
if (( USE_POSTGRES == 1 )); then
  PRISMA_PROVIDER="postgresql"
else
  PRISMA_PROVIDER="sqlite"   # D1 is SQLite
fi

if [[ ! -f prisma/schema.prisma ]]; then
  log "Initializing Prisma for ${PRISMA_PROVIDER}..."
  NPX prisma init --datasource-provider "$PRISMA_PROVIDER" --output ../app/generated/prisma
  ok "Prisma initialized"
else
  ok "Prisma is already initialized"
fi

# `prisma init` writes `import "dotenv/config"` into prisma.config.ts, but dotenv is
# not part of this stack. Swap it for Node's built-in .env loader (Node 20.12+).
if [[ -f prisma.config.ts ]] && grep -q '^import "dotenv/config";' prisma.config.ts \
   && [[ -z "$(installed_version dotenv)" ]]; then
  node <<'NODE'
const fs = require('fs');
const file = 'prisma.config.ts';
const src = fs.readFileSync(file, 'utf8').replace(
  /^import "dotenv\/config";\s*$/m,
  '// Load .env with Node\'s built-in loader (no dotenv dependency).\ntry { process.loadEnvFile(); } catch {}',
);
fs.writeFileSync(file, src);
NODE
  ok "prisma.config.ts now loads .env without dotenv"
fi

# The generated client runs inside a Worker: target the Cloudflare runtime.
if [[ -f prisma/schema.prisma ]] && ! grep -qE '^\s*runtime\s*=' prisma/schema.prisma; then
  if node <<'NODE'
const fs = require('fs');
const file = 'prisma/schema.prisma';
const src = fs.readFileSync(file, 'utf8');
const re = /(generator\s+client\s*\{[^}]*?)(\n\})/;
if (!re.test(src)) process.exit(3);
fs.writeFileSync(file, src.replace(re, '$1\n  runtime  = "cloudflare"$2'));
NODE
  then
    ok 'Prisma generator set to runtime = "cloudflare"'
  else
    warn 'Add runtime = "cloudflare" to the generator block in prisma/schema.prisma manually.'
  fi
fi

log "Generating Prisma Client..."
NPX prisma generate
ok "Prisma Client generated"

# -----------------------------------------------------------------------------
# Better Auth files for Cloudflare Workers (email/password + passkeys)
# - auth.options.ts  shared options (plugins etc.) — no database imports
# - auth.server.ts   runtime instance, built from context.cloudflare.env
# - auth.cli.ts      config for the Better Auth CLI (Node), no live DB needed
# Existing user files are never overwritten.
# -----------------------------------------------------------------------------
if [[ ! -f app/lib/auth.options.ts ]]; then
  cat > app/lib/auth.options.ts <<'TS'
import { passkey } from "@better-auth/passkey";
import type { BetterAuthOptions } from "better-auth";

// Options shared by the Worker runtime and the Better Auth CLI.
// Add plugins here so schema generation always sees the same set.
export const authOptions = {
  emailAndPassword: { enabled: true },
  plugins: [passkey()],
} satisfies Partial<BetterAuthOptions>;
TS
  ok "app/lib/auth.options.ts created"
else
  ok "app/lib/auth.options.ts already exists — not overwritten"
fi

if [[ ! -f app/lib/auth.server.ts ]]; then
  if (( USE_POSTGRES == 1 )); then
    cat > app/lib/auth.server.ts <<'TS'
import { PrismaPg } from "@prisma/adapter-pg";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { PrismaClient } from "../generated/prisma/client";
import { authOptions } from "./auth.options";

export type AuthEnv = {
  DATABASE_URL: string;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL: string;
};

// Workers cannot reuse a TCP connection across requests, so build a fresh
// client per request instead of caching it at module scope.
export function buildAuth(env: AuthEnv) {
  const prisma = new PrismaClient({
    adapter: new PrismaPg({ connectionString: env.DATABASE_URL }),
  });

  return betterAuth({
    ...authOptions,
    database: prismaAdapter(prisma, { provider: "postgresql" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
  });
}
TS
  else
    cat > app/lib/auth.server.ts <<'TS'
import { PrismaD1 } from "@prisma/adapter-d1";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { PrismaClient } from "../generated/prisma/client";
import { authOptions } from "./auth.options";

export type AuthEnv = {
  DB: D1Database;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL: string;
};

function createAuth(env: AuthEnv) {
  const prisma = new PrismaClient({ adapter: new PrismaD1(env.DB) });

  return betterAuth({
    ...authOptions,
    database: prismaAdapter(prisma, { provider: "sqlite" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
  });
}

// D1 bindings are not tied to a single request, so one instance per binding is safe.
const instances = new WeakMap<D1Database, ReturnType<typeof createAuth>>();

export function buildAuth(env: AuthEnv) {
  let instance = instances.get(env.DB);
  if (!instance) {
    instance = createAuth(env);
    instances.set(env.DB, instance);
  }
  return instance;
}
TS
  fi
  ok "app/lib/auth.server.ts created"
else
  ok "app/lib/auth.server.ts already exists — not overwritten"
  if ! grep -q 'passkey\|authOptions' app/lib/auth.server.ts; then
    warn "Your existing auth.server.ts does not include the passkey plugin."
    warn "Spread authOptions from ./auth.options into betterAuth({...}) to enable it."
  fi
fi

if [[ ! -f app/lib/auth.cli.ts ]]; then
  cat > app/lib/auth.cli.ts <<TS
// Used ONLY by the Better Auth CLI (\`auth generate\`), which runs in Node.
// It never touches a database: the CLI only needs the adapter type and plugins.
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { authOptions } from "./auth.options";

export const auth = betterAuth({
  ...authOptions,
  database: prismaAdapter({} as never, { provider: "${PRISMA_PROVIDER}" }),
});
TS
  ok "app/lib/auth.cli.ts created"
else
  ok "app/lib/auth.cli.ts already exists — not overwritten"
fi

if [[ ! -f app/lib/auth-client.ts ]]; then
  cat > app/lib/auth-client.ts <<'TS'
import { passkeyClient } from "@better-auth/passkey/client";
import { createAuthClient } from "better-auth/react";

export const authClient = createAuthClient({
  plugins: [passkeyClient()],
});

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

# Better Auth CLI: exact stable version, kept in lock-step with better-auth.
# Regenerate whenever the User or Passkey model is missing.
if grep -qE '^model (User|user) ' prisma/schema.prisma 2>/dev/null \
   && grep -qE '^model (Passkey|passkey) ' prisma/schema.prisma 2>/dev/null; then
  ok "Better Auth models (incl. Passkey) already exist in prisma/schema.prisma"
else
  AUTH_CLI_VERSION="$BETTER_AUTH_VERSION"
  if [[ -z "$(npm view "auth@${AUTH_CLI_VERSION}" version 2>/dev/null)" ]]; then
    AUTH_CLI_VERSION="$(require_stable auth)"
  fi
  log "Generating Better Auth Prisma schema with auth@${AUTH_CLI_VERSION}..."
  NPX --yes "auth@${AUTH_CLI_VERSION}" generate \
    --config app/lib/auth.cli.ts \
    --output prisma/schema.prisma \
    --yes
  ok "Better Auth schema generated"

  log "Regenerating Prisma Client after Better Auth schema generation..."
  NPX prisma generate
  ok "Prisma Client regenerated"
fi

# D1 binding check — the script does not edit wrangler config for you.
if (( USE_POSTGRES == 0 )) && ! grep -q 'd1_databases' "$WRANGLER_CONFIG"; then
  warn "No d1_databases entry in ${WRANGLER_CONFIG}. Create the database and add the binding:"
  warn "  npx wrangler d1 create my-app-db"
  warn '  "d1_databases": [{ "binding": "DB", "database_name": "my-app-db", "database_id": "<id>" }]'
fi

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
  tag="$(curl -fsSL https://api.github.com/repos/stripe/stripe-cli/releases/latest 2>/dev/null | node -e '
let s=""; process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).tag_name||"")}catch{}});' || true)"
  [[ -n "$tag" ]] || { warn "Could not resolve Stripe CLI release."; return 0; }

  version="${tag#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
    warn "Stripe CLI latest release is not a plain stable SemVer (${tag}); skipping it."
    return 0
  fi
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
  NPX wrangler types || warn "Worker type generation failed; configure ${WRANGLER_CONFIG} and retry."
fi

log "Checking direct dependency tree..."
npm list --depth=0 || warn "npm reported dependency-tree warnings; review the output above."

version_report

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ Add-on installation complete.${RESET}"
echo ""
if (( UPGRADE_TEMPLATE == 1 )); then
  echo "Template packages were upgraded to newest stable (TypeScript held to its major, @types/node to Node ${node_major})."
else
  echo "Template packages were left at the versions selected by the Cloudflare template."
  echo "Rerun with --upgrade-template to move them to newest stable as well."
fi
echo "Add-on packages were resolved to exact newest stable releases; prereleases were excluded."
echo ""
echo "Next steps:"
if (( USE_POSTGRES == 1 )); then
  echo "  1. Set a real DATABASE_URL in .env and .dev.vars."
  echo "  2. Fill in Resend/Stripe keys as needed."
  echo "  3. Run: npx prisma migrate dev --name init"
else
  echo "  1. Create the D1 database and add the \"DB\" binding to ${WRANGLER_CONFIG}:"
  echo "       npx wrangler d1 create my-app-db"
  echo "  2. Fill in Resend/Stripe keys as needed."
  echo "  3. Create and apply the first migration:"
  echo "       npx wrangler d1 migrations create my-app-db init"
  echo "       npx prisma migrate diff --from-empty --to-schema prisma/schema.prisma --script \\"
  echo "         --output migrations/0001_init.sql"
  echo "       npx wrangler d1 migrations apply my-app-db --local"
fi
echo "  4. Call usePreline() inside App in app/root.tsx (from ~/lib/use-preline)."
echo "  5. Run: npm run dev   (tests: npm test)"
echo "  6. Deploy with: npm run deploy"
echo ""
