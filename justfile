# Claude Meter - development and release tasks.
# Run `just` to see the list, `just --show <recipe>` to read one.

widget_id      := "com.github.p3kj.claudemeter"
store_id       := "2348058"
store_edit_url := "https://store.kde.org/p/" + store_id + "/edit"
dist           := "dist"
rel            := "python3 tools/release.py"

set positional-arguments

# List the available recipes.
default:
    @just --list --unsorted

# Print the current version from metadata.json.
version:
    @{{rel}} version

# Validate metadata, config schema, shell scripts and QML (STRICT_QML=1 to enforce warnings).
lint:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0

    echo "==> metadata.json"
    python3 -c 'import json; json.load(open("metadata.json"))' || failed=1

    echo "==> contents/config/main.xml"
    python3 -c 'import xml.etree.ElementTree as e; e.parse("contents/config/main.xml")' || failed=1

    echo "==> shell scripts"
    for script in install.sh contents/scripts/fetch_usage.sh; do
        bash -n "$script" || failed=1
    done

    echo "==> qml"
    mapfile -t qml < <(find contents -name '*.qml' | sort)
    if command -v qmlformat >/dev/null; then
        # qmlformat is a pure parser: it fails on syntax errors and, unlike
        # qmllint, says nothing about unresolvable org.kde.plasma imports.
        for file in "${qml[@]}"; do
            qmlformat "$file" >/dev/null || { echo "syntax error in $file" >&2; failed=1; }
        done
    fi
    if command -v qmllint >/dev/null; then
        output="$(qmllint "${qml[@]}" 2>&1)"
        status=$?
        if [ -n "$output" ]; then echo "$output"; fi
        if [ "$status" -ne 0 ]; then
            if [ "${STRICT_QML:-0}" = 1 ]; then
                failed=1
            else
                # Plasma applets cannot be fully type-checked outside plasmashell
                # (the org.kde.plasma imports live in plugin paths qmllint does
                # not see), so warnings are advisory by default.
                echo "qmllint reported issues (advisory; STRICT_QML=1 to enforce)" >&2
            fi
        fi
    else
        echo "qmllint not installed, skipping" >&2
    fi

    if [ "$failed" -ne 0 ]; then
        echo "lint FAILED" >&2
        exit 1
    fi
    echo "lint OK"

# Build dist/claudemeter-<version>.plasmoid (plus a stable-named copy).
package:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$({{rel}} version)"
    asset="{{dist}}/claudemeter-$version.plasmoid"
    {{rel}} package "$version" "$asset" >/dev/null
    cp -f "$asset" "{{dist}}/{{widget_id}}.plasmoid"
    ls -lh "$asset" "{{dist}}/{{widget_id}}.plasmoid"

# Lint and build without touching git. Safe to run any time.
check: lint package

# Install or update the widget in the local Plasma session.
install:
    bash install.sh

# Install, then restart plasmashell so it stops running the cached old QML.
reinstall: install
    #!/usr/bin/env bash
    set -euo pipefail
    if systemctl --user is-active --quiet plasma-plasmashell.service; then
        echo "Restarting plasmashell (drops the stale QML cache)..."
        systemctl --user restart plasma-plasmashell.service
    elif command -v kquitapp6 >/dev/null; then
        kquitapp6 plasmashell && (setsid kstart plasmashell >/dev/null 2>&1 &)
    else
        echo "Restart plasmashell yourself, or the panel keeps the old QML." >&2
    fi

# Remove the widget from the local Plasma session.
uninstall:
    kpackagetool6 -t Plasma/Applet -r {{widget_id}}

# Open the widget in a standalone window for testing.
run:
    plasmawindowed {{widget_id}}

# Add a bullet to the "## Unreleased" section of CHANGELOG.md.
note text:
    #!/usr/bin/env bash
    set -euo pipefail
    {{rel}} note "$1"
    git --no-pager diff -- CHANGELOG.md

# Cut a release: bump, changelog, package, tag, push, GitHub release, store handoff.
release bump="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    # Usage: just release [patch|minor|major|X.Y.Z]
    # DRY_RUN=1 does everything locally but skips the push, the GitHub release
    # and the browser handoff.

    bump="$1"
    dry="${DRY_RUN:-0}"
    step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
    die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }
    run()  { if [ "$dry" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

    step "Preflight"
    for tool in git gh python3; do
        command -v "$tool" >/dev/null || die "$tool is not installed"
    done
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = master ] || die "on branch '$branch'; releases are cut from master"
    # CHANGELOG.md is exempt: `just note` leaves it dirty on purpose and the
    # release commit picks it up. Untracked files elsewhere in the repo (design
    # sources and the like) cannot affect the release, so they are ignored too.
    dirty="$(git status --porcelain --untracked-files=no -- . ':(exclude)CHANGELOG.md')"
    if [ -n "$dirty" ]; then
        printf '%s\n' "$dirty" >&2
        die "uncommitted changes to tracked files; commit or stash them first"
    fi
    # An untracked file inside the packaged set would ship to the store without
    # ever being committed, which is the one case worth blocking on.
    stowaways="$(git ls-files --others --exclude-standard -- contents metadata.json icon.png LICENSE)"
    if [ -n "$stowaways" ]; then
        printf '%s\n' "$stowaways" >&2
        die "these would be packaged but are not in git; 'git add' them first"
    fi
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
    git fetch --quiet --tags origin
    behind="$(git rev-list --count HEAD..origin/master)"
    [ "$behind" -eq 0 ] || die "master is $behind commit(s) behind origin; pull first"
    echo "  master, no stray changes, in sync with origin"

    current="$({{rel}} version)"
    version="$({{rel}} next "$bump")"
    tag="v$version"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        die "tag $tag already exists locally"
    fi
    if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
        die "tag $tag already exists on origin"
    fi
    # Validates the changelog before anything is written.
    notes="$({{rel}} unreleased)"

    step "Lint"
    just lint

    step "Preview"
    echo "  version : $current -> $version"
    echo "  tag     : $tag"
    echo "  notes   :"
    printf '%s\n' "$notes" | sed 's/^/            /'
    if [ "$dry" = 1 ]; then
        echo "  (DRY_RUN=1: no push, no GitHub release, no browser)"
    fi

    printf '\nRelease %s? [y/N] ' "$tag"
    read -r reply
    case "$reply" in
        [yY]*) ;;
        *) die "aborted, nothing changed" ;;
    esac

    trap 'printf "\n\033[1;31mrelease failed\033[0m - undo local edits with: git restore metadata.json CHANGELOG.md\n" >&2' ERR

    step "Bump"
    {{rel}} bump "$version"
    mkdir -p {{dist}}
    {{rel}} promote "$version" > "{{dist}}/notes-$version.md"

    step "Package"
    asset="{{dist}}/claudemeter-$version.plasmoid"
    {{rel}} package "$version" "$asset" >/dev/null
    cp -f "$asset" "{{dist}}/{{widget_id}}.plasmoid"

    step "Commit and tag"
    git add metadata.json CHANGELOG.md
    git commit -q -m "Release $tag"
    git tag -a "$tag" -m "$tag"
    git --no-pager log -1 --oneline
    # From here the commit exists, so `git restore` is the wrong advice.
    trap 'printf "\n\033[1;31mrelease failed after committing\033[0m - undo with: git tag -d %s && git reset --hard HEAD~1\n" "$tag" >&2' ERR

    step "Push"
    run git push --quiet origin master
    run git push --quiet origin "$tag"

    step "GitHub release"
    run gh release create "$tag" --verify-tag --latest \
        --title "$tag" \
        --notes-file "{{dist}}/notes-$version.md" \
        "$asset"

    step "KDE Store"
    store_file="$(realpath "{{dist}}/{{widget_id}}.plasmoid")"
    if command -v wl-copy >/dev/null; then
        # wl-copy daemonises to serve the selection; without closing its stdout
        # it holds the pipe open and anything reading this output never sees EOF.
        wl-copy < "{{dist}}/notes-$version.md" >/dev/null 2>&1
        echo "  release notes are on the clipboard"
    fi
    echo "  file    : $store_file"
    echo "  version : $version"
    echo "  page    : {{store_edit_url}}"
    if [ "$dry" != 1 ] && command -v xdg-open >/dev/null; then
        xdg-open "{{store_edit_url}}" >/dev/null 2>&1 &
        xdg-open "$(realpath {{dist}})" >/dev/null 2>&1 &
    fi
    printf '%s\n' \
        "" \
        "  The KDE Store has no write API, so this last bit is manual:" \
        "    1. upload the .plasmoid shown above" \
        "    2. set the version field" \
        "    3. paste the changelog (already on your clipboard)" \
        "    4. save"

# One-shot repair of the pre-automation history (tags + releases for past versions).
backfill:
    #!/usr/bin/env bash
    set -euo pipefail
    # Creates the never-made v0.3.0 / v0.3.1 tags and a GitHub release, with a
    # rebuilt .plasmoid, for every version that predates this automation.

    # Commits carrying each untagged version, from `git show <sha>:metadata.json`.
    declare -A missing=( [v0.3.0]=a1023b1 [v0.3.1]=fedd5df )
    for tag in v0.3.0 v0.3.1; do
        if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            echo "tag $tag exists, skipping"
        else
            git tag -a "$tag" "${missing[$tag]}" -m "$tag"
            echo "created annotated tag $tag at ${missing[$tag]}"
        fi
        git push --quiet origin "$tag"
    done

    tmp="$(mktemp -d)"
    trap 'git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

    # Ascending order, so GitHub ends up with the newest marked as latest.
    for tag in v0.1.0 v0.2.0 v0.3.0 v0.3.1 v0.4.0; do
        version="${tag#v}"
        if gh release view "$tag" >/dev/null 2>&1; then
            echo "release $tag exists, skipping"
            continue
        fi
        git worktree add --quiet --detach "$tmp/wt" "$tag"
        asset="$tmp/claudemeter-$version.plasmoid"
        {{rel}} --root "$tmp/wt" package "$version" "$asset" >/dev/null
        {{rel}} extract "$version" > "$tmp/notes-$version.md"
        latest=false
        if [ "$tag" = v0.4.0 ]; then latest=true; fi
        gh release create "$tag" --verify-tag --latest="$latest" \
            --title "$tag" \
            --notes-file "$tmp/notes-$version.md" \
            "$asset"
        git worktree remove --force "$tmp/wt"
    done
