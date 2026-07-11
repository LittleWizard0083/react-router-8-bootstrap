#!/usr/bin/env bash
# ==============================================================================
# install-packages.sh — Full React Router 8 setup with scaffolding + packages
#
# This script:
#   1. Scaffolds a React Router 8 project (if package.json doesn't exist)
#   2. Starts `bunx prisma dev` in the background
#   3. Installs all npm/bun packages
#   4. Extracts and saves DATABASE_URL + SHADOW_DATABASE_URL to .env
#   5. Runs prisma migrate and generate
#
# Usage:
#   ./install-packages.sh              # scaffold + start prisma in background
#   ./install-packages.sh --foreground # scaffold + run prisma in foreground
#   ./install-packages.sh --skip-db    # scaffold + skip prisma entirely
#   ./install-packages.sh --skip-scaffold # skip scaffold, just install packages
#
# ==============================================================================
set -euo pipefail

# ---------- Output helpers -------------------------------------------------
c_dim=$'\033[2m'
c_bold=$'\033[1m'
c_cyan=$'\033[0;36m'
c_green=$'\033[0;32m'
c_yellow=$'\033[0;33m'
c_red=$'\033[0;31m'
c_mag=$'\033[0;35m'
c_reset=$'\033[0m'

SYM_STEP="◼"
SYM_OK="✔"
SYM_SKIP="━"
SYM_WARN="▲"
SYM_ERR="✖"

log()  { printf "  %s%s%s  %s\n" "$c_cyan" "$SYM_STEP" "$c_reset" "$1"; }
ok()   { printf "  %s%s%s  %s\n" "$c_green" "$SYM_OK" "$c_reset" "$1"; }
skip() { printf "  %s%s  %s%s\n" "$c_dim" "$SYM_SKIP" "$1" "$c_reset"; }
warn() { printf "  %s%s%s  %s\n" "$c_yellow" "$SYM_WARN" "$c_reset" "$1"; }
err()  { printf "  %s%s%s  %s\n" "$c_red" "$SYM_ERR" "$c_reset" "$1" >&2; }

banner() {
  local title="$1" subtitle="${2:-}"
  local hbar
  hbar=$(printf '─%.0s' $(seq 1 60))
  echo ""
  printf "%s╭%s╮%s\n" "$c_mag" "$hbar" "$c_reset"
  printf "%s│%s│%s\n" "$c_mag" "" "$c_reset"
  printf "%s│%s  %s%s%s%s│%s\n" "$c_mag" "" "$c_bold" "$title" "$c_reset" "$c_mag" "$c_reset"
  if [[ -n "$subtitle" ]]; then
    printf "%s│%s  %s%s%s%s│%s\n" "$c_mag" "" "$c_dim" "$subtitle" "$c_reset" "$c_mag" "$c_reset"
  fi
  printf "%s│%s│%s\n" "$c_mag" "" "$c_reset"
  printf "%s╰%s╯%s\n" "$c_mag" "$hbar" "$c_reset"
  echo ""
}

group() {
  local label="$1"
  echo ""
  printf "  %s%s%s\n" "$c_mag$c_bold" "$label" "$c_reset"
  printf "  %s────────────────────────────────────────────%s\n" "$c_dim" "$c_reset"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command '$1' not found. Install it and re-run."
    exit 1
  fi
}

# has_dep: Check if package is in package.json
has_dep() {
  local pkg="$1"
  [[ -f package.json ]] || return 1
  node -e "
    const pkg = require('./package.json');
    const all = { ...(pkg.dependencies||{}), ...(pkg.devDependencies||{}), ...(pkg.peerDependencies||{}), ...(pkg.optionalDependencies||{}) };
    process.exit(all['$pkg'] ? 0 : 1);
  " 2>/dev/null
}

# install_dep: Install packages with npm
install_dep() {
  local flags="$1"; shift
  local to_install=()
  for pkg in "$@"; do
    if has_dep "$pkg"; then
      skip "$pkg already in package.json"
    else
      to_install+=("$pkg")
    fi
  done
  if (( ${#to_install[@]} > 0 )); then
    log "npm install $flags ${to_install[*]}"
    # shellcheck disable=SC2086
    npm install $flags "${to_install[@]}"
  fi
}

# install_dep_bun: Install packages with bun (fallback to npm)
install_dep_bun() {
  local flags="$1"; shift
  if ! command -v bun >/dev/null 2>&1; then
    install_dep "$flags" "$@"
    return
  fi
  local to_install=()
  for pkg in "$@"; do
    if has_dep "$pkg"; then
      skip "$pkg already in package.json"
    else
      to_install+=("$pkg")
    fi
  done
  if (( ${#to_install[@]} > 0 )); then
    log "bun add $flags ${to_install[*]}"
    # shellcheck disable=SC2086
    bun add $flags "${to_install[@]}"
  fi
}

# ensure_env_var: Add key=value to .env if not present
ensure_env_var() {
  local key="$1"; local value="$2"
  touch .env
  if grep -q -E "^${key}=" .env 2>/dev/null; then
    skip ".env already has $key"
  else
    echo "${key}=${value}" >> .env
    log "added $key to .env"
  fi
}

# replace_env_var: Force-write key=value to .env, removing any existing line
replace_env_var() {
  local key="$1"; local value="$2"
  touch .env
  if grep -qE "^${key}=" .env; then
    grep -v -E "^${key}=" .env > .env.tmp || true
    mv .env.tmp .env
  fi
  echo "${key}=${value}" >> .env
  log "set $key in .env"
}

# Verify prerequisites
require_cmd node
require_cmd npm

banner "React Router 8 Complete Setup" "Scaffold + Packages + Prisma"

# Parse command-line arguments
SCAFFOLD_SKIP=false
PRISMA_MODE="background"  # default: background
case "${1:-}" in
  --foreground)
    PRISMA_MODE="foreground"
    ;;
  --skip-db)
    PRISMA_MODE="skip"
    ;;
  --skip-scaffold)
    SCAFFOLD_SKIP=true
    ;;
  *)
    ;;
esac

# ---------- 1. Scaffold React Router (if needed) -----
if [[ "$SCAFFOLD_SKIP" == false ]] && [[ ! -f package.json ]]; then
  group "Scaffolding React Router 8 project"
  
  log "Running: npx create-react-router@latest . --template remix-run/react-router-templates/node-custom-server"
  
  if npx create-react-router@latest . --template remix-run/react-router-templates/node-custom-server; then
    ok "React Router template scaffolded successfully"
  else
    warn "Scaffold installer exited non-zero — checking if template files were created..."
    if [[ ! -f package.json ]]; then
      err "Scaffold failed: package.json not created."
      err "Try manually: npx create-react-router@latest . --template remix-run/react-router-templates/node-custom-server"
      exit 1
    fi
    ok "Template files created despite exit code"
  fi
elif [[ -f package.json ]]; then
  skip "package.json already exists — skipping scaffold"
else
  skip "Scaffold skipped (--skip-scaffold flag)"
fi

# If node_modules is missing, run npm install for base template deps
if [[ ! -d node_modules ]] || [[ -z "$(ls -A node_modules 2>/dev/null)" ]]; then
  log "node_modules missing — running npm install for base template deps..."
  npm install
else
  skip "node_modules already populated"
fi

# ---------- 2. Start Prisma dev (if not skipped) -----
if [[ "$PRISMA_MODE" != "skip" ]]; then
  group "Starting Prisma development database"
  
  if [[ "$PRISMA_MODE" == "foreground" ]]; then
    log "Starting 'bunx prisma dev' in foreground..."
    log "Copy the DATABASE_URL and SHADOW_DATABASE_URL from the output below."
    log "When ready, Ctrl+C and run: ./install-packages.sh --skip-db"
    echo ""
    if command -v bun >/dev/null 2>&1; then
      bunx prisma dev
    else
      npx prisma dev
    fi
    exit 0
  else
    # Background mode
    log "Starting 'bunx prisma dev' in background..."
    
    # Create a log file to capture output
    local logfile="/tmp/prisma-dev-$$.log"
    
    if command -v bun >/dev/null 2>&1; then
      bunx prisma dev > "$logfile" 2>&1 &
    else
      npx prisma dev > "$logfile" 2>&1 &
    fi
    
    local prisma_pid=$!
    echo "$prisma_pid" > .prisma-dev.pid
    
    # Wait for DATABASE_URL to appear in logs
    local timeout=60
    local db_url=""
    local shadow_url=""
    
    log "Waiting for Prisma to start (timeout: ${timeout}s)..."
    
    while (( timeout > 0 )); do
      if [[ -f "$logfile" ]]; then
        # Try to extract DATABASE_URL
        if [[ -z "$db_url" ]] && grep -q 'DATABASE_URL=' "$logfile"; then
          db_url=$(grep 'DATABASE_URL=' "$logfile" | head -1 | sed 's/.*DATABASE_URL="//' | sed 's/".*//')
        fi
        # Try to extract SHADOW_DATABASE_URL
        if [[ -z "$shadow_url" ]] && grep -q 'SHADOW_DATABASE_URL=' "$logfile"; then
          shadow_url=$(grep 'SHADOW_DATABASE_URL=' "$logfile" | head -1 | sed 's/.*SHADOW_DATABASE_URL="//' | sed 's/".*//')
        fi
        
        # If both found, we're good
        if [[ -n "$db_url" ]] && [[ -n "$shadow_url" ]]; then
          ok "Prisma database started (PID: $prisma_pid)"
          replace_env_var "DATABASE_URL" "$db_url"
          replace_env_var "SHADOW_DATABASE_URL" "$shadow_url"
          break
        fi
      fi
      
      sleep 1
      ((timeout--))
    done
    
    if (( timeout == 0 )); then
      warn "Prisma startup timeout. Showing last 20 lines from log:"
      tail -20 "$logfile" >&2
      rm -f "$logfile"
      exit 1
    fi
    
    rm -f "$logfile"
  fi
fi

group "Installing packages"

# Production dependencies
install_dep "--save" three
install_dep ""       better-auth
install_dep ""       motion
install_dep ""       zod
install_dep ""       dompurify
install_dep ""       jsdom
install_dep ""       resend
install_dep "--save" lexical @lexical/react
install_dep "--save" stripe

# Dev dependencies
install_dep "-D"     daisyui

# Prisma + database toolchain (using bun if available)
install_dep_bun "--dev" prisma tsx @types/pg
install_dep_bun ""      @prisma/client @prisma/adapter-pg dotenv pg

group "Verifying installation"

# Verify key packages were installed
if npm list better-auth > /dev/null 2>&1; then
  ok "better-auth installed"
else
  warn "better-auth not found"
fi

if npm list prisma > /dev/null 2>&1; then
  ok "prisma installed"
else
  warn "prisma not found"
fi

if npm list @prisma/client > /dev/null 2>&1; then
  ok "@prisma/client installed"
else
  warn "@prisma/client not found"
fi

# ---------- 3. Database migration ----------------------------------
if [[ "$PRISMA_MODE" != "skip" ]] && grep -qE '^DATABASE_URL=postgres' .env 2>/dev/null; then
  group "Running database migrations"
  
  log "Running prisma migrate dev --name init..."
  if command -v bun >/dev/null 2>&1; then
    bunx prisma migrate dev --name init || warn "prisma migrate failed"
  else
    npx prisma migrate dev --name init || warn "prisma migrate failed"
  fi
  
  log "Running prisma generate..."
  if command -v bun >/dev/null 2>&1; then
    bunx prisma generate || warn "prisma generate failed"
  else
    npx prisma generate || warn "prisma generate failed"
  fi
fi

echo ""
printf "  %s%s%s\n" "$c_green" "✔ Setup complete!" "$c_reset"
echo ""
echo "  ────────────────────────────────────────────"
echo "  ✓ React Router scaffolded"
echo "  ✓ Packages installed"
if [[ "$PRISMA_MODE" != "skip" ]]; then
  echo "  ✓ Prisma database running"
  echo "  ✓ DATABASE_URL saved to .env"
fi
echo ""
echo "  Remaining tasks:"
echo "  ────────────────────────────────────────────"
echo "  1. Fill in .env with:"
echo "     - BETTER_AUTH_SECRET (run: openssl rand -base64 32)"
echo "     - RESEND_API_KEY"
echo "     - STRIPE_SECRET_KEY"
echo ""
if [[ "$PRISMA_MODE" != "skip" ]]; then
  echo "  2. Keep Prisma dev running in background:"
  if [[ -f .prisma-dev.pid ]]; then
    echo "     PID: $(cat .prisma-dev.pid)"
    echo "     To stop: kill $(cat .prisma-dev.pid)"
  fi
  echo "     To restart: bunx prisma dev"
  echo ""
  echo "  3. Start your app:"
fi
echo "     npm run dev"
echo ""
