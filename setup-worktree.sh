#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: ./setup-worktree.sh [OPTIONS]

Bootstrap a new git worktree (optimized for Linux/WSL):
  - Copies environment files from the primary worktree
  - Installs dependencies for backend/frontend projects
  - Builds backend/frontend projects (backend supports uv)

Options:
  --main-dir PATH      Explicit path to the primary worktree
  --backend-dir PATH   Explicit backend directory (can be repeated)
  --frontend-dir PATH  Explicit frontend directory (can be repeated)
  --force-env          Overwrite existing env files in this worktree
  --skip-install       Skip dependency installation
  --skip-build         Skip build step
  --dry-run            Print planned actions without executing
  -h, --help           Show this help message
USAGE
}

log() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup][warn] %s\n' "$*" >&2; }
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    eval "$@"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    warn "Missing required command: $cmd"
    return 1
  }
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

detect_package_manager() {
  local dir="$1"
  if [[ -f "$dir/pnpm-lock.yaml" ]] && command -v pnpm >/dev/null 2>&1; then
    echo "pnpm"
  elif [[ -f "$dir/yarn.lock" ]] && command -v yarn >/dev/null 2>&1; then
    echo "yarn"
  elif [[ -f "$dir/package-lock.json" ]] && command -v npm >/dev/null 2>&1; then
    echo "npm"
  elif command -v npm >/dev/null 2>&1; then
    echo "npm"
  else
    echo ""
  fi
}

has_uv_project() {
  local dir="$1"
  [[ -f "$dir/pyproject.toml" || -f "$dir/uv.lock" ]]
}

install_and_build_node_project() {
  local dir="$1"
  local label="$2"

  if [[ ! -d "$dir" ]]; then
    warn "$label directory not found: $dir"
    return 0
  fi
  if [[ ! -f "$dir/package.json" ]]; then
    warn "$label has no package.json, skipping: $dir"
    return 0
  fi

  local pm
  pm="$(detect_package_manager "$dir")"
  if [[ -z "$pm" ]]; then
    warn "No Node package manager found for $label at $dir"
    return 1
  fi

  log "$label: using $pm in $dir"

  if [[ "$SKIP_INSTALL" != "true" ]]; then
    case "$pm" in
      pnpm) run_cmd "cd '$dir' && pnpm install --frozen-lockfile" ;;
      yarn) run_cmd "cd '$dir' && yarn install --frozen-lockfile" ;;
      npm) run_cmd "cd '$dir' && npm ci || npm install" ;;
    esac
  fi

  if [[ "$SKIP_BUILD" != "true" ]]; then
    run_cmd "cd '$dir' && $pm run build"
  fi
}

install_and_build_backend_project() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    warn "backend directory not found: $dir"
    return 0
  fi

  if has_uv_project "$dir"; then
    require_cmd uv >/dev/null
    log "backend: using uv in $dir"

    if [[ "$SKIP_INSTALL" != "true" ]]; then
      run_cmd "cd '$dir' && uv sync"
    fi

    if [[ "$SKIP_BUILD" != "true" ]]; then
      if [[ -f "$dir/Makefile" ]] && grep -qE '^[[:space:]]*build:' "$dir/Makefile"; then
        run_cmd "cd '$dir' && uv run make build"
      elif [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool.hatch.build\]' "$dir/pyproject.toml"; then
        run_cmd "cd '$dir' && uv run python -m build"
      else
        warn "backend build step is not explicitly configured in $dir (skipping build)"
      fi
    fi
    return 0
  fi

  if [[ -f "$dir/package.json" ]]; then
    install_and_build_node_project "$dir" "backend"
    return 0
  fi

  warn "backend has no uv/python or Node project metadata, skipping: $dir"
}

copy_env_files() {
  local source_root="$1"
  local target_root="$2"
  local copied=0

  local env_patterns=(
    ".env"
    ".env.local"
    ".env.development"
    ".env.production"
    ".env.staging"
  )

  for name in "${env_patterns[@]}"; do
    local src="$source_root/$name"
    local dst="$target_root/$name"

    if [[ -f "$src" ]]; then
      if [[ -f "$dst" && "$FORCE_ENV" != "true" ]]; then
        log "Keeping existing $name"
        continue
      fi
      run_cmd "cp '$src' '$dst'"
      ((copied+=1))
      log "Copied $name from $source_root"
    fi
  done

  if [[ "$copied" -eq 0 ]]; then
    warn "No env files copied. Ensure env files exist in: $source_root"
  fi
}

auto_detect_main_dir() {
  local current="$1"
  local first
  first="$(git worktree list --porcelain | awk '/^worktree / {print $2; exit}')"

  if [[ -n "$first" ]]; then
    echo "$first"
    return
  fi

  echo "$current"
}

auto_detect_component_dirs() {
  local root="$1"
  local kind="$2"
  case "$kind" in
    backend)
      for path in backend api server services/backend apps/backend; do
        [[ -d "$root/$path" ]] && echo "$root/$path"
      done
      ;;
    frontend)
      for path in frontend web client apps/frontend; do
        [[ -d "$root/$path" ]] && echo "$root/$path"
      done
      ;;
  esac
}

DRY_RUN="false"
FORCE_ENV="false"
SKIP_INSTALL="false"
SKIP_BUILD="false"
MAIN_DIR=""

BACKEND_DIRS=()
FRONTEND_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-dir)
      MAIN_DIR="$2"; shift 2 ;;
    --backend-dir)
      BACKEND_DIRS+=("$2"); shift 2 ;;
    --frontend-dir)
      FRONTEND_DIRS+=("$2"); shift 2 ;;
    --force-env)
      FORCE_ENV="true"; shift ;;
    --skip-install)
      SKIP_INSTALL="true"; shift ;;
    --skip-build)
      SKIP_BUILD="true"; shift ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      warn "Unknown option: $1"
      usage
      exit 1 ;;
  esac
done

require_cmd git >/dev/null

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

if [[ -z "$MAIN_DIR" ]]; then
  MAIN_DIR="$(auto_detect_main_dir "$ROOT_DIR")"
fi

if [[ ! -d "$MAIN_DIR" ]]; then
  warn "Main directory does not exist: $MAIN_DIR"
  exit 1
fi

if is_wsl; then
  log "Running inside WSL/Linux environment"
else
  warn "Not running in WSL; continuing with Linux-compatible setup"
fi

log "Current worktree: $ROOT_DIR"
log "Main directory: $MAIN_DIR"

copy_env_files "$MAIN_DIR" "$ROOT_DIR"

if [[ ${#BACKEND_DIRS[@]} -eq 0 ]]; then
  while IFS= read -r path; do BACKEND_DIRS+=("$path"); done < <(auto_detect_component_dirs "$ROOT_DIR" backend)
fi

if [[ ${#FRONTEND_DIRS[@]} -eq 0 ]]; then
  while IFS= read -r path; do FRONTEND_DIRS+=("$path"); done < <(auto_detect_component_dirs "$ROOT_DIR" frontend)
fi

if [[ ${#BACKEND_DIRS[@]} -eq 0 ]]; then
  warn "No backend directory detected. Pass --backend-dir PATH if needed."
fi
if [[ ${#FRONTEND_DIRS[@]} -eq 0 ]]; then
  warn "No frontend directory detected. Pass --frontend-dir PATH if needed."
fi

for backend in "${BACKEND_DIRS[@]}"; do
  install_and_build_backend_project "$backend"
done

for frontend in "${FRONTEND_DIRS[@]}"; do
  install_and_build_node_project "$frontend" "frontend"
done

log "Worktree setup complete."
