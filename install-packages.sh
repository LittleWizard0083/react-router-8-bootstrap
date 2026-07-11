#!/usr/bin/env bash
# ==============================================================================
# install-packages.sh — Package installation only (no Prisma dev server)
#
# This script installs npm/bun packages without attempting to start the
# Prisma development database server. Use this when:
#   - You want to install packages independently
#   - You're providing your own DATABASE_URL (via `bunx prisma dev`)
#   - You want to skip database setup and manage it separately
#
# Usage:
#   ./install-packages.sh              # uses npm
#   ./install-packages.sh bun          # uses bun (recommended)
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

# Verify prerequisites
require_cmd node
require_cmd npm

banner "Package Installation" "React Router 8 stack"

# Check for package.json
if [[ ! -f package.json ]]; then
  err "package.json not found in $(pwd)"
  err "Run this script in your React Router project directory."
  exit 1
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

echo ""
printf "  %s%s%s\n" "$c_green" "✔ Package installation complete!" "$c_reset"
echo ""
echo "  Next steps:"
echo "  ────────────────────────────────────────────"
echo "  1. Start Prisma local database (in a separate terminal):"
echo "     bunx prisma dev"
echo ""
echo "  2. Copy the connection strings from the output above:"
echo "     DATABASE_URL=\"postgres://...\""
echo "     SHADOW_DATABASE_URL=\"postgres://...\""
echo ""
echo "  3. Add them to your .env file:"
echo "     echo 'DATABASE_URL=\"<paste-here>\"' >> .env"
echo "     echo 'SHADOW_DATABASE_URL=\"<paste-here>\"' >> .env"
echo ""
echo "  4. Then run the database setup:"
echo "     bunx prisma migrate dev --name init"
echo "     bunx prisma generate"
echo ""
echo "  5. Fill in remaining .env variables:"
echo "     BETTER_AUTH_SECRET (run: openssl rand -base64 32)"
echo "     RESEND_API_KEY"
echo "     STRIPE_SECRET_KEY"
echo ""
